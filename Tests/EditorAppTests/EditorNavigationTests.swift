import AppKit
import EditorCore
import EditorUI
import XCTest
@testable import EditorApp

final class EditorNavigationTests: XCTestCase {
    @MainActor
    func testLineJumpUsesCurrentRevisionAndNeverChangesSourceOrUndo() async throws {
        _ = NSApplication.shared
        let session = EditorSession()
        defer { session.lineRuler.invalidate(); session.syntax.cancel(); session.presentation?.cancel() }
        let source = "中文 🦊\r\nsecond\rthird\n"
        session.textView.insertText(source, replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(session.goToLine(2), "A pending index must not navigate using old offsets")
        try await waitUntil { session.lineRuler.displayedRevision == session.revision }
        let index = try XCTUnwrap(session.lineRuler.currentIndex)
        XCTAssertEqual(index.newlineStyle, .mixed)
        XCTAssertEqual(index.lineCount, 4)
        XCTAssertTrue(session.goToLine(2))
        XCTAssertEqual(session.textView.selectedRange(), NSRange(location: 7, length: 0))
        XCTAssertFalse(session.goToLine(0))
        XCTAssertFalse(session.goToLine(5))
        XCTAssertTrue(session.goToLine(4))
        XCTAssertEqual(session.textView.selectedRange().location, source.utf16.count)
        XCTAssertEqual(Array(session.textView.string.utf16), Array(source.utf16))
        session.undoStack.undo()
        try await waitUntil { session.lineRuler.displayedRevision == session.revision }
        XCTAssertEqual(session.textView.string, "")
        XCTAssertEqual(session.lineRuler.currentIndex?.lineCount, 1)
        XCTAssertFalse(session.goToLine(2))
    }

    @MainActor
    func testLanguageChoiceIsPerTabAndMarkedTextPreventsLineJump() async throws {
        _ = NSApplication.shared
        let first = EditorSession(), second = EditorSession()
        defer {
            for session in [first, second] { session.lineRuler.invalidate(); session.syntax.cancel() }
        }
        first.languageOverride = .python
        second.languageOverride = .plainText
        XCTAssertEqual(first.languageOverride, .python)
        XCTAssertEqual(second.languageOverride, .plainText)
        XCTAssertFalse(first.dirty)
        XCTAssertFalse(first.undoStack.canUndo)
        try await waitUntil { first.lineRuler.currentIndex != nil }
        first.textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(first.goToLine(1))
        XCTAssertTrue(first.textView.hasMarkedText())
        first.textView.unmarkText()
        first.languageOverride = nil
        XCTAssertNil(first.languageOverride)
        XCTAssertEqual(second.languageOverride, .plainText)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Line index did not update"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
