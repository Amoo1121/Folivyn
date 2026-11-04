import AppKit
import EditorCore

/// A TextKit 2-only gutter. Source indexing happens off the main actor; drawing
/// uses already laid-out viewport fragments and never requests whole-file layout.
@MainActor
final class LineNumberRuler: NSRulerView {
    typealias Snapshot = () -> (String, UInt64)
    typealias Builder = @Sendable (String) throws -> TextLineIndex
    struct Label: Equatable {
        let line: Int
        /// Top of the visual line, in NSTextView coordinates.
        let textY: CGFloat
        let height: CGFloat
    }

    private(set) var currentIndex: TextLineIndex?
    private(set) var displayedRevision: UInt64?
    private(set) var lastError: Error?
    var onIndexChange: (() -> Void)?
    private weak var sourceTextView: NSTextView?
    private let snapshot: Snapshot
    private let builder: Builder
    private var indexTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var pendingRevision: UInt64?
    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView, snapshot: @escaping Snapshot,
         builder: @escaping Builder = { try TextLineIndex.build($0) }) {
        sourceTextView = textView
        self.snapshot = snapshot
        self.builder = builder
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        // Since macOS 14 views do not clip by default. NSRulerView's own
        // border drawing must stay in the gutter when a plain tab is redrawn.
        clipsToBounds = true
        clientView = textView
        ruleThickness = 42
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: textView)
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    required init(coder: NSCoder) { fatalError("LineNumberRuler requires a source text view") }

    deinit {
        indexTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    /// Call for every source revision (including undo, redo and Reload). No stale
    /// index remains available for Go to Line while the replacement is pending.
    func refresh() {
        let (source, revision) = snapshot()
        if displayedRevision == revision, currentIndex != nil { needsDisplay = true; return }
        if pendingRevision == revision { return }
        invalidate()
        pendingRevision = revision
        let request = generation
        let builder = self.builder
        indexTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) { Result { try builder(source) } }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.generation == request,
                  self.snapshot().1 == revision else { return }
            self.indexTask = nil
            self.pendingRevision = nil
            switch result {
            case .success(let index):
                self.currentIndex = index
                self.displayedRevision = revision
                self.lastError = nil
                let width = (String(index.lineCount) as NSString).size(withAttributes: [.font: self.labelFont]).width + 16
                self.ruleThickness = max(42, ceil(width))
            case .failure(let error):
                self.lastError = error
            }
            self.needsDisplay = true
            self.onIndexChange?()
        }
    }

    func invalidate() {
        generation &+= 1
        indexTask?.cancel()
        indexTask = nil
        pendingRevision = nil
        currentIndex = nil
        displayedRevision = nil
        lastError = nil
        needsDisplay = true
        onIndexChange?()
    }

    @objc private func geometryChanged(_ notification: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let textView = sourceTextView else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        for label in visibleLabels() {
            let number = String(label.line) as NSString
            let size = number.size(withAttributes: attributes)
            let top = convert(NSPoint(x: 0, y: label.textY), from: textView).y
            let point = NSPoint(x: bounds.maxX - size.width - 7, y: top + max(0, (label.height - size.height) / 2))
            if NSRect(origin: point, size: size).intersects(rect) { number.draw(at: point, withAttributes: attributes) }
        }
    }

    /// Internal for layout tests. The fixed ceilings complement viewport bounds
    /// even for pathological metrics. They limit decoration, never source edits.
    func visibleLabels(maximumFragments: Int = 2_048, maximumVisualLines: Int = 4_096) -> [Label] {
        guard maximumFragments > 0, maximumVisualLines > 0,
              let index = currentIndex, displayedRevision == snapshot().1,
              let textView = sourceTextView,
              let layout = textView.textLayoutManager,
              let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return [] }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        guard visible.height > 0 else { return [] }
        let documentStart = content.documentRange.location
        let viewportEnd = content.offset(from: documentStart, to: viewport.endLocation)
        var labels: [Label] = []
        var fragmentsVisited = 0, visualLinesVisited = 0
        var lastLine: Int?
        layout.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresExtraLineFragment]) { fragment in
            guard fragmentsVisited < min(maximumFragments, 2_048), visualLinesVisited < min(maximumVisualLines, 4_096) else { return false }
            fragmentsVisited += 1
            let fragmentStart = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            guard fragmentStart <= viewportEnd else { return false }
            guard fragment.state == .layoutAvailable else { return true }
            let frame = fragment.layoutFragmentFrame
            if frame.minY > visible.maxY { return false }
            if frame.maxY < visible.minY { return true }
            let elementStart = fragment.textElement?.elementRange.map {
                content.offset(from: documentStart, to: $0.location)
            } ?? fragmentStart
            let lines = fragment.textLineFragments
            // A very long wrapped paragraph may have many visual lines. Find
            // the first visible one by geometry instead of scanning from its top.
            var lower = 0, upper = lines.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if frame.minY + lines[middle].typographicBounds.maxY < visible.minY { lower = middle + 1 }
                else { upper = middle }
            }
            var position = lower
            while position < lines.count, visualLinesVisited < min(maximumVisualLines, 4_096) {
                let line = lines[position]
                position += 1
                visualLinesVisited += 1
                let bounds = line.typographicBounds
                let top = frame.minY + bounds.minY
                if top > visible.maxY { break }
                let offset = elementStart + line.characterRange.location
                guard let logicalLine = index.lineNumber(atUTF16Offset: offset), logicalLine != lastLine,
                      index.insertionRange(forLine: logicalLine)?.location == offset else { continue }
                labels.append(Label(line: logicalLine, textY: origin.y + top, height: bounds.height))
                lastLine = logicalLine
            }
            return true
        }
        return labels
    }
}
