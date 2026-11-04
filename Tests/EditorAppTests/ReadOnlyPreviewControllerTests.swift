import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class ReadOnlyPreviewControllerTests: XCTestCase {
    @MainActor
    func testLargeFileIsBoundedAndCannotBecomeAnEditableDocument() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.py")
        let prefix = Data(String(repeating: "x", count: TextPreview.defaultByteLimit + 8).utf8)
        try prefix.write(to: url)
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: 64 * 1_024 * 1_024)
        try writer.close()
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        var opened: [URL] = []
        let controller = ReadOnlyPreviewController(onOpenWithSystem: { opened.append($0) })
        defer { controller.cancel() }
        await controller.load(url: url)

        let preview = try XCTUnwrap(controller.preview)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertTrue(preview.truncated)
        XCTAssertEqual(preview.text.utf8.count, TextPreview.defaultByteLimit)
        XCTAssertEqual(controller.displayedByteCount, TextPreview.defaultByteLimit)
        XCTAssertEqual(controller.sourceByteCount, 64 * 1_024 * 1_024)
        let status = try label("readonly-preview-status", in: controller)
        XCTAssertTrue(status.stringValue.contains("Prefix only"))
        XCTAssertTrue(status.stringValue.contains("UTF-8"))
        XCTAssertTrue(status.stringValue.contains("204800"))
        XCTAssertTrue(status.stringValue.contains("67108864"))

        let text = controller.textView
        XCTAssertNotNil(text.textLayoutManager, "The preview must remain on TextKit 2")
        XCTAssertFalse(text.isEditable)
        XCTAssertFalse(text.allowsUndo)
        XCTAssertFalse(text.importsGraphics)
        XCTAssertFalse(text.isAutomaticLinkDetectionEnabled)
        XCTAssertTrue(text.isSelectable)
        XCTAssertNil(text.undoManager)
        XCTAssertNil(controller.undoManager)
        XCTAssertTrue(text.readablePasteboardTypes.isEmpty)
        XCTAssertTrue(text.acceptableDragTypes.isEmpty)
        text.setSelectedRange(NSRange(location: 0, length: 5))
        text.insertText("overwrite", replacementRange: text.selectedRange())
        text.deleteBackward(nil)
        text.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: text.selectedRange())
        XCTAssertFalse(text.hasMarkedText())
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(url.absoluteString, forType: .fileURL)
        XCTAssertFalse(text.readSelection(from: pasteboard))
        XCTAssertFalse(text.readSelection(from: pasteboard, type: .fileURL))
        XCTAssertEqual(text.string, preview.text)
        pasteboard.clearContents()
        // Exercise the types advertised by AppKit, as its Copy command does.
        // NSTextView advertises the legacy NSStringPboardType on this SDK.
        text.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 5))
        let copyType = try XCTUnwrap(text.writablePasteboardTypes.first)
        XCTAssertTrue(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: copyType), "xxxxx", "Copy remains available")
        XCTAssertTrue(opened.isEmpty, "Loading never opens or executes a file")
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first)
        button.performClick(nil)
        XCTAssertEqual(opened, [url], "Only the explicit button delegates to the host")
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
    }

    @MainActor
    func testUTF16LineBudgetCountsEncodedBytesAndPreservesOriginalFile() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lines.txt")
        let line = "中🦊\r\n"
        let source = String(repeating: line, count: 2_001)
        var bytes = Data([0xFF, 0xFE])
        for unit in source.utf16 { bytes.append(UInt8(unit & 0xFF)); bytes.append(UInt8(unit >> 8)) }
        try bytes.write(to: url)
        let controller = ReadOnlyPreviewController(onOpenWithSystem: { _ in XCTFail("Unexpected open") })
        defer { controller.cancel() }
        await controller.load(url: url)
        XCTAssertEqual(controller.preview?.encoding, .utf16LittleEndianBOM)
        XCTAssertEqual(controller.preview?.truncated, true)
        XCTAssertEqual(controller.textView.string, String(repeating: line, count: 2_000))
        XCTAssertEqual(controller.displayedByteCount, 20_000)
        XCTAssertEqual(controller.sourceByteCount, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    @MainActor
    func testBinaryInvalidEncodingAndMissingFilesClearOldTextWithoutAutomaticOpening() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appendingPathComponent("valid.json")
        try Data(#"{"a":1}"#.utf8).write(to: textURL)
        let binary = directory.appendingPathComponent("binary.bin")
        try Data([0x61, 0, 0x62]).write(to: binary)
        let invalid = directory.appendingPathComponent("invalid.txt")
        try Data([0xC0, 0x80]).write(to: invalid)
        let missing = directory.appendingPathComponent("missing.txt")
        let controller = ReadOnlyPreviewController(onOpenWithSystem: { _ in XCTFail("Unexpected open") })
        defer { controller.cancel() }
        await controller.load(url: textURL)
        XCTAssertEqual(controller.state, .ready)
        for url in [binary, invalid, missing, directory] {
            await controller.load(url: url)
            XCTAssertEqual(controller.state, .unavailable)
            XCTAssertNil(controller.preview)
            XCTAssertNil(controller.displayedByteCount)
            XCTAssertTrue(controller.textView.string.isEmpty, "An error must not leave old source visible")
            XCTAssertFalse(try XCTUnwrap(controller.errorDescription).isEmpty)
            XCTAssertFalse(try label("readonly-preview-error", in: controller).isHidden)
        }
        await controller.load(url: binary)
        XCTAssertEqual(controller.sourceByteCount, 3)
        XCTAssertEqual(controller.errorDescription, TextPreviewError.binaryContent.localizedDescription)
    }

    @MainActor
    func testEmptyFileAndInjectedStringsAndRemoteURLNeverReachReader() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("empty.txt")
        try Data().write(to: url)
        var strings = ReadOnlyPreviewController.Strings()
        strings.title = "只读预览"
        strings.empty = "空文本文件"
        strings.budget = "最多 200 KiB 或 2,000 行"
        strings.previewByteCount = { "显示 \($0) 字节" }
        strings.sourceByteCount = { "文件 \($0) 字节" }
        let controller = ReadOnlyPreviewController(strings: strings, reader: { url in
            XCTAssertTrue(url.isFileURL, "A non-file URL must not reach any reader")
            return try TextPreview.read(url)
        }, onOpenWithSystem: { _ in XCTFail("Remote URL must not be opened") })
        defer { controller.cancel() }
        await controller.load(url: url)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.preview?.truncated, false)
        XCTAssertEqual(controller.displayedByteCount, 0)
        XCTAssertEqual(controller.sourceByteCount, 0)
        XCTAssertTrue(try label("readonly-preview-status", in: controller).stringValue.contains("空文本文件"))
        XCTAssertTrue(try label("readonly-preview-status", in: controller).stringValue.contains("显示 0 字节"))
        await controller.load(url: try XCTUnwrap(URL(string: "https://example.invalid/no-network.txt")))
        XCTAssertEqual(controller.state, .unavailable)
        XCTAssertNil(controller.sourceByteCount)
        controller.openWithSystem()
        XCTAssertFalse(try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first).isEnabled)
    }

    @MainActor
    func testOldNoncooperativeReadCannotReplaceNewerFile() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.txt"), new = directory.appendingPathComponent("new.txt")
        try Data("old text".utf8).write(to: old)
        try Data("new".utf8).write(to: new)
        let gate = PreviewReadGate()
        let controller = ReadOnlyPreviewController(reader: { url in
            XCTAssertFalse(Thread.isMainThread, "Disk reads must happen off the UI thread")
            if url == old { gate.wait() }
            return try TextPreview.read(url, isCancelled: { false })
        }, onOpenWithSystem: { _ in })
        defer { gate.release(); controller.cancel() }
        let pending = Task { await controller.load(url: old) }
        try await waitUntil { gate.hasStarted }
        await controller.load(url: new)
        XCTAssertEqual(controller.state, .ready)
        gate.release()
        await pending.value
        XCTAssertEqual(controller.fileURL, new)
        XCTAssertEqual(controller.textView.string, "new")
        XCTAssertEqual(controller.sourceByteCount, 3)
    }

    @MainActor
    func testCancellationAndDisappearanceRejectPendingResultsAndAllowReload() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pending.txt")
        try Data("source".utf8).write(to: url)
        for cancellation in 0..<3 {
            let gate = PreviewReadGate()
            let controller = ReadOnlyPreviewController(reader: { url in
                gate.wait()
                return try TextPreview.read(url, isCancelled: { false })
            }, onOpenWithSystem: { _ in })
            defer { gate.release(); controller.cancel() }
            let pending = Task { await controller.load(url: url) }
            try await waitUntil { gate.hasStarted }
            switch cancellation {
            case 0: controller.cancel()
            case 1: controller.viewDidDisappear()
            default: pending.cancel()
            }
            gate.release()
            await pending.value
            XCTAssertEqual(controller.state, .cancelled)
            XCTAssertNil(controller.preview)
            XCTAssertTrue(controller.textView.string.isEmpty)
            await controller.load(url: url)
            XCTAssertEqual(controller.state, .ready)
            XCTAssertEqual(controller.textView.string, "source")
            controller.viewDidDisappear()
            XCTAssertEqual(controller.state, .ready, "Hiding a loaded tab preserves its completed snapshot")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor private func label(_ identifier: String, in controller: ReadOnlyPreviewController) throws -> NSTextField {
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == identifier })
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Preview reader did not start"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class PreviewReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    var hasStarted: Bool {
        condition.lock(); defer { condition.unlock() }
        return started
    }
    func wait() {
        condition.lock()
        started = true
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
