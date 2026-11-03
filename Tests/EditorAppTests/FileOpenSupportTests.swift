import AppKit
import Darwin
import XCTest
@testable import EditorApp

final class FileOpenSupportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileOpenSupportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func file(_ name: String, data: Data = Data("fixture".utf8)) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testCanonicalPathsAndSymlinksAreDeduplicatedInInputOrder() throws {
        let first = try file("中文 🦊 # 100%.py")
        let second = try file("second.json")
        let link = directory.appendingPathComponent("link.py")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let dotted = URL(fileURLWithPath: directory.path + "/./" + first.lastPathComponent)
        let validated = try FileDropURLs.validate([first, second, link, dotted, first])
        XCTAssertEqual(validated, [first.resolvingSymlinksInPath(), second.resolvingSymlinksInPath()])
        XCTAssertEqual(try Data(contentsOf: first), Data("fixture".utf8))
    }

    func testRemoteRelativeAndAmbiguousURLsAreRefusedBeforeFileLookup() throws {
        for value in ["https://example.invalid/code.py", "file://remote.example/tmp/code.py", "file:relative.py",
                      "file:///tmp/code.py?query=yes", "file:///tmp/code.py#fragment", "file://user@localhost/tmp/code.py"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertNil(FileDropURLs.canonicalLocalURL(url), value)
            XCTAssertThrowsError(try FileDropURLs.validate([url])) {
                XCTAssertEqual($0 as? FileDropError, .notLocalFile, value)
            }
        }
    }

    func testDirectoriesMissingFilesFIFOsAndOverLimitDropsFailAsAWhole() throws {
        let valid = try file("valid.txt")
        XCTAssertThrowsError(try FileDropURLs.validate([valid, directory])) {
            XCTAssertEqual($0 as? FileDropError, .notRegularFile(self.directory.resolvingSymlinksInPath()))
        }
        let missing = directory.appendingPathComponent("missing")
        XCTAssertThrowsError(try FileDropURLs.validate([valid, missing])) {
            XCTAssertEqual($0 as? FileDropError, .unavailableFile(missing.resolvingSymlinksInPath()))
        }
        let fifo = directory.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try FileDropURLs.validate([fifo])) {
            XCTAssertEqual($0 as? FileDropError, .notRegularFile(fifo.resolvingSymlinksInPath()))
        }
        XCTAssertThrowsError(try FileDropURLs.validate(Array(repeating: valid, count: FileDropURLs.maximumFileCount + 1))) {
            XCTAssertEqual($0 as? FileDropError, .tooManyFiles(limit: FileDropURLs.maximumFileCount))
        }
        XCTAssertThrowsError(try FileDropURLs.validate([])) {
            XCTAssertEqual($0 as? FileDropError, .noFiles)
        }
    }

    func testContentIsNotReadOrExecutedDuringDropValidation() throws {
        // Invalid text and executable-looking content still go to the normal open
        // path for validation. This layer neither loads nor interprets the bytes.
        let binary = try file("file.bin", data: Data([0xFF, 0x00, 0xC0]))
        let marker = directory.appendingPathComponent("must-not-exist")
        let scriptText = "#!/bin/sh\ntouch '\(marker.path)'\n"
        let script = try file("code.sh", data: Data(scriptText.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: binary.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.path) }
        XCTAssertEqual(try FileDropURLs.validate([binary, script]).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: script), Data(scriptText.utf8))
    }

    @MainActor
    func testPasteboardAcceptsOnlyExplicitFileURLItems() async throws {
        _ = NSApplication.shared
        let url = try file("file.txt")
        let pasteboard = NSPasteboard(name: .init("Folivyn.FileDropTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL, url as NSURL]))
        XCTAssertEqual(try FileDropURLs.read(pasteboard), [url.resolvingSymlinksInPath()])
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
        XCTAssertThrowsError(try FileDropURLs.read(pasteboard)) {
            XCTAssertEqual($0 as? FileDropError, .unsupportedContent)
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL, URL(string: "https://example.invalid")! as NSURL]))
        XCTAssertThrowsError(try FileDropURLs.read(pasteboard)) {
            XCTAssertEqual($0 as? FileDropError, .unsupportedContent)
        }
        pasteboard.clearContents()
        let promise = NSPasteboardItem()
        promise.setString("pending.txt", forType: .init("com.apple.pasteboard.promised-file-url"))
        XCTAssertTrue(pasteboard.writeObjects([promise]))
        XCTAssertThrowsError(try FileDropURLs.read(pasteboard))
    }

    @MainActor
    func testDropCallbackDoesNotReplaceDocumentTextOrRequireHitTestOverlay() async throws {
        _ = NSApplication.shared
        let url = try file("drop.py")
        let pasteboard = NSPasteboard(name: .init("Folivyn.WindowDropTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
        let window = FolivynWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let textView = FolivynTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        textView.string = "unsaved 中文 🦊"
        window.contentView?.addSubview(textView)
        window.makeFirstResponder(textView)
        let selection = NSRange(location: 2, length: 3)
        textView.setSelectedRange(selection)
        var received = [[URL]]()
        XCTAssertEqual(window.proposedFileOperation(from: pasteboard, sourceOperations: .copy), [])
        window.onOpenURLs = { received.append($0) }
        XCTAssertEqual(window.proposedFileOperation(from: pasteboard, sourceOperations: .move), [])
        XCTAssertEqual(window.proposedFileOperation(from: pasteboard, sourceOperations: .copy), .copy)
        XCTAssertTrue(window.receiveFileDrop(from: pasteboard))
        XCTAssertEqual(received, [[url.resolvingSymlinksInPath()]])
        XCTAssertEqual(textView.string, "unsaved 中文 🦊")
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertTrue(textView.acceptableDragTypes.contains(.fileURL))
        let nativeTextView = NSTextView(usingTextLayoutManager: true)
        XCTAssertTrue(Set(nativeTextView.acceptableDragTypes).isSubset(of: Set(textView.acceptableDragTypes)),
                      "File routing must preserve every native text drag type")
        window.canOpenDroppedFiles = { false }
        XCTAssertFalse(window.receiveFileDrop(from: pasteboard))
        XCTAssertEqual(received.count, 1)
    }

    @MainActor
    func testFileURLCannotReplaceDraftInOrdinaryWindowButPlainTextStillPastes() async throws {
        _ = NSApplication.shared
        let url = try file("dropped.txt")
        let pasteboard = NSPasteboard(name: .init("Folivyn.FieldDropTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
        // CSV's editor sheet uses an ordinary NSWindow, without an open callback.
        // Keep this window hidden and call the native reading API directly.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let input = FolivynTextView(usingTextLayoutManager: true)
        input.isRichText = false
        input.importsGraphics = false
        input.string = "unsaved 中文 🦊"
        window.contentView?.addSubview(input)
        let selection = NSRange(location: 8, length: 2)
        input.setSelectedRange(selection)
        XCTAssertFalse(input.readSelection(from: pasteboard, type: .fileURL))
        XCTAssertFalse(input.readSelection(from: pasteboard, type: .URL),
                       "Alternate representations of the same file must also be refused")
        XCTAssertEqual(input.string, "unsaved 中文 🦊")
        XCTAssertEqual(input.selectedRange(), selection)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("plain 🦊", forType: .string))
        XCTAssertTrue(input.readSelection(from: pasteboard, type: .string))
        XCTAssertEqual(input.string, "unsaved plain 🦊 🦊")
    }

    @MainActor
    func testRecentMenuDeduplicatesDisambiguatesAndDoesNotWriteOnRebuildOrOpen() async throws {
        _ = NSApplication.shared
        let firstFolder = directory.appendingPathComponent("first")
        let secondFolder = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: false)
        let first = firstFolder.appendingPathComponent("same.txt")
        let second = secondFolder.appendingPathComponent("same.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let missing = directory.appendingPathComponent("moved.txt")
        let store = FakeRecentStore(urls: [first, first, second, missing, URL(string: "https://example.invalid")!])
        var opened = [URL]()
        let coordinator = RecentFilesCoordinator(store: store, onOpen: { opened.append($0) })
        XCTAssertEqual(coordinator.menu.items.filter { $0.representedObject is URL }.count, 3)
        XCTAssertTrue(coordinator.menu.items[0].title.contains("first"))
        XCTAssertTrue(coordinator.menu.items[1].title.contains("second"))
        coordinator.rebuildMenu()
        XCTAssertEqual(store.notes.count, 0)
        XCTAssertEqual(store.clearCount, 0)
        let missingItem = try XCTUnwrap(coordinator.menu.items.first { ($0.representedObject as? URL)?.lastPathComponent == "moved.txt" })
        coordinator.openRecentItem(missingItem)
        XCTAssertEqual(opened, [missing.resolvingSymlinksInPath()])
        XCTAssertEqual(store.notes.count, 0, "Only a successful open may update recent history")
        XCTAssertFalse(coordinator.noteSuccessfulOpen(missing))
        XCTAssertTrue(coordinator.noteSuccessfulOpen(first))
        XCTAssertEqual(store.notes, [first.resolvingSymlinksInPath()])
        XCTAssertFalse(coordinator.noteSuccessfulOpen(directory))
    }

    @MainActor
    func testRecentMenuUsesInjectedStringsHonorsSystemLimitAndClearsOnlyOnAction() async throws {
        _ = NSApplication.shared
        let first = try file("first.txt")
        let second = try file("second.txt")
        let store = FakeRecentStore(urls: [first, second])
        store.maximumRecentDocumentCount = 1
        let strings = RecentFilesStrings(menuTitle: "最近打开", empty: "暂无最近文件", clear: "清除菜单")
        let coordinator = RecentFilesCoordinator(strings: strings, store: store, onOpen: { _ in })
        XCTAssertEqual(coordinator.menu.title, "最近打开")
        XCTAssertEqual(coordinator.menu.items.filter { $0.representedObject is URL }.count, 1)
        XCTAssertEqual(store.clearCount, 0)
        coordinator.menuNeedsUpdate(coordinator.menu)
        XCTAssertEqual(store.clearCount, 0)
        let unrelated = NSMenuItem(title: "Clear", action: nil, keyEquivalent: "")
        coordinator.clearFromMenu(unrelated)
        XCTAssertEqual(store.clearCount, 0)
        let clear = try XCTUnwrap(coordinator.menu.items.last)
        XCTAssertEqual(clear.title, "清除菜单")
        coordinator.clearFromMenu(clear)
        XCTAssertEqual(store.clearCount, 1)
        XCTAssertEqual(coordinator.menu.items.first?.title, "暂无最近文件")
        XCTAssertFalse(try XCTUnwrap(coordinator.menu.items.first).isEnabled)
        XCTAssertFalse(try XCTUnwrap(coordinator.menu.items.last).isEnabled)
    }
}

@MainActor
private final class FakeRecentStore: RecentDocumentStore {
    var recentDocumentURLs: [URL]
    var maximumRecentDocumentCount = 10
    var notes = [URL]()
    var clearCount = 0
    init(urls: [URL]) { recentDocumentURLs = urls }
    func note(_ url: URL) { notes.append(url) }
    func clear() { clearCount += 1; recentDocumentURLs = [] }
}
