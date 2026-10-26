import AppKit
import EditorCore

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
    var dirty: Bool { !textView.string.utf16.elementsEqual(baseline.utf16) }
    var name: String { file?.url.lastPathComponent ?? "未命名" }

    init(file: LoadedTextFile? = nil) {
        super.init()
        self.file = file
        baseline = file?.text ?? ""
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
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

    func undoManager(for view: NSTextView) -> UndoManager? { undoStack }

    func acceptSaved(_ loaded: LoadedTextFile) {
        file = loaded
        baseline = loaded.text
        diskChanged = false
        syntax.highlight(textView: textView, fileURL: loaded.url)
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
final class EditorApplication: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTabViewDelegate {
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
        appMenu.addItem(withTitle: "关于文件编辑器", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出文件编辑器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addMenu("文件编辑器", menu: appMenu, to: bar)

        let file = NSMenu(title: "文件")
        addAction("新建", #selector(newDocument), "n", to: file)
        addAction("打开…", #selector(openDocument), "o", to: file)
        file.addItem(.separator())
        addAction("保存", #selector(saveDocument), "s", to: file)
        addAction("另存为…", #selector(saveDocumentAs), "s", modifiers: [.command, .shift], to: file)
        addAction("从磁盘重新加载", #selector(reloadDocument), "r", to: file)
        file.addItem(.separator())
        addAction("关闭标签", #selector(closeTab), "w", to: file)
        addMenu("文件", menu: file, to: bar)

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addMenu("编辑", menu: edit, to: bar)

        let view = NSMenu(title: "标签")
        addAction("上一个标签", #selector(previousTab), "[", modifiers: [.command, .shift], to: view)
        addAction("下一个标签", #selector(nextTab), "]", modifiers: [.command, .shift], to: view)
        addMenu("标签", menu: view, to: bar)
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

    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "文件编辑器"
        window.minSize = NSSize(width: 600, height: 380)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        let content = window.contentView!
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        for (title, action) in [("打开…", #selector(openDocument)), ("新建", #selector(newDocument)),
                                ("保存", #selector(saveDocument)), ("重新加载", #selector(reloadDocument))] {
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
        window?.title = session.name + " — 文件编辑器"
        window?.representedURL = session.file?.url
        window?.isDocumentEdited = session.dirty
        reloadButton?.isEnabled = session.file != nil
        var parts = [session.file?.encoding.displayName ?? "UTF-8", SyntaxHighlighter.languageName(for: session.file?.url)]
        if session.textView.string.utf8.count > 200 * 1024 { parts.append("大文本：基础纯文本模式") }
        if session.dirty { parts.append("未保存") }
        if session.diskChanged { parts.append("磁盘文件已变化，请重新加载或另存") }
        parts.append(session.file?.url.path ?? "新文档")
        status.stringValue = parts.joined(separator: "  ·  ")
        status.toolTip = status.stringValue
    }

    @objc private func newDocument() { addSession(EditorSession()) }
    @objc private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "选择文本或代码文件（原型支持不超过 10 MiB 的文件）"
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
        panel.title = copy ? "保存未保存修改的副本" : "保存文件"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func save(_ session: EditorSession, saveAs: Bool) -> Bool {
        let chosen = saveAs || session.file == nil
        guard let url = chosen ? pickSaveURL(for: session) : session.file?.url else { return false }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let other = sessions.first(where: { $0 !== session && $0.file?.url == canonical }) {
            showMessage("该文件已在另一个标签中打开", "请切换到“\(other.name)”编辑，或选择其他保存位置。")
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
            alert.messageText = "磁盘文件已被修改或删除"
            alert.informativeText = "当前编辑内容仍然保留。请另存为其他文件，或取消后重新加载磁盘版本。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "另存为…")
            if alert.runModal() == .alertSecondButtonReturn { return save(session, saveAs: true) }
            return false
        } catch { showError(error); return false }
    }

    @objc private func reloadDocument() {
        guard let session = current, let source = session.file?.url else { return }
        if session.dirty {
            let alert = NSAlert()
            alert.messageText = "重新加载“\(session.name)”？"
            alert.informativeText = "此标签有未保存的修改。重新加载会用磁盘内容替换它，并清除旧的撤销记录。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "放弃修改并重新加载")
            alert.addButton(withTitle: "另存副本后重新加载…")
            switch alert.runModal() {
            case .alertSecondButtonReturn: break
            case .alertThirdButtonReturn:
                guard let copy = pickSaveURL(for: session, copy: true) else { return }
                let canonical = copy.standardizedFileURL.resolvingSymlinksInPath()
                guard canonical != source, !sessions.contains(where: { $0 !== session && $0.file?.url == canonical }) else {
                    showMessage("请选择其他副本位置", "副本不能覆盖原文件或另一个已打开的文件。")
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
            guard let file = session.file else { continue }
            DispatchQueue.global(qos: .utility).async { [weak self, weak session] in
                let result = try? DocumentFile.read(file.url)
                DispatchQueue.main.async {
                    guard let self, let session, session.file?.diskSnapshot == file.diskSnapshot,
                          session.file?.url == file.url else { return }
                    session.diskChanged = result?.diskSnapshot != file.diskSnapshot
                    self.refresh()
                }
            }
        }
    }

    private func confirmClose(_ session: EditorSession) -> Bool {
        guard session.dirty else { return true }
        tabs.selectTabViewItem(session.item)
        let alert = NSAlert()
        alert.messageText = "保存对“\(session.name)”的修改？"
        alert.informativeText = "未保存的内容将在关闭后丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")
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
        showMessage("文件编辑器 · 离线原型", "多文件标签、打开保存、磁盘重新加载和基础语法着色。\n所有功能在本机运行，无网络依赖。\n当前原型单文件上限：10 MiB。")
    }
    private func showError(_ error: Error) { showMessage("操作未完成", error.localizedDescription) }
    private func showMessage(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
