import AppKit
import EditorCore
import EditorUI

/// Ephemeral background drawing. No text, document attributes or undo entries
/// are changed, and neither TextKit delegate nor the input client is replaced.
@MainActor
final class EditorDecorations: NSObject {
    typealias Snapshot = () -> (String, UInt64)
    typealias Matcher = @Sendable (String, Int, BracketMatcher.Policy) throws -> BracketPair?

    struct Geometry {
        var currentLine: NSRect?
        var brackets: [NSRect] = []
    }

    private(set) var bracketPair: BracketPair?
    private(set) var displayedRevision: UInt64?
    private(set) var lastError: BracketMatchError?
    private weak var textView: FolivynTextView?
    private let snapshot: Snapshot
    private let language: () -> SyntaxLanguage
    private let matcher: Matcher
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var active = false
    private var matchedSelection: NSRange?
    private var matchedLanguage: SyntaxLanguage?
    private static let maximumUTF16Units = BracketMatcher.Limits().maximumUTF16Units

    init(textView: FolivynTextView, snapshot: @escaping Snapshot,
         language: @escaping () -> SyntaxLanguage,
         matcher: @escaping Matcher = { try BracketMatcher.match(in: $0, atUTF16Offset: $1, policy: $2) }) {
        self.textView = textView
        self.snapshot = snapshot
        self.language = language
        self.matcher = matcher
        super.init()
        textView.editorDecorations?.invalidate()
        textView.editorDecorations = self
        for name in [NSTextView.didChangeSelectionNotification, NSText.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(sourceOrSelectionChanged(_:)),
                                                   name: name, object: textView)
        }
        refresh()
    }

    deinit {
        task?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    /// Call after source revision or language changes, including undo/redo/reload.
    /// Selection notifications are observed without replacing the text delegate.
    func refresh() {
        invalidate()
        // An owner may briefly retain an old controller after installing another
        // one. Later owner callbacks must not reactivate the superseded observer.
        guard textView?.editorDecorations === self else { return }
        active = true
        guard let textView, !textView.hasMarkedText(), textView.textLayoutManager != nil,
              textView.selectedRanges.count == 1,
              textView.selectedRange().length == 0,
              let storage = textView.textStorage, storage.length <= Self.maximumUTF16Units else { return }
        let selection = textView.selectedRange()
        guard selection.location >= 0, selection.location <= storage.length else { return }
        let (source, revision) = snapshot()
        let chosenLanguage = language()
        let policy: BracketMatcher.Policy
        switch chosenLanguage {
        case .plainText: policy = .literal
        case .json: policy = .json
        default: policy = .conservativeCode
        }
        let request = generation
        let matcher = self.matcher
        task = Task { @MainActor [weak self, weak textView] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            let worker = Task.detached(priority: .utility) {
                Result { try matcher(source, selection.location, policy) }
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, let textView, self.active,
                  self.generation == request, !textView.hasMarkedText(),
                  textView.selectedRanges.count == 1, textView.selectedRange() == selection,
                  self.language() == chosenLanguage else { return }
            let latest = self.snapshot()
            guard latest.1 == revision, latest.0.utf16.elementsEqual(source.utf16) else { return }
            self.task = nil
            self.displayedRevision = revision
            self.matchedSelection = selection
            self.matchedLanguage = chosenLanguage
            switch result {
            case .success(let pair): self.bracketPair = pair
            case .failure(let error): self.lastError = error as? BracketMatchError
            }
            self.redrawVisibleArea()
        }
    }

    /// Cancels work and removes both decorations. A later refresh enables them.
    func invalidate() {
        generation &+= 1
        task?.cancel()
        task = nil
        active = false
        bracketPair = nil
        displayedRevision = nil
        matchedSelection = nil
        matchedLanguage = nil
        lastError = nil
        redrawVisibleArea()
    }

    @objc private func sourceOrSelectionChanged(_ notification: Notification) {
        if active { refresh() }
    }

    private func redrawVisibleArea() {
        guard let textView else { return }
        textView.setNeedsDisplay(textView.visibleRect.intersection(textView.bounds), avoidAdditionalLayout: true)
    }

    /// Called by NSTextView's documented background drawing hook, behind glyphs.
    func draw(in dirtyRect: NSRect) {
        guard let textView, active, !textView.hasMarkedText() else { return }
        let clip = dirtyRect.intersection(textView.visibleRect).intersection(textView.bounds)
        guard !clip.isEmpty else { return }
        let geometry = visibleGeometry()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clip).addClip()
        if let line = geometry.currentLine {
            NSColor.labelColor.withAlphaComponent(0.045).setFill()
            line.fill()
        }
        for rect in geometry.brackets {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// Uses already laid-out viewport fragments only. The highlighted row is the
    /// caret's visual line, so a long soft-wrapped paragraph requires no full scan.
    func visibleGeometry(maximumFragments: Int = 2_048, maximumVisualLines: Int = 4_096) -> Geometry {
        var result = Geometry()
        guard active, maximumFragments > 0, maximumVisualLines > 0,
              let textView, !textView.hasMarkedText(), textView.selectedRanges.count == 1,
              textView.selectedRange().length == 0,
              let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return result }
        let selection = textView.selectedRange()
        let sourceLength = textView.textStorage?.length ?? 0
        guard selection.location >= 0, selection.location <= sourceLength else { return result }
        let visible = textView.visibleRect.intersection(textView.bounds)
        guard !visible.isEmpty else { return result }
        let origin = textView.textContainerOrigin
        let containerVisible = visible.offsetBy(dx: -origin.x, dy: -origin.y)
        let documentStart = content.documentRange.location
        let viewportEnd = content.offset(from: documentStart, to: viewport.endLocation)
        let pair: BracketPair?
        if matchedSelection == selection, matchedLanguage == language(),
           let displayedRevision, displayedRevision == snapshot().1 { pair = bracketPair }
        else { pair = nil }
        let bracketOffsets = pair.map { [$0.opening.location, $0.closing.location] } ?? []
        var fragmentsVisited = 0, linesVisited = 0
        layout.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresExtraLineFragment]) { fragment in
            guard fragmentsVisited < min(maximumFragments, 2_048), linesVisited < min(maximumVisualLines, 4_096) else { return false }
            fragmentsVisited += 1
            let fragmentStart = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            guard fragmentStart <= viewportEnd else { return false }
            guard fragment.state == .layoutAvailable else { return true }
            let frame = fragment.layoutFragmentFrame
            if frame.minY > containerVisible.maxY { return false }
            if frame.maxY < containerVisible.minY { return true }
            let elementStart = fragment.textElement?.elementRange.map {
                content.offset(from: documentStart, to: $0.location)
            } ?? fragmentStart
            let lines = fragment.textLineFragments
            var lower = 0, upper = lines.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if frame.minY + lines[middle].typographicBounds.maxY < containerVisible.minY { lower = middle + 1 }
                else { upper = middle }
            }
            for index in lower..<lines.count {
                guard linesVisited < min(maximumVisualLines, 4_096) else { return false }
                linesVisited += 1
                let line = lines[index]
                let bounds = line.typographicBounds
                let top = origin.y + frame.minY + bounds.minY
                if top > visible.maxY { break }
                let start = elementStart + line.characterRange.location
                let end = start + line.characterRange.length
                if (selection.location >= start && selection.location < end) ||
                    (selection.location == sourceLength && selection.location == end) {
                    result.currentLine = NSRect(x: visible.minX, y: top, width: visible.width, height: bounds.height).intersection(visible)
                }
                for offset in bracketOffsets where offset >= start && offset < end {
                    guard let startLocation = content.location(documentStart, offsetBy: offset),
                          let endLocation = content.location(startLocation, offsetBy: 1),
                          let range = NSTextRange(location: startLocation, end: endLocation) else { continue }
                    // Query only this already-laid-out visible character. Caret
                    // edge subtraction is wrong at bidirectional run boundaries;
                    // the segment API supplies the actual displayed glyph span.
                    var segments = 0
                    layout.enumerateTextSegments(in: range, type: .standard, options: []) { segmentRange, frame, _, _ in
                        guard segments < 4 else { return false }
                        segments += 1
                        guard let segmentRange, !segmentRange.isEmpty else { return true }
                        let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
                        if !rect.isEmpty, rect.intersects(visible) {
                            let clipped = rect.intersection(visible)
                            if !result.brackets.contains(clipped) { result.brackets.append(clipped) }
                        }
                        return true
                    }
                }
            }
            return true
        }
        return result
    }
}
