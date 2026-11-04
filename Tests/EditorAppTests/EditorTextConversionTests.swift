import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class EditorTextConversionTests: XCTestCase {
    @MainActor
    func testExplicitConversionMapsSelectionUsesOneUndoAndNeverSaves() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "中文 🦊\r\ne\u{301}\nlast\r"
        let loaded = try DocumentFile.save(source, to: directory.appendingPathComponent("text.txt"), encoding: .utf8BOM)
        let diskBytes = try Data(contentsOf: loaded.url)
        let session = EditorSession(file: loaded)
        defer { cleanUp(session) }
        let selection = (source as NSString).range(of: "e\u{301}\nlast")
        session.textView.setSelectedRange(selection)
        let expected = try NewlineConversion.convert(source, to: .crlf, selection: selection)

        let applied = await session.applyNewlineConversion(.crlf, actionName: "Convert Line Endings")
        XCTAssertTrue(applied)
        XCTAssertEqual(Array(session.textView.string.utf16), Array(expected.text.utf16))
        XCTAssertEqual(session.textView.selectedRange(), expected.selection)
        XCTAssertTrue(session.dirty)
        XCTAssertEqual(session.file?.diskSnapshot, loaded.diskSnapshot)
        XCTAssertEqual(try Data(contentsOf: loaded.url), diskBytes)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(session.undoStack.undoActionName, "Convert Line Endings")
        session.undoStack.undo()
        XCTAssertEqual(Array(session.textView.string.utf16), Array(source.utf16))
        XCTAssertFalse(session.dirty)
        XCTAssertFalse(session.undoStack.canUndo, "The complete conversion is one edit")
        session.undoStack.redo()
        XCTAssertEqual(Array(session.textView.string.utf16), Array(expected.text.utf16))
        XCTAssertEqual(try Data(contentsOf: loaded.url), diskBytes)
    }

    @MainActor
    func testNoOpDoesNotChangeRevisionSelectionOrUndo() async {
        _ = NSApplication.shared
        let source = "e\u{301}\r\n中文 🦊\r\n"
        let session = session(with: source)
        defer { cleanUp(session) }
        let selection = NSRange(location: 3, length: 1) // Between unchanged CR and LF.
        session.textView.setSelectedRange(selection)
        let revision = session.revision
        let applied = await session.applyNewlineConversion(.crlf, actionName: "Convert")
        XCTAssertTrue(applied)
        XCTAssertEqual(Array(session.textView.string.utf16), Array(source.utf16))
        XCTAssertEqual(session.textView.selectedRange(), selection)
        XCTAssertEqual(session.revision, revision)
        XCTAssertFalse(session.dirty)
        XCTAssertFalse(session.undoStack.canUndo)
    }

    @MainActor
    func testSelectionRaceRejectsResultAndPendingFlagExcludesOtherCommands() async throws {
        _ = NSApplication.shared
        let source = "first\r\nsecond"
        let session = session(with: source)
        let gate = NewlinePlanGate()
        defer { gate.release(); cleanUp(session) }
        let pending = Task { await session.applyNewlineConversion(.lf, actionName: "Convert", planner: gate.planner) }
        try await waitUntil { gate.hasStarted }
        XCTAssertFalse(gate.startedOnMainThread)
        XCTAssertTrue(session.lineEditPending)
        let repeated = await session.applyNewlineConversion(.cr, actionName: "Convert")
        let lineEdit = try await session.applyLineOperation(.indent(unit: "  "), actionName: "Indent")
        XCTAssertFalse(repeated)
        XCTAssertFalse(lineEdit)
        let selection = NSRange(location: 7, length: 6)
        session.textView.setSelectedRange(selection)
        gate.release()
        let applied = await pending.value
        XCTAssertFalse(applied)
        XCTAssertEqual(session.textView.string, source)
        XCTAssertEqual(session.textView.selectedRange(), selection)
        XCTAssertFalse(session.undoStack.canUndo)
        XCTAssertFalse(session.lineEditPending)
        let retry = await session.applyNewlineConversion(.lf, actionName: "Convert")
        XCTAssertTrue(retry)
        XCTAssertEqual(session.textView.string, "first\nsecond")
    }

    @MainActor
    func testUserEditDuringPlanningRetainsItsOwnUndo() async throws {
        _ = NSApplication.shared
        let source = "first\r\nsecond"
        let session = session(with: source)
        let gate = NewlinePlanGate()
        defer { gate.release(); cleanUp(session) }
        let selection = session.textView.selectedRange()
        let pending = Task { await session.applyNewlineConversion(.lf, actionName: "Convert", planner: gate.planner) }
        try await waitUntil { gate.hasStarted }
        session.textView.insertText("!", replacementRange: NSRange(location: source.utf16.count, length: 0))
        session.textView.setSelectedRange(selection)
        gate.release()
        let applied = await pending.value
        XCTAssertFalse(applied)
        XCTAssertEqual(session.textView.string, source + "!")
        try await Task.sleep(for: .milliseconds(20))
        session.undoStack.undo()
        XCTAssertEqual(session.textView.string, source)
        XCTAssertFalse(session.undoStack.canUndo)
    }

    @MainActor
    func testExactUTF16GuardRejectsUnreportedCanonicalChangeEvenForNoOp() async throws {
        _ = NSApplication.shared
        let source = "e\u{301}\nnext"
        let session = session(with: source)
        let gate = NewlinePlanGate()
        defer { gate.release(); cleanUp(session) }
        session.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let revision = session.revision
        let pending = Task { await session.applyNewlineConversion(.lf, actionName: "Convert", planner: gate.planner) }
        try await waitUntil { gate.hasStarted }
        session.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 2), with: "é")
        session.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(session.revision, revision, "Direct storage mutation does not notify the session delegate")
        XCTAssertEqual(session.textView.string, source, "Canonical String equality cannot detect this change")
        XCTAssertFalse(session.textView.string.utf16.elementsEqual(source.utf16))
        gate.release()
        let applied = await pending.value
        XCTAssertFalse(applied)
        XCTAssertEqual(Array(session.textView.string.utf16), Array("é\nnext".utf16))
        XCTAssertFalse(session.undoStack.canUndo)
    }

    @MainActor
    func testCompositionBeforeOrDuringPlanningIsNeverCommitted() async throws {
        _ = NSApplication.shared
        let session = session(with: "first\r\nsecond")
        let gate = NewlinePlanGate()
        defer { gate.release(); session.textView.unmarkText(); cleanUp(session) }
        let pending = Task { await session.applyNewlineConversion(.lf, actionName: "Convert", planner: gate.planner) }
        try await waitUntil { gate.hasStarted }
        session.textView.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 5))
        let source = session.textView.string, selection = session.textView.selectedRange(), marked = session.textView.markedRange()
        gate.release()
        let applied = await pending.value
        XCTAssertFalse(applied)
        let rejected = await session.applyNewlineConversion(.cr, actionName: "Convert")
        XCTAssertFalse(rejected)
        XCTAssertEqual(session.textView.string, source)
        XCTAssertEqual(session.textView.selectedRange(), selection)
        XCTAssertEqual(session.textView.markedRange(), marked)
        XCTAssertTrue(session.textView.hasMarkedText())
        XCTAssertFalse(session.lineEditPending)
    }

    @MainActor
    func testHostLossRejectsResultAndDoesNotDeliverStaleError() async throws {
        _ = NSApplication.shared
        for error in [nil, NewlineConversionError.invalidSelection] {
            let session = session(with: "first\r\nsecond")
            let gate = NewlinePlanGate(error: error)
            defer { gate.release(); cleanUp(session) }
            var host: ConversionHost? = ConversionHost()
            var reportedErrors = 0
            let pending = Task {
                await session.applyNewlineConversion(.lf, actionName: "Convert", planner: gate.planner,
                    isEligible: { [weak host] in host != nil }, onError: { _ in reportedErrors += 1 })
            }
            try await waitUntil { gate.hasStarted }
            host = nil
            gate.release()
            let applied = await pending.value
            XCTAssertFalse(applied)
            XCTAssertEqual(reportedErrors, 0)
            XCTAssertFalse(session.undoStack.canUndo)
            XCTAssertFalse(session.lineEditPending)
            XCTAssertEqual(session.textView.string, "first\r\nsecond")
        }
    }

    @MainActor
    func testSheetAndReadOnlyGuardsBeforeAndAfterPlanning() async throws {
        _ = NSApplication.shared
        let session = session(with: "first\r\nsecond")
        let window = ConversionTestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                          styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sheet.isReleasedWhenClosed = false
        window.contentView = session.item.view
        defer { window.simulatedSheet = nil; window.contentView = nil; window.close(); sheet.close(); cleanUp(session) }
        for blockedBySheet in [true, false] {
            let gate = NewlinePlanGate()
            defer { gate.release() }
            let pending = Task { await session.applyNewlineConversion(.lf, actionName: "Convert", planner: gate.planner) }
            try await waitUntil { gate.hasStarted }
            if blockedBySheet { window.simulatedSheet = sheet } else { session.textView.isEditable = false }
            gate.release()
            let applied = await pending.value
            XCTAssertFalse(applied)
            let rejected = await session.applyNewlineConversion(.lf, actionName: "Convert")
            XCTAssertFalse(rejected)
            XCTAssertEqual(session.textView.string, "first\r\nsecond")
            XCTAssertFalse(session.undoStack.canUndo)
            window.simulatedSheet = nil
            session.textView.isEditable = true
        }
        let preview = EditorSession(readOnlyURL: URL(fileURLWithPath: "/preview.txt"))
        defer { cleanUp(preview) }
        preview.textView.string = "first\r\nsecond"
        preview.textView.isEditable = true // A read-only session is still ineligible.
        let rejected = await preview.applyNewlineConversion(.lf, actionName: "Convert")
        XCTAssertFalse(rejected)
    }

    @MainActor
    func testCancellationAndBudgetErrorNeverMutateAndAllowRetry() async throws {
        _ = NSApplication.shared
        let source = "first\r\nsecond"
        let session = session(with: source)
        let gate = NewlinePlanGate()
        defer { gate.release(); cleanUp(session) }
        var errors: [Error] = []
        let pending = Task {
            await session.applyNewlineConversion(.lf, actionName: "Convert", planner: gate.planner, onError: { errors.append($0) })
        }
        try await waitUntil { gate.hasStarted }
        pending.cancel()
        gate.release()
        let cancelled = await pending.value
        XCTAssertFalse(cancelled)
        XCTAssertTrue(errors.isEmpty)
        let overBudget = await session.applyNewlineConversion(.crlf, actionName: "Convert", planner: {
            try NewlineConversion.convert($0, to: $1, selection: $2, limits: .init(maximumOutputUTF16Units: 2))
        }, onError: { errors.append($0) })
        XCTAssertFalse(overBudget)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first as? NewlineConversionError, .outputLimitExceeded(limit: 2))
        XCTAssertEqual(session.textView.string, source)
        XCTAssertFalse(session.undoStack.canUndo)
        XCTAssertFalse(session.lineEditPending)
        let retry = await session.applyNewlineConversion(.lf, actionName: "Convert")
        XCTAssertTrue(retry)
    }

    @MainActor
    func testCSVCellEditStartedDuringPlanningRemainsValid() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "name,value\r\nalpha,00123\r\n"
        let loaded = try DocumentFile.save(source, to: directory.appendingPathComponent("pending.csv"), encoding: .utf8)
        let session = EditorSession(file: loaded)
        let gate = NewlinePlanGate()
        defer { gate.release(); session.presentation?.csv?.cancelCellEditor(); cleanUp(session) }
        let presentation = try XCTUnwrap(session.presentation), csv = try XCTUnwrap(presentation.csv)
        try await waitUntil { csv.parsed?.revision == session.revision }
        XCTAssertTrue(presentation.setShowsStructure(false))
        let selection = session.textView.selectedRange()
        let pending = Task { await session.applyNewlineConversion(.lf, actionName: "Convert", planner: gate.planner) }
        try await waitUntil { gate.hasStarted }
        XCTAssertTrue(presentation.setShowsStructure(true))
        let cellEdit = try XCTUnwrap(csv.beginCellEdit(row: 1, column: 1))
        session.textView.setSelectedRange(selection)
        gate.release()
        let applied = await pending.value
        XCTAssertFalse(applied)
        XCTAssertTrue(csv.hasPendingCellEdit)
        XCTAssertEqual(session.textView.string, source)
        XCTAssertFalse(session.undoStack.canUndo)
        XCTAssertTrue(csv.apply("00042", for: cellEdit))
        csv.cancelCellEditor()
        XCTAssertEqual(session.textView.string, "name,value\r\nalpha,00042\r\n")
        XCTAssertEqual(try DocumentFile.read(loaded.url).text, source)
    }

    @MainActor private func session(with source: String) -> EditorSession {
        let session = EditorSession()
        session.textView.string = source
        session.baseline = source
        session.textDidChange(Notification(name: NSText.didChangeNotification, object: session.textView))
        return session
    }

    @MainActor private func cleanUp(_ session: EditorSession) {
        session.presentation?.cancel()
        session.lineRuler.invalidate()
        session.decorations?.invalidate()
        session.syntax.cancel()
        session.stopFileObservation()
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out awaiting the conversion planner or CSV parser")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor private final class ConversionHost {}

/// Keeps both windows hidden while deterministically exercising the actual
/// textView.window.attachedSheet guard, without starting an AppKit modal loop.
@MainActor private final class ConversionTestWindow: NSWindow {
    var simulatedSheet: NSWindow?
    override var attachedSheet: NSWindow? { simulatedSheet ?? super.attachedSheet }
}

private final class NewlinePlanGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let error: NewlineConversionError?
    private var started = false, onMainThread = false, released = false
    init(error: NewlineConversionError? = nil) { self.error = error }

    var hasStarted: Bool {
        condition.lock(); defer { condition.unlock() }
        return started
    }
    var startedOnMainThread: Bool {
        condition.lock(); defer { condition.unlock() }
        return onMainThread
    }
    var planner: @Sendable (String, NewlineConversion.Target, NSRange) throws -> NewlineConversion.Conversion {
        { [self] source, target, selection in
            condition.lock()
            started = true
            onMainThread = Thread.isMainThread
            while !released { condition.wait() }
            condition.unlock()
            if let error { throw error }
            return try NewlineConversion.convert(source, to: target, selection: selection)
        }
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
