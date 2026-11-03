import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class CSVTableControllerTests: XCTestCase {
    @MainActor
    func testHeaderAndDelimiterOnlyChangePresentationAndKeepSourceRanges() async throws {
        _ = NSApplication.shared
        let source = "姓名,编号\r\n中文🦊,00123\n只有名字\n"
        var replacements = 0
        let controller = CSVTableController(delimiter: .comma, snapshot: { (source, 7) },
            replace: { _, _, _, _ in replacements += 1; return false }, selectSource: { _ in })
        defer { controller.cancelParsing() }
        try await settle(controller) { controller.refresh(immediately: true) }
        XCTAssertEqual(controller.numberOfRows(in: controller.tableView), 3)
        XCTAssertTrue(controller.setFirstRowAsHeader(true))
        XCTAssertEqual(controller.numberOfRows(in: controller.tableView), 2)
        XCTAssertEqual(controller.sourceRecordIndex(forDisplayRow: 0), 1)
        XCTAssertEqual(controller.displayRow(forSourceRecord: 2), 1)
        XCTAssertNil(controller.displayRow(forSourceRecord: 0))
        XCTAssertEqual(controller.tableView.tableColumns[1].title, "姓名")
        XCTAssertEqual(controller.tableView.tableColumns[2].title, "编号")
        let edit = try XCTUnwrap(controller.prepareEdit(row: 0, column: 1))
        XCTAssertEqual(edit.row, 1)
        XCTAssertEqual(edit.value, "00123")
        XCTAssertEqual(edit.snapshot.document.field(row: edit.row, column: edit.column)?.rawRange,
                       (source as NSString).range(of: "00123"))
        let cell = try XCTUnwrap(controller.tableView(controller.tableView,
            viewFor: controller.tableView.tableColumns[2], row: 0) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.stringValue, "00123")
        XCTAssertFalse(try XCTUnwrap(cell.textField).isEditable)
        let missing = try XCTUnwrap(controller.tableView(controller.tableView,
            viewFor: controller.tableView.tableColumns[2], row: 1) as? NSTableCellView)
        XCTAssertEqual(missing.textField?.stringValue, "—")
        XCTAssertNil(controller.prepareEdit(row: 1, column: 1))
        XCTAssertTrue(controller.setFirstRowAsHeader(false))
        XCTAssertEqual(controller.sourceRecordIndex(forDisplayRow: 0), 0)
        XCTAssertEqual(controller.tableView.tableColumns[1].title, "Column 1")
        try await settle(controller) { XCTAssertTrue(controller.setDelimiter(.tab)) }
        XCTAssertEqual(controller.parsed?.document.maximumColumnCount, 1)
        XCTAssertEqual(controller.parsed?.document.records[1].fields[0].value, "中文🦊,00123")
        XCTAssertEqual(Data(try XCTUnwrap(controller.parsed).text.utf8), Data(source.utf8))
        XCTAssertEqual(replacements, 0)
        XCTAssertEqual(CSVTableController.delimiter(for: URL(fileURLWithPath: "/tmp/file.TSV")), .tab)
        XCTAssertNil(CSVTableController.delimiter(for: URL(fileURLWithPath: "/tmp/file.txt")))
    }

    @MainActor
    func testPendingCellEditLocksConfigurationAndCancelNeverWrites() async throws {
        _ = NSApplication.shared
        let source = "a,b\nx,00123"
        var replacements = 0
        let controller = CSVTableController(delimiter: .comma, snapshot: { (source, 0) },
            replace: { _, _, _, _ in replacements += 1; return true }, selectSource: { _ in })
        defer { controller.cancelParsing() }
        try await settle(controller) { controller.refresh(immediately: true) }
        XCTAssertNotNil(controller.beginCellEdit(row: 1, column: 1))
        XCTAssertTrue(controller.hasPendingCellEdit)
        XCTAssertFalse(controller.setDelimiter(.tab))
        XCTAssertFalse(controller.setFirstRowAsHeader(true))
        XCTAssertEqual(controller.delimiter, .comma)
        XCTAssertFalse(controller.usesFirstRowAsHeader)
        XCTAssertNil(controller.beginCellEdit(row: 0, column: 0))
        controller.cancelCellEditor()
        XCTAssertFalse(controller.hasPendingCellEdit)
        XCTAssertTrue(controller.setFirstRowAsHeader(true))
        XCTAssertEqual(replacements, 0)
        XCTAssertEqual(Data(try XCTUnwrap(controller.parsed).text.utf8), Data(source.utf8))
    }

    @MainActor
    func testCellApplyUsesRealTextViewUndoAndOnlyReplacesItsRawRange() async throws {
        _ = NSApplication.shared
        let session = EditorSession()
        defer { session.syntax.cancel() }
        let original = "\"姓名\",编号,备注\r\n\"中文🦊\",00123,=A1\n"
        session.textView.string = original
        session.baseline = original
        var revision: UInt64 = 1
        var replacements = 0
        let controller = CSVTableController(delimiter: .comma, snapshot: { (session.textView.string, revision) },
            replace: { range, expected, replacement, expectedRevision in
                guard revision == expectedRevision,
                      (session.textView.string as NSString).substring(with: range).utf16.elementsEqual(expected.utf16) else { return false }
                session.textView.breakUndoCoalescing()
                session.undoStack.beginUndoGrouping()
                defer {
                    session.undoStack.endUndoGrouping()
                    session.textView.breakUndoCoalescing()
                }
                guard session.textView.shouldChangeText(in: range, replacementString: replacement) else { return false }
                session.textView.textStorage?.replaceCharacters(in: range, with: replacement)
                session.textView.didChangeText()
                revision &+= 1
                replacements += 1
                return true
            }, selectSource: { _ in })
        defer { controller.cancelParsing() }
        try await settle(controller) { controller.refresh(immediately: true) }
        XCTAssertTrue(controller.setFirstRowAsHeader(true))
        let edit = try XCTUnwrap(controller.prepareEdit(row: 0, column: 1))
        XCTAssertTrue(controller.apply("00123", for: edit))
        XCTAssertEqual(replacements, 0, "A no-op preserves quotes and does not add undo")
        XCTAssertFalse(session.undoStack.canUndo)
        XCTAssertTrue(controller.apply("00077,\"中\"\n🦊", for: edit))
        let expected = "\"姓名\",编号,备注\r\n\"中文🦊\",\"00077,\"\"中\"\"\n🦊\",=A1\n"
        XCTAssertEqual(Data(session.textView.string.utf8), Data(expected.utf8))
        XCTAssertEqual(replacements, 1)
        XCTAssertTrue(session.dirty)
        XCTAssertTrue(session.textView.undoManager === session.undoStack)
        session.undoStack.undo()
        revision &+= 1
        XCTAssertEqual(Data(session.textView.string.utf8), Data(original.utf8))
        XCTAssertFalse(session.dirty)
        XCTAssertFalse(session.undoStack.canUndo, "One cell apply is exactly one document undo")
        session.undoStack.redo()
        XCTAssertEqual(Data(session.textView.string.utf8), Data(expected.utf8))
    }

    @MainActor
    func testStaleRevisionAndCanonicallyEquivalentChangedSourceCannotBeEdited() async throws {
        _ = NSApplication.shared
        var source = "name,e\u{301}\n"
        var revision: UInt64 = 0
        var replacements = 0
        let controller = CSVTableController(delimiter: .comma, snapshot: { (source, revision) },
            replace: { _, _, _, _ in replacements += 1; return true }, selectSource: { _ in })
        defer { controller.cancelParsing() }
        try await settle(controller) { controller.refresh(immediately: true) }
        let edit = try XCTUnwrap(controller.prepareEdit(row: 0, column: 1))
        // Defend even against an integration bug that forgot to advance revision:
        // Swift String equality considers these two source strings equivalent.
        source = "name,é\n"
        XCTAssertEqual(source, edit.snapshot.text)
        XCTAssertFalse(controller.apply("new", for: edit))
        XCTAssertEqual(replacements, 0)
        try await settle(controller) { controller.refresh(immediately: true) }
        let newerEdit = try XCTUnwrap(controller.prepareEdit(row: 0, column: 1))
        revision += 1
        XCTAssertFalse(controller.apply("new", for: newerEdit))
        XCTAssertEqual(replacements, 0)
        XCTAssertEqual(Data(source.utf8), Data("name,é\n".utf8))
    }

    @MainActor
    func testLateCancelledParserCannotReplaceTheNewestTable() async throws {
        _ = NSApplication.shared
        let oldStarted = expectation(description: "Old worker started")
        let oldFinished = expectation(description: "Old worker returned after cancellation")
        let obsoletePublished = expectation(description: "Obsolete result must not publish")
        obsoletePublished.isInverted = true
        let releaseOld = DispatchSemaphore(value: 0)
        let cancellation = CancellationObservation()
        var source = "old,00123"
        var revision: UInt64 = 0
        let controller = CSVTableController(delimiter: .comma, parser: { text, delimiter, limits, isCancelled in
            if text.hasPrefix("old") {
                oldStarted.fulfill()
                _ = releaseOld.wait(timeout: .now() + 5)
                cancellation.set(isCancelled())
                let result = try CSVDocument.parse(text, delimiter: delimiter, limits: limits)
                oldFinished.fulfill()
                return result // Deliberately ignore cancellation: the UI must still reject it.
            }
            return try CSVDocument.parse(text, delimiter: delimiter, limits: limits, isCancelled: isCancelled)
        }, snapshot: { (source, revision) }, replace: { _, _, _, _ in false }, selectSource: { _ in })
        defer { releaseOld.signal(); controller.cancelParsing() }
        controller.refresh(immediately: true)
        await fulfillment(of: [oldStarted], timeout: 5)
        source = "latest,00999"
        revision = 1
        try await settle(controller) { controller.refresh(immediately: true) }
        controller.stateDidChange = {
            if controller.state == .ready, controller.parsed?.text.hasPrefix("old") == true { obsoletePublished.fulfill() }
        }
        releaseOld.signal()
        await fulfillment(of: [oldFinished], timeout: 5)
        await fulfillment(of: [obsoletePublished], timeout: 0.1)
        XCTAssertTrue(cancellation.value)
        XCTAssertEqual(controller.parsed?.text, "latest,00999")
        XCTAssertEqual(controller.parsed?.revision, 1)
        controller.stateDidChange = nil
    }

    @MainActor
    func testCancellingAnActiveParseLeavesNoEditableSnapshot() async throws {
        _ = NSApplication.shared
        let started = expectation(description: "Worker started")
        let finished = expectation(description: "Worker returned")
        let published = expectation(description: "Cancelled result must not publish")
        published.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let controller = CSVTableController(delimiter: .comma, parser: { text, delimiter, limits, _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            let document = try CSVDocument.parse(text, delimiter: delimiter, limits: limits)
            finished.fulfill()
            return document
        }, snapshot: { ("a,b", 0) }, replace: { _, _, _, _ in false }, selectSource: { _ in })
        defer { release.signal(); controller.cancelParsing() }
        controller.stateDidChange = { if controller.state == .ready { published.fulfill() } }
        controller.refresh(immediately: true)
        await fulfillment(of: [started], timeout: 5)
        controller.cancelParsing()
        XCTAssertEqual(controller.state, .idle)
        release.signal()
        await fulfillment(of: [finished], timeout: 5)
        await fulfillment(of: [published], timeout: 0.1)
        XCTAssertNil(controller.parsed)
        XCTAssertNil(controller.prepareEdit(row: 0, column: 0))
        controller.stateDidChange = nil
    }

    @MainActor
    func testInvalidTableKeepsSourceAndRecoversAfterSourceRepair() async throws {
        _ = NSApplication.shared
        var source = "name,\"unclosed"
        var revision: UInt64 = 0
        let controller = CSVTableController(delimiter: .comma, snapshot: { (source, revision) },
            replace: { _, _, _, _ in XCTFail("Invalid table must never edit"); return false }, selectSource: { _ in })
        defer { controller.cancelParsing() }
        try await settle(controller, expectedState: .failed) { controller.refresh(immediately: true) }
        XCTAssertNil(controller.prepareEdit(row: 0, column: 0))
        XCTAssertEqual(source, "name,\"unclosed")
        guard case .unclosedQuotedField = controller.lastError as? CSVDocumentError else {
            return XCTFail("Expected a positioned CSV error")
        }
        source += "\""
        revision += 1
        try await settle(controller) { controller.refresh(immediately: true) }
        XCTAssertEqual(controller.prepareEdit(row: 0, column: 1)?.value, "unclosed")
    }

    @MainActor
    func testVisibleCellsAreBoundedButEditingKeepsTheEntireValue() async throws {
        _ = NSApplication.shared
        let value = String(repeating: "🦊", count: 2_000)
        let controller = CSVTableController(delimiter: .comma, snapshot: { ("key," + value, 0) },
            replace: { _, _, _, _ in false }, selectSource: { _ in })
        defer { controller.cancelParsing() }
        try await settle(controller) { controller.refresh(immediately: true) }
        let cell = try XCTUnwrap(controller.tableView(controller.tableView,
            viewFor: controller.tableView.tableColumns[2], row: 0) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.stringValue.unicodeScalars.count, 512)
        XCTAssertEqual(controller.prepareEdit(row: 0, column: 1)?.value, value)
    }

    @MainActor
    func testEmbeddedLineBreaksAreVisibleMarkersWithoutChangingCellValueOrSource() async throws {
        _ = NSApplication.shared
        let value = "first\r\n第二行 🦊\nthird\rlast\u{2028}separator"
        let source = "id,\"" + value + "\"\r\n"
        var replacements = 0
        let controller = CSVTableController(delimiter: .comma, snapshot: { (source, 0) },
            replace: { _, _, _, _ in replacements += 1; return false }, selectSource: { _ in })
        defer { controller.cancelParsing() }
        try await settle(controller) { controller.refresh(immediately: true) }
        let cell = try XCTUnwrap(controller.tableView(controller.tableView,
            viewFor: controller.tableView.tableColumns[2], row: 0) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.stringValue, "first ↵ 第二行 🦊 ↵ third ↵ last ↵ separator")
        let edit = try XCTUnwrap(controller.prepareEdit(row: 0, column: 1))
        XCTAssertEqual(Array(edit.value.utf16), Array(value.utf16))
        XCTAssertTrue(controller.apply(value, for: edit))
        XCTAssertEqual(replacements, 0)
        XCTAssertTrue(controller.setFirstRowAsHeader(true))
        XCTAssertEqual(controller.tableView.tableColumns[2].title, "first ↵ 第二行 🦊 ↵ third ↵ last ↵ separator")
        XCTAssertEqual(Data(try XCTUnwrap(controller.parsed).text.utf8), Data(source.utf8))
    }

    @MainActor
    private func settle(_ controller: CSVTableController, expectedState: CSVTableController.State = .ready,
                        action: () -> Void) async throws {
        let finished = expectation(description: "Table parse settled")
        var fulfilled = false
        controller.stateDidChange = {
            if !fulfilled, controller.state == .ready || controller.state == .failed {
                fulfilled = true
                finished.fulfill()
            }
        }
        action()
        if !fulfilled, controller.state == .ready || controller.state == .failed {
            fulfilled = true
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        controller.stateDidChange = nil
        XCTAssertEqual(controller.state, expectedState)
    }
}

private final class CancellationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return observed }
    func set(_ value: Bool) { lock.lock(); observed = value; lock.unlock() }
}
