import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class FileOpeningDecisionTests: XCTestCase {
    func testSupportedTextEncodingsRemainEditableWithoutChangingBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "中文 🦊\tvalue\r\nnext\rlast\n"
        for encoding in TextFileEncoding.allCases {
            let url = directory.appendingPathComponent(encoding.rawValue + ".txt")
            let original = try DocumentFile.save(source, to: url, encoding: encoding)
            let bytes = try Data(contentsOf: url)
            guard case .editable(let loaded) = try FileOpeningDecision.open(url) else {
                XCTFail("Valid \(encoding) text should remain editable"); continue
            }
            XCTAssertEqual(loaded.url, original.url)
            XCTAssertEqual(loaded.encoding, encoding)
            XCTAssertEqual(Array(loaded.text.utf16), Array(source.utf16))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testNULAndBinaryControlsUseReadOnlyFallbackIncludingUTF16() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disallowed = Array(0...8) + [11] + Array(14...31)
        for scalar in disallowed {
            let url = directory.appendingPathComponent("control-\(scalar).txt")
            let bytes = Data([0x61, UInt8(scalar), 0x62])
            try bytes.write(to: url)
            try assertPreview(url)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        for encoding in [TextFileEncoding.utf16LittleEndianBOM, .utf16BigEndianBOM] {
            let url = directory.appendingPathComponent(encoding.rawValue + ".txt")
            let loaded = try DocumentFile.save("中\u{0}🦊", to: url, encoding: encoding)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(try DocumentFile.read(url).text, loaded.text, "NUL is encoding-valid but is not editable text")
            try assertPreview(url)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testInvalidEncodingUsesReadOnlyFallbackWithoutRepairingBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples: [[UInt8]] = [
            [0x61, 0xC0, 0xAF], // Invalid UTF-8 overlong sequence.
            [0xF0, 0x9F, 0xA6], // Truncated UTF-8 scalar.
            [0xFF, 0xFE, 0x00, 0xD8], // UTF-16 LE unpaired high surrogate.
            [0xFE, 0xFF, 0x00] // UTF-16 BE incomplete code unit.
        ]
        for (index, sample) in samples.enumerated() {
            let url = directory.appendingPathComponent("invalid-\(index).txt")
            let bytes = Data(sample)
            try bytes.write(to: url)
            try assertPreview(url)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testOversizedAndSymlinkedFilesUseOneCanonicalPreviewIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.txt")
        try createLargeFile(url)
        let alias = directory.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        try assertPreview(url)
        guard case .preview(let resolved) = try FileOpeningDecision.open(alias) else {
            return XCTFail("The same oversized file reached through a symlink must remain read-only")
        }
        XCTAssertEqual(resolved, url.resolvingSymlinksInPath())
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testMissingDirectoriesAndRemoteURLsRemainOpenErrors() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try FileOpeningDecision.open(directory.appendingPathComponent("missing.txt"))) { error in
            guard case .fileNotFound = error as? DocumentFileError else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try FileOpeningDecision.open(directory)) { error in
            guard case .notRegularFile = error as? DocumentFileError else { return XCTFail("Unexpected error: \(error)") }
        }
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/source.txt"))
        XCTAssertThrowsError(try FileOpeningDecision.open(remote)) { error in
            XCTAssertEqual(error as? DocumentFileError, .invalidURL(remote))
        }
    }

    @MainActor
    func testPreviewSessionNeverOwnsSaveablePrefixOrDocumentUndo() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.py")
        try createLargeFile(url)
        guard case .preview(let canonical) = try FileOpeningDecision.open(url) else { return XCTFail("Expected preview") }
        let session = EditorSession(readOnlyURL: canonical)
        let other = EditorSession()
        defer { cleanUp(session); cleanUp(other) }
        let presentation = try XCTUnwrap(session.presentation)
        let preview = try XCTUnwrap(presentation.preview)
        try await waitUntil { preview.state == .ready }
        XCTAssertTrue(session.isReadOnly)
        XCTAssertEqual(session.documentURL, canonical)
        XCTAssertEqual(session.name, "large.py")
        XCTAssertNil(session.file)
        XCTAssertEqual(session.baseline, "")
        XCTAssertEqual(session.textView.string, "", "The bounded prefix never enters the document's save buffer")
        XCTAssertFalse(session.textView.isEditable)
        XCTAssertFalse(session.textView.allowsUndo)
        XCTAssertFalse(session.dirty)
        XCTAssertFalse(session.undoStack.canUndo)
        XCTAssertNil(session.beginDiskChangeCheck())
        XCTAssertFalse(presentation.supportsStructure)
        XCTAssertFalse(presentation.setShowsStructure(true))
        XCTAssertTrue(presentation.preferredResponder === preview.textView)
        XCTAssertNotNil(preview.textView.textLayoutManager)
        XCTAssertFalse(preview.textView.isEditable)
        XCTAssertFalse(preview.textView.allowsUndo)
        XCTAssertNil(preview.textView.undoManager)
        XCTAssertNil(presentation.view.undoManager)
        XCTAssertEqual(preview.displayedByteCount, TextPreview.defaultByteLimit)
        XCTAssertEqual(preview.preview?.truncated, true)

        XCTAssertFalse(session.replaceSource(in: NSRange(location: 0, length: 0), expected: "", with: "edited",
                                             revision: session.revision, actionName: "Edit"))
        let lineEdit = try await session.applyLineOperation(.indent(unit: "    "), actionName: "Indent")
        XCTAssertFalse(lineEdit)
        XCTAssertFalse(session.goToLine(1))
        other.textView.insertText("other tab", replacementRange: NSRange(location: 0, length: 0))
        presentation.view.undo(nil)
        presentation.view.redo(nil)
        XCTAssertEqual(other.textView.string, "other tab")
        let savedElsewhere = try DocumentFile.save("unrelated text", to: directory.appendingPathComponent("other.txt"), encoding: .utf8)
        session.acceptSaved(savedElsewhere)
        session.reload(savedElsewhere)
        XCTAssertNil(session.file)
        XCTAssertEqual(session.documentURL, canonical)
        XCTAssertTrue(session.textView.string.isEmpty)
        XCTAssertEqual(preview.displayedByteCount, TextPreview.defaultByteLimit)
        XCTAssertFalse(session.dirty)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
                       DocumentFile.maximumReadBytes + 1)
    }

    @MainActor
    func testAlreadyCancelledLoadPreservesExistingPreviewAndURL() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.txt")
        let other = directory.appendingPathComponent("other.txt")
        try Data("original preview".utf8).write(to: original)
        try Data("new preview".utf8).write(to: other)
        let controller = ReadOnlyPreviewController(onOpenWithSystem: { _ in XCTFail("Unexpected open") })
        defer { controller.cancel() }
        await controller.load(url: original)
        let cancelled = Task { @MainActor in await controller.load(url: other) }
        // This synchronous cancellation happens before the new main-actor task
        // can enter load, so it must not clear a previously completed preview.
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.fileURL, original)
        XCTAssertEqual(controller.textView.string, "original preview")
        XCTAssertEqual(controller.sourceByteCount, Int64("original preview".utf8.count))
    }

    @MainActor
    func testHiddenPreviewDoesNotStartCancelledLoadAndCanLoadWhenShown() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.txt")
        try Data("source preview".utf8).write(to: url)
        let session = EditorSession(readOnlyURL: url)
        defer { cleanUp(session) }
        let presentation = try XCTUnwrap(session.presentation)
        let preview = try XCTUnwrap(presentation.preview)
        presentation.hidePreview()
        // Allow the cancelled scheduled task to run without involving a window.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(preview.state, .idle)
        XCTAssertNil(preview.fileURL)
        XCTAssertTrue(preview.textView.string.isEmpty)
        presentation.showPreviewIfNeeded()
        try await waitUntil { preview.state == .ready }
        XCTAssertEqual(preview.textView.string, "source preview")
        presentation.hidePreview()
        XCTAssertEqual(preview.state, .ready, "Hiding a completed preview keeps its snapshot")
        presentation.showPreviewIfNeeded()
        XCTAssertEqual(preview.textView.string, "source preview")
    }

    private func assertPreview(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        guard case .preview(let canonical) = try FileOpeningDecision.open(url) else {
            return XCTFail("Expected a read-only preview", file: file, line: line)
        }
        XCTAssertEqual(canonical, url.standardizedFileURL.resolvingSymlinksInPath(), file: file, line: line)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func createLargeFile(_ url: URL) throws {
        try Data(String(repeating: "x", count: TextPreview.defaultByteLimit + 8).utf8).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(DocumentFile.maximumReadBytes + 1))
    }

    @MainActor private func cleanUp(_ session: EditorSession) {
        session.presentation?.cancel()
        session.lineRuler.invalidate()
        session.syntax.cancel()
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out awaiting preview presentation")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
