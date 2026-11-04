import AppKit
import EditorCore
import EditorUI
import XCTest
@testable import EditorApp

final class EditorTextCommandTests: XCTestCase {
    @MainActor
    func testLineCommandsShareNativeUndoAndPreserveMixedEndings() async throws {
        _ = NSApplication.shared
        let session = EditorSession()
        defer { session.lineRuler.invalidate(); session.syntax.cancel() }
        let source = "中文 🦊\r\n  second\nthird"
        session.textView.insertText(source, replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(20))
        session.textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).range(of: "third").location))
        let first = try await session.applyLineOperation(.indent(unit: "    "), actionName: "Indent")
        XCTAssertTrue(first)
        XCTAssertEqual(session.textView.string, "    中文 🦊\r\n      second\nthird")
        try await Task.sleep(for: .milliseconds(20))
        let second = try await session.applyLineOperation(.toggleLineComment(prefix: "#"), actionName: "Comment")
        XCTAssertTrue(second)
        XCTAssertEqual(session.textView.string, "    # 中文 🦊\r\n      # second\nthird")
        try await Task.sleep(for: .milliseconds(20))
        session.undoStack.undo()
        XCTAssertEqual(session.textView.string, "    中文 🦊\r\n      second\nthird")
        session.undoStack.undo()
        XCTAssertEqual(Array(session.textView.string.utf16), Array(source.utf16))
        session.undoStack.redo()
        XCTAssertEqual(session.textView.string, "    中文 🦊\r\n      second\nthird")
    }

    @MainActor
    func testCommentLanguageAndCompositionGuards() async throws {
        _ = NSApplication.shared
        let session = EditorSession()
        defer { session.lineRuler.invalidate(); session.syntax.cancel() }
        XCTAssertNil(session.lineCommentPrefix)
        session.languageOverride = .json
        XCTAssertNil(session.lineCommentPrefix)
        session.languageOverride = .jsonWithComments
        XCTAssertEqual(session.lineCommentPrefix, "//")
        session.languageOverride = .python
        XCTAssertEqual(session.lineCommentPrefix, "#")
        session.textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let result = try await session.applyLineOperation(.indent(unit: "    "), actionName: "Indent")
        XCTAssertFalse(result)
        XCTAssertEqual(session.textView.string, "中")
        XCTAssertTrue(session.textView.hasMarkedText())
        XCTAssertFalse(session.lineEditPending)
        session.textView.unmarkText()
    }

    @MainActor
    func testSelectionMoveWhilePlanningRejectsEditWithoutMovingNewSelection() async throws {
        _ = NSApplication.shared
        let source = "alpha\nbeta"
        let session = session(with: source)
        let gate = LineCommandPlanGate()
        defer { gate.release(); cleanUp(session) }
        let revision = session.revision
        session.textView.setSelectedRange(NSRange(location: 0, length: 5))
        let pending = Task {
            try await session.applyLineOperation(.indent(unit: "    "), actionName: "Indent", planner: gate.planner)
        }
        try await waitUntil { gate.hasStarted }
        XCTAssertTrue(session.lineEditPending)
        XCTAssertFalse(gate.startedOnMainThread)
        let newSelection = NSRange(location: 6, length: 4)
        session.textView.setSelectedRange(newSelection)
        XCTAssertEqual(session.revision, revision, "Only the selection changed")
        gate.release()
        let applied = try await pending.value
        XCTAssertFalse(applied)
        XCTAssertEqual(session.textView.string, source)
        XCTAssertEqual(session.textView.selectedRange(), newSelection)
        XCTAssertFalse(session.undoStack.canUndo)
        XCTAssertFalse(session.lineEditPending)
    }

    @MainActor
    func testSourceEditWhilePlanningRejectsOldRevisionAndPreservesUserUndo() async throws {
        _ = NSApplication.shared
        let source = "alpha\nbeta"
        let session = session(with: source)
        let gate = LineCommandPlanGate()
        defer { gate.release(); cleanUp(session) }
        let originalSelection = NSRange(location: 0, length: 5)
        session.textView.setSelectedRange(originalSelection)
        let originalRevision = session.revision
        let pending = Task {
            try await session.applyLineOperation(.indent(unit: "    "), actionName: "Indent", planner: gate.planner)
        }
        try await waitUntil { gate.hasStarted }
        session.textView.insertText("!", replacementRange: NSRange(location: source.utf16.count, length: 0))
        session.textView.setSelectedRange(originalSelection)
        XCTAssertGreaterThan(session.revision, originalRevision)
        gate.release()
        let applied = try await pending.value
        XCTAssertFalse(applied)
        XCTAssertEqual(session.textView.string, source + "!")
        XCTAssertEqual(session.textView.selectedRange(), originalSelection)
        XCTAssertFalse(session.lineEditPending)
        try await Task.sleep(for: .milliseconds(20))
        session.undoStack.undo()
        XCTAssertEqual(session.textView.string, source, "The user's edit remains independently undoable")
        XCTAssertFalse(session.undoStack.canUndo, "A rejected line operation creates no undo entry")
    }

    @MainActor
    func testCompositionStartedWhilePlanningIsNotCommittedOrReplaced() async throws {
        _ = NSApplication.shared
        let session = session(with: "alpha\nbeta")
        let gate = LineCommandPlanGate()
        defer { gate.release(); session.textView.unmarkText(); cleanUp(session) }
        session.textView.setSelectedRange(NSRange(location: 0, length: 5))
        let pending = Task {
            try await session.applyLineOperation(.toggleLineComment(prefix: "#"), actionName: "Comment", planner: gate.planner)
        }
        try await waitUntil { gate.hasStarted }
        session.textView.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                                       replacementRange: NSRange(location: 0, length: 5))
        let composingSource = session.textView.string
        let composingSelection = session.textView.selectedRange()
        let markedRange = session.textView.markedRange()
        XCTAssertTrue(session.textView.hasMarkedText())
        gate.release()
        let applied = try await pending.value
        XCTAssertFalse(applied)
        XCTAssertEqual(session.textView.string, composingSource)
        XCTAssertEqual(session.textView.selectedRange(), composingSelection)
        XCTAssertEqual(session.textView.markedRange(), markedRange)
        XCTAssertTrue(session.textView.hasMarkedText(), "A late command must not commit the user's composition")
        XCTAssertFalse(session.lineEditPending)
    }

    @MainActor
    func testHostEligibilityLostWhilePlanningRejectsUnchangedSourceAndCanRetry() async throws {
        _ = NSApplication.shared
        let source = "alpha\nbeta"
        let session = session(with: source)
        let gate = LineCommandPlanGate()
        defer { gate.release(); cleanUp(session) }
        var isEligible = true
        let originalSelection = NSRange(location: 0, length: 5)
        session.textView.setSelectedRange(originalSelection)
        let revision = session.revision
        let pending = Task {
            try await session.applyLineOperation(.indent(unit: "    "), actionName: "Indent",
                planner: gate.planner, isEligible: { isEligible })
        }
        try await waitUntil { gate.hasStarted }
        isEligible = false
        gate.release()
        let applied = try await pending.value
        XCTAssertFalse(applied)
        XCTAssertEqual(session.revision, revision)
        XCTAssertEqual(session.textView.string, source)
        XCTAssertEqual(session.textView.selectedRange(), originalSelection)
        XCTAssertFalse(session.undoStack.canUndo)
        XCTAssertFalse(session.lineEditPending)

        isEligible = true
        let retried = try await session.applyLineOperation(.indent(unit: "    "), actionName: "Indent",
                                                          isEligible: { isEligible })
        XCTAssertTrue(retried)
        XCTAssertEqual(session.textView.string, "    " + source)
        try await Task.sleep(for: .milliseconds(20))
        session.undoStack.undo()
        XCTAssertEqual(session.textView.string, source)
        XCTAssertFalse(session.undoStack.canUndo)
    }

    @MainActor
    func testCellEditStartedWhilePlanningRemainsValidAndRejectsLineOperation() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "name,value\r\nalpha,00123\r\n"
        let loaded = try DocumentFile.save(source, to: directory.appendingPathComponent("pending.csv"), encoding: .utf8)
        let session = EditorSession(file: loaded)
        let gate = LineCommandPlanGate()
        defer { gate.release(); session.presentation?.csv?.cancelCellEditor(); cleanUp(session) }
        let presentation = try XCTUnwrap(session.presentation)
        let csv = try XCTUnwrap(presentation.csv)
        try await waitUntil { csv.parsed?.revision == session.revision }
        XCTAssertTrue(presentation.setShowsStructure(false))
        let originalSelection = NSRange(location: 0, length: 4)
        session.textView.setSelectedRange(originalSelection)
        let revision = session.revision
        let pending = Task {
            try await session.applyLineOperation(.indent(unit: "    "), actionName: "Indent", planner: gate.planner)
        }
        try await waitUntil { gate.hasStarted }
        XCTAssertTrue(presentation.setShowsStructure(true))
        XCTAssertNotNil(csv.prepareEdit(row: 1, column: 1))
        let cellEdit = try XCTUnwrap(csv.beginCellEdit(row: 1, column: 1))
        XCTAssertTrue(csv.hasPendingCellEdit)
        XCTAssertEqual(session.revision, revision)
        XCTAssertEqual(session.textView.selectedRange(), originalSelection)
        gate.release()
        let applied = try await pending.value
        XCTAssertFalse(applied)
        XCTAssertEqual(session.textView.string, source)
        XCTAssertEqual(session.revision, revision)
        XCTAssertTrue(csv.hasPendingCellEdit)
        XCTAssertFalse(session.undoStack.canUndo)
        XCTAssertFalse(session.lineEditPending)
        XCTAssertTrue(csv.apply("00042", for: cellEdit), "The user's pending cell edit must remain valid")
        csv.cancelCellEditor()
        XCTAssertEqual(session.textView.string, "name,value\r\nalpha,00042\r\n")
        try await Task.sleep(for: .milliseconds(20))
        session.undoStack.undo()
        XCTAssertEqual(session.textView.string, source)
        XCTAssertFalse(session.undoStack.canUndo)
        XCTAssertEqual(try DocumentFile.read(loaded.url).text, source, "Neither command saves to disk")
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
        session.syntax.cancel()
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out awaiting line operation or CSV parse")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Holds the detached planner at a deterministic suspension point while the
/// main actor performs a real selection, text-input, or cell-edit interaction.
private final class LineCommandPlanGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var onMainThread = false
    private var released = false

    var hasStarted: Bool {
        condition.lock(); defer { condition.unlock() }
        return started
    }

    var startedOnMainThread: Bool {
        condition.lock(); defer { condition.unlock() }
        return onMainThread
    }

    var planner: @Sendable (TextEditingOperations.Operation, String, NSRange) throws -> TextEditingOperations.Edit? {
        { [self] operation, source, selection in
            condition.lock()
            started = true
            onMainThread = Thread.isMainThread
            while !released { condition.wait() }
            condition.unlock()
            return try TextEditingOperations.plan(operation, in: source, selection: selection)
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
