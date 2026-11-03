import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class JSONTreeControllerTests: XCTestCase {
    @MainActor
    func testReadOnlyTreePreservesOrderDuplicatesAndNumberLexemes() async throws {
        _ = NSApplication.shared
        let source = #"{"a":900719925474099312345,"a":1.2300e+04,"nested":{"items":[true,null]}}"#
        var selections: [NSRange] = []
        let controller = JSONTreeController(snapshot: { (source, 7) }, selectSource: { selections.append($0) })
        defer { controller.cancel() }
        controller.refresh()
        try await waitUntil { controller.displayedRevision == 7 }

        XCTAssertEqual(controller.structure?.source, source)
        XCTAssertEqual(controller.outlineView.numberOfRows, 4, "Only the root is initially expanded")
        let first = try XCTUnwrap(controller.outlineView.item(atRow: 1) as? JSONTreeItem)
        let second = try XCTUnwrap(controller.outlineView.item(atRow: 2) as? JSONTreeItem)
        let nested = try XCTUnwrap(controller.outlineView.item(atRow: 3) as? JSONTreeItem)
        XCTAssertEqual(first.label, #""a""#)
        XCTAssertEqual(second.label, first.label)
        XCTAssertTrue(first.duplicateKey)
        XCTAssertTrue(second.duplicateKey)
        XCTAssertEqual(controller.valueSummary(for: first), "900719925474099312345")
        XCTAssertEqual(controller.valueSummary(for: second), "1.2300e+04")
        XCTAssertFalse(controller.outlineView.isItemExpanded(nested))

        controller.outlineView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(selections.last, second.node.tokenRange)
        XCTAssertEqual(controller.selectedPointer?.value, "/a")
        XCTAssertEqual(controller.selectedPointer?.isAmbiguous, true)
        let pointerButton = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NSButton }
            .first { $0.title == "Copy JSON Pointer" })
        XCTAssertFalse(pointerButton.isEnabled, "Duplicate paths must never be copied as unique pointers")

        controller.revealSourceRange((source as NSString).range(of: "null"))
        XCTAssertEqual(controller.selectedPointer?.value, "/nested/items/1")
        XCTAssertEqual(controller.selectedPointer?.isAmbiguous, false)
        XCTAssertTrue(pointerButton.isEnabled)
        XCTAssertEqual(selections.count, 1, "Source-to-tree navigation must not feed another source selection back")
        let keyRange = (source as NSString).range(of: #""nested""#)
        controller.revealSourceRange(NSRange(location: keyRange.location + 2, length: 0))
        XCTAssertEqual(controller.selectedPointer?.value, "/nested")
        XCTAssertEqual(controller.structure?.source, source, "Navigation never serializes or edits the source")
    }

    func testSearchUsesDecodedKeysAndValuesButPreservesSourceRangesAndRawNumbers() throws {
        let source = #"{"\u4e2d":900719925474099312345,"中":"v\u0061lue","nested":["VALUE",null,true,1.2300e+04]}"#
        let parsed = try JSONStructure.parse(source)
        let keyMatches = JSONTreeSearch.matches(in: parsed, query: "中")
        XCTAssertEqual(keyMatches.count, 2)
        XCTAssertEqual(parsed.rawToken(in: keyMatches[0].selectionRange), #""\u4e2d""#)
        XCTAssertEqual(parsed.rawToken(in: keyMatches[1].selectionRange), #""中""#)
        let values = JSONTreeSearch.matches(in: parsed, query: "value")
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(parsed.rawToken(in: values[0].selectionRange), #""v\u0061lue""#)
        XCTAssertEqual(parsed.rawToken(in: values[1].selectionRange), #""VALUE""#)
        XCTAssertEqual(JSONTreeSearch.matches(in: parsed, query: "900719925474099312345").count, 1)
        XCTAssertEqual(JSONTreeSearch.matches(in: parsed, query: "1.2300e+04").count, 1)
        XCTAssertTrue(JSONTreeSearch.matches(in: parsed, query: "").isEmpty)
        XCTAssertTrue(JSONTreeSearch.matches(in: parsed, query: ".*").isEmpty, "Search is literal")
        XCTAssertTrue(JSONTreeSearch.matches(in: parsed, query: "value", isCancelled: { true }).isEmpty)
        XCTAssertEqual(parsed.source, source)
    }

    @MainActor
    func testLongKeyCellsAndTooltipsAreBoundedWithoutTruncatingSourceOrPointers() async throws {
        _ = NSApplication.shared
        let longKey = String(repeating: "🦊", count: 200_000)
        let text = "{\"\(longKey)\":1,\"dup\":2,\"dup\":3}"
        let controller = JSONTreeController(snapshot: { (text, 1) }, selectSource: { _ in })
        defer { controller.cancel() }
        controller.refresh()
        try await waitUntil { controller.displayedRevision == 1 }
        let item = try XCTUnwrap(controller.outlineView.item(atRow: 1) as? JSONTreeItem)
        let column = try XCTUnwrap(controller.outlineView.tableColumns.first)
        let cell = try XCTUnwrap(controller.outlineView(controller.outlineView, viewFor: column, item: item) as? NSTextField)
        XCTAssertEqual(cell.stringValue.unicodeScalars.count, 241, "240 complete scalars plus an ellipsis")
        XCTAssertTrue(cell.stringValue.hasSuffix("…"))
        XCTAssertFalse(cell.stringValue.contains("\u{FFFD}"), "Truncation must not split an emoji surrogate pair")
        XCTAssertEqual(cell.toolTip, cell.stringValue)
        XCTAssertEqual(item.label, "\"\(longKey)\"", "The underlying key lexeme remains complete")
        XCTAssertEqual(controller.structure?.source, text)
        controller.outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(controller.selectedPointer?.value, "/" + longKey)
        let pointerButton = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NSButton }
            .first { $0.title == "Copy JSON Pointer" })
        XCTAssertEqual(pointerButton.toolTip?.unicodeScalars.count, 241)
        XCTAssertTrue(pointerButton.isEnabled)

        let duplicate = try XCTUnwrap(controller.outlineView.item(atRow: 2) as? JSONTreeItem)
        let duplicateCell = try XCTUnwrap(controller.outlineView(controller.outlineView, viewFor: column, item: duplicate) as? NSTextField)
        XCTAssertTrue(duplicateCell.stringValue.hasSuffix(" · Duplicate key"))
        XCTAssertEqual(duplicateCell.toolTip, duplicateCell.stringValue)
    }

    @MainActor
    func testRevealingRowsPreservesHorizontalPositionAndDoesNotRescrollSelectedRow() async throws {
        _ = NSApplication.shared
        let text = "{" + (0..<100).map { "\"key\($0)\":\($0)" }.joined(separator: ",") + "}"
        weak var linkedController: JSONTreeController?
        let controller = JSONTreeController(snapshot: { (text, 1) }, selectSource: { range in
            // Mirrors the source-selection notification sent back by the host.
            linkedController?.revealSourceRange(range)
        })
        linkedController = controller
        defer { controller.cancel() }
        controller.refresh()
        try await waitUntil { controller.displayedRevision == 1 }
        controller.view.setFrameSize(NSSize(width: 420, height: 260))
        controller.view.layoutSubtreeIfNeeded()
        let outline = controller.outlineView
        let scroll = try XCTUnwrap(outline.enclosingScrollView)
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        for column in outline.tableColumns { column.width = 600 }
        outline.setFrameSize(NSSize(width: 1_200, height: CGFloat(outline.numberOfRows) * (outline.rowHeight + outline.intercellSpacing.height)))
        scroll.tile()
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 150, y: 0))
        scroll.reflectScrolledClipView(clip)
        XCTAssertEqual(clip.bounds.minX, 150, accuracy: 0.5)

        let lastKey = (text as NSString).range(of: #""key99""#)
        controller.revealSourceRange(lastKey)
        XCTAssertEqual(outline.selectedRow, 100)
        XCTAssertEqual(clip.bounds.minX, 150, accuracy: 0.5,
                       "Navigation must not scroll the full row width into view")
        XCTAssertGreaterThan(clip.bounds.minY, 0)
        XCTAssertTrue(outline.visibleRect.intersects(outline.rect(ofRow: 100)))

        // Once a row is selected, source-selection feedback must not repeat the
        // selection or disturb a position the user has independently scrolled to.
        clip.scroll(to: NSPoint(x: 240, y: 0))
        scroll.reflectScrolledClipView(clip)
        controller.revealSourceRange(lastKey)
        XCTAssertEqual(clip.bounds.minX, 240, accuracy: 0.5)
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 0.5)

        // A direct tree selection causes the real delegate callback, which in
        // turn selects source and re-enters reveal through the linked closure.
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(clip.bounds.minX, 240, accuracy: 0.5)
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 0.5)
    }

    @MainActor
    func testInvalidRevisionClearsTreeAndErrorNavigationNeverUsesAnOldRevision() async throws {
        _ = NSApplication.shared
        var text = #"{"ok":true}"#
        var revision: UInt64 = 1
        var selections: [NSRange] = []
        let controller = JSONTreeController(snapshot: { (text, revision) }, selectSource: { selections.append($0) })
        defer { controller.cancel() }
        controller.refresh()
        try await waitUntil { controller.displayedRevision == 1 }
        text = "{\r\n\"🦊\": }"
        revision = 2
        controller.refresh()
        XCTAssertNil(controller.structure)
        XCTAssertEqual(controller.outlineView.numberOfRows, 0)
        try await waitUntil { controller.displayedRevision == 2 }
        let error = try XCTUnwrap(controller.parseError)
        XCTAssertEqual(error.kind, .expectedValue)
        XCTAssertNil(controller.structure)
        let position = JSONTreeController.sourcePosition(in: text, at: error.utf16Location)
        XCTAssertEqual(position.line, 2)
        XCTAssertEqual(position.column, 7, "Columns are UTF-16 offsets, like source selection ranges")
        controller.showParseError()
        XCTAssertEqual(selections, [NSRange(location: error.utf16Location, length: 0)])

        revision = 3
        controller.showParseError()
        XCTAssertEqual(selections.count, 1, "A changed source rejects even an old error location")
    }

    @MainActor
    func testSearchNavigationRevealsNestedResultsAndStopsWhenSourceChanges() async throws {
        _ = NSApplication.shared
        let text = #"{"items":[{"name":"needle"},{"name":"needle"}]}"#
        var revision: UInt64 = 5
        var selections: [NSRange] = []
        let controller = JSONTreeController(snapshot: { (text, revision) }, selectSource: { selections.append($0) })
        defer { controller.cancel() }
        controller.refresh()
        try await waitUntil { controller.displayedRevision == 5 }
        controller.setSearchQuery("needle")
        let next = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NSButton }
            .first { $0.title == "Next" })
        try await waitUntil { next.isEnabled }
        controller.nextMatch()
        XCTAssertEqual(controller.selectedPointer?.value, "/items/0/name")
        controller.nextMatch()
        XCTAssertEqual(controller.selectedPointer?.value, "/items/1/name")
        controller.nextMatch()
        XCTAssertEqual(controller.selectedPointer?.value, "/items/0/name")
        controller.previousMatch()
        XCTAssertEqual(controller.selectedPointer?.value, "/items/1/name")
        XCTAssertEqual(selections.count, 4)
        for selection in selections { XCTAssertEqual((text as NSString).substring(with: selection), #""needle""#) }
        revision += 1
        controller.nextMatch()
        XCTAssertEqual(selections.count, 4, "Source edits invalidate all cached search ranges")
    }

    @MainActor
    func testCancelledOldParserCannotReplaceNewerTree() async throws {
        _ = NSApplication.shared
        let gate = ParseGate()
        var text = #"{"old":true}"#
        var revision: UInt64 = 1
        let controller = JSONTreeController(snapshot: { (text, revision) }, selectSource: { _ in }, parser: { text in
            if text.contains("old") { gate.wait() }
            // Deliberately finish the old parse despite task cancellation to prove
            // publication checks do not depend on a cooperative parser alone.
            return try JSONStructure.parse(text, isCancelled: { false })
        })
        defer { gate.release(); controller.cancel() }
        controller.refresh()
        try await waitUntil { gate.hasStarted }
        text = #"{"new":42}"#
        revision = 2
        controller.refresh()
        try await waitUntil { controller.displayedRevision == 2 }
        XCTAssertEqual(controller.structure?.source, text)
        gate.release()
        try await waitUntil { gate.hasFinished }
        // Let the old worker's main-actor continuation run after releasing it.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.displayedRevision, 2)
        XCTAssertEqual(controller.structure?.source, text)
    }

    @MainActor
    func testSourceRevisionChangeWithoutRefreshRejectsPendingParse() async throws {
        _ = NSApplication.shared
        let gate = ParseGate()
        var revision: UInt64 = 1
        let controller = JSONTreeController(snapshot: { (#"{"old":true}"#, revision) }, selectSource: { _ in }, parser: { text in
            gate.wait()
            return try JSONStructure.parse(text)
        })
        defer { gate.release(); controller.cancel() }
        controller.refresh()
        try await waitUntil { gate.hasStarted }
        revision = 2
        gate.release()
        try await waitUntil { gate.hasFinished }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(controller.displayedRevision)
        XCTAssertNil(controller.structure)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for a JSON tree result"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

private final class ParseGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var finished = false
    private var released = false

    var hasStarted: Bool {
        condition.lock(); defer { condition.unlock() }
        return started
    }

    var hasFinished: Bool {
        condition.lock(); defer { condition.unlock() }
        return finished
    }

    func wait() {
        condition.lock()
        started = true
        while !released { condition.wait() }
        finished = true
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
