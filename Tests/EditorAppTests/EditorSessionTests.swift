import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class EditorSessionTests: XCTestCase {
    @MainActor
    func testDiskChecksIgnoreOlderResultsThatFinishAfterNewerChecks() async throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("checked.txt")
        let original = try DocumentFile.save("original", to: url, encoding: .utf8)
        let session = EditorSession(file: original)
        let olderCheck = try XCTUnwrap(session.beginDiskChangeCheck())
        let olderResult = try DocumentFile.read(url)

        try Data("external edit".utf8).write(to: url)
        let newerCheck = try XCTUnwrap(session.beginDiskChangeCheck())
        let newerResult = try DocumentFile.read(url)
        var acceptedResults = 0
        session.changed = { acceptedResults += 1 }

        // Explicitly reverse completion order; no scheduling or timing is required.
        session.finishDiskChangeCheck(newerCheck, result: newerResult)
        XCTAssertTrue(session.diskChanged)
        session.finishDiskChangeCheck(olderCheck, result: olderResult)
        XCTAssertTrue(session.diskChanged)
        XCTAssertEqual(acceptedResults, 1)
        XCTAssertEqual(session.textView.string, "original")
    }

    @MainActor
    func testSaveAndReloadInvalidatePendingChecksEvenWithUnchangedBaseline() async throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("baseline.txt")
        let original = try DocumentFile.save("original", to: url, encoding: .utf8)
        let session = EditorSession(file: original)
        let beforeSave = try XCTUnwrap(session.beginDiskChangeCheck())
        let saved = try DocumentFile.save(original.text, to: url, encoding: original.encoding,
                                         expectedSnapshot: original.diskSnapshot)
        session.acceptSaved(saved)
        session.finishDiskChangeCheck(beforeSave, result: nil)
        XCTAssertFalse(session.diskChanged)

        let beforeReload = try XCTUnwrap(session.beginDiskChangeCheck())
        try Data("temporary external edit".utf8).write(to: url)
        let staleResult = try DocumentFile.read(url)
        try Data(original.text.utf8).write(to: url)
        session.reload(try DocumentFile.read(url))
        session.finishDiskChangeCheck(beforeReload, result: staleResult)
        XCTAssertFalse(session.diskChanged)

        let afterReload = try XCTUnwrap(session.beginDiskChangeCheck())
        session.finishDiskChangeCheck(afterReload, result: nil)
        XCTAssertTrue(session.diskChanged, "A current failed read must still report a disk change")
    }

    @MainActor
    func testTabsKeepIndependentUndoAndRedoHistories() async throws {
        _ = NSApplication.shared
        let first = EditorSession()
        let second = EditorSession()
        let firstUndo = try XCTUnwrap(first.textView.undoManager)
        let secondUndo = try XCTUnwrap(second.textView.undoManager)
        XCTAssertFalse(firstUndo === secondUndo)

        try insert("first tab", into: first)
        try insert("second tab", into: second)
        firstUndo.undo()

        XCTAssertEqual(first.textView.string, "")
        XCTAssertFalse(first.dirty)
        XCTAssertEqual(second.textView.string, "second tab")
        XCTAssertTrue(second.dirty)
        XCTAssertTrue(secondUndo.canUndo)

        firstUndo.redo()
        XCTAssertEqual(first.textView.string, "first tab")
        XCTAssertTrue(first.dirty)
        secondUndo.undo()
        XCTAssertEqual(second.textView.string, "")
        XCTAssertEqual(first.textView.string, "first tab")
    }

    @MainActor
    func testReloadAppliesDiskContentsAndClearsOnlyItsOwnUndoHistory() async throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reload.txt")
        let original = try DocumentFile.save("original text", to: url, encoding: .utf8)
        let first = EditorSession(file: original)
        let second = EditorSession()
        try insert(" with local changes", into: first)
        try insert("keep this undo", into: second)
        first.diskChanged = true
        first.textView.setSelectedRange(NSRange(location: first.textView.string.utf16.count, length: 0))

        try Data("disk".utf8).write(to: url)
        let diskVersion = try DocumentFile.read(url)
        first.reload(diskVersion)

        XCTAssertEqual(first.textView.string, "disk")
        XCTAssertEqual(first.baseline, "disk")
        XCTAssertEqual(first.file?.diskSnapshot, diskVersion.diskSnapshot)
        XCTAssertFalse(first.dirty)
        XCTAssertFalse(first.diskChanged)
        XCTAssertEqual(first.textView.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertFalse(first.undoStack.canUndo)
        XCTAssertFalse(first.undoStack.canRedo)
        XCTAssertTrue(second.undoStack.canUndo)
        second.undoStack.undo()
        XCTAssertEqual(second.textView.string, "")
        XCTAssertEqual(first.textView.string, "disk")
    }

    @MainActor
    func testCanonicallyEquivalentUnicodeEditIsStillDirty() async throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        let url = directory.appendingPathComponent("unicode.txt")
        let loaded = try DocumentFile.save(composed, to: url, encoding: .utf8)
        let session = EditorSession(file: loaded)
        XCTAssertFalse(session.dirty)

        try insert(decomposed, into: session,
                   replacing: NSRange(location: 0, length: composed.utf16.count))

        // Swift String equality intentionally treats these spellings as equal.
        // A file editor still has to protect their different on-disk bytes.
        XCTAssertEqual(session.textView.string, composed)
        XCTAssertNotEqual(Array(session.textView.string.utf16), Array(composed.utf16))
        XCTAssertTrue(session.dirty)
        session.undoStack.undo()
        XCTAssertEqual(Array(session.textView.string.utf16), Array(composed.utf16))
        XCTAssertFalse(session.dirty)
    }

    @MainActor
    func testAcceptingSaveAsChangesBaselineAndKeepsUndoAndOriginalFile() async throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("original.txt")
        let destinationURL = directory.appendingPathComponent("copy.txt")
        let original = try DocumentFile.save("original", to: originalURL, encoding: .utf8)
        let session = EditorSession(file: original)
        try insert(" edited", into: session)
        let edited = session.textView.string
        let saved = try DocumentFile.save(edited, to: destinationURL, encoding: .utf8)

        session.acceptSaved(saved)

        XCTAssertEqual(session.file?.url, destinationURL.resolvingSymlinksInPath())
        XCTAssertEqual(session.baseline, edited)
        XCTAssertFalse(session.dirty)
        XCTAssertTrue(session.undoStack.canUndo)
        session.undoStack.undo()
        XCTAssertEqual(session.textView.string, "original")
        XCTAssertTrue(session.dirty)
        XCTAssertEqual(try DocumentFile.read(originalURL).text, "original")
        XCTAssertEqual(try DocumentFile.read(destinationURL).text, edited)
    }

    @MainActor
    private func insert(_ text: String, into session: EditorSession,
                        replacing range: NSRange? = nil) throws {
        let undo = try XCTUnwrap(session.textView.undoManager)
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        session.textView.insertText(text, replacementRange:
            range ?? NSRange(location: session.textView.string.utf16.count, length: 0))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
