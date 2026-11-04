import AppKit
import EditorCore
import EditorUI

/// Views retain no independent writable document. The session owns both text and
/// undo; these controllers are disposable projections of its current revision.
@MainActor
final class DocumentPresentation {
    enum Kind { case text, csv, json, preview }
    let view = DocumentPresentationView()
    private(set) var kind: Kind = .text
    private(set) var showsStructure = false
    private(set) var csv: CSVTableController?
    private(set) var json: JSONTreeController?
    private(set) var preview: ReadOnlyPreviewController?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration: UInt64 = 0
    private weak var session: EditorSession?
    private var fileExtension = ""
    private var split: NSSplitView?

    init(session: EditorSession) {
        self.session = session
        view.session = session
        configure()
    }

    var supportsStructure: Bool { kind == .csv || kind == .json }
    var structureTitle: String { L10n.text(kind == .csv ? .tableView : .treeView) }
    var preferredResponder: NSResponder? {
        if let preview { return preview.textView }
        return showsStructure && kind == .csv ? csv?.tableView : session?.textView
    }

    func configure() {
        guard let session else { return }
        if let url = session.readOnlyURL {
            guard preview == nil else { return }
            kind = .preview
            showsStructure = false
            preview = ReadOnlyPreviewController(strings: PreviewStrings.make(), onOpenWithSystem: { url in
                let workspace = NSWorkspace.shared
                if let application = workspace.urlForApplication(toOpen: url),
                   Bundle(url: application)?.bundleIdentifier != Bundle.main.bundleIdentifier {
                    workspace.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    workspace.activateFileViewerSelecting([url])
                }
            })
            rebuild()
            reloadPreview(url)
            return
        }
        let ext = session.file?.url.pathExtension.lowercased() ?? ""
        if fileExtension == ext, !view.subviews.isEmpty { return }
        cancel()
        fileExtension = ext
        csv = nil
        json = nil
        kind = ["csv", "tsv"].contains(ext) ? .csv : (ext == "json" ? .json : .text)
        showsStructure = supportsStructure
        let snapshot: () -> (String, UInt64) = { [weak session] in
            guard let session else { return ("", 0) }
            return (session.textView.string, session.revision)
        }
        let select: (NSRange) -> Void = { [weak self] range in self?.selectSource(range) }
        if kind == .csv {
            csv = CSVTableController(delimiter: ext == "tsv" ? .tab : .comma,
                strings: StructuredViewStrings.csv(), snapshot: snapshot,
                replace: { [weak session] range, expected, replacement, revision in
                    session?.replaceSource(in: range, expected: expected, with: replacement,
                        revision: revision, actionName: L10n.text(.editCell)) ?? false
                }, selectSource: select)
        } else if kind == .json {
            json = JSONTreeController(snapshot: snapshot, selectSource: select, strings: StructuredViewStrings.json())
        }
        rebuild()
    }

    @discardableResult
    func setShowsStructure(_ show: Bool) -> Bool {
        guard let session, !session.isReadOnly, !session.textView.hasMarkedText(), csv?.hasPendingCellEdit != true else { return false }
        let show = show && supportsStructure
        guard show != showsStructure else { return true }
        showsStructure = show
        rebuild()
        session.changed?()
        view.window?.makeFirstResponder(preferredResponder)
        return true
    }

    private func rebuild() {
        guard let session else { return }
        cancel()
        session.scrollView.removeFromSuperview()
        csv?.view.removeFromSuperview()
        json?.view.removeFromSuperview()
        for child in view.subviews { child.removeFromSuperview() }
        split = nil
        let content: NSView
        if let preview {
            content = preview.view
        } else if showsStructure, let csv {
            content = csv.view
            csv.refresh(immediately: true)
        } else if showsStructure, let json {
            let split = NSSplitView()
            split.isVertical = true
            split.dividerStyle = .thin
            split.addArrangedSubview(session.scrollView)
            split.addArrangedSubview(json.view)
            self.split = split
            content = split
            json.refresh()
        } else {
            content = session.scrollView
        }
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = view.bounds
        content.autoresizingMask = [.width, .height]
        view.addSubview(content)
        // NSTabView sizes its newly installed content later in this event. Set
        // the first divider only after that layout, not against a zero-size view.
        if let split {
            DispatchQueue.main.async { [weak split] in
                guard let split, split.bounds.width > 0 else { return }
                split.setPosition(split.bounds.width * 0.5, ofDividerAt: 0)
            }
        }
    }

    func sourceDidChange() {
        guard showsStructure else { return }
        csv?.refresh()
        json?.refresh()
    }

    func sourceSelectionDidChange() {
        guard showsStructure, let session else { return }
        json?.revealSourceRange(session.textView.selectedRange())
    }

    private func selectSource(_ range: NSRange) {
        guard let session, !session.textView.hasMarkedText() else { return }
        let length = session.textView.string.utf16.count
        guard range.location >= 0, range.length >= 0, range.location <= length,
              range.length <= length - range.location else { return }
        if kind == .csv { _ = setShowsStructure(false) }
        session.textView.setSelectedRange(range)
        session.textView.scrollRangeToVisible(range)
        // Tree/search controls retain focus so keyboard navigation stays usable.
        if kind == .csv { view.window?.makeFirstResponder(session.textView) }
    }

    func cancel() {
        hidePreview()
        csv?.cancelParsing()
        json?.cancel()
    }

    func showPreviewIfNeeded() {
        guard preview?.state == .idle || preview?.state == .cancelled else { return }
        if previewTask == nil { reloadPreview() }
    }

    func hidePreview() {
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        preview?.cancel()
    }

    func reloadPreview(_ url: URL? = nil) {
        guard let preview, let url = url ?? session?.readOnlyURL else { return }
        hidePreview()
        let generation = previewGeneration
        previewTask = Task { @MainActor [weak self, weak preview] in
            guard !Task.isCancelled, self?.previewGeneration == generation, let preview else { return }
            await preview.load(url: url)
            if self?.previewGeneration == generation { self?.previewTask = nil }
        }
    }
}

/// Keeps document undo available when a read-only table/tree owns keyboard focus.
/// Native field editors still handle their own undo earlier in the responder chain.
@MainActor
final class DocumentPresentationView: NSView, NSUserInterfaceValidations {
    weak var session: EditorSession?
    override var undoManager: UndoManager? { session?.isReadOnly == true ? nil : session?.undoStack }
    @objc func undo(_ sender: Any?) { if session?.isReadOnly != true { session?.undoStack.undo() } }
    @objc func redo(_ sender: Any?) { if session?.isReadOnly != true { session?.undoStack.redo() } }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard session?.isReadOnly != true else { return false }
        if item.action == #selector(undo(_:)) { return session?.undoStack.canUndo == true }
        if item.action == #selector(redo(_:)) { return session?.undoStack.canRedo == true }
        return false
    }
}
