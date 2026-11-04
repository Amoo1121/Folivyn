import Foundation
import EditorCore

/// File events are hints. Only a fresh bounded DocumentFile read and the
/// session's baseline/generation check may change its disk-change indicator.
/// This object never replaces, saves, or otherwise edits the source buffer.
@MainActor
final class DocumentFileObservation {
    typealias Reader = @Sendable (URL) throws -> LoadedTextFile

    private weak var session: EditorSession?
    private let reader: Reader
    private var monitor: FileChangeMonitor?
    private var activeRead: Task<Result<LoadedTextFile, Error>, Never>?
    private var needsRecheck = false
    private var generation: UInt64 = 0
    private(set) var observedURL: URL?
    private(set) var isStopped = false
    var isReading: Bool { activeRead != nil }

    init(session: EditorSession, reader: @escaping Reader = { try DocumentFile.read($0) }) {
        self.session = session
        self.reader = reader
        updateURL()
    }

    deinit { activeRead?.cancel() }

    /// Call after Save As, save, or reload. LoadedTextFile supplies the canonical
    /// URL; do not reinterpret that identity by resolving a new symlink later.
    func updateURL() {
        guard !isStopped else { return }
        guard let session else { stop(); return }
        let newURL = session.file?.url.standardizedFileURL
        if newURL != observedURL {
            generation &+= 1
            monitor?.stop()
            monitor = nil
            observedURL = newURL
            needsRecheck = false
            // Keep the active slot until the worker actually finishes. A
            // noncooperative old read must not overlap a read of the new URL.
            activeRead?.cancel()
            if let newURL {
                monitor = FileChangeMonitor(url: newURL) { [weak self] in self?.requestCheck() }
            }
        }
        requestCheck()
    }

    /// Activation is also a recovery point for revoked watches, failed initial
    /// opens, or a parent directory that was removed and recreated in place.
    func checkNow() {
        guard !isStopped else { return }
        if session?.file?.url.standardizedFileURL != observedURL {
            updateURL()
            return
        }
        monitor?.reconnect()
        requestCheck()
    }

    /// Permanently stops this observer. Construct a new instance to resume.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        generation &+= 1
        needsRecheck = false
        monitor?.stop()
        monitor = nil
        activeRead?.cancel()
    }

    private func requestCheck() {
        guard !isStopped else { return }
        guard let session else { stop(); return }
        guard let observedURL else { return }
        guard session.file?.url.standardizedFileURL == observedURL else {
            updateURL()
            return
        }
        guard activeRead == nil else { needsRecheck = true; return }
        guard let check = session.beginDiskChangeCheck() else { return }
        needsRecheck = false
        let expectedGeneration = generation
        let read = reader
        let task = Task.detached(priority: .utility) {
            Result {
                try Task.checkCancellation()
                return try read(check.file.url)
            }
        }
        activeRead = task
        Task { @MainActor [weak self] in
            let result = await task.value
            self?.finish(check, result: result, generation: expectedGeneration)
        }
    }

    private func finish(_ check: EditorSession.DiskChangeCheck,
                        result: Result<LoadedTextFile, Error>, generation expectedGeneration: UInt64) {
        activeRead = nil
        guard !isStopped else { return }
        guard let session else { stop(); return }
        if generation == expectedGeneration, observedURL == check.file.url.standardizedFileURL {
            switch result {
            case .failure(is CancellationError): break
            case .failure:
                // Unavailable, missing, and newly oversized/binary files are
                // changes too; the current buffer and undo remain untouched.
                session.finishDiskChangeCheck(check, result: nil)
            case .success(let loaded):
                session.finishDiskChangeCheck(check, result: loaded)
            }
        }
        if needsRecheck { requestCheck() }
    }
}
