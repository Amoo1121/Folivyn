import AppKit

enum FileDropError: Error, Equatable {
    case noFiles
    case tooManyFiles(limit: Int)
    case unsupportedContent
    case notLocalFile
    case notRegularFile(URL)
    case unavailableFile(URL)
}

/// File identity and metadata only. Encoding, size, and content validation remain
/// in the normal document-open path; dropping a file never executes its contents.
enum FileDropURLs {
    static let maximumFileCount = 32

    static func canonicalLocalURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/"),
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func validate(_ urls: [URL], limit: Int = maximumFileCount) throws -> [URL] {
        guard !urls.isEmpty else { throw FileDropError.noFiles }
        guard limit > 0, urls.count <= limit else { throw FileDropError.tooManyFiles(limit: limit) }
        var seen = Set<URL>()
        var accepted = [URL]()
        for url in urls {
            guard let canonical = canonicalLocalURL(url) else { throw FileDropError.notLocalFile }
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: canonical.path) }
            catch { throw FileDropError.unavailableFile(canonical) }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw FileDropError.notRegularFile(canonical)
            }
            if seen.insert(canonical).inserted { accepted.append(canonical) }
        }
        return accepted
    }

    @MainActor
    static func containsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL]) != nil
    }

    @MainActor
    static func read(_ pasteboard: NSPasteboard, limit: Int = maximumFileCount) throws -> [URL] {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { throw FileDropError.noFiles }
        guard limit > 0, items.count <= limit else { throw FileDropError.tooManyFiles(limit: limit) }
        // Require each item to be an explicit file URL. Do not reinterpret plain
        // text paths, web links, promised files, or a mixed payload as local files.
        guard items.allSatisfy({ $0.types.contains(.fileURL) }) else { throw FileDropError.unsupportedContent }
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], objects.count == items.count else {
            throw FileDropError.unsupportedContent
        }
        return try validate(objects, limit: limit)
    }
}

/// A window-level destination leaves ordinary mouse/keyboard hit testing alone.
/// Use FolivynTextView for the document surface so its built-in drag handling
/// forwards file URLs instead of inserting a filename into the text buffer.
@MainActor
final class FolivynWindow: NSWindow, NSDraggingDestination {
    var onOpenURLs: (([URL]) -> Void)?
    var canOpenDroppedFiles: () -> Bool = { true }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        registerForDraggedTypes([.fileURL])
    }

    private var permitsFileDrop: Bool {
        onOpenURLs != nil && attachedSheet == nil && NSApp.modalWindow == nil && canOpenDroppedFiles()
    }

    func proposedFileOperation(from pasteboard: NSPasteboard, sourceOperations: NSDragOperation) -> NSDragOperation {
        guard permitsFileDrop, sourceOperations.contains(.copy), (try? FileDropURLs.read(pasteboard)) != nil else { return [] }
        // Copy describes opening a document reference. No filesystem move/copy is
        // performed, and the source must never be asked to delete the original.
        return .copy
    }

    @discardableResult
    func receiveFileDrop(from pasteboard: NSPasteboard) -> Bool {
        guard permitsFileDrop, let urls = try? FileDropURLs.read(pasteboard), let onOpenURLs else { return false }
        onOpenURLs(urls)
        return true
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        proposedFileOperation(from: sender.draggingPasteboard, sourceOperations: sender.draggingSourceOperationMask)
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingEntered(sender) == .copy }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSourceOperationMask.contains(.copy) else { return false }
        return receiveFileDrop(from: sender.draggingPasteboard)
    }
}

@MainActor
final class FolivynTextView: NSTextView {
    weak var editorDecorations: EditorDecorations?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        editorDecorations?.draw(in: rect)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let native = super.acceptableDragTypes
        return native.contains(.fileURL) ? native : native + [.fileURL]
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // File URLs are document-open requests, never buffer text. This also
        // protects field-editor sheets, whose window is not a FolivynWindow.
        guard type != .fileURL, !FileDropURLs.containsFileURLs(pasteboard) else { return false }
        return super.readSelection(from: pasteboard, type: type)
    }

    override func dragOperation(for draggingInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        if FileDropURLs.containsFileURLs(draggingInfo.draggingPasteboard) {
            return (window as? FolivynWindow)?.proposedFileOperation(from: draggingInfo.draggingPasteboard,
                sourceOperations: draggingInfo.draggingSourceOperationMask) ?? []
        }
        return super.dragOperation(for: draggingInfo, type: type)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if FileDropURLs.containsFileURLs(sender.draggingPasteboard) {
            return (window as? FolivynWindow)?.prepareForDragOperation(sender) ?? false
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if FileDropURLs.containsFileURLs(sender.draggingPasteboard) {
            return (window as? FolivynWindow)?.performDragOperation(sender) ?? false
        }
        return super.performDragOperation(sender)
    }
}

@MainActor
protocol RecentDocumentStore: AnyObject {
    var recentDocumentURLs: [URL] { get }
    var maximumRecentDocumentCount: Int { get }
    func note(_ url: URL)
    func clear()
}

@MainActor
final class SystemRecentDocumentStore: RecentDocumentStore {
    private let controller: NSDocumentController
    init(controller: NSDocumentController? = nil) { self.controller = controller ?? .shared }
    var recentDocumentURLs: [URL] { controller.recentDocumentURLs }
    var maximumRecentDocumentCount: Int { controller.maximumRecentDocumentCount }
    func note(_ url: URL) { controller.noteNewRecentDocumentURL(url) }
    func clear() { controller.clearRecentDocuments(nil) }
}

struct RecentFilesStrings {
    var menuTitle = "Open Recent"
    var empty = "No Recent Files"
    var clear = "Clear Menu"
}

/// Uses the system's history, with explicit public menu actions that re-enter
/// Folivyn's existing open path. No private "recent documents menu" selector or
/// default-app association change is needed for a non-NSDocument application.
@MainActor
final class RecentFilesCoordinator: NSObject, NSMenuDelegate {
    let menu: NSMenu
    var onOpen: (URL) -> Void
    private let store: RecentDocumentStore
    private let strings: RecentFilesStrings

    init(strings: RecentFilesStrings = RecentFilesStrings(), store: RecentDocumentStore? = nil,
         onOpen: @escaping (URL) -> Void) {
        self.strings = strings
        self.store = store ?? SystemRecentDocumentStore()
        self.onOpen = onOpen
        menu = NSMenu(title: strings.menuTitle)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        rebuildMenu()
    }

    /// Call only after the normal document-open/save path succeeds. History does
    /// not get a speculative entry when a drop is offered or reading a file fails.
    @discardableResult
    func noteSuccessfulOpen(_ url: URL) -> Bool {
        guard let canonical = try? FileDropURLs.validate([url]).first else { return false }
        store.note(canonical)
        rebuildMenu()
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    func rebuildMenu() {
        menu.removeAllItems()
        var seen = Set<URL>()
        let urls = store.recentDocumentURLs.compactMap(FileDropURLs.canonicalLocalURL).filter { seen.insert($0).inserted }
        let visible = Array(urls.prefix(min(32, max(0, store.maximumRecentDocumentCount))))
        let nameCounts = Dictionary(grouping: visible, by: \.lastPathComponent)
        for url in visible {
            let name = Self.singleLine(url.lastPathComponent)
            let title = (nameCounts[url.lastPathComponent]?.count ?? 0) > 1
                ? name + " — " + Self.singleLine(url.deletingLastPathComponent().path) : name
            let item = NSMenuItem(title: title, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if visible.isEmpty {
            let empty = NSMenuItem(title: strings.empty, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: strings.clear, action: #selector(clearFromMenu(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !store.recentDocumentURLs.isEmpty
        menu.addItem(clear)
    }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        guard sender.menu === menu, let url = sender.representedObject as? URL,
              let canonical = FileDropURLs.canonicalLocalURL(url) else { return }
        // Keep missing/moved entries visible. The normal open path supplies its
        // existing localized error and only records successful reopens.
        onOpen(canonical)
    }

    @objc func clearFromMenu(_ sender: NSMenuItem) {
        guard sender.menu === menu, sender.action == #selector(clearFromMenu(_:)) else { return }
        store.clear()
        rebuildMenu()
    }

    private static func singleLine(_ value: String) -> String {
        String(value.unicodeScalars.prefix(160)).replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    }
}
