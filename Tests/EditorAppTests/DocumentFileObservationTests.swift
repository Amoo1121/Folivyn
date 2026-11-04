import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class DocumentFileObservationTests: XCTestCase {
    @MainActor
    func testRepeatedChecksKeepOneReaderAndOnlyOneQueuedRecheck() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loaded = try DocumentFile.save("baseline", to: directory.appendingPathComponent("source.txt"), encoding: .utf8)
        let session = EditorSession(file: loaded)
        let gate = ObservationReadGate()
        let observation = DocumentFileObservation(session: session, reader: gate.reader)
        defer { observation.stop(); gate.releaseAll(); cleanUp(session) }
        try await waitUntil { gate.snapshotCount == 1 }
        for _ in 0..<100 { observation.checkNow() }
        XCTAssertEqual(gate.callCount, 1)
        XCTAssertEqual(gate.maximumConcurrentReads, 1)
        XCTAssertFalse(gate.readOnMainThread)
        gate.release(1)
        try await waitUntil { gate.snapshotCount == 2 }
        XCTAssertEqual(gate.callCount, 2)
        XCTAssertEqual(gate.maximumConcurrentReads, 1)
        gate.release(2)
        try await waitUntil { !observation.isReading }
        XCTAssertEqual(gate.callCount, 2, "A burst queues one recheck, not one read per event")
        XCTAssertFalse(session.diskChanged)
        XCTAssertEqual(session.textView.string, loaded.text)
        XCTAssertFalse(session.undoStack.canUndo)
    }

    @MainActor
    func testSaveAsQueuesNewURLWithoutOverlapOrPublishingOldResult() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try DocumentFile.save("baseline", to: directory.appendingPathComponent("old.txt"), encoding: .utf8)
        let savedAs = try DocumentFile.save("baseline", to: directory.appendingPathComponent("new.txt"), encoding: .utf8)
        try Data("external old file".utf8).write(to: original.url)
        let session = EditorSession(file: original)
        let gate = ObservationReadGate()
        let observation = DocumentFileObservation(session: session, reader: gate.reader)
        defer { observation.stop(); gate.releaseAll(); cleanUp(session) }
        try await waitUntil { gate.snapshotCount == 1 }
        session.acceptSaved(savedAs)
        observation.updateURL()
        XCTAssertEqual(observation.observedURL, savedAs.url)
        XCTAssertEqual(gate.callCount, 1, "Cancellation cannot free a still-running reader's slot")
        gate.release(1)
        try await waitUntil { gate.snapshotCount == 2 }
        XCTAssertFalse(session.diskChanged, "A late result for the old path cannot mark the new file")
        XCTAssertEqual(gate.requestedURLs, [original.url, savedAs.url])
        XCTAssertEqual(gate.maximumConcurrentReads, 1)
        gate.release(2)
        try await waitUntil { !observation.isReading }
        XCTAssertFalse(session.diskChanged)
        XCTAssertEqual(session.textView.string, "baseline")
    }

    @MainActor
    func testStopRejectsPendingResultAndClearsQueuedRecheck() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loaded = try DocumentFile.save("baseline", to: directory.appendingPathComponent("source.txt"), encoding: .utf8)
        try Data("external".utf8).write(to: loaded.url)
        let session = EditorSession(file: loaded)
        let gate = ObservationReadGate()
        let observation = DocumentFileObservation(session: session, reader: gate.reader)
        defer { observation.stop(); gate.releaseAll(); cleanUp(session) }
        try await waitUntil { gate.snapshotCount == 1 }
        observation.checkNow()
        observation.stop()
        observation.checkNow()
        observation.updateURL()
        gate.release(1)
        try await waitUntil { !observation.isReading }
        XCTAssertTrue(observation.isStopped)
        XCTAssertEqual(gate.callCount, 1)
        XCTAssertFalse(session.diskChanged)
        XCTAssertEqual(session.textView.string, "baseline")
        XCTAssertFalse(session.undoStack.canUndo)
    }

    @MainActor
    func testSamePathSaveAndReloadInvalidateLateReadEvenWithUnchangedBaseline() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for reload in [false, true] {
            let url = directory.appendingPathComponent(reload ? "reload.txt" : "save.txt")
            let original = try DocumentFile.save("baseline", to: url, encoding: .utf8)
            try Data("temporary external bytes".utf8).write(to: url)
            let session = EditorSession(file: original)
            let gate = ObservationReadGate()
            let observation = DocumentFileObservation(session: session, reader: gate.reader)
            defer { observation.stop(); gate.releaseAll(); cleanUp(session) }
            try await waitUntil { gate.snapshotCount == 1 }
            let restored = try DocumentFile.save("baseline", to: url, encoding: .utf8, overwriteExternalChanges: true)
            if reload { session.reload(restored) } else { session.acceptSaved(restored) }
            observation.updateURL()
            gate.release(1)
            try await waitUntil { gate.snapshotCount >= 2 }
            XCTAssertFalse(session.diskChanged, "Save/reload invalidates checks even when its baseline bytes are unchanged")
            gate.releaseAll()
            try await waitUntil { !observation.isReading }
            XCTAssertFalse(session.diskChanged, "Our own save event must compare against the accepted saved baseline")
            XCTAssertEqual(session.textView.string, "baseline")
            XCTAssertEqual(gate.maximumConcurrentReads, 1)
            observation.stop()
        }
    }

    @MainActor
    func testRealAtomicReplacementDeletionAndRecreationOnlyChangeDiskIndicator() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loaded = try DocumentFile.save("baseline", to: directory.appendingPathComponent("source.txt"), encoding: .utf8)
        let session = EditorSession(file: loaded)
        session.textView.insertText(" local draft", replacementRange: NSRange(location: loaded.text.utf16.count, length: 0))
        let localDraft = session.textView.string
        let observation = DocumentFileObservation(session: session)
        defer { observation.stop(); cleanUp(session) }
        try await waitUntil { !observation.isReading }
        try Data("atomic replacement".utf8).write(to: loaded.url, options: .atomic)
        try await waitUntil { session.diskChanged }
        XCTAssertEqual(session.textView.string, localDraft)
        try Data(loaded.text.utf8).write(to: loaded.url, options: .atomic)
        try await waitUntil { !session.diskChanged }
        try FileManager.default.removeItem(at: loaded.url)
        try await waitUntil { session.diskChanged }
        try Data(loaded.text.utf8).write(to: loaded.url)
        try await waitUntil { !session.diskChanged }
        XCTAssertEqual(session.textView.string, localDraft)
        XCTAssertEqual(session.baseline, loaded.text)
        XCTAssertTrue(session.dirty)
        session.undoStack.undo()
        XCTAssertEqual(session.textView.string, loaded.text)
        XCTAssertFalse(session.undoStack.canUndo)
        XCTAssertEqual(try DocumentFile.read(loaded.url).text, loaded.text)
    }

    @MainActor
    func testActivationReconnectsParentDirectoryAfterItIsRecreated() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let loaded = try DocumentFile.save("baseline", to: parent.appendingPathComponent("source.txt"), encoding: .utf8)
        let session = EditorSession(file: loaded)
        let observation = DocumentFileObservation(session: session)
        defer { observation.stop(); cleanUp(session) }
        try await waitUntil { !observation.isReading }
        try FileManager.default.moveItem(at: parent, to: directory.appendingPathComponent("old-parent"))
        try await waitUntil { session.diskChanged && !observation.isReading }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try Data(loaded.text.utf8).write(to: loaded.url)
        observation.checkNow()
        try await waitUntil { !session.diskChanged && !observation.isReading }
        try Data("changed in new parent".utf8).write(to: loaded.url, options: .atomic)
        try await waitUntil { session.diskChanged }
        XCTAssertEqual(session.textView.string, loaded.text)
        XCTAssertFalse(session.undoStack.canUndo)
    }

    @MainActor
    func testObserverDoesNotRetainSessionWhileReaderIsBlocked() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loaded = try DocumentFile.save("baseline", to: directory.appendingPathComponent("source.txt"), encoding: .utf8)
        var session: EditorSession? = EditorSession(file: loaded)
        let sessionWasReleased = { [weak session] in session == nil }
        let gate = ObservationReadGate()
        let observation = DocumentFileObservation(session: try XCTUnwrap(session), reader: gate.reader)
        defer { observation.stop(); gate.releaseAll() }
        try await waitUntil { gate.snapshotCount == 1 }
        cleanUp(try XCTUnwrap(session))
        session = nil
        XCTAssertTrue(sessionWasReleased())
        gate.release(1)
        try await waitUntil { !observation.isReading }
        XCTAssertTrue(observation.isStopped)
        XCTAssertEqual(gate.callCount, 1)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor private func cleanUp(_ session: EditorSession) {
        session.presentation?.cancel()
        session.lineRuler.invalidate()
        session.syntax.cancel()
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out awaiting file observation")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Reads a real immutable disk snapshot, then delays its return. Deliberately
/// ignores cancellation so tests exercise publication and concurrency guards.
private final class ObservationReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var urls: [URL] = []
    private var snapshots = Set<Int>()
    private var released = Set<Int>()
    private var allReleased = false
    private var active = 0
    private var maximumActive = 0
    private var onMainThread = false

    var callCount: Int { locked { urls.count } }
    var snapshotCount: Int { locked { snapshots.count } }
    var maximumConcurrentReads: Int { locked { maximumActive } }
    var requestedURLs: [URL] { locked { urls } }
    var readOnMainThread: Bool { locked { onMainThread } }

    var reader: @Sendable (URL) throws -> LoadedTextFile {
        { [self] url in
            condition.lock()
            urls.append(url)
            let index = urls.count
            active += 1
            maximumActive = max(maximumActive, active)
            onMainThread = onMainThread || Thread.isMainThread
            condition.unlock()
            let result = Result { try DocumentFile.read(url) }
            condition.lock()
            snapshots.insert(index)
            while !allReleased && !released.contains(index) { condition.wait() }
            active -= 1
            condition.unlock()
            return try result.get()
        }
    }

    func release(_ index: Int) {
        condition.lock()
        released.insert(index)
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        allReleased = true
        condition.broadcast()
        condition.unlock()
    }

    private func locked<T>(_ body: () -> T) -> T {
        condition.lock(); defer { condition.unlock() }
        return body()
    }
}
