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
    let textView = FolivynTextView(usingTextLayoutManager: true)
    let scrollView = NSScrollView()
    let item = NSTabViewItem()
    let syntax = SyntaxHighlighter()
    let undoStack = UndoManager()
    var lineEditPending = false
    private(set) var lineRuler: LineNumberRuler!
    private(set) var decorations: EditorDecorations?
    var languageOverride: SyntaxLanguage? {
        didSet {
            syntax.highlight(textView: textView, fileURL: file?.url, override: languageOverride)
            decorations?.refresh()
            changed?()
        }
    }
    private(set) var presentation: DocumentPresentation?
    private(set) var fileObservation: DocumentFileObservation?
    let readOnlyURL: URL?
    var isReadOnly: Bool { readOnlyURL != nil }
    var documentURL: URL? { readOnlyURL ?? file?.url }
    var file: LoadedTextFile?
    var baseline = ""
    var diskChanged = false
    var changed: (() -> Void)?
    var sourceChanged: (() -> Void)?
    private(set) var revision: UInt64 = 0
    private var diskCheckGeneration: UInt64 = 0
    var dirty: Bool { !isReadOnly && !textView.string.utf16.elementsEqual(baseline.utf16) }
    var name: String { documentURL?.lastPathComponent ?? L10n.text(.untitled) }

    init(file: LoadedTextFile? = nil, readOnlyURL: URL? = nil) {
        self.readOnlyURL = readOnlyURL
        super.init()
        self.file = readOnlyURL == nil ? file : nil
        baseline = self.file?.text ?? ""
        textView.isEditable = !isReadOnly
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = !isReadOnly
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
        lineRuler = LineNumberRuler(textView: textView, snapshot: { [weak self] in
            guard let self else { return ("", 0) }
            return (self.textView.string, self.revision)
        })
        scrollView.verticalRulerView = lineRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        lineRuler.onIndexChange = { [weak self] in self?.changed?() }
        lineRuler.refresh()
        if !isReadOnly {
            decorations = EditorDecorations(textView: textView, snapshot: { [weak self] in
                guard let self else { return ("", 0) }
                return (self.textView.string, self.revision)
            }, language: { [weak self] in
                self?.languageOverride ?? SyntaxLanguage.forFile(self?.file?.url) ?? .plainText
            })
        }
        item.identifier = id
        presentation = DocumentPresentation(session: self)
        item.view = presentation?.view
        sourceChanged = { [weak self] in self?.presentation?.sourceDidChange() }
        item.label = name
        syntax.highlight(textView: textView, fileURL: file?.url, override: languageOverride)
    }

    func textDidChange(_ notification: Notification) {
        revision &+= 1
        syntax.highlight(textView: textView, fileURL: file?.url, override: languageOverride)
        decorations?.refresh()
        lineRuler.refresh()
        sourceChanged?()
        changed?()
    }

    /// Every derived view applies one local edit to this sole source buffer.
    /// A matching revision alone is insufficient: compare exact UTF-16 units too.
    @discardableResult
    func replaceSource(in range: NSRange, expected: String, with replacement: String,
                       revision expectedRevision: UInt64, actionName: String) -> Bool {
        guard revision == expectedRevision, !textView.hasMarkedText(), textView.isEditable else { return false }
        let source = textView.string as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length,
              range.length <= source.length - range.location else { return false }
        func isScalarBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < source.length else { return true }
            return !((0xD800...0xDBFF).contains(source.character(at: offset - 1)) &&
                     (0xDC00...0xDFFF).contains(source.character(at: offset)))
        }
        guard isScalarBoundary(range.location), isScalarBoundary(NSMaxRange(range)),
              source.substring(with: range).utf16.elementsEqual(expected.utf16) else { return false }
        if expected.utf16.elementsEqual(replacement.utf16) { return true }
        textView.breakUndoCoalescing()
        undoStack.beginUndoGrouping()
        // AppKit registers its inverse edit during shouldChangeText, so the
        // group must already be open before asking it to approve the mutation.
        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            undoStack.endUndoGrouping()
            return false
        }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location, length: replacement.utf16.count))
        undoStack.endUndoGrouping()
        undoStack.setActionName(actionName)
        textView.breakUndoCoalescing()
        return true
    }

    @objc private func historyDidChange(_ notification: Notification) {
        // Undo/redo can change NSTextView without calling its text-change delegate.
        textDidChange(notification)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undoStack }

    func textViewDidChangeSelection(_ notification: Notification) {
        presentation?.sourceSelectionDidChange()
    }

    @discardableResult
    func goToLine(_ line: Int) -> Bool {
        guard !isReadOnly, !textView.hasMarkedText(), presentation?.csv?.hasPendingCellEdit != true,
              lineRuler.displayedRevision == revision,
              let range = lineRuler.currentIndex?.insertionRange(forLine: line) else { return false }
        if presentation?.kind == .csv, presentation?.setShowsStructure(false) != true { return false }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
        return true
    }

    func acceptSaved(_ loaded: LoadedTextFile) {
        guard !isReadOnly else { return }
        // Invalidate checks started before a save or reload, even when the
        // resulting bytes happen to match the previous baseline.
        diskCheckGeneration &+= 1
        file = loaded
        baseline = loaded.text
        diskChanged = false
        syntax.highlight(textView: textView, fileURL: loaded.url, override: languageOverride)
        decorations?.refresh()
        presentation?.configure()
        fileObservation?.updateURL()
        changed?()
    }

    func startFileObservation() {
        guard !isReadOnly, fileObservation == nil else { return }
        fileObservation = DocumentFileObservation(session: self)
    }

    func stopFileObservation() {
        fileObservation?.stop()
        fileObservation = nil
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
        guard !isReadOnly else { return }
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        textView.unmarkText()
        textView.string = loaded.text
        revision &+= 1
        lineRuler.refresh()
        sourceChanged?()
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
    private var window: FolivynWindow!
    private let tabs = NSTabView()
    private let status = NSTextField(labelWithString: "")
    private var sessions: [EditorSession] = []
    private var reloadButton: NSButton!
    private var saveButton: NSButton!
    private let viewMode = NSSegmentedControl()
    private var mayTerminate = false
    private var pendingURLs: [URL] = []
    private var recentFiles: RecentFilesCoordinator!

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
        guard window?.attachedSheet == nil else { sender.reply(toOpenOrPrint: .failure); return }
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
        guard window?.attachedSheet == nil else { return .terminateCancel }
        return (mayTerminate || confirmCloseAll()) ? .terminateNow : .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.attachedSheet == nil else { return false }
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
        recentFiles = RecentFilesCoordinator(strings: RecentFilesStrings(
            menuTitle: L10n.text(.openRecent), empty: L10n.text(.noRecentFiles), clear: L10n.text(.clearRecentFiles)),
            onOpen: { [weak self] url in
                guard let self, self.window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
                self.open([url])
            })
        addMenu(L10n.text(.openRecent), menu: recentFiles.menu, to: file)
        file.addItem(.separator())
        addAction(L10n.text(.save), #selector(saveDocument), "s", to: file)
        addAction(L10n.text(.saveAs), #selector(saveDocumentAs), "s", modifiers: [.command, .shift], to: file)
        addAction(L10n.text(.reloadFromDisk), #selector(reloadDocument), "r", to: file)
        file.addItem(.separator())
        addAction(L10n.text(.closeTab), #selector(closeTab), "w", to: file)
        addMenu(L10n.text(.fileMenu), menu: file, to: bar)

        let edit = NSMenu(title: L10n.text(.editMenu))
        edit.addItem(withTitle: L10n.text(.undo), action: #selector(DocumentPresentationView.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L10n.text(.redo), action: #selector(DocumentPresentationView.redo(_:)), keyEquivalent: "z")
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
        addAction(L10n.text(.goToLine), #selector(goToLine), "l", to: edit)
        let languages = NSMenu(title: L10n.text(.language))
        let automatic = languages.addItem(withTitle: L10n.text(.automaticLanguage), action: #selector(changeLanguage(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.tag = -1
        languages.addItem(.separator())
        for (index, language) in SyntaxLanguage.allCases.enumerated() {
            let item = languages.addItem(withTitle: language.displayName, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
        }
        addMenu(L10n.text(.language), menu: languages, to: edit)
        edit.addItem(.separator())
        addAction(L10n.text(.indent), #selector(indentLines), "]", to: edit)
        addAction(L10n.text(.unindent), #selector(unindentLines), "[", to: edit)
        addAction(L10n.text(.toggleLineComment), #selector(toggleLineComment), "/", to: edit)
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
        guard let session = current, !session.isReadOnly else { return }
        if session.presentation?.kind == .csv {
            guard session.presentation?.setShowsStructure(false) == true else { return }
        }
        session.textView.performTextFinderAction(sender)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard window?.attachedSheet == nil else { return false }
        if current?.isReadOnly == true,
           [#selector(saveDocument), #selector(saveDocumentAs), #selector(goToLine), #selector(changeLanguage(_:)),
            #selector(performTextFinderAction(_:)), #selector(indentLines), #selector(unindentLines), #selector(toggleLineComment)].contains(item.action) {
            return false
        }
        if [#selector(indentLines), #selector(unindentLines), #selector(toggleLineComment)].contains(item.action) {
            guard let session = current, !session.lineEditPending, !session.textView.hasMarkedText(),
                  window.firstResponder === session.textView else { return false }
            return item.action != #selector(toggleLineComment) || session.lineCommentPrefix != nil
        }
        if item.action == #selector(goToLine) {
            return current?.lineRuler.currentIndex != nil && current?.textView.hasMarkedText() == false
        }
        if item.action == #selector(changeLanguage(_:)), let item = item as? NSMenuItem {
            let chosen = current?.languageOverride.flatMap { SyntaxLanguage.allCases.firstIndex(of: $0) } ?? -1
            item.state = item.tag == chosen ? .on : .off
            return current?.textView.hasMarkedText() == false
        }
        if item.action == #selector(performTextFinderAction(_:)) {
            return current?.textView.validateUserInterfaceItem(item) ?? false
        }
        return true
    }

    private func createWindow() {
        window = FolivynWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = L10n.appName
        window.minSize = NSSize(width: 600, height: 380)
        window.delegate = self
        window.onOpenURLs = { [weak self] in self?.open($0) }
        window.canOpenDroppedFiles = { [weak self] in self?.current?.textView.hasMarkedText() != true }
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
            if action == #selector(saveDocument) { saveButton = button }
        }
        viewMode.segmentCount = 2
        viewMode.trackingMode = .selectOne
        viewMode.target = self
        viewMode.action = #selector(changeViewMode)
        viewMode.setAccessibilityIdentifier("document-view-mode")
        toolbar.addArrangedSubview(viewMode)
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
        session.startFileObservation()
        sessions.append(session)
        tabs.addTabViewItem(session.item)
        tabs.selectTabViewItem(session.item)
        refresh()
        window.makeFirstResponder(session.presentation?.preferredResponder)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        for session in sessions where session !== current { session.presentation?.hidePreview() }
        current?.presentation?.showPreviewIfNeeded()
        refresh()
        if let session = current { window?.makeFirstResponder(session.presentation?.preferredResponder) }
    }

    private func refresh() {
        for session in sessions { session.item.label = session.name + (session.dirty ? " •" : "") }
        guard let session = current else { return }
        window?.title = L10n.format(.windowTitle, session.name, L10n.appName)
        window?.representedURL = session.documentURL
        window?.isDocumentEdited = session.dirty
        reloadButton?.isEnabled = session.documentURL != nil
        saveButton?.isEnabled = !session.isReadOnly
        viewMode.isHidden = session.presentation?.supportsStructure != true
        viewMode.setLabel(L10n.text(.sourceView), forSegment: 0)
        viewMode.setLabel(session.presentation?.structureTitle ?? "", forSegment: 1)
        viewMode.selectedSegment = session.presentation?.showsStructure == true ? 1 : 0
        if session.isReadOnly {
            status.stringValue = [L10n.text(.readOnlyPreview), session.documentURL?.path ?? ""].joined(separator: "  ·  ")
            status.toolTip = status.stringValue
            return
        }
        var parts = [session.file?.encoding.displayName ?? "UTF-8", SyntaxHighlighter.languageName(for: session.file?.url, override: session.languageOverride)]
        if let index = session.lineRuler.currentIndex {
            switch index.newlineStyle {
            case .none: parts.append(L10n.text(.noLineEndings))
            case .mixed: parts.append(L10n.text(.mixedLineEndings))
            default: parts.append(index.newlineStyle.rawValue)
            }
        } else if session.lineRuler.lastError != nil { parts.append(L10n.text(.lineIndexUnavailable)) }
        if session.syntax.isLimited { parts.append(L10n.text(.largeText)) }
        if session.dirty { parts.append(L10n.text(.unsaved)) }
        if session.diskChanged { parts.append(L10n.text(.diskChanged)) }
        parts.append(session.file?.url.path ?? L10n.text(.newDocument))
        status.stringValue = parts.joined(separator: "  ·  ")
        status.toolTip = status.stringValue
    }

    @objc private func newDocument() {
        guard window.attachedSheet == nil else { return }
        addSession(EditorSession())
    }
    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let session = current, !session.isReadOnly, window.attachedSheet == nil, !session.textView.hasMarkedText() else { return }
        session.languageOverride = SyntaxLanguage.allCases.indices.contains(sender.tag) ? SyntaxLanguage.allCases[sender.tag] : nil
    }

    @objc private func indentLines() { applyLineOperation(.indent(unit: "    "), name: .indent) }
    @objc private func unindentLines() { applyLineOperation(.unindent(spaceWidth: 4), name: .unindent) }
    @objc private func toggleLineComment() {
        guard let prefix = current?.lineCommentPrefix else { return }
        applyLineOperation(.toggleLineComment(prefix: prefix), name: .toggleLineComment)
    }
    private func applyLineOperation(_ operation: TextEditingOperations.Operation, name: L10n.Key) {
        guard window.attachedSheet == nil, let session = current,
              window.firstResponder === session.textView else { return }
        Task { @MainActor [weak self, weak session] in
            guard let session else { return }
            do {
                _ = try await session.applyLineOperation(operation, actionName: L10n.text(name), isEligible: { [weak self, weak session] in
                    guard let self, let session else { return false }
                    return self.current === session && self.window.attachedSheet == nil && NSApp.modalWindow == nil &&
                        self.window.firstResponder === session.textView
                })
            } catch is CancellationError { }
            catch {
                guard let self, self.current === session, self.window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
                self.showMessage(L10n.text(name), L10n.text(.lineOperationLimit))
            }
        }
    }

    @objc private func goToLine() {
        guard let session = current, !session.isReadOnly, window.attachedSheet == nil, !session.textView.hasMarkedText(),
              let index = session.lineRuler.currentIndex else { return }
        let revision = session.revision
        let alert = NSAlert()
        alert.messageText = L10n.text(.goToLine)
        alert.informativeText = L10n.format(.lineRange, index.lineCount)
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = String(index.lineNumber(atUTF16Offset: session.textView.selectedRange().location) ?? 1)
        input.setAccessibilityLabel(L10n.text(.lineNumber))
        alert.accessoryView = input
        alert.addButton(withTitle: L10n.text(.go))
        alert.addButton(withTitle: L10n.text(.cancel))
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard session.revision == revision, let line = Int(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              session.goToLine(line) else {
            showMessage(L10n.text(.goToLine), L10n.format(.lineRange, index.lineCount))
            return
        }
    }
    @objc private func changeViewMode() {
        _ = current?.presentation?.setShowsStructure(viewMode.selectedSegment == 1)
        refresh()
    }
    @objc private func openDocument() {
        guard window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L10n.format(.openMessage, DocumentFile.maximumReadBytes / 1_024 / 1_024)
        if panel.runModal() == .OK { open(panel.urls) }
    }

    private func open(_ urls: [URL]) {
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if let existing = sessions.first(where: { $0.documentURL == canonical }) {
                tabs.selectTabViewItem(existing.item)
                recentFiles.noteSuccessfulOpen(canonical)
                continue
            }
            do {
                let session: EditorSession
                switch try FileOpeningDecision.open(url) {
                case .editable(let loaded): session = EditorSession(file: loaded)
                case .preview(let url): session = EditorSession(readOnlyURL: url)
                }
                if sessions.count == 1, let empty = sessions.first, empty.documentURL == nil, empty.textView.string.isEmpty {
                    empty.stopFileObservation()
                    empty.lineRuler.invalidate()
                    empty.decorations?.invalidate()
                    empty.syntax.cancel()
                    tabs.removeTabViewItem(empty.item)
                    sessions.removeAll()
                }
                addSession(session)
                recentFiles.noteSuccessfulOpen(canonical)
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
        guard window.attachedSheet == nil, !session.isReadOnly else { return false }
        let chosen = saveAs || session.file == nil
        guard let url = chosen ? pickSaveURL(for: session) : session.file?.url else { return false }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let other = sessions.first(where: { $0 !== session && $0.documentURL == canonical }) {
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
            recentFiles.noteSuccessfulOpen(saved.url)
            if chosen { window.makeFirstResponder(session.presentation?.preferredResponder) }
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
        guard window.attachedSheet == nil else { return }
        if current?.isReadOnly == true { current?.presentation?.reloadPreview(); return }
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
                guard canonical != source, !sessions.contains(where: { $0 !== session && $0.documentURL == canonical }) else {
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
            // Apply the same classification as Open before replacing text. A
            // file that became binary/oversized must not enter an editable buffer.
            switch try FileOpeningDecision.open(source) {
            case .editable(let loaded):
                session.reload(loaded)
                window.makeFirstResponder(session.presentation?.preferredResponder)
            case .preview:
                showMessage(L10n.text(.readOnlyPreview), L10n.text(.reloadRequiresPreview))
            }
        } catch { showError(error) }
    }

    private func checkDiskChanges() {
        for session in sessions { session.fileObservation?.checkNow() }
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
        guard window.attachedSheet == nil else { return }
        guard let session = current else { return }
        if sessions.count == 1 { window.performClose(nil); return }
        guard confirmClose(session) else { return }
        session.stopFileObservation()
        session.presentation?.cancel()
        session.lineRuler.invalidate()
        session.decorations?.invalidate()
        session.syntax.cancel()
        sessions.removeAll { $0 === session }
        tabs.removeTabViewItem(session.item)
        refresh()
    }
    @objc private func nextTab() { cycleTab(1) }
    @objc private func previousTab() { cycleTab(-1) }
    private func cycleTab(_ offset: Int) {
        guard window.attachedSheet == nil else { return }
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
