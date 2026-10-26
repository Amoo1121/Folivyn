import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class StructuredEditTests: XCTestCase {
    @MainActor
    func testCSVEditAndSourceEditShareUndoWithoutChangingOtherBytesOrTabs() async throws {
        _ = NSApplication.shared
        let original = "name,value\r\n\"中文 🦊\",00123\r\n\"with,comma\",\"two words\"\r\n"
        let session = EditorSession()
        let other = EditorSession()
        defer { session.syntax.cancel(); other.syntax.cancel() }
        session.textView.string = original
        session.baseline = original
        other.textView.string = "other tab"
        let map = try CSVDocument.parse(original, delimiter: .comma)
        let edit = try map.replacement(row: 1, column: 1, value: "=1+2,\"quoted\"")
        XCTAssertTrue(session.replaceSource(in: edit.range, expected: edit.expectedSource,
            with: edit.escapedReplacement, revision: session.revision, actionName: "Edit Cell"))
        await finishEvent()
        let afterCell = session.textView.string
        XCTAssertEqual(afterCell, "name,value\r\n\"中文 🦊\",\"=1+2,\"\"quoted\"\"\"\r\n\"with,comma\",\"two words\"\r\n")
        XCTAssertGreaterThan(session.revision, 0)
        XCTAssertTrue(session.dirty)

        session.undoStack.beginUndoGrouping()
        session.textView.insertText("tail", replacementRange: NSRange(location: afterCell.utf16.count, length: 0))
        session.undoStack.endUndoGrouping()
        session.textView.breakUndoCoalescing()
        await finishEvent()
        session.undoStack.undo()
        XCTAssertEqual(Array(session.textView.string.utf16), Array(afterCell.utf16))
        session.undoStack.undo()
        XCTAssertEqual(Array(session.textView.string.utf16), Array(original.utf16))
        XCTAssertFalse(session.dirty)
        session.undoStack.redo()
        XCTAssertEqual(Array(session.textView.string.utf16), Array(afterCell.utf16))
        session.undoStack.redo()
        XCTAssertEqual(session.textView.string, afterCell + "tail")
        XCTAssertEqual(other.textView.string, "other tab")
        XCTAssertFalse(other.undoStack.canUndo)
    }

    // Native undo groups are event-based. Let the run loop close an event
    // between the cell command and source typing, as real user actions do.
    @MainActor
    private func finishEvent() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    @MainActor
    func testStaleOrCanonicallyEquivalentExpectedTextCannotReplaceSource() async throws {
        _ = NSApplication.shared
        let session = EditorSession()
        defer { session.syntax.cancel() }
        session.textView.string = "é,🦊"
        session.baseline = session.textView.string
        let revision = session.revision
        XCTAssertFalse(session.replaceSource(in: NSRange(location: 0, length: 1), expected: "e\u{301}",
            with: "changed", revision: revision, actionName: "Cell"))
        XCTAssertFalse(session.replaceSource(in: NSRange(location: 2, length: 1), expected: "�",
            with: "changed", revision: revision, actionName: "Cell"))
        XCTAssertFalse(session.replaceSource(in: NSRange(location: Int.max, length: Int.max), expected: "",
            with: "changed", revision: revision, actionName: "Cell"))
        XCTAssertFalse(session.undoStack.canUndo)
        XCTAssertTrue(session.replaceSource(in: NSRange(location: 0, length: 1), expected: "é",
            with: "e\u{301}", revision: revision, actionName: "Cell"))
        XCTAssertTrue(session.dirty)
        XCTAssertFalse(session.replaceSource(in: NSRange(location: 0, length: 2), expected: "e\u{301}",
            with: "stale", revision: revision, actionName: "Cell"))
        session.undoStack.undo()
        XCTAssertEqual(Array(session.textView.string.utf16), Array("é,🦊".utf16))
        XCTAssertFalse(session.dirty)
        XCTAssertGreaterThan(session.revision, revision)
    }

    @MainActor
    func testMarkedTextRejectsStructuredWriteAndReloadInvalidatesMaps() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loaded = try DocumentFile.save("a,b", to: directory.appendingPathComponent("test.csv"), encoding: .utf8)
        let session = EditorSession(file: loaded)
        defer { session.syntax.cancel() }
        let revision = session.revision
        session.textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                                      replacementRange: NSRange(location: 0, length: 1))
        XCTAssertTrue(session.textView.hasMarkedText())
        XCTAssertFalse(session.replaceSource(in: NSRange(location: 2, length: 1), expected: "b",
            with: "cell", revision: session.revision, actionName: "Cell"))
        session.reload(loaded)
        XCTAssertFalse(session.textView.hasMarkedText())
        XCTAssertGreaterThan(session.revision, revision)
        XCTAssertFalse(session.replaceSource(in: NSRange(location: 2, length: 1), expected: "b",
            with: "cell", revision: revision, actionName: "Cell"))
        XCTAssertEqual(session.textView.string, "a,b")
    }
}
