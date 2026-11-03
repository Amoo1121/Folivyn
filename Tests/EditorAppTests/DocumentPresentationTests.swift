import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class DocumentPresentationTests: XCTestCase {
    @MainActor
    func testNewCSVPresentationAcceptsFocusBeforeItsFirstParseFinishes() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = EditorSession()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.presentation?.view
        defer { session.presentation?.cancel(); session.syntax.cancel(); window.close() }
        let loaded = try DocumentFile.save("a,b\n1,2", to: directory.appendingPathComponent("new.csv"), encoding: .utf8)
        session.reload(loaded)
        let csv = try XCTUnwrap(session.presentation?.csv)
        XCTAssertNil(csv.parsed)
        XCTAssertTrue(window.makeFirstResponder(csv.tableView))
        XCTAssertTrue(window.firstResponder === csv.tableView)
    }

    @MainActor
    func testCSVSourceSwitchesPreserveDocumentAndHeaderPreferenceWithSharedUndo() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = "name,value\r\nalpha,00123\r\n"
        let loaded = try DocumentFile.save(original, to: directory.appendingPathComponent("test.csv"), encoding: .utf8BOM)
        let session = EditorSession(file: loaded)
        let presentation = try XCTUnwrap(session.presentation)
        defer { presentation.cancel(); session.syntax.cancel() }
        XCTAssertEqual(presentation.kind, .csv)
        XCTAssertTrue(presentation.showsStructure)
        let csv = try XCTUnwrap(presentation.csv)
        try await waitUntil { csv.parsed != nil }
        XCTAssertTrue(csv.setFirstRowAsHeader(true))
        let edit = try XCTUnwrap(csv.prepareEdit(row: 0, column: 1))
        XCTAssertEqual(edit.row, 1)
        XCTAssertTrue(csv.apply("00042", for: edit))
        try await waitUntil { csv.parsed?.revision == session.revision }
        XCTAssertTrue(presentation.setShowsStructure(false))
        XCTAssertTrue(presentation.setShowsStructure(true))
        XCTAssertTrue(csv.usesFirstRowAsHeader)
        XCTAssertEqual(session.textView.string, "name,value\r\nalpha,00042\r\n")
        XCTAssertTrue(session.dirty)
        // This is the responder used by table/tree keyboard undo.
        presentation.view.undo(nil)
        try await waitUntil { csv.parsed?.revision == session.revision }
        XCTAssertEqual(Array(session.textView.string.utf16), Array(original.utf16))
        XCTAssertFalse(session.dirty)
        XCTAssertEqual(try Data(contentsOf: loaded.url), Data([0xEF, 0xBB, 0xBF]) + Data(original.utf8))
    }

    @MainActor
    func testSaveAsChangesAvailableViewsWithoutReplacingSourceOrUndo() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = EditorSession()
        defer { session.presentation?.cancel(); session.syntax.cancel() }
        session.textView.insertText(#"{"中":1.2300e+04,"中":900719925474099312345}"#, replacementRange: NSRange(location: 0, length: 0))
        let original = session.textView.string
        let loaded = try DocumentFile.save(original, to: directory.appendingPathComponent("saved.json"), encoding: .utf8)
        session.acceptSaved(loaded)
        let presentation = try XCTUnwrap(session.presentation)
        XCTAssertEqual(presentation.kind, .json)
        XCTAssertTrue(presentation.showsStructure)
        let json = try XCTUnwrap(presentation.json)
        try await waitUntil { json.displayedRevision == session.revision }
        XCTAssertEqual(json.structure?.source, original)
        XCTAssertFalse(session.dirty)
        XCTAssertTrue(session.undoStack.canUndo)
        presentation.view.undo(nil)
        try await waitUntil { json.parseError != nil }
        XCTAssertEqual(session.textView.string, "")
        XCTAssertTrue(session.dirty)
        XCTAssertEqual(try DocumentFile.read(loaded.url).text, original)
    }

    @MainActor
    func testCompositionPreventsHidingSourceOrApplyingStructuredChanges() async throws {
        _ = NSApplication.shared
        let session = EditorSession()
        defer { session.presentation?.cancel(); session.syntax.cancel() }
        session.textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                                      replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(session.presentation?.setShowsStructure(true) ?? true)
        XCTAssertTrue(session.textView.hasMarkedText())
        XCTAssertEqual(session.textView.string, "中")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out awaiting presentation"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
