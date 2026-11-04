import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class RecoveredSessionTests: XCTestCase {
    @MainActor
    func testRecoveredEmptyDocumentIsDirtyAndIndependentUntilSaved() throws {
        _ = NSApplication.shared
        let id = UUID()
        let session = EditorSession(recovered: .init(documentID: id, generation: 8, text: "",
            originPath: "/never-overwrite/original.py", encodingHint: .utf16BigEndianBOM))
        defer { dispose(session) }
        XCTAssertEqual(session.id, id)
        XCTAssertTrue(session.dirty)
        XCTAssertNil(session.file)
        XCTAssertNil(session.documentURL)
        XCTAssertEqual(session.textView.string, "")
        XCTAssertEqual(session.saveEncoding, .utf16BigEndianBOM)
        XCTAssertEqual(session.languageOverride, .python)
        XCTAssertFalse(session.undoStack.canUndo)
        XCTAssertNotNil(session.recoveryContent)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = try DocumentFile.save("", to: directory.appendingPathComponent("copy.py"), encoding: session.saveEncoding)
        session.acceptSaved(saved)
        XCTAssertFalse(session.dirty)
        XCTAssertNil(session.recoveryOriginPath)
        XCTAssertNil(session.recoveryContent)
        XCTAssertEqual(session.documentURL, saved.url)
        XCTAssertEqual(try Data(contentsOf: saved.url), Data([0xFE, 0xFF]))
    }

    @MainActor
    func testRecoveryDoesNotReadOrOverwriteChangedOriginAndKeepsExactSelection() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = directory.appendingPathComponent("original.txt")
        let disk = Data("newer disk content".utf8)
        try disk.write(to: origin)
        let text = "draft 中文 🦊\r\ne\u{301}\n"
        let snapshot = DraftRecoverySnapshot(documentID: UUID(), generation: 2, text: text,
            originPath: origin.path, encodingHint: .utf8BOM, selection: .init(location: 6, length: 2))
        let session = EditorSession(recovered: snapshot)
        defer { dispose(session) }
        XCTAssertTrue(session.textView.string.utf16.elementsEqual(text.utf16))
        XCTAssertEqual(session.textView.selectedRange(), NSRange(location: 6, length: 2))
        XCTAssertTrue(session.dirty)
        XCTAssertNil(session.file)
        XCTAssertEqual(try Data(contentsOf: origin), disk)
        XCTAssertEqual(session.recoveryContent?.originPath, origin.path)
        XCTAssertEqual(session.saveEncoding, .utf8BOM)
    }

    @MainActor
    func testRecoveredDraftUndoAndSaveNotifyPersistenceWithoutLosingRecoveredState() throws {
        _ = NSApplication.shared
        let session = EditorSession(recovered: .init(documentID: UUID(), generation: 1, text: "restored"))
        defer { dispose(session) }
        var states = [Bool]()
        session.recoveryChanged = { [weak session] in states.append(session?.dirty == true) }
        XCTAssertTrue(session.replaceSource(in: NSRange(location: 0, length: 8), expected: "restored", with: "edited", revision: session.revision, actionName: "Edit"))
        session.undoStack.undo()
        XCTAssertEqual(session.textView.string, "restored")
        XCTAssertTrue(session.dirty)
        XCTAssertFalse(states.isEmpty)
        XCTAssertTrue(states.allSatisfy { $0 })
        session.textView.setMarkedText("candidate", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertNil(session.recoveryContent, "Uncommitted IME text is not snapshotted")
        session.textView.unmarkText()
    }

    @MainActor
    private func dispose(_ session: EditorSession) {
        session.recoveryChanged = nil
        session.presentation?.cancel()
        session.syntax.cancel()
        session.lineRuler.invalidate()
        session.decorations?.invalidate()
        session.stopFileObservation()
    }
}
