import AppKit
import EditorCore
import XCTest
@testable import EditorApp

/// Exercises the text-input client directly; this does not test an input method's
/// candidate window, keyboard handling, or interactions with a visible window.
final class EditorInputTests: XCTestCase {
    @MainActor
    func testUnicodeReplacementUndoAndRedoPreserveExactText() async throws {
        _ = NSApplication.shared
        let original = "before 🦊 after\n"
        let (session, directory) = try makeSession(text: original)
        defer {
            session.syntax.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
        let replacement = "中文 👩🏽‍💻 e\u{301} é"
        let range = (original as NSString).range(of: "🦊")
        let expected = "before \(replacement) after\n"

        withInputGroup(session) {
            session.textView.insertText(replacement, replacementRange: range)
        }

        XCTAssertEqual(Array(session.textView.string.utf8), Array(expected.utf8))
        XCTAssertTrue(session.dirty)
        session.undoStack.undo()
        XCTAssertEqual(Array(session.textView.string.utf8), Array(original.utf8))
        XCTAssertFalse(session.dirty)
        XCTAssertFalse(session.undoStack.canUndo)
        session.undoStack.redo()
        XCTAssertEqual(Array(session.textView.string.utf8), Array(expected.utf8))
        XCTAssertTrue(session.dirty)
    }

    @MainActor
    func testMarkedTextUpdatesCommitAndUndoWithoutLosingSurroundingText() async throws {
        _ = NSApplication.shared
        let original = "# e\u{301} 👩🏽‍💻\nvalue = '原文'\n"
        let (session, directory) = try makeSession(text: original, fileExtension: "py")
        defer {
            session.syntax.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
        let view = session.textView
        let replacementRange = (original as NSString).range(of: "原文")
        let currentInput = NSRange(location: NSNotFound, length: 0)
        let expected = "# e\u{301} 👩🏽‍💻\nvalue = '中文'\n"

        withInputGroup(session) {
            view.setMarkedText("zh", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: replacementRange)
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(view.markedRange(), NSRange(location: replacementRange.location, length: 2))
            view.setMarkedText("zhong wen", selectedRange: NSRange(location: 9, length: 0),
                               replacementRange: currentInput)
            let markedRange = view.markedRange()
            let markedText = view.string
            let selection = view.selectedRange()
            XCTAssertEqual(markedRange, NSRange(location: replacementRange.location, length: 9))
            XCTAssertEqual(Array(markedText.utf8), Array("# e\u{301} 👩🏽‍💻\nvalue = 'zhong wen'\n".utf8))

            session.syntax.highlight(textView: view, fileURL: session.file?.url)
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(view.markedRange(), markedRange)
            XCTAssertEqual(view.selectedRange(), selection)
            XCTAssertEqual(Array(view.string.utf8), Array(markedText.utf8))

            view.insertText("中文", replacementRange: currentInput)
        }

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(Array(view.string.utf8), Array(expected.utf8))
        XCTAssertTrue(session.dirty)
        session.undoStack.undo()
        XCTAssertEqual(Array(view.string.utf8), Array(original.utf8))
        XCTAssertFalse(session.dirty)
        XCTAssertFalse(session.undoStack.canUndo)
        session.undoStack.redo()
        XCTAssertEqual(Array(view.string.utf8), Array(expected.utf8))
        XCTAssertFalse(view.hasMarkedText())
    }

    @MainActor
    func testCompletedHighlightingPreservesTextSelectionAndUndoHistory() async throws {
        _ = NSApplication.shared
        let original = "# 中文 👩🏽‍💻 e\u{301}\n"
        let (session, directory) = try makeSession(text: original, fileExtension: "py")
        defer {
            session.syntax.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
        let added = "value = 42\n"
        let expected = original + added
        withInputGroup(session) {
            session.textView.insertText(added,
                replacementRange: NSRange(location: original.utf16.count, length: 0))
        }
        let selection = (expected as NSString).range(of: "👩🏽‍💻")
        session.textView.setSelectedRange(selection)
        let numberLocation = (expected as NSString).range(of: "42").location

        try await waitForSyntaxColor(in: session.textView, at: numberLocation)

        XCTAssertEqual(Array(session.textView.string.utf8), Array(expected.utf8))
        XCTAssertEqual(session.textView.selectedRange(), selection)
        XCTAssertTrue(session.dirty)
        session.undoStack.undo()
        XCTAssertEqual(Array(session.textView.string.utf8), Array(original.utf8))
        XCTAssertFalse(session.dirty)
        XCTAssertFalse(session.undoStack.canUndo, "Coloring must not add an undo action")
        session.undoStack.redo()
        XCTAssertEqual(Array(session.textView.string.utf8), Array(expected.utf8))
    }

    @MainActor
    private func makeSession(text: String, fileExtension suffix: String = "txt") throws -> (EditorSession, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorInputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("input.\(suffix)")
        let loaded = try DocumentFile.save(text, to: url, encoding: .utf8)
        return (EditorSession(file: loaded), directory)
    }

    @MainActor
    private func withInputGroup(_ session: EditorSession, _ input: () -> Void) {
        session.textView.breakUndoCoalescing()
        session.undoStack.beginUndoGrouping()
        defer {
            session.undoStack.endUndoGrouping()
            session.textView.breakUndoCoalescing()
        }
        input()
    }

    @MainActor
    private func waitForSyntaxColor(in view: NSTextView, at location: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let color = view.textStorage?.attribute(.foregroundColor, at: location,
                                                       effectiveRange: nil) as? NSColor,
               color != NSColor.textColor {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected syntax coloring to complete before checking input safety")
    }
}
