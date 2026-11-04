import Darwin
import Foundation
import EditorCore
import XCTest
@testable import EditorApp

final class DraftRecoveryCoordinatorTests: XCTestCase {
    @MainActor
    func testBlockedWriterCoalescesEditsAndPublishesOnlyNewestGeneration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        await gate.setBlocking(true)
        let id = UUID()
        var content = DraftRecoveryContent(text: "first")
        var captures = 0, published: [UInt64] = []
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, debounce: .zero, snapshotProvider: { requested in
            XCTAssertEqual(requested, id); XCTAssertTrue(Thread.isMainThread)
            captures += 1; return content
        }, onEvent: { if case .persisted(_, let generation) = $0 { published.append(generation) } })
        coordinator.schedule(documentID: id)
        try await waitUntil { await gate.saveCount == 1 }
        for index in 1...100 {
            content = .init(text: "latest \(index) 中文 🦊", selection: .init(location: 0, length: 2))
            coordinator.schedule(documentID: id)
        }
        XCTAssertEqual(captures, 1, "Queued keystrokes must not copy the full buffer")
        await gate.release(1)
        try await waitUntil { await gate.saveCount == 2 }
        XCTAssertEqual(captures, 2)
        await gate.releaseAll()
        assertCompleted(await coordinator.flush())
        XCTAssertEqual(published, [101], "The first write completed after newer decisions and must not publish stale status")
        let stats = await gate.stats()
        XCTAssertEqual(stats.maximumConcurrent, 1)
        XCTAssertFalse(stats.onMainThread)
        XCTAssertEqual(stats.saves.map(\.text), ["first", "latest 100 中文 🦊"])
        assertCompleted(await coordinator.finish())
        let scan = try await fixture.scanAfterClose()
        XCTAssertEqual(scan.drafts.count, 1)
        XCTAssertEqual(scan.drafts.first?.snapshot.generation, 101)
        XCTAssertEqual(scan.drafts.first?.snapshot.text, content.text)
    }

    @MainActor
    func testClearAfterAnInFlightSaveSupersedesQueuedEditsAndCannotResurrect() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        await gate.setBlocking(true)
        let id = UUID()
        var content: DraftRecoveryContent? = .init(text: "unsaved")
        var cleared: [UInt64] = [], persisted: [UInt64] = []
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, debounce: .zero, snapshotProvider: { _ in content }, onEvent: {
            if case .cleared(_, let value) = $0 { cleared.append(value) }
            if case .persisted(_, let value) = $0 { persisted.append(value) }
        })
        coordinator.schedule(documentID: id)
        try await waitUntil { await gate.saveCount == 1 }
        coordinator.schedule(documentID: id)
        coordinator.clear(documentID: id)
        content = nil // The tab has actually closed.
        await gate.releaseAll()
        assertCompleted(await coordinator.flush())
        XCTAssertEqual(cleared, [3]); XCTAssertTrue(persisted.isEmpty)
        let stats = await gate.stats()
        XCTAssertEqual(stats.saves.count, 1)
        XCTAssertEqual(stats.discards.map(\.1), [3])
        assertCompleted(await coordinator.finish())
        let scan = try await fixture.scanAfterClose()
        XCTAssertTrue(scan.drafts.isEmpty)
    }

    @MainActor
    func testClearingDebouncedCaptureDoesNotTakeOrWriteSnapshot() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        var captures = 0
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, debounce: .seconds(1), snapshotProvider: { _ in
            captures += 1; return .init(text: "should not be captured")
        })
        let id = UUID()
        coordinator.schedule(documentID: id)
        coordinator.clear(documentID: id)
        assertCompleted(await coordinator.flush())
        XCTAssertEqual(captures, 0)
        let stats = await gate.stats()
        XCTAssertTrue(stats.saves.isEmpty)
        XCTAssertEqual(stats.discards.count, 1)
        assertCompleted(await coordinator.finish())
    }

    @MainActor
    func testEditAfterSuccessfulSaveDecisionSupersedesPendingClear() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        await gate.setBlocking(true)
        let id = UUID()
        var content = DraftRecoveryContent(text: "before save")
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, debounce: .zero, snapshotProvider: { _ in content })
        coordinator.schedule(documentID: id)
        try await waitUntil { await gate.saveCount == 1 }
        coordinator.clear(documentID: id)
        content = .init(text: "new edit after saving")
        coordinator.schedule(documentID: id)
        await gate.releaseAll()
        assertCompleted(await coordinator.finish())
        let scan = try await fixture.scanAfterClose()
        XCTAssertEqual(scan.drafts.first?.snapshot.text, content.text)
        XCTAssertEqual(scan.drafts.first?.snapshot.generation, 3)
        let stats = await gate.stats()
        XCTAssertEqual(stats.maximumConcurrent, 1)
    }

    @MainActor
    func testMaximumDebounceWindowMakesProgressDuringContinuousEdits() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        let id = UUID()
        var content = DraftRecoveryContent(text: "0")
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, debounce: .milliseconds(80),
            maximumDelay: .milliseconds(120), snapshotProvider: { _ in content })
        for index in 0..<12 {
            content = .init(text: "\(index)")
            coordinator.schedule(documentID: id)
            try await Task.sleep(for: .milliseconds(20))
        }
        let savesWhileTyping = await gate.saveCount
        XCTAssertGreaterThan(savesWhileTyping, 0, "Continuous input must not postpone every write until typing stops")
        assertCompleted(await coordinator.finish())
        let scan = try await fixture.scanAfterClose()
        XCTAssertEqual(scan.drafts.first?.snapshot.text, "11")
    }

    @MainActor
    func testUnavailableSnapshotTimesOutWithoutClearingPreviousData() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        let id = UUID()
        var content: DraftRecoveryContent? = .init(text: "durable committed text")
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, debounce: .zero, retryDelay: .milliseconds(5),
            snapshotProvider: { _ in content })
        coordinator.schedule(documentID: id)
        assertCompleted(await coordinator.flush())
        content = nil // Example: an active IME composition is not yet committed.
        coordinator.schedule(documentID: id)
        assertTimedOut(await coordinator.flush(timeout: .milliseconds(25)))
        let deferredStats = await gate.stats()
        XCTAssertTrue(deferredStats.discards.isEmpty)
        content = .init(text: "committed 中文")
        coordinator.schedule(documentID: id)
        assertCompleted(await coordinator.finish())
        let scan = try await fixture.scanAfterClose()
        XCTAssertEqual(scan.drafts.first?.snapshot.text, "committed 中文")
    }

    @MainActor
    func testFailedWriteIsReportedAndExplicitFlushRetriesSameGeneration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        await gate.setSaveErrors([.snapshotLimit])
        var issues = 0
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, debounce: .zero,
            snapshotProvider: { _ in .init(text: "retry me") }, onEvent: { if case .issue = $0 { issues += 1 } })
        coordinator.schedule(documentID: UUID())
        guard case .failed(let failures) = await coordinator.flush() else { return XCTFail("Expected failed drain") }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.error as? DraftRecoveryError, .snapshotLimit)
        XCTAssertEqual(issues, 1)
        assertCompleted(await coordinator.flush())
        let retryStats = await gate.stats()
        XCTAssertEqual(retryStats.saves.map(\.generation), [1, 1])
        assertCompleted(await coordinator.finish())
    }

    @MainActor
    func testTransientStoreContentionRetriesWithoutParallelWriters() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        await gate.setSaveErrors([.storeBusy, .storeBusy, .storeBusy])
        var issues = 0
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, debounce: .zero, retryDelay: .milliseconds(5),
            snapshotProvider: { _ in .init(text: "eventually durable") }, onEvent: { if case .issue = $0 { issues += 1 } })
        coordinator.schedule(documentID: UUID())
        assertCompleted(await coordinator.flush())
        let stats = await gate.stats()
        XCTAssertEqual(stats.saves.count, 4)
        XCTAssertEqual(stats.maximumConcurrent, 1)
        XCTAssertEqual(issues, 0)
        assertCompleted(await coordinator.finish())
    }

    @MainActor
    func testFinishDeadlineDoesNotWaitForNoncooperativeWriterOrReleaseLockEarly() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        await gate.setBlocking(true)
        var coordinator: DraftRecoveryCoordinator? = .init(backend: gate.backend, debounce: .zero,
            snapshotProvider: { _ in .init(text: "will be discarded") })
        let id = UUID()
        coordinator?.schedule(documentID: id)
        try await waitUntil { await gate.saveCount == 1 }
        coordinator?.clear(documentID: id)
        let start = ContinuousClock.now
        assertTimedOut(await coordinator!.finish(timeout: .milliseconds(30)))
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertFalse(coordinator!.schedule(documentID: id))
        XCTAssertFalse(coordinator!.clear(documentID: id))
        let waitingStats = await gate.stats()
        XCTAssertEqual(waitingStats.closeCount, 0)
        let reader = try DraftRecoveryStore(directory: fixture.root)
        let active = try await reader.scan()
        XCTAssertEqual(active.activeInstanceCount, 1)
        await reader.close()
        let wasReleased = { [weak coordinator] in coordinator == nil }
        coordinator = nil
        XCTAssertFalse(wasReleased(), "Shutdown retains its queued discard after the bounded UI wait returns")
        await gate.releaseAll()
        try await waitUntil { await gate.stats().closeCount == 1 }
        try await waitUntil { wasReleased() }
        let scan = try await fixture.scanAfterClose()
        XCTAssertTrue(scan.drafts.isEmpty)
    }

    @MainActor
    func testClaimKeepsOldCopyUntilNewSnapshotSucceedsAndUsesNewDocumentID() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let old = try await fixture.makeRecoverableDraft()
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        await gate.setBlocking(true)
        await gate.setSaveErrors([.snapshotLimit])
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, snapshotProvider: { _ in nil })
        let scan = try await coordinator.scan()
        XCTAssertEqual(scan.drafts.count, 1)
        let id = UUID()
        let attempt = Task { @MainActor in try await coordinator.claim(old, as: id) }
        try await waitUntil { await gate.saveCount == 1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path(old.reference).path))
        let pendingStats = await gate.stats()
        XCTAssertEqual(pendingStats.cleanupCount, 0)
        await gate.releaseAll()
        do { _ = try await attempt.value; XCTFail("Expected failed new snapshot") }
        catch { XCTAssertEqual(error as? DraftRecoveryError, .snapshotLimit) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path(old.reference).path))
        let claim = try await coordinator.claim(old, as: id)
        XCTAssertNil(claim.cleanupIssue)
        XCTAssertEqual(claim.snapshot.documentID, id)
        XCTAssertEqual(claim.snapshot.generation, 2)
        XCTAssertTrue(claim.snapshot.text.utf16.elementsEqual(old.snapshot.text.utf16))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path(old.reference).path))
        assertCompleted(await coordinator.finish())
        let recovered = try await fixture.scanAfterClose()
        XCTAssertEqual(recovered.drafts.map(\.snapshot.documentID), [id])
        XCTAssertEqual(recovered.drafts.first?.snapshot.originPath, "/never/read/or/write/origin.txt")
    }

    @MainActor
    func testClaimCleanupFailureReportsIssueAndRetainsBothCopies() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let old = try await fixture.makeRecoverableDraft()
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        await gate.setCleanupError(.changedRecovery)
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, snapshotProvider: { _ in nil })
        let result = try await coordinator.claim(old, as: UUID())
        XCTAssertEqual(result.cleanupIssue?.error as? DraftRecoveryError, .changedRecovery)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path(old.reference).path))
        assertCompleted(await coordinator.finish())
        let scan = try await fixture.scanAfterClose()
        XCTAssertEqual(scan.drafts.count, 2)
        XCTAssertTrue(scan.drafts.allSatisfy { $0.snapshot.text.utf16.elementsEqual(old.snapshot.text.utf16) })
    }

    @MainActor
    func testScanAndCloseShareWriterQueueAndRepeatedFinishDoesNotCloseTwice() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        await gate.setBlocking(true)
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, debounce: .zero, snapshotProvider: { _ in .init(text: "draft") })
        coordinator.schedule(documentID: UUID())
        try await waitUntil { await gate.saveCount == 1 }
        let scanTask = Task { @MainActor in try await coordinator.scan() }
        try await Task.sleep(for: .milliseconds(10))
        let queuedStats = await gate.stats()
        XCTAssertEqual(queuedStats.scanCount, 0)
        await gate.releaseAll()
        _ = try await scanTask.value
        assertCompleted(await coordinator.finish())
        assertCompleted(await coordinator.finish())
        assertCompleted(await coordinator.flush())
        let stats = await gate.stats()
        XCTAssertEqual(stats.scanCount, 1); XCTAssertEqual(stats.closeCount, 1)
        XCTAssertEqual(stats.maximumConcurrent, 1)
        do { _ = try await coordinator.scan(); XCTFail("Closed coordinator accepted a scan") }
        catch { XCTAssertTrue(error is DraftRecoveryCoordinator.CoordinatorError) }
    }

    @MainActor
    func testExplicitRecoveredDiscardSharesWriterQueueAndPreservesOtherDrafts() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let old = try await fixture.makeRecoverableDraft()
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        await gate.setBlocking(true)
        let currentID = UUID()
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, debounce: .zero,
            snapshotProvider: { _ in .init(text: "keep this open document") })
        coordinator.schedule(documentID: currentID)
        try await waitUntil { await gate.saveCount == 1 }
        let discard = Task { @MainActor in try await coordinator.discardRecovered(old.reference) }
        try await Task.sleep(for: .milliseconds(10))
        let waiting = await gate.stats()
        XCTAssertEqual(waiting.cleanupCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path(old.reference).path))
        await gate.releaseAll()
        try await discard.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path(old.reference).path))
        assertCompleted(await coordinator.finish())
        let scan = try await fixture.scanAfterClose()
        XCTAssertEqual(scan.drafts.map(\.snapshot.documentID), [currentID])
        let completed = await gate.stats()
        XCTAssertEqual(completed.maximumConcurrent, 1)
        XCTAssertEqual(completed.cleanupCount, 1)
    }

    @MainActor
    func testRejectedRecoveredDiscardLeavesReferenceAvailableForLaterRetry() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let old = try await fixture.makeRecoverableDraft()
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        await gate.setCleanupError(.changedRecovery)
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, snapshotProvider: { _ in nil })
        do { try await coordinator.discardRecovered(old.reference); XCTFail("Expected rejected reference") }
        catch { XCTAssertEqual(error as? DraftRecoveryError, .changedRecovery) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path(old.reference).path))
        await gate.setCleanupError(nil)
        try await coordinator.discardRecovered(old.reference)
        assertCompleted(await coordinator.finish())
        let scan = try await fixture.scanAfterClose()
        XCTAssertTrue(scan.drafts.isEmpty)
    }

    @MainActor
    func testCancelledQuitCanRescheduleAllDirtyDocumentsAfterPartialClear() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = RecoveryCoordinatorGate(store: fixture.store)
        let first = UUID(), second = UUID()
        let content = [first: DraftRecoveryContent(text: "first dirty buffer"), second: DraftRecoveryContent(text: "second dirty buffer")]
        let coordinator = DraftRecoveryCoordinator(backend: gate.backend, debounce: .zero, snapshotProvider: { content[$0] })
        coordinator.schedule(documentID: first); coordinator.schedule(documentID: second)
        assertCompleted(await coordinator.flush())
        await gate.setDiscardError(.unsafePath, for: second)
        coordinator.clear(documentID: first); coordinator.clear(documentID: second)
        guard case .failed(let issues) = await coordinator.flush() else { return XCTFail("Expected failed clear") }
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.documentID, second)
        XCTAssertFalse(coordinator.isFinishing)
        XCTAssertTrue(coordinator.schedule(documentID: first))
        XCTAssertTrue(coordinator.schedule(documentID: second))
        assertCompleted(await coordinator.flush())
        assertCompleted(await coordinator.finish())
        let scan = try await fixture.scanAfterClose()
        XCTAssertEqual(Set(scan.drafts.map(\.snapshot.documentID)), Set([first, second]))
        XCTAssertTrue(scan.drafts.allSatisfy { $0.snapshot.generation == 3 })
        XCTAssertEqual(Set(scan.drafts.map(\.snapshot.text)), Set(content.values.map(\.text)))
    }

    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out awaiting recovery coordination"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @MainActor private func assertCompleted(_ result: DraftRecoveryCoordinator.DrainResult,
                                           file: StaticString = #filePath, line: UInt = #line) {
        guard case .completed = result else { return XCTFail("Expected completed drain, got \(result)", file: file, line: line) }
    }
    @MainActor private func assertTimedOut(_ result: DraftRecoveryCoordinator.DrainResult,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard case .timedOut = result else { return XCTFail("Expected bounded timeout", file: file, line: line) }
    }
    private func makeFixture() throws -> RecoveryCoordinatorFixture {
        let canonical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let directory = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("RecoveryCoordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let root = directory.appendingPathComponent("Recovery")
        return try .init(directory: directory, root: root, store: DraftRecoveryStore(directory: root))
    }
}

private struct RecoveryCoordinatorFixture {
    let directory: URL
    let root: URL
    let store: DraftRecoveryStore
    func cleanUp() { Task { await store.close(); try? FileManager.default.removeItem(at: directory) } }
    func scanAfterClose() async throws -> DraftRecoveryScan {
        let reader = try DraftRecoveryStore(directory: root)
        let result = try await reader.scan()
        await reader.close()
        return result
    }
    func makeRecoverableDraft() async throws -> RecoveredDraft {
        let writer = try DraftRecoveryStore(directory: root)
        try await writer.save(.init(documentID: UUID(), generation: 12, text: "e\u{301} 中文 🦊\r\n",
            originPath: "/never/read/or/write/origin.txt", encodingHint: .utf16BigEndianBOM, selection: .init(location: 0, length: 2)))
        await writer.close()
        let scan = try await scanAfterClose()
        return try XCTUnwrap(scan.drafts.first)
    }
    func path(_ reference: DraftRecoveryReference) -> URL {
        root.appendingPathComponent(reference.instanceID.uuidString).appendingPathComponent(reference.documentID.uuidString + ".draft")
    }
}

/// Calls the real store after a controllable asynchronous gate. Deliberately
/// ignores task cancellation so the coordinator's own deadline is exercised.
private actor RecoveryCoordinatorGate {
    struct Stats {
        let saves: [DraftRecoverySnapshot]
        let discards: [(UUID, UInt64)]
        let scanCount: Int, cleanupCount: Int, closeCount: Int, maximumConcurrent: Int
        let onMainThread: Bool
    }
    let store: DraftRecoveryStore
    private var saved: [DraftRecoverySnapshot] = []
    private var discarded: [(UUID, UInt64)] = []
    private var scans = 0, cleanups = 0, closes = 0, active = 0, maximumActive = 0
    private var mainThread = false, blocking = false
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var saveErrors: [DraftRecoveryError] = []
    private var discardErrors: [UUID: DraftRecoveryError] = [:]
    private var cleanupError: DraftRecoveryError?
    init(store: DraftRecoveryStore) { self.store = store }
    var saveCount: Int { saved.count }
    nonisolated var backend: DraftRecoveryBackend {
        .init(save: { try await self.save($0) }, discard: { try await self.discard($0, $1) },
              scan: { try await self.scan() }, discardRecovered: { try await self.discardRecovered($0) }, close: { await self.close() })
    }
    func setBlocking(_ value: Bool) { blocking = value }
    func setSaveErrors(_ errors: [DraftRecoveryError]) { saveErrors = errors }
    func setCleanupError(_ error: DraftRecoveryError?) { cleanupError = error }
    func setDiscardError(_ error: DraftRecoveryError, for id: UUID) { discardErrors[id] = error }
    func release(_ index: Int) { continuations.removeValue(forKey: index)?.resume() }
    func releaseAll() {
        blocking = false
        let waiting = continuations; continuations.removeAll()
        for continuation in waiting.values { continuation.resume() }
    }
    func stats() -> Stats {
        .init(saves: saved, discards: discarded, scanCount: scans, cleanupCount: cleanups, closeCount: closes,
              maximumConcurrent: maximumActive, onMainThread: mainThread)
    }
    private func begin() { active += 1; maximumActive = max(maximumActive, active); mainThread = mainThread || Thread.isMainThread }
    private func save(_ snapshot: DraftRecoverySnapshot) async throws {
        begin(); defer { active -= 1 }
        saved.append(snapshot)
        let index = saved.count
        if blocking { await withCheckedContinuation { continuations[index] = $0 } }
        if !saveErrors.isEmpty { throw saveErrors.removeFirst() }
        try await store.save(snapshot)
    }
    private func discard(_ id: UUID, _ generation: UInt64) async throws {
        begin(); defer { active -= 1 }
        discarded.append((id, generation))
        if let error = discardErrors.removeValue(forKey: id) { throw error }
        try await store.discard(documentID: id, throughGeneration: generation)
    }
    private func scan() async throws -> DraftRecoveryScan {
        begin(); defer { active -= 1 }
        scans += 1; return try await store.scan()
    }
    private func discardRecovered(_ reference: DraftRecoveryReference) async throws {
        begin(); defer { active -= 1 }
        cleanups += 1
        if let cleanupError { throw cleanupError }
        try await store.discardRecovered(reference)
    }
    private func close() async { begin(); defer { active -= 1 }; closes += 1; await store.close() }
}
