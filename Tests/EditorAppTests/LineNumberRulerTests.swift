import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class LineNumberRulerTests: XCTestCase {
    @MainActor
    func testOnlyLogicalStartsAreLabeledInWrappedViewport() async throws {
        let source = String(repeating: "wrapped text ", count: 20) + "\r\nsecond\nthird\n"
        let fixture = Fixture(source: source, size: NSSize(width: 330, height: 450))
        defer { fixture.close() }
        fixture.ruler.refresh()
        try await waitUntil { fixture.ruler.currentIndex != nil }
        fixture.layout()
        let labels = fixture.ruler.visibleLabels()
        XCTAssertEqual(labels.map(\.line), [1, 2, 3, 4])
        XCTAssertEqual(Set(labels.map(\.line)).count, labels.count)
        XCTAssertGreaterThan(try XCTUnwrap(labels.first { $0.line == 2 }).textY - labels[0].textY, 50)
        XCTAssertNotNil(fixture.textView.textLayoutManager, "The gutter must never switch the text view to TextKit 1")
        XCTAssertEqual(fixture.textView.string, source)
    }

    @MainActor
    func testScrollingAndWorkBudgetUseVisibleFragmentsOnly() async throws {
        let source = (1...200).map { "Line \($0)" }.joined(separator: "\n") + "\n"
        let fixture = Fixture(source: source, size: NSSize(width: 330, height: 160))
        defer { fixture.close() }
        fixture.ruler.refresh()
        try await waitUntil { fixture.ruler.currentIndex != nil }
        fixture.layout()
        let first = fixture.ruler.visibleLabels()
        XCTAssertEqual(first.first?.line, 1)
        XCTAssertLessThan(first.count, 30)
        XCTAssertEqual(fixture.ruler.visibleLabels(maximumFragments: 1).count, 1)
        XCTAssertTrue(fixture.ruler.visibleLabels(maximumVisualLines: 0).isEmpty)
        fixture.textView.scrollRangeToVisible(NSRange(location: source.utf16.count, length: 0))
        fixture.layout()
        let last = fixture.ruler.visibleLabels()
        XCTAssertGreaterThan(last.first?.line ?? 0, 150)
        XCTAssertEqual(last.last?.line, 201, "The final empty line has a real line number")
        XCTAssertLessThan(last.count, 30)
        XCTAssertNotNil(fixture.textView.textLayoutManager)
    }

    @MainActor
    func testViewportInsideOneWrappedLineDoesNotRepeatItsNumber() async throws {
        let source = String(repeating: "long wrapped paragraph ", count: 200) + "\nnext"
        let fixture = Fixture(source: source, size: NSSize(width: 330, height: 160))
        defer { fixture.close() }
        fixture.ruler.refresh()
        try await waitUntil { fixture.ruler.currentIndex != nil }
        fixture.layout()
        XCTAssertEqual(fixture.ruler.visibleLabels().map(\.line), [1])
        fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 200))
        fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)
        fixture.layout()
        XCTAssertTrue(fixture.ruler.visibleLabels().isEmpty, "A soft-wrap continuation is not another logical line")
        XCTAssertNotNil(fixture.textView.textLayoutManager)
    }

    @MainActor
    func testEmptyAndUnicodeSeparatorsUseLogicalLines() async throws {
        for source in ["", "a\r\nb\rc\nd\u{85}e\u{2028}f\u{2029}"] {
            let fixture = Fixture(source: source, size: NSSize(width: 330, height: 450))
            fixture.ruler.refresh()
            try await waitUntil { fixture.ruler.currentIndex != nil }
            fixture.layout()
            XCTAssertEqual(fixture.ruler.visibleLabels().map(\.line), Array(1...(fixture.ruler.currentIndex?.lineCount ?? 0)))
            fixture.close()
        }
    }

    @MainActor
    func testInvalidationAndOldWorkerCannotPublishStaleIndex() async throws {
        _ = NSApplication.shared
        let gate = LineIndexGate()
        var source = "old\nline", revision: UInt64 = 1
        let textView = NSTextView(usingTextLayoutManager: true)
        let ruler = LineNumberRuler(textView: textView, snapshot: { (source, revision) }, builder: { value in
            if value.hasPrefix("old") { gate.wait() }
            return try TextLineIndex.build(value, isCancelled: { false })
        })
        defer { gate.release(); ruler.invalidate() }
        ruler.refresh()
        try await waitUntil { gate.started }
        source = "new\r\nlines\r\n"
        revision = 2
        ruler.refresh()
        XCTAssertNil(ruler.currentIndex)
        try await waitUntil { ruler.displayedRevision == 2 }
        XCTAssertEqual(ruler.currentIndex?.lineCount, 3)
        gate.release()
        try await waitUntil { gate.finished }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(ruler.displayedRevision, 2)
        XCTAssertEqual(ruler.currentIndex?.newlineStyle, .crlf)
        ruler.invalidate()
        XCTAssertNil(ruler.currentIndex)
        XCTAssertNil(ruler.displayedRevision)
        XCTAssertTrue(ruler.visibleLabels().isEmpty)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for a line index"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private final class Fixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: NSTextView
        let ruler: LineNumberRuler

        init(source: String, size: NSSize) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
            scrollView.hasVerticalScroller = true
            textView = NSTextView(usingTextLayoutManager: true)
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.frame = NSRect(origin: .zero, size: size)
            textView.string = source
            scrollView.documentView = textView
            window.contentView = scrollView
            ruler = LineNumberRuler(textView: textView, snapshot: { (source, 1) })
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
            layout()
        }

        func layout() {
            scrollView.tile()
            scrollView.layoutSubtreeIfNeeded()
            textView.layoutSubtreeIfNeeded()
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }

        func close() { ruler.invalidate(); window.close() }
    }
}

private final class LineIndexGate: @unchecked Sendable {
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
