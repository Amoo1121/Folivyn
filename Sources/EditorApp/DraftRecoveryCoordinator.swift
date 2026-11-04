import Foundation
import EditorCore

/// Captured from the one editable buffer on the main actor. Origin and encoding
/// are recovery hints; this coordinator never reads or writes the origin path.
struct DraftRecoveryContent: Sendable {
    let text: String
    let originPath: String?
    let encodingHint: TextFileEncoding?
    let selection: DraftRecoverySelection

    init(text: String, originPath: String? = nil, encodingHint: TextFileEncoding? = nil,
         selection: DraftRecoverySelection = .init()) {
        self.text = text; self.originPath = originPath; self.encodingHint = encodingHint; self.selection = selection
    }
}

/// Injectable asynchronous storage operations. A coordinator exclusively owns
/// its store; other callers must not write generations into the same instance.
struct DraftRecoveryBackend: Sendable {
    var save: @Sendable (DraftRecoverySnapshot) async throws -> Void
    var discard: @Sendable (UUID, UInt64) async throws -> Void
    var scan: @Sendable () async throws -> DraftRecoveryScan
    var discardRecovered: @Sendable (DraftRecoveryReference) async throws -> Void
    var close: @Sendable () async -> Void

    init(store: DraftRecoveryStore) {
        save = { try await store.save($0) }
        discard = { try await store.discard(documentID: $0, throughGeneration: $1) }
        scan = { try await store.scan() }
        discardRecovered = { try await store.discardRecovered($0) }
        close = { await store.close() }
    }

    init(save: @escaping @Sendable (DraftRecoverySnapshot) async throws -> Void,
         discard: @escaping @Sendable (UUID, UInt64) async throws -> Void,
         scan: @escaping @Sendable () async throws -> DraftRecoveryScan,
         discardRecovered: @escaping @Sendable (DraftRecoveryReference) async throws -> Void,
         close: @escaping @Sendable () async -> Void) {
        self.save = save; self.discard = discard; self.scan = scan
        self.discardRecovered = discardRecovered; self.close = close
    }
}

@MainActor
final class DraftRecoveryCoordinator {
    enum CoordinatorError: Error { case finishing, generationExhausted }
    enum Operation: Sendable { case save, discard, scan, claim, recoveryCleanup }
    struct Issue: Sendable {
        let documentID: UUID?
        let operation: Operation
        let error: Error
    }
    enum Event {
        case persisted(documentID: UUID, generation: UInt64)
        case cleared(documentID: UUID, generation: UInt64)
        case issue(Issue)
        case closed
    }
    enum DrainResult {
        case completed
        case failed([Issue])
        case timedOut
    }
    struct ClaimResult: Sendable {
        let snapshot: DraftRecoverySnapshot
        /// Failure here leaves both copies. The new snapshot is still durable.
        let cleanupIssue: Issue?
    }

    typealias SnapshotProvider = @MainActor (UUID) -> DraftRecoveryContent?
    private enum Action { case capture, discard }
    private struct Pending {
        let action: Action
        let generation: UInt64
        let firstRequested: ContinuousClock.Instant
        var readyAt: ContinuousClock.Instant
        var busyRetries = 0
    }
    private enum QueueEntry { case document(UUID), request(UUID) }
    private enum Request {
        case scan(CheckedContinuation<DraftRecoveryScan, Error>)
        case claim(RecoveredDraft, DraftRecoverySnapshot, CheckedContinuation<ClaimResult, Error>)
        case discardRecovered(DraftRecoveryReference, CheckedContinuation<Void, Error>)
    }
    private enum Work: Sendable {
        case save(DraftRecoverySnapshot)
        case discard(UUID, UInt64)
        case scan(UUID)
        case claim(UUID, RecoveredDraft, DraftRecoverySnapshot)
        case discardRecovered(UUID, DraftRecoveryReference)
        case close
    }
    private enum WorkResult: Sendable {
        case mutation(Result<Void, Error>)
        case scan(Result<DraftRecoveryScan, Error>)
        case claim(Result<ClaimResult, Error>)
        case closed
    }
    private struct Waiter {
        let continuation: CheckedContinuation<DrainResult, Never>
        let deadline: Task<Void, Never>
    }

    private let backend: DraftRecoveryBackend
    private let snapshotProvider: SnapshotProvider
    private let debounce: Duration
    private let maximumDelay: Duration
    private let retryDelay: Duration
    private var pending: [UUID: Pending] = [:]
    private var failed: [UUID: (Pending, Issue)] = [:]
    private var generations: [UUID: UInt64] = [:]
    private var queue: [QueueEntry] = []
    private var requests: [UUID: Request] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var timer: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    // A timed-out quit wait must not deallocate queued discards while the
    // non-cancellable storage operation is still finishing.
    private var shutdownLifetime: DraftRecoveryCoordinator?
    private(set) var isFinishing = false
    private(set) var isFinished = false
    var isBusy: Bool { worker != nil || !queue.isEmpty }
    var onEvent: ((Event) -> Void)?

    init(backend: DraftRecoveryBackend, debounce: Duration = .milliseconds(750),
         maximumDelay: Duration = .seconds(5), retryDelay: Duration = .milliseconds(100),
         snapshotProvider: @escaping SnapshotProvider, onEvent: ((Event) -> Void)? = nil) {
        self.backend = backend; self.snapshotProvider = snapshotProvider; self.onEvent = onEvent
        self.debounce = max(.zero, debounce); self.maximumDelay = max(.zero, maximumDelay)
        self.retryDelay = max(.milliseconds(1), retryDelay)
    }

    convenience init(store: DraftRecoveryStore, debounce: Duration = .milliseconds(750),
                     maximumDelay: Duration = .seconds(5), snapshotProvider: @escaping SnapshotProvider,
                     onEvent: ((Event) -> Void)? = nil) {
        self.init(backend: .init(store: store), debounce: debounce, maximumDelay: maximumDelay,
                  snapshotProvider: snapshotProvider, onEvent: onEvent)
    }

    deinit {
        timer?.cancel()
        for waiter in waiters.values {
            waiter.deadline.cancel()
            waiter.continuation.resume(returning: .timedOut)
        }
    }

    /// Call for committed source edits (including undo/redo). No full-text copy
    /// is taken until the single worker is ready to start this document's save.
    @discardableResult
    func schedule(documentID: UUID) -> Bool {
        guard !isFinishing, let generation = nextGeneration(documentID) else { return false }
        let now = ContinuousClock.now
        let first = pending[documentID]?.firstRequested ?? now
        enqueue(documentID, pending: .init(action: .capture, generation: generation, firstRequested: first,
            readyAt: min(now.advanced(by: debounce), first.advanced(by: maximumDelay))))
        pump()
        return true
    }

    /// Call only after a real save/reload/close decision succeeded. Cancelling
    /// a panel or failing to save must not clear the last recoverable snapshot.
    @discardableResult
    func clear(documentID: UUID) -> Bool {
        guard !isFinishing, let generation = nextGeneration(documentID) else { return false }
        let now = ContinuousClock.now
        enqueue(documentID, pending: .init(action: .discard, generation: generation, firstRequested: now, readyAt: now))
        pump()
        return true
    }

    /// Forces all queued captures and retries prior failed decisions once.
    /// Does not cancel an in-flight filesystem operation on timeout. New edits
    /// remain accepted and may keep the drain busy until the deadline.
    func flush(timeout: Duration = .seconds(3)) async -> DrainResult {
        if isFinished { return drainResult() }
        forcePending()
        pump()
        return await waitForDrain(timeout: timeout)
    }

    /// Irreversible shutdown after the app has accepted its close decisions.
    /// Late edits/clears are refused. The store closes only after its worker and
    /// queue really finish, even if this bounded wait has already timed out.
    /// A failed result must be surfaced: it is not proof that a discard reached disk.
    func finish(timeout: Duration = .seconds(3)) async -> DrainResult {
        if isFinished { return drainResult() }
        isFinishing = true
        shutdownLifetime = self
        forcePending()
        pump()
        return await waitForDrain(timeout: timeout)
    }

    func scan() async throws -> DraftRecoveryScan {
        guard !isFinishing else { throw CoordinatorError.finishing }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            requests[id] = .scan(continuation); queue.append(.request(id)); pump()
        }
    }

    /// The caller must use documentID for the new independent EditorSession.
    /// A queued claim runs to completion once accepted; cancellation of its
    /// awaiting UI task must not be treated as confirmation that no copy exists.
    func claim(_ recovered: RecoveredDraft, as documentID: UUID) async throws -> ClaimResult {
        guard !isFinishing else { throw CoordinatorError.finishing }
        guard let generation = nextGeneration(documentID) else { throw CoordinatorError.generationExhausted }
        let old = recovered.snapshot
        let snapshot = DraftRecoverySnapshot(documentID: documentID, generation: generation, text: old.text,
            originPath: old.originPath, encodingHint: old.encodingHint, selection: old.selection, updatedAt: old.updatedAt)
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            requests[id] = .claim(recovered, snapshot, continuation); queue.append(.request(id)); pump()
        }
    }

    /// Explicitly discards only a reference returned by scan. Uses the same
    /// worker and the store's exact reference validation as recovery claims.
    func discardRecovered(_ reference: DraftRecoveryReference) async throws {
        guard !isFinishing else { throw CoordinatorError.finishing }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            requests[id] = .discardRecovered(reference, continuation); queue.append(.request(id)); pump()
        }
    }

    private func nextGeneration(_ id: UUID) -> UInt64? {
        let old = generations[id] ?? 0
        guard old < UInt64.max else {
            onEvent?(.issue(.init(documentID: id, operation: .save, error: CoordinatorError.generationExhausted)))
            return nil
        }
        generations[id] = old + 1
        return old + 1
    }

    private func enqueue(_ id: UUID, pending decision: Pending) {
        if pending[id] == nil { queue.append(.document(id)) }
        pending[id] = decision
        failed[id] = nil
    }

    private func forcePending() {
        let now = ContinuousClock.now
        for (id, value) in failed where generations[id] == value.0.generation && pending[id] == nil {
            var decision = value.0; decision.readyAt = now; decision.busyRetries = 0
            enqueue(id, pending: decision)
        }
        for id in pending.keys { pending[id]?.readyAt = now }
    }

    private func pump() {
        guard worker == nil, !isFinished else { return }
        timer?.cancel(); timer = nil
        let now = ContinuousClock.now
        while let index = queue.firstIndex(where: { entry in
            switch entry {
            case .request: return true
            case .document(let id): return pending[id].map { $0.readyAt <= now } ?? true
            }
        }) {
            let entry = queue.remove(at: index)
            switch entry {
            case .request(let id):
                guard let request = requests[id] else { continue }
                switch request {
                case .scan: start(.scan(id))
                case .claim(let old, let snapshot, _): start(.claim(id, old, snapshot))
                case .discardRecovered(let reference, _): start(.discardRecovered(id, reference))
                }
                return
            case .document(let id):
                guard let decision = pending.removeValue(forKey: id) else { continue }
                switch decision.action {
                case .discard: start(.discard(id, decision.generation), decision: decision); return
                case .capture:
                    guard let content = snapshotProvider(id) else {
                        // Marked text or temporarily unavailable sessions must
                        // never silently delete their previously durable draft.
                        if generations[id] == decision.generation {
                            var deferred = decision; deferred.readyAt = now.advanced(by: retryDelay)
                            enqueue(id, pending: deferred)
                        }
                        continue
                    }
                    guard generations[id] == decision.generation else { continue }
                    let snapshot = DraftRecoverySnapshot(documentID: id, generation: decision.generation,
                        text: content.text, originPath: content.originPath, encodingHint: content.encodingHint,
                        selection: content.selection)
                    start(.save(snapshot), decision: decision)
                    return
                }
            }
        }
        if queue.isEmpty {
            if isFinishing { start(.close) }
            else { resolveWaiters() }
        } else if let deadline = pending.values.map(\.readyAt).min() {
            timer = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: max(.zero, ContinuousClock.now.duration(to: deadline))) }
                catch { return }
                self?.pump()
            }
        }
    }

    private func start(_ work: Work, decision: Pending? = nil) {
        let backend = backend
        worker = Task.detached(priority: .utility) { [weak self] in
            let result: WorkResult
            switch work {
            case .save(let snapshot):
                do { try await backend.save(snapshot); result = .mutation(.success(())) }
                catch { result = .mutation(.failure(error)) }
            case .discard(let id, let generation):
                do { try await backend.discard(id, generation); result = .mutation(.success(())) }
                catch { result = .mutation(.failure(error)) }
            case .scan:
                do { result = .scan(.success(try await backend.scan())) }
                catch { result = .scan(.failure(error)) }
            case .claim(_, let old, let snapshot):
                do {
                    try await backend.save(snapshot)
                    var cleanupIssue: Issue?
                    do { try await backend.discardRecovered(old.reference) }
                    catch { cleanupIssue = .init(documentID: snapshot.documentID, operation: .recoveryCleanup, error: error) }
                    result = .claim(.success(.init(snapshot: snapshot, cleanupIssue: cleanupIssue)))
                } catch { result = .claim(.failure(error)) }
            case .discardRecovered(_, let reference):
                do { try await backend.discardRecovered(reference); result = .mutation(.success(())) }
                catch { result = .mutation(.failure(error)) }
            case .close: await backend.close(); result = .closed
            }
            await self?.completed(work, result: result, decision: decision)
        }
    }

    private func completed(_ work: Work, result: WorkResult, decision: Pending?) {
        worker = nil
        switch (work, result) {
        case (.save(let snapshot), .mutation(let result)):
            finishMutation(snapshot.documentID, generation: snapshot.generation, operation: .save, result: result, decision: decision)
        case (.discard(let id, let generation), .mutation(let result)):
            finishMutation(id, generation: generation, operation: .discard, result: result, decision: decision)
        case (.scan(let id), .scan(let result)):
            if case .failure(let error) = result { onEvent?(.issue(.init(documentID: nil, operation: .scan, error: error))) }
            if case .scan(let continuation) = requests.removeValue(forKey: id) { continuation.resume(with: result) }
        case (.claim(let id, _, let snapshot), .claim(let result)):
            if case .claim(_, _, let continuation) = requests.removeValue(forKey: id) {
                switch result {
                case .success(let claim):
                    if generations[snapshot.documentID] == snapshot.generation {
                        onEvent?(.persisted(documentID: snapshot.documentID, generation: snapshot.generation))
                    }
                    if let issue = claim.cleanupIssue { onEvent?(.issue(issue)) }
                case .failure(let error): onEvent?(.issue(.init(documentID: snapshot.documentID, operation: .claim, error: error)))
                }
                continuation.resume(with: result)
            }
        case (.discardRecovered(let id, let reference), .mutation(let result)):
            if case .failure(let error) = result {
                onEvent?(.issue(.init(documentID: reference.documentID, operation: .recoveryCleanup, error: error)))
            }
            if case .discardRecovered(_, let continuation) = requests.removeValue(forKey: id) { continuation.resume(with: result) }
        case (.close, .closed):
            isFinished = true; onEvent?(.closed); resolveWaiters(); shutdownLifetime = nil
        default: assertionFailure("Recovery worker result does not match its operation")
        }
        pump()
    }

    private func finishMutation(_ id: UUID, generation: UInt64, operation: Operation,
                                result: Result<Void, Error>, decision: Pending?) {
        guard generations[id] == generation else { return }
        switch result {
        case .success:
            failed[id] = nil
            onEvent?(operation == .save ? .persisted(documentID: id, generation: generation) : .cleared(documentID: id, generation: generation))
        case .failure(let error):
            if error as? DraftRecoveryError == .storeBusy, var decision, decision.busyRetries < 3 {
                decision.busyRetries += 1; decision.readyAt = ContinuousClock.now.advanced(by: retryDelay)
                enqueue(id, pending: decision)
                return
            }
            let issue = Issue(documentID: id, operation: operation, error: error)
            if let decision { failed[id] = (decision, issue) }
            onEvent?(.issue(issue))
        }
    }

    private func waitForDrain(timeout: Duration) async -> DrainResult {
        if !isBusy && (!isFinishing || isFinished) { return drainResult() }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            let deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: max(.zero, timeout)) }
                catch { return }
                self?.waiters.removeValue(forKey: id)?.continuation.resume(returning: .timedOut)
            }
            waiters[id] = .init(continuation: continuation, deadline: deadline)
        }
    }

    private func drainResult() -> DrainResult {
        failed.isEmpty ? .completed : .failed(failed.values.map(\.1))
    }

    private func resolveWaiters() {
        let result = drainResult()
        let completed = waiters; waiters.removeAll()
        for waiter in completed.values {
            waiter.deadline.cancel(); waiter.continuation.resume(returning: result)
        }
    }
}
