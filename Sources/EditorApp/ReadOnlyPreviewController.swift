import AppKit
import EditorCore
import EditorUI

/// A bounded, independent snapshot. The host decides which files need this view
/// and disables document editing/saving commands while its tab is selected.
@MainActor
final class ReadOnlyPreviewController: NSViewController {
    struct Strings {
        var title = "Read-only preview"
        var loading = "Reading preview…"
        var cancelled = "Preview cancelled. Reload to try again."
        var unavailable = "Preview unavailable"
        var empty = "Empty text file"
        var complete = "Complete text preview"
        var truncated = "Prefix only. The rest of the file has not been decoded."
        var budget = "Preview limit: 200 KiB of text or 2,000 lines."
        var openWithSystem = "Open with System App…"
        var fileSizeUnknown = "File size unavailable"
        var sourceByteCount: (Int64) -> String = { "File size observed: \($0) bytes" }
        var previewByteCount: (Int) -> String = { "Displayed text: \($0) bytes (excluding BOM)" }
    }

    enum State: Equatable {
        case idle, loading, ready, unavailable, cancelled
    }

    typealias Reader = @Sendable (URL) throws -> LoadedTextPreview

    let textView: NSTextView = ReadOnlyPreviewTextView(usingTextLayoutManager: true)
    private(set) var fileURL: URL?
    private(set) var state: State = .idle
    private(set) var preview: LoadedTextPreview?
    /// Metadata observed immediately before reading; not an atomic disk snapshot.
    private(set) var sourceByteCount: Int64?
    private(set) var displayedByteCount: Int?
    private(set) var errorDescription: String?

    private let strings: Strings
    private let reader: Reader
    private let onOpenWithSystem: (URL) -> Void
    private let syntax = SyntaxHighlighter()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let errorMessage = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton()
    private var revision: UInt64 = 0
    private var readTask: Task<ReadResult, Never>?

    init(strings: Strings = Strings(),
         reader: @escaping Reader = { try TextPreview.read($0) },
         onOpenWithSystem: @escaping (URL) -> Void) {
        self.strings = strings
        self.reader = reader
        self.onOpenWithSystem = onOpenWithSystem
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit { readTask?.cancel() }

    override var undoManager: UndoManager? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let title = NSTextField(labelWithString: strings.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        openButton.title = strings.openWithSystem
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openWithSystem)
        openButton.isEnabled = false
        openButton.setAccessibilityIdentifier("readonly-open-system")
        let header = NSStackView(views: [title, spacer, openButton])
        header.spacing = 8

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.unregisterDraggedTypes()
        textView.setAccessibilityIdentifier("readonly-preview-text")
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("readonly-preview-status")
        errorMessage.font = .systemFont(ofSize: 12)
        errorMessage.textColor = .secondaryLabelColor
        errorMessage.isSelectable = true
        errorMessage.setAccessibilityIdentifier("readonly-preview-error")
        let footer = NSStackView(views: [errorMessage, status])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        errorMessage.isHidden = true
        for child in [header, scroll, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            errorMessage.widthAnchor.constraint(equalTo: footer.widthAnchor),
            status.widthAnchor.constraint(equalTo: footer.widthAnchor)
        ])
    }

    /// Call from a task owned by the host tab. Reading and metadata lookup happen
    /// off the main actor; cancellation never publishes a partial or stale result.
    func load(url: URL) async {
        cancelPendingRead()
        let expectedRevision = revision
        _ = view
        fileURL = url
        preview = nil
        sourceByteCount = nil
        displayedByteCount = nil
        errorDescription = nil
        textView.string = ""
        errorMessage.stringValue = ""
        errorMessage.isHidden = true
        openButton.isEnabled = url.isFileURL
        state = .loading
        setStatus(strings.loading)

        let read = reader
        let task = Task.detached(priority: .userInitiated) {
            guard url.isFileURL else {
                return ReadResult(result: .failure(DocumentFileError.invalidURL(url)), byteCount: nil)
            }
            if Task.isCancelled {
                return ReadResult(result: .failure(CancellationError()), byteCount: nil)
            }
            // This metadata is informative only. TextPreview independently
            // validates its opened descriptor and enforces all read budgets.
            let target = url.standardizedFileURL.resolvingSymlinksInPath()
            let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
            let bytes = attributes?[.type] as? FileAttributeType == .typeRegular
                ? (attributes?[.size] as? NSNumber)?.int64Value : nil
            return ReadResult(result: Result { try read(url) }, byteCount: bytes)
        }
        readTask = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard revision == expectedRevision else { return }
        readTask = nil
        guard !Task.isCancelled else { showCancelled(); return }
        sourceByteCount = result.byteCount
        switch result.result {
        case .success(let loaded):
            preview = loaded
            textView.string = loaded.text
            let byteCount: Int
            switch loaded.encoding {
            case .utf8, .utf8BOM: byteCount = loaded.text.utf8.count
            case .utf16LittleEndianBOM, .utf16BigEndianBOM: byteCount = loaded.text.utf16.count * 2
            }
            displayedByteCount = byteCount
            state = .ready
            let summary = loaded.truncated ? strings.truncated : loaded.text.isEmpty ? strings.empty : strings.complete
            setStatus([summary, strings.budget,
                       [loaded.encoding.displayName, strings.previewByteCount(byteCount), sizeDescription]
                        .joined(separator: "  ·  ")].joined(separator: "\n"))
            syntax.highlight(textView: textView, fileURL: url)
        case .failure(is CancellationError):
            showCancelled()
        case .failure(let error):
            state = .unavailable
            errorDescription = error.localizedDescription
            errorMessage.stringValue = error.localizedDescription
            errorMessage.isHidden = false
            setStatus([strings.unavailable, sizeDescription].joined(separator: "  ·  "))
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.enclosingScrollView?.contentView.scroll(to: .zero)
    }

    /// Invalidates publication even if a reader ignores cooperative cancellation.
    /// A completed preview stays visible when its tab is temporarily hidden.
    func cancel() {
        cancelPendingRead()
        if state == .loading { showCancelled() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        cancel()
    }

    @objc func openWithSystem() {
        guard let fileURL, fileURL.isFileURL else { return }
        // Only explicit user action invokes the host. This controller never
        // resolves an application, opens a URL, or executes file contents.
        onOpenWithSystem(fileURL)
    }

    private var sizeDescription: String {
        sourceByteCount.map(strings.sourceByteCount) ?? strings.fileSizeUnknown
    }

    private func cancelPendingRead() {
        revision &+= 1
        readTask?.cancel()
        readTask = nil
        syntax.cancel()
    }

    private func showCancelled() {
        state = .cancelled
        setStatus(strings.cancelled)
    }

    private func setStatus(_ value: String) {
        status.stringValue = value
        status.toolTip = value
    }

    private struct ReadResult: Sendable {
        let result: Result<LoadedTextPreview, Error>
        let byteCount: Int64?
    }
}

/// Keeps text selection/copy, but does not accept input, Services replacements,
/// dropped file paths, or the host document's undo manager.
@MainActor
private final class ReadOnlyPreviewTextView: NSTextView {
    override var undoManager: UndoManager? { nil }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [] }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
    override func readSelection(from pboard: NSPasteboard) -> Bool { false }
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool { false }
    override func insertText(_ string: Any, replacementRange: NSRange) {}
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool { false }
}
