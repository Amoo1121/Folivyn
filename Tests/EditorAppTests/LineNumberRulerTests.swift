import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class LineNumberRulerTests: XCTestCase {
    @MainActor
    func testSessionInstalledAtZeroSizeGetsNarrowGutterAndVisibleNumbers() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loaded = try DocumentFile.save("{\n  \"first\": 1,\n  \"second\": 2\n}",
            to: directory.appendingPathComponent("structure.json"), encoding: .utf8)
        var sessions: [EditorSession] = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            for session in sessions { session.lineRuler.invalidate(); session.syntax.cancel(); session.presentation?.cancel() }
            window.close()
        }
        let tabs = NSTabView()
        tabs.tabViewType = .topTabsBezelBorder
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let toolbar = NSStackView()
        toolbar.addArrangedSubview(NSButton(title: "Open", target: nil, action: nil))
        toolbar.addArrangedSubview(NSButton(title: "New", target: nil, action: nil))
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let status = NSTextField(labelWithString: "UTF-8 • Python • LF")
        status.translatesAutoresizingMaskIntoConstraints = false
        let content = try XCTUnwrap(window.contentView)
        content.wantsLayer = true
        for child in [toolbar, tabs, status] { content.addSubview(child) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            tabs.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            tabs.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -7),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -9),
            status.heightAnchor.constraint(equalToConstant: 16)
        ])
        // Mirror the native failure: a first plain tab, a JSON split, then a
        // newly created plain tab. Each session begins with a zero-size scroll view.
        for file in [nil, loaded, nil] as [LoadedTextFile?] {
            let session = EditorSession(file: file)
            sessions.append(session)
            XCTAssertEqual(session.scrollView.frame.size, .zero)
            tabs.addTabViewItem(session.item)
            tabs.selectTabViewItem(session.item)
            window.makeFirstResponder(session.textView)
            if file == nil {
                session.textView.insertText("def main():\n    return 1\nmain()", replacementRange: NSRange(location: 0, length: 0))
                session.languageOverride = .python
            }
            content.layoutSubtreeIfNeeded()
            try await waitUntil { session.lineRuler.displayedRevision == session.revision }
            // Include asynchronous highlighting and the first split-divider layout.
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertLessThanOrEqual(session.lineRuler.frame.width, session.lineRuler.ruleThickness + 1)
            XCTAssertEqual(session.lineRuler.visibleLabels().map(\.line), file == nil ? [1, 2, 3] : [1, 2, 3, 4])
            try assertGutterRendered(in: content, session: session)
            XCTAssertNotNil(session.textView.textLayoutManager)
        }
        tabs.selectTabViewItem(sessions[0].item)
        tabs.selectTabViewItem(sessions[2].item)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(sessions[2].lineRuler.visibleLabels().map(\.line), [1, 2, 3])
        try assertGutterRendered(in: content, session: sessions[2])
    }

    @MainActor
    private func assertGutterRendered(in content: NSView, session: EditorSession) throws {
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let ruler = session.lineRuler!
        let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
        let rect = content.convert(ruler.bounds, from: ruler)
        let top = content.bounds.maxY - rect.maxY
        func rgba(_ x: CGFloat, _ y: CGFloat) throws -> [CGFloat] {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
            return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        }
        func different(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> Bool {
            zip(lhs, rhs).contains { abs($0 - $1) > 0.1 }
        }
        for label in ruler.visibleLabels() {
            let y = top + ruler.convert(NSPoint(x: 0, y: label.textY), from: session.textView).y
            var foundInk = false
            for row in Int(y)..<Int(y + label.height) {
                let background = try rgba(rect.minX + 2, CGFloat(row))
                for column in 18..<38 where try different(rgba(rect.minX + CGFloat(column), CGFloat(row)), background) {
                    foundInk = true
                    break
                }
                if foundInk { break }
            }
            XCTAssertTrue(foundInk, "Logical line \(label.line) must be visible in the composited tab, not merely in ruler layout data")
        }
        // The ruler's superclass also draws. Its separator must not extend up
        // through toolbar/titlebar when AppKit gives it a window-sized dirty rect.
        XCTAssertFalse(try different(rgba(rect.maxX - 0.5, 4), rgba(rect.maxX + 2, 4)))
    }

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
