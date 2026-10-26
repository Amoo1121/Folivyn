import AppKit
import EditorCore
import EditorUI

@main
enum EditorMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = EditorApplication()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class EditorSession: NSObject, NSTextViewDelegate {
    struct DiskChangeCheck: Sendable {
        let generation: UInt64
        let file: LoadedTextFile
    }

    let id = UUID()
    let textView = NSTextView(usingTextLayoutManager: true)
    let scrollView = NSScrollView()
    let item = NSTabViewItem()
    let syntax = SyntaxHighlighter()
    let undoStack = UndoManager()
    var file: LoadedTextFile?
    var baseline = ""
    var diskChanged = false
    var changed: (() -> Void)?
    private var diskCheckGeneration: UInt64 = 0
    var dirty: Bool { !textView.string.utf16.elementsEqual(baseline.utf16) }
    var name: String { file?.url.lastPathComponent ?? L10n.text(.untitled) }

    init(file: LoadedTextFile? = nil) {
        super.init()
        self.file = file
        baseline = file?.text ?? ""
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .textColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(historyDidChange(_:)),
                                                   name: name, object: undoStack)
        }
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.autoresizingMask = [.width, .height]
        textView.string = baseline
        item.identifier = id
        item.view = scrollView
        item.label = name
        syntax.highlight(textView: textView, fileURL: file?.url)
    }

    func textDidChange(_ notification: Notification) {
        syntax.highlight(textView: textView, fileURL: file?.url)
        changed?()
    }

    @objc private func historyDidChange(_ notification: Notification) {
        // Undo/redo can change NSTextView without calling its text-change delegate.
        textDidChange(notification)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undoStack }

    func acceptSaved(_ loaded: LoadedTextFile) {
        // Invalidate checks started before a save or reload, even when the
        // resulting bytes happen to match the previous baseline.
        diskCheckGeneration &+= 1
        file = loaded
        baseline = loaded.text
        diskChanged = false
        syntax.highlight(textView: textView, fileURL: loaded.url)
        changed?()
    }

    func beginDiskChangeCheck() -> DiskChangeCheck? {
        guard let file else { return nil }
        diskCheckGeneration &+= 1
        return DiskChangeCheck(generation: diskCheckGeneration, file: file)
    }

    func finishDiskChangeCheck(_ check: DiskChangeCheck, result: LoadedTextFile?) {
        guard check.generation == diskCheckGeneration,
              file?.url == check.file.url,
              file?.diskSnapshot == check.file.diskSnapshot else { return }
        diskChanged = result?.diskSnapshot != check.file.diskSnapshot
        changed?()
    }

    func reload(_ loaded: LoadedTextFile) {
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        textView.unmarkText()
        textView.string = loaded.text
        undoStack.removeAllActions()
        let count = (loaded.text as NSString).length
        let location = min(selection.location, count)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, count - location)))
        acceptSaved(loaded)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

@MainActor
final class EditorApplication: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTabViewDelegate, NSUserInterfaceValidations {
    private var window: NSWindow!
    private let tabs = NSTabView()
    private let status = NSTextField(labelWithString: "")
    private var sessions: [EditorSession] = []
    private var reloadButton: NSButton!
    private var mayTerminate = false
    private var pendingURLs: [URL] = []

    private var current: EditorSession? {
        sessions.first { $0.id == tabs.selectedTabViewItem?.identifier as? UUID }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        createWindow()
        if pendingURLs.isEmpty { addSession(EditorSession()) }
        else { open(pendingURLs); pendingURLs = [] }
        if sessions.isEmpty { addSession(EditorSession()) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if window == nil { pendingURLs.append(contentsOf: urls) }
        else { open(urls); window.makeKeyAndOrderFront(nil) }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) { checkDiskChanges() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (mayTerminate || confirmCloseAll()) ? .terminateNow : .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        mayTerminate = confirmCloseAll()
        return mayTerminate
    }

    private func installMenu() {
        let bar = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.format(.about, L10n.appName), action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.format(.quit, L10n.appName), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addMenu(L10n.appName, menu: appMenu, to: bar)

        let file = NSMenu(title: L10n.text(.fileMenu))
        addAction(L10n.text(.new), #selector(newDocument), "n", to: file)
        addAction(L10n.text(.open), #selector(openDocument), "o", to: file)
        file.addItem(.separator())
        addAction(L10n.text(.save), #selector(saveDocument), "s", to: file)
        addAction(L10n.text(.saveAs), #selector(saveDocumentAs), "s", modifiers: [.command, .shift], to: file)
        addAction(L10n.text(.reloadFromDisk), #selector(reloadDocument), "r", to: file)
        file.addItem(.separator())
        addAction(L10n.text(.closeTab), #selector(closeTab), "w", to: file)
        addMenu(L10n.text(.fileMenu), menu: file, to: bar)

        let edit = NSMenu(title: L10n.text(.editMenu))
        edit.addItem(withTitle: L10n.text(.undo), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L10n.text(.redo), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.text(.cut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.text(.copy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.text(.paste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.text(.selectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        addFindAction(.find, .showFindInterface, "f", to: edit)
        addFindAction(.replace, .showReplaceInterface, "f", modifiers: [.command, .option], to: edit)
        addFindAction(.findNext, .nextMatch, "g", to: edit)
        addFindAction(.findPrevious, .previousMatch, "g", modifiers: [.command, .shift], to: edit)
        addFindAction(.useSelectionForFind, .setSearchString, "e", to: edit)
        addMenu(L10n.text(.editMenu), menu: edit, to: bar)

        let view = NSMenu(title: L10n.text(.tabsMenu))
        addAction(L10n.text(.previousTab), #selector(previousTab), "[", modifiers: [.command, .shift], to: view)
        addAction(L10n.text(.nextTab), #selector(nextTab), "]", modifiers: [.command, .shift], to: view)
        addMenu(L10n.text(.tabsMenu), menu: view, to: bar)
        NSApp.mainMenu = bar
    }

    private func addMenu(_ title: String, menu: NSMenu, to bar: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        bar.addItem(item)
    }

    private func addAction(_ title: String, _ action: Selector, _ key: String,
                           modifiers: NSEvent.ModifierFlags = [.command], to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
    }

    private func addFindAction(_ title: L10n.Key, _ action: NSTextFinder.Action, _ key: String,
                               modifiers: NSEvent.ModifierFlags = [.command], to menu: NSMenu) {
        let item = menu.addItem(withTitle: L10n.text(title),
                                action: #selector(performTextFinderAction(_:)), keyEquivalent: key)
        item.target = self
        item.tag = action.rawValue
        item.keyEquivalentModifierMask = modifiers
    }

    @objc private func performTextFinderAction(_ sender: NSMenuItem) {
        // The find bar's field can be first responder. Always search this tab's
        // document, rather than a field editor or another session's text view.
        current?.textView.performTextFinderAction(sender)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) {
            return current?.textView.validateUserInterfaceItem(item) ?? false
        }
        return true
    }

    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = L10n.appName
        window.minSize = NSSize(width: 600, height: 380)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        let content = window.contentView!
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        for (title, action) in [(L10n.text(.open), #selector(openDocument)), (L10n.text(.new), #selector(newDocument)),
                                (L10n.text(.save), #selector(saveDocument)), (L10n.text(.reload), #selector(reloadDocument))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            toolbar.addArrangedSubview(button)
            if action == #selector(reloadDocument) { reloadButton = button }
        }
        tabs.tabViewType = .topTabsBezelBorder
        tabs.allowsTruncatedLabels = true
        tabs.delegate = self
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        for view in [toolbar, tabs, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            tabs.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            tabs.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -7),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -9),
            status.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    private func addSession(_ session: EditorSession) {
        session.changed = { [weak self] in self?.refresh() }
        sessions.append(session)
        tabs.addTabViewItem(session.item)
        tabs.selectTabViewItem(session.item)
        refresh()
        window.makeFirstResponder(session.textView)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        refresh()
        if let session = current { window?.makeFirstResponder(session.textView) }
    }

    private func refresh() {
        for session in sessions { session.item.label = session.name + (session.dirty ? " •" : "") }
        guard let session = current else { return }
        window?.title = L10n.format(.windowTitle, session.name, L10n.appName)
        window?.representedURL = session.file?.url
        window?.isDocumentEdited = session.dirty
        reloadButton?.isEnabled = session.file != nil
        var parts = [session.file?.encoding.displayName ?? "UTF-8", SyntaxHighlighter.languageName(for: session.file?.url)]
        if session.syntax.isLimited { parts.append(L10n.text(.largeText)) }
        if session.dirty { parts.append(L10n.text(.unsaved)) }
        if session.diskChanged { parts.append(L10n.text(.diskChanged)) }
        parts.append(session.file?.url.path ?? L10n.text(.newDocument))
        status.stringValue = parts.joined(separator: "  ·  ")
        status.toolTip = status.stringValue
    }

    @objc private func newDocument() { addSession(EditorSession()) }
    @objc private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L10n.format(.openMessage, DocumentFile.maximumReadBytes / 1_024 / 1_024)
        if panel.runModal() == .OK { open(panel.urls) }
    }

    private func open(_ urls: [URL]) {
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if let existing = sessions.first(where: { $0.file?.url == canonical }) {
                tabs.selectTabViewItem(existing.item)
                continue
            }
            do {
                let loaded = try DocumentFile.read(url)
                if sessions.count == 1, let empty = sessions.first, empty.file == nil, empty.textView.string.isEmpty {
                    tabs.removeTabViewItem(empty.item)
                    sessions.removeAll()
                }
                addSession(EditorSession(file: loaded))
            } catch { showError(error) }
        }
    }

    @objc private func saveDocument() { if let session = current { _ = save(session, saveAs: false) } }
    @objc private func saveDocumentAs() { if let session = current { _ = save(session, saveAs: true) } }

    private func pickSaveURL(for session: EditorSession, copy: Bool = false) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.file?.url.lastPathComponent ?? "Untitled.txt"
        panel.directoryURL = session.file?.url.deletingLastPathComponent()
        panel.title = copy ? L10n.text(.saveCopyTitle) : L10n.text(.saveTitle)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func save(_ session: EditorSession, saveAs: Bool) -> Bool {
        let chosen = saveAs || session.file == nil
        guard let url = chosen ? pickSaveURL(for: session) : session.file?.url else { return false }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let other = sessions.first(where: { $0 !== session && $0.file?.url == canonical }) {
            showMessage(L10n.text(.alreadyOpenTitle), L10n.format(.alreadyOpenMessage, other.name))
            return false
        }
        let sameFile = canonical == session.file?.url
        do {
            let saved = try DocumentFile.save(session.textView.string, to: url,
                encoding: session.file?.encoding ?? .utf8,
                expectedSnapshot: sameFile ? session.file?.diskSnapshot : nil,
                overwriteExternalChanges: chosen && !sameFile)
            session.acceptSaved(saved)
            return true
        } catch DocumentFileError.externalConflict {
            session.diskChanged = true
            refresh()
            let alert = NSAlert()
            alert.messageText = L10n.text(.conflictTitle)
            alert.informativeText = L10n.text(.conflictMessage)
            alert.addButton(withTitle: L10n.text(.cancel))
            alert.addButton(withTitle: L10n.text(.saveAs))
            if alert.runModal() == .alertSecondButtonReturn { return save(session, saveAs: true) }
            return false
        } catch { showError(error); return false }
    }

    @objc private func reloadDocument() {
        guard let session = current, let source = session.file?.url else { return }
        if session.dirty {
            let alert = NSAlert()
            alert.messageText = L10n.format(.reloadTitle, session.name)
            alert.informativeText = L10n.text(.reloadMessage)
            alert.addButton(withTitle: L10n.text(.cancel))
            alert.addButton(withTitle: L10n.text(.discardAndReload))
            alert.addButton(withTitle: L10n.text(.saveCopyAndReload))
            switch alert.runModal() {
            case .alertSecondButtonReturn: break
            case .alertThirdButtonReturn:
                guard let copy = pickSaveURL(for: session, copy: true) else { return }
                let canonical = copy.standardizedFileURL.resolvingSymlinksInPath()
                guard canonical != source, !sessions.contains(where: { $0 !== session && $0.file?.url == canonical }) else {
                    showMessage(L10n.text(.copyLocationTitle), L10n.text(.copyLocationMessage))
                    return
                }
                do {
                    _ = try DocumentFile.save(session.textView.string, to: copy,
                        encoding: session.file?.encoding ?? .utf8, overwriteExternalChanges: true)
                } catch { showError(error); return }
            default: return
            }
        }
        do {
            // Load completely before replacing text: failure leaves the current buffer intact.
            let loaded = try DocumentFile.read(source)
            session.reload(loaded)
            window.makeFirstResponder(session.textView)
        } catch { showError(error) }
    }

    private func checkDiskChanges() {
        for session in sessions {
            guard let check = session.beginDiskChangeCheck() else { continue }
            DispatchQueue.global(qos: .utility).async { [weak session] in
                let result = try? DocumentFile.read(check.file.url)
                DispatchQueue.main.async {
                    session?.finishDiskChangeCheck(check, result: result)
                }
            }
        }
    }

    private func confirmClose(_ session: EditorSession) -> Bool {
        guard session.dirty else { return true }
        tabs.selectTabViewItem(session.item)
        let alert = NSAlert()
        alert.messageText = L10n.format(.closeTitle, session.name)
        alert.informativeText = L10n.text(.closeMessage)
        alert.addButton(withTitle: L10n.text(.save))
        alert.addButton(withTitle: L10n.text(.cancel))
        alert.addButton(withTitle: L10n.text(.dontSave))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(session, saveAs: false)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func confirmCloseAll() -> Bool {
        for session in sessions { if !confirmClose(session) { return false } }
        return true
    }

    @objc private func closeTab() {
        guard let session = current else { return }
        if sessions.count == 1 { window.performClose(nil); return }
        guard confirmClose(session) else { return }
        sessions.removeAll { $0 === session }
        tabs.removeTabViewItem(session.item)
        refresh()
    }
    @objc private func nextTab() { cycleTab(1) }
    @objc private func previousTab() { cycleTab(-1) }
    private func cycleTab(_ offset: Int) {
        guard let session = current, let index = sessions.firstIndex(where: { $0 === session }) else { return }
        tabs.selectTabViewItem(sessions[(index + offset + sessions.count) % sessions.count].item)
    }
    @objc private func showAbout() {
        showMessage(L10n.appName, L10n.format(.aboutMessage, DocumentFile.maximumReadBytes / 1_024 / 1_024))
    }
    private func showError(_ error: Error) { showMessage(L10n.text(.operationFailed), error.localizedDescription) }
    private func showMessage(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text(.ok))
        alert.runModal()
    }
}
