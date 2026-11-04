import AppKit
import EditorCore
import EditorUI
import XCTest
@testable import EditorApp

final class EditorDecorationsTests: XCTestCase {
    @MainActor
    func testRealBackgroundDrawingPreservesTextAttributesSelectionAndUndo() async throws {
        let fixture = Fixture(source: "🙂 (abc)\nsecond\n")
        defer { fixture.close() }
        let view = fixture.session.textView
        view.setSelectedRange(NSRange(location: 3, length: 0))
        fixture.layout()
        let text = view.string
        let attributes = try XCTUnwrap(view.textStorage?.copy() as? NSAttributedString)
        let revision = fixture.session.revision
        let selection = view.selectedRange()
        let plain = try fixture.bitmap()
        let decorations = fixture.attach()
        try await waitUntil { decorations.displayedRevision == revision }
        fixture.layout()
        let geometry = decorations.visibleGeometry()
        let row = try XCTUnwrap(geometry.currentLine)
        XCTAssertEqual(geometry.brackets.count, 2)
        XCTAssertEqual(decorations.bracketPair?.opening, NSRange(location: 3, length: 1))
        XCTAssertEqual(decorations.bracketPair?.closing, NSRange(location: 7, length: 1))
        let painted = try fixture.bitmap()
        // Compare empty space on the current visual row, and a bracket edge.
        XCTAssertTrue(try pixelDiffers(plain, painted, at: NSPoint(x: 260, y: row.midY), in: view))
        let bracket = try XCTUnwrap(geometry.brackets.first)
        XCTAssertTrue(try pixelDiffers(plain, painted, at: NSPoint(x: bracket.minX, y: bracket.minY + 2), in: view))
        XCTAssertFalse(try pixelDiffers(plain, painted, at: NSPoint(x: 260, y: row.maxY + 8), in: view))
        XCTAssertEqual(view.string, text)
        XCTAssertTrue(try XCTUnwrap(view.textStorage).isEqual(to: attributes))
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(fixture.session.revision, revision)
        XCTAssertTrue(fixture.session.dirty)
        fixture.session.undoStack.undo()
        XCTAssertEqual(view.string, "")
        XCTAssertFalse(fixture.session.undoStack.canUndo, "Drawing must not create undo actions")
        fixture.session.undoStack.redo()
        XCTAssertEqual(view.string, text)
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testOnlyVisibleCurrentRowAndBracketAreDrawnWithHardGeometryBudget() async throws {
        let source = "(" + (1...300).map { "row \($0)" }.joined(separator: "\n") + ")"
        let fixture = Fixture(source: source, size: NSSize(width: 350, height: 160))
        defer { fixture.close() }
        let view = fixture.session.textView
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        let decorations = fixture.attach()
        try await waitUntil { decorations.bracketPair != nil }
        fixture.layout()
        XCTAssertEqual(decorations.visibleGeometry().brackets.count, 1)
        XCTAssertTrue(decorations.visibleGeometry(maximumFragments: 0).brackets.isEmpty)
        XCTAssertNil(decorations.visibleGeometry(maximumVisualLines: 0).currentLine)
        view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        fixture.layout()
        try await waitUntil { decorations.displayedRevision == fixture.session.revision }
        let geometry = decorations.visibleGeometry()
        XCTAssertEqual(geometry.brackets.count, 1)
        let row = try XCTUnwrap(geometry.currentLine)
        XCTAssertTrue(row.intersects(view.visibleRect))
        XCTAssertLessThanOrEqual(row.height, 30)
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testSoftWrappedCurrentLineUsesOnlyCaretVisualRow() async throws {
        let source = String(repeating: "word ", count: 2_000)
        let fixture = Fixture(source: source, size: NSSize(width: 300, height: 160))
        defer { fixture.close() }
        let view = fixture.session.textView
        view.setSelectedRange(NSRange(location: 2_500, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        fixture.layout()
        let decorations = fixture.attach()
        let row = try XCTUnwrap(decorations.visibleGeometry().currentLine)
        XCTAssertLessThanOrEqual(row.height, 30)
        XCTAssertTrue(row.intersects(view.visibleRect))
        XCTAssertTrue(decorations.visibleGeometry().brackets.isEmpty)
        XCTAssertEqual(view.string, source)
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testBracketFramesAgreeWithTextInputGeometryAcrossWrapAndBidirectionalText() async throws {
        for source in ["🙂 (abc)", String(repeating: "word ", count: 15) + "(🦊)", "אבג (value)"] {
            let fixture = Fixture(source: source, size: NSSize(width: 300, height: 240))
            defer { fixture.close() }
            let view = fixture.session.textView
            let opening = (source as NSString).range(of: "(")
            view.setSelectedRange(NSRange(location: opening.location, length: 0))
            let decorations = fixture.attach()
            try await waitUntil { decorations.bracketPair != nil }
            fixture.layout()
            let painted = try XCTUnwrap(decorations.visibleGeometry().brackets.first)
            var actual = NSRange()
            let screen = view.firstRect(forCharacterRange: opening, actualRange: &actual)
            let expected = view.convert(fixture.window.convertFromScreen(screen), from: nil)
            XCTAssertEqual(painted.minX, expected.minX, accuracy: 1, source)
            XCTAssertEqual(painted.minY, expected.minY, accuracy: 1, source)
            XCTAssertEqual(painted.width, expected.width, accuracy: 1, source)
            XCTAssertNotNil(view.textLayoutManager)
        }
    }

    @MainActor
    func testUnsupportedSyntaxLargeTextSelectionAndInvalidationClearMatching() async throws {
        let fixture = Fixture(source: "(a / b)")
        defer { fixture.close() }
        let view = fixture.session.textView
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let decorations = fixture.attach()
        try await waitUntil { decorations.bracketPair != nil }
        fixture.language = .javascript
        decorations.refresh()
        XCTAssertNil(decorations.bracketPair)
        try await waitUntil { decorations.lastError != nil }
        guard case .unsupportedSyntax = decorations.lastError else { return XCTFail("Expected conservative fallback") }
        XCTAssertTrue(decorations.visibleGeometry().brackets.isEmpty)
        fixture.replace("()\n" + String(repeating: "a\n", count: 103_000))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        decorations.refresh()
        XCTAssertNil(decorations.bracketPair)
        XCTAssertNil(decorations.displayedRevision)
        fixture.replace("(small)")
        view.setSelectedRange(NSRange(location: 0, length: 2))
        decorations.refresh()
        XCTAssertNil(decorations.visibleGeometry().currentLine)
        XCTAssertTrue(decorations.visibleGeometry().brackets.isEmpty)
        decorations.invalidate()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(decorations.displayedRevision, "Invalidation stays disabled until an explicit refresh")
        XCTAssertNil(decorations.visibleGeometry().currentLine)
    }

    @MainActor
    func testMarkedTextSkipsDecorationWithoutChangingComposition() async throws {
        let fixture = Fixture(source: "(value)")
        defer { fixture.close() }
        let view = fixture.session.textView
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let decorations = fixture.attach()
        try await waitUntil { decorations.bracketPair != nil }
        view.setMarkedText("zh", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: 1, length: 5))
        let source = view.string
        let marked = view.markedRange()
        let selected = view.selectedRange()
        let attributes = try XCTUnwrap(view.textStorage?.copy() as? NSAttributedString)
        decorations.refresh()
        fixture.layout()
        _ = try fixture.bitmap()
        XCTAssertNil(decorations.bracketPair)
        XCTAssertNil(decorations.visibleGeometry().currentLine)
        XCTAssertTrue(decorations.visibleGeometry().brackets.isEmpty)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), marked)
        XCTAssertEqual(view.selectedRange(), selected)
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(try XCTUnwrap(view.textStorage).isEqual(to: attributes))
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor
    func testSlowOldMatchCannotReplaceNewSourceOrSelection() async throws {
        let fixture = Fixture(source: "old()")
        let gate = DecorationGate()
        defer { gate.release(); fixture.close() }
        let view = fixture.session.textView
        view.setSelectedRange(NSRange(location: 3, length: 0))
        let decorations = fixture.attach(matcher: { source, caret, policy in
            if source.hasPrefix("old") { gate.wait() }
            return try BracketMatcher.match(in: source, atUTF16Offset: caret, policy: policy, isCancelled: { false })
        })
        try await waitUntil { gate.started }
        fixture.replace("xx[123]")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        decorations.refresh()
        try await waitUntil { decorations.displayedRevision == fixture.session.revision }
        XCTAssertEqual(decorations.bracketPair?.closing.location, 6)
        gate.release()
        try await waitUntil { gate.finished }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(decorations.bracketPair?.opening.location, 2)
        XCTAssertEqual(decorations.bracketPair?.closing.location, 6)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(decorations.visibleGeometry().brackets.isEmpty)
    }

    @MainActor
    func testLanguageChangeAndDeallocationRejectPendingResult() async throws {
        let fixture = Fixture(source: "(text)")
        let gate = DecorationGate()
        defer { gate.release(); fixture.close() }
        fixture.session.textView.setSelectedRange(NSRange(location: 0, length: 0))
        var decorations: EditorDecorations? = fixture.attach(matcher: { source, caret, policy in
            gate.wait()
            return try BracketMatcher.match(in: source, atUTF16Offset: caret, policy: policy, isCancelled: { false })
        })
        try await waitUntil { gate.started }
        fixture.language = .json
        gate.release()
        try await waitUntil { gate.finished }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(decorations?.displayedRevision, "A stale language must not publish without a new refresh")
        fixture.decorations = nil
        decorations = nil
        XCTAssertNil(fixture.session.textView.editorDecorations)
    }

    @MainActor
    func testPendingWorkerDoesNotRetainDetachedDecorations() async throws {
        let fixture = Fixture(source: "(text)")
        let gate = DecorationGate()
        defer { gate.release(); fixture.close() }
        fixture.session.textView.setSelectedRange(NSRange(location: 0, length: 0))
        _ = fixture.attach(matcher: { source, caret, policy in
            gate.wait()
            return try BracketMatcher.match(in: source, atUTF16Offset: caret, policy: policy, isCancelled: { false })
        })
        try await waitUntil { gate.started }
        fixture.decorations = nil
        XCTAssertNil(fixture.session.textView.editorDecorations, "Neither observer, view nor worker may retain the controller")
        gate.release()
        try await waitUntil { gate.finished }
        XCTAssertEqual(fixture.session.textView.string, "(text)")
    }

    @MainActor
    private func pixelDiffers(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep, at point: NSPoint, in view: NSView) throws -> Bool {
        let scale = CGFloat(lhs.pixelsWide) / view.bounds.width
        let x = Int((point.x - view.bounds.minX) * scale)
        let y = Int((point.y - view.bounds.minY) * scale)
        let a = try XCTUnwrap(lhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        let b = try XCTUnwrap(rhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.02
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out awaiting decorations"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private final class Fixture {
        let session = EditorSession()
        let window: NSWindow
        var language: SyntaxLanguage = .plainText
        var decorations: EditorDecorations?

        init(source: String, size: NSSize = NSSize(width: 380, height: 240)) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = session.presentation?.view
            replace(source)
            layout()
        }

        func attach(matcher: @escaping EditorDecorations.Matcher = { try BracketMatcher.match(in: $0, atUTF16Offset: $1, policy: $2) }) -> EditorDecorations {
            let value = EditorDecorations(textView: session.textView,
                snapshot: { [weak self] in (self?.session.textView.string ?? "", self?.session.revision ?? 0) },
                language: { [weak self] in self?.language ?? .plainText }, matcher: matcher)
            decorations = value
            return value
        }

        func replace(_ source: String) {
            session.textView.breakUndoCoalescing()
            session.undoStack.beginUndoGrouping()
            session.textView.insertText(source, replacementRange: NSRange(location: 0, length: session.textView.string.utf16.count))
            session.undoStack.endUndoGrouping()
            session.textView.breakUndoCoalescing()
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            session.scrollView.tile()
            session.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }

        func bitmap() throws -> NSBitmapImageRep {
            let view = session.textView
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }

        func close() {
            decorations?.invalidate()
            session.syntax.cancel()
            session.lineRuler.invalidate()
            session.presentation?.cancel()
            window.close()
        }
    }
}

private final class DecorationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didStart = false, didFinish = false, released = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return didStart }
    var finished: Bool { condition.lock(); defer { condition.unlock() }; return didFinish }
    func wait() {
        condition.lock()
        didStart = true
        while !released { condition.wait() }
        didFinish = true
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
