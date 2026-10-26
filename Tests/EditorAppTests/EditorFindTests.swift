import AppKit
import XCTest
@testable import EditorApp

/// Uses AppKit's native finder actions against real text views. Visible find-bar
/// interaction and system-localized controls still require native acceptance.
final class EditorFindTests: XCTestCase {
    @MainActor
    func testNativeFindUsesDocumentUnicodeRangesAndPreservesIndependentUndo() async throws {
        _ = NSApplication.shared
        let first = EditorSession()
        let second = EditorSession()
        defer {
            first.syntax.cancel()
            second.syntax.cancel()
        }
        let needle = "a.b 中文 👩🏽‍💻 e\u{301}"
        let original = "前 🦊 \(needle)\naxb 中文 👩🏽‍💻 e\u{301}\n\(needle)\n"
        first.textView.string = original
        first.baseline = original
        second.textView.string = "Second document: \(needle)"
        second.baseline = second.textView.string

        append("first edit", to: first)
        append("second edit", to: second)
        let firstEdited = first.textView.string
        let secondEdited = second.textView.string
        let otherSelection = second.textView.selectedRange()
        let initial = (original as NSString).range(of: needle)
        let last = (original as NSString).range(of: needle, options: .backwards)

        // AppKit intentionally shares find text through the standard find
        // pasteboard. Keep this test from replacing the user's previous query.
        let restorePasteboard = preserveFindPasteboard()
        defer { restorePasteboard() }
        first.textView.setSelectedRange(initial)
        perform(.setSearchString, on: first)
        perform(.nextMatch, on: first)
        XCTAssertEqual(first.textView.selectedRange(), last)
        perform(.nextMatch, on: first)
        XCTAssertEqual(first.textView.selectedRange(), initial, "Find next wraps within this document")
        perform(.previousMatch, on: first)
        XCTAssertEqual(first.textView.selectedRange(), last)

        XCTAssertEqual(Array(first.textView.string.utf8), Array(firstEdited.utf8))
        XCTAssertEqual(Array(second.textView.string.utf8), Array(secondEdited.utf8))
        XCTAssertEqual(second.textView.selectedRange(), otherSelection)
        first.undoStack.undo()
        XCTAssertEqual(Array(first.textView.string.utf8), Array(original.utf8))
        XCTAssertFalse(first.dirty)
        XCTAssertFalse(first.undoStack.canUndo, "Finding must not add an undo operation")
        XCTAssertTrue(second.dirty)
        XCTAssertTrue(second.undoStack.canUndo)
        first.undoStack.redo()
        XCTAssertEqual(Array(first.textView.string.utf8), Array(firstEdited.utf8))
        XCTAssertEqual(Array(second.textView.string.utf8), Array(secondEdited.utf8))
    }

    @MainActor
    private func perform(_ action: NSTextFinder.Action, on session: EditorSession) {
        let sender = NSMenuItem(title: "", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "")
        sender.tag = action.rawValue
        session.textView.performTextFinderAction(sender)
    }

    @MainActor
    private func append(_ text: String, to session: EditorSession) {
        session.textView.breakUndoCoalescing()
        session.undoStack.beginUndoGrouping()
        session.textView.insertText(text,
            replacementRange: NSRange(location: session.textView.string.utf16.count, length: 0))
        session.undoStack.endUndoGrouping()
        session.textView.breakUndoCoalescing()
    }

    @MainActor
    private func preserveFindPasteboard() -> () -> Void {
        let pasteboard = NSPasteboard(name: .find)
        let contents = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        return {
            pasteboard.clearContents()
            let restored = contents.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
    }
}
