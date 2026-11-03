import AppKit
import QuickLookUI
import EditorCore
import EditorUI

/// A separate, read-only snapshot. This extension never owns an editable document.
@objc(FolivynPreviewViewController)
@MainActor
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let textView = NSTextView(usingTextLayoutManager: true)
    private let status = NSTextField(labelWithString: "")
    private let syntax = SyntaxHighlighter()
    private var request: Task<Void, Never>?
    private var revision: UInt64 = 0

    override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let title = NSTextField(labelWithString: localized("preview.title"))
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        for child in [title, scroll, status] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
        view = content
        preferredContentSize = NSSize(width: 800, height: 600)
    }

    nonisolated func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { handler(CocoaError(.userCancelled)); return }
            self.prepare(url, completionHandler: handler)
        }
    }

    private func prepare(_ url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        request?.cancel()
        revision &+= 1
        let expectedRevision = revision
        _ = view
        syntax.cancel()
        textView.string = ""
        status.stringValue = localized("preview.loading")
        request = Task { @MainActor [weak self] in
            let read = Task.detached(priority: .userInitiated) { try TextPreview.read(url) }
            let result = await withTaskCancellationHandler { await read.result } onCancel: { read.cancel() }
            guard let self, !Task.isCancelled, self.revision == expectedRevision else {
                handler(CocoaError(.userCancelled))
                return
            }
            switch result {
            case .success(let preview):
                self.textView.string = preview.text
                var parts = [preview.encoding.displayName]
                if preview.truncated { parts.append(self.localized("preview.truncated")) }
                if preview.text.isEmpty { parts.append(self.localized("preview.empty")) }
                self.status.stringValue = parts.joined(separator: "  ·  ")
                self.syntax.highlight(textView: self.textView, fileURL: url)
            case .failure(let error):
                self.textView.string = error.localizedDescription
                self.status.stringValue = self.localized("preview.unavailable")
            }
            self.status.toolTip = self.status.stringValue
            self.textView.setSelectedRange(NSRange(location: 0, length: 0))
            self.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            handler(nil)
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        request?.cancel()
        syntax.cancel()
    }

    private func localized(_ key: String) -> String {
        Bundle(for: Self.self).localizedString(forKey: key, value: nil, table: nil)
    }
}
