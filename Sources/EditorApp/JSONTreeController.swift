import AppKit
import EditorCore

/// A read-only projection of a specific source revision. All edits stay in the
/// source text view; this controller only asks its owner to select source ranges.
@MainActor
final class JSONTreeController: NSViewController, NSOutlineViewDataSource,
                                NSOutlineViewDelegate, NSSearchFieldDelegate {
    struct Strings {
        var keyColumn = "Key / index"
        var valueColumn = "Value"
        var root = "Root"
        var searchPlaceholder = "Search keys and values"
        var previous = "Previous"
        var next = "Next"
        var copyPointer = "Copy JSON Pointer"
        var showError = "Show Error in Source"
        var loading = "Reading JSON…"
        var searching = "Searching…"
        var noMatches = "No matches"
        var duplicateKey = "Duplicate key"
        var ambiguousPointer = "This path contains a duplicate key; its JSON Pointer is ambiguous."
        var rootPointer = "The root JSON Pointer is an empty string."
        var unavailable = "JSON structure is unavailable. You can continue editing the source."
        var objectSummary: (Int) -> String = { "Object · \($0) members" }
        var arraySummary: (Int) -> String = { "Array · \($0) items" }
        var ready: (Int) -> String = { "\($0) values · read only" }
        var matchCount: (Int, Int) -> String = { "Match \($0) of \($1)" }
        var parseError: (JSONStructureError.Kind, Int, Int) -> String = {
            "\($0.rawValue) at line \($1), column \($2). Edit the source to fix it."
        }
    }

    typealias Snapshot = () -> (String, UInt64)
    typealias Parser = @Sendable (String) throws -> JSONStructure

    let outlineView = NSOutlineView()
    let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let copyButton = NSButton()
    private let errorButton = NSButton()
    private let snapshot: Snapshot
    private let selectSource: (NSRange) -> Void
    private let strings: Strings
    private let parser: Parser
    private var parseTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var rootItem: JSONTreeItem?
    private var matches: [JSONTreeSearch.Match] = []
    private var matchIndex: Int?
    private var suppressSourceSelection = false
    private(set) var structure: JSONStructure?
    private(set) var displayedRevision: UInt64?
    private(set) var parseError: JSONStructureError?

    init(snapshot: @escaping Snapshot, selectSource: @escaping (NSRange) -> Void,
         strings: Strings = Strings(),
         parser: @escaping Parser = { try JSONStructure.parse($0) }) {
        self.snapshot = snapshot
        self.selectSource = selectSource
        self.strings = strings
        self.parser = parser
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        parseTask?.cancel()
        searchTask?.cancel()
    }

    override func loadView() {
        view = NSView()
        let key = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        key.title = strings.keyColumn
        key.width = 180
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        value.title = strings.valueColumn
        value.width = 260
        outlineView.addTableColumn(key)
        outlineView.addTableColumn(value)
        outlineView.outlineTableColumn = key
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .small
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = false
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        searchField.placeholderString = strings.searchPlaceholder
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel(strings.searchPlaceholder)
        configure(previousButton, title: strings.previous, action: #selector(previousMatch))
        configure(nextButton, title: strings.next, action: #selector(nextMatch))
        configure(copyButton, title: strings.copyPointer, action: #selector(copyJSONPointer))
        configure(errorButton, title: strings.showError, action: #selector(showParseError))
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        let searchRow = NSStackView(views: [searchField, previousButton, nextButton])
        searchRow.spacing = 6
        let footer = NSStackView(views: [copyButton, errorButton])
        footer.spacing = 6
        for child in [searchRow, scrollView, status, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            searchRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            searchRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            scrollView.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            status.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
        updateButtons()
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    /// Call after any source edit, undo/redo or Reload, with a new source revision.
    /// Clearing the old tree immediately prevents navigating through stale ranges.
    func refresh() {
        loadViewIfNeeded()
        cancel()
        let requestedGeneration = generation
        let (text, revision) = snapshot()
        structure = nil
        displayedRevision = nil
        parseError = nil
        rootItem = nil
        matches = []
        matchIndex = nil
        outlineView.reloadData()
        status.stringValue = strings.loading
        updateButtons()
        let parser = self.parser
        parseTask = Task { @MainActor [weak self] in
            // Coalesce typing before the bounded parser enters its worker task.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) {
                Result { try parser(text) }
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self,
                  self.generation == requestedGeneration,
                  self.snapshot().1 == revision else { return }
            self.displayedRevision = revision
            switch result {
            case .success(let parsed):
                self.structure = parsed
                let root = JSONTreeItem(node: parsed.root, label: self.strings.root)
                self.rootItem = root
                self.outlineView.reloadData()
                // Do not recursively expand a potentially 100,000-node tree.
                self.outlineView.expandItem(root, expandChildren: false)
                self.status.stringValue = self.strings.ready(parsed.nodeCount)
                self.beginSearch()
            case .failure(let error):
                if let jsonError = error as? JSONStructureError, jsonError.kind != .cancelled {
                    self.parseError = jsonError
                    let position = Self.sourcePosition(in: text, at: jsonError.utf16Location)
                    self.status.stringValue = self.strings.parseError(jsonError.kind, position.line, position.column)
                } else {
                    self.status.stringValue = self.strings.unavailable
                }
            }
            self.parseTask = nil
            self.updateButtons()
        }
    }

    func cancel() {
        generation &+= 1
        searchGeneration &+= 1
        parseTask?.cancel()
        searchTask?.cancel()
        parseTask = nil
        searchTask = nil
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? JSONTreeItem)?.childCount ?? (rootItem == nil ? 0 : 1)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let parent = item as? JSONTreeItem { return parent.child(at: index) }
        return rootItem!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? JSONTreeItem)?.childCount ?? 0 > 0
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? JSONTreeItem, let column = tableColumn else { return nil }
        let field = (outlineView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = column.identifier
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        if column.identifier.rawValue == "key" {
            field.stringValue = Self.displaySlice(item.label as NSString,
                                                 range: NSRange(location: 0, length: item.label.utf16.count))
                + (item.duplicateKey ? " · \(strings.duplicateKey)" : "")
            field.textColor = item.duplicateKey ? .systemOrange : .labelColor
        } else {
            field.stringValue = valueSummary(for: item)
            field.textColor = .secondaryLabelColor
        }
        field.toolTip = field.stringValue
        return field
    }

    func valueSummary(for item: JSONTreeItem) -> String {
        switch item.node.value {
        case .object(let members): return strings.objectSummary(members.count)
        case .array(let children): return strings.arraySummary(children.count)
        default:
            guard let source = structure?.source as NSString? else { return "" }
            return Self.displaySlice(source, range: item.node.tokenRange)
        }
    }

    private static func displaySlice(_ source: NSString, range: NSRange) -> String {
        // Limit keys and values before asking an AppKit cell to lay them out.
        // A truncated label is presentation only; source ranges stay complete.
        var length = 0, scalars = 0
        while length < range.length, scalars < 240 {
            let unit = source.character(at: range.location + length)
            length += 1
            if (0xD800...0xDBFF).contains(unit), length < range.length,
               (0xDC00...0xDFFF).contains(source.character(at: range.location + length)) { length += 1 }
            scalars += 1
        }
        let text = source.substring(with: NSRange(location: range.location, length: length))
        return text + (length < range.length ? "…" : "")
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        guard !suppressSourceSelection, isCurrent,
              let selected = selectedItem else { return }
        selectSource(selected.node.tokenRange)
    }

    private var selectedItem: JSONTreeItem? {
        outlineView.item(atRow: outlineView.selectedRow) as? JSONTreeItem
    }

    private var isCurrent: Bool {
        displayedRevision != nil && displayedRevision == snapshot().1
    }

    var selectedPointer: JSONPointer? {
        guard isCurrent, let selected = selectedItem else { return nil }
        return structure?.pointer(to: selected.node)
    }

    private func updateButtons() {
        previousButton.isEnabled = isCurrent && !matches.isEmpty
        nextButton.isEnabled = previousButton.isEnabled
        let pointer = selectedPointer
        copyButton.isEnabled = pointer != nil && pointer?.isAmbiguous == false
        copyButton.toolTip = pointer?.isAmbiguous == true ? strings.ambiguousPointer
            : (pointer?.value == "" ? strings.rootPointer : pointer.map {
                Self.displaySlice($0.value as NSString,
                                  range: NSRange(location: 0, length: $0.value.utf16.count))
            })
        errorButton.isHidden = parseError == nil
        errorButton.isEnabled = isCurrent && parseError != nil
    }

    @objc private func copyJSONPointer() {
        guard let pointer = selectedPointer, !pointer.isAmbiguous else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pointer.value, forType: .string)
    }

    @objc func showParseError() {
        guard isCurrent, let error = parseError else { return }
        selectSource(NSRange(location: error.utf16Location, length: 0))
    }

    func controlTextDidChange(_ obj: Notification) { beginSearch() }

    func setSearchQuery(_ query: String) {
        loadViewIfNeeded()
        searchField.stringValue = query
        beginSearch()
    }

    private func beginSearch() {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        matches = []
        matchIndex = nil
        updateButtons()
        guard let structure, let revision = displayedRevision, isCurrent else { return }
        let query = searchField.stringValue
        guard !query.isEmpty else {
            status.stringValue = strings.ready(structure.nodeCount)
            return
        }
        status.stringValue = strings.searching
        let requestedGeneration = searchGeneration
        searchTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) {
                JSONTreeSearch.matches(in: structure, query: query)
            }
            let results = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self,
                  self.searchGeneration == requestedGeneration,
                  self.displayedRevision == revision, self.isCurrent else { return }
            self.matches = results
            self.status.stringValue = results.isEmpty ? self.strings.noMatches : self.strings.matchCount(0, results.count)
            self.searchTask = nil
            self.updateButtons()
        }
    }

    @objc func nextMatch() { moveMatch(by: 1) }
    @objc func previousMatch() { moveMatch(by: -1) }

    private func moveMatch(by offset: Int) {
        guard isCurrent, !matches.isEmpty else { return }
        let index = matchIndex.map { ($0 + offset + matches.count) % matches.count }
            ?? (offset > 0 ? 0 : matches.count - 1)
        let match = matches[index]
        guard reveal(tokenRange: match.nodeRange) else { return }
        matchIndex = index
        status.stringValue = strings.matchCount(index + 1, matches.count)
        selectSource(match.selectionRange)
    }

    /// Optional source-to-tree navigation; does not feed a selection back to source.
    func revealSourceRange(_ range: NSRange) {
        guard isCurrent, let rootItem,
              let item = rootItem.deepestItem(containing: range.location) else { return }
        _ = reveal(tokenRange: item.node.tokenRange)
    }

    @discardableResult
    private func reveal(tokenRange: NSRange) -> Bool {
        guard isCurrent, let rootItem,
              let item = rootItem.item(with: tokenRange) else { return false }
        // Selecting source notifies the host, which may reveal that selection
        // back here. An already-selected item needs no second scroll/selection.
        if selectedItem === item { return true }
        let horizontalOrigin = scrollView.contentView.bounds.origin.x
        var ancestors: [JSONTreeItem] = []
        var parent = item.parent
        while let ancestor = parent { ancestors.append(ancestor); parent = ancestor.parent }
        for ancestor in ancestors.reversed() { outlineView.expandItem(ancestor, expandChildren: false) }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return false }
        suppressSourceSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSourceSelection = false
        // scrollRowToVisible can also move horizontally to expose the complete
        // table row. Reveal only its vertical extent and retain the user's x.
        let rowRect = outlineView.rect(ofRow: row)
        let visibleRect = outlineView.visibleRect
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.x = horizontalOrigin
        if rowRect.minY < visibleRect.minY {
            origin.y += rowRect.minY - visibleRect.minY
        } else if rowRect.maxY > visibleRect.maxY {
            origin.y += rowRect.maxY - visibleRect.maxY
        }
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
        updateButtons()
        return true
    }

    static func sourcePosition(in text: String, at location: Int) -> (line: Int, column: Int) {
        var line = 1, column = 1, offset = 0
        var previousWasCR = false
        for unit in text.utf16 {
            guard offset < location else { break }
            if unit == 13 { line += 1; column = 1 }
            else if unit == 10 { if !previousWasCR { line += 1 }; column = 1 }
            else { column += 1 }
            previousWasCR = unit == 13
            offset += 1
        }
        return (line, column)
    }
}

/// Nodes are wrapped only when NSOutlineView asks for a child or navigation needs
/// a particular path. Parsing a large array does not allocate a view per element.
final class JSONTreeItem: NSObject {
    let node: JSONNode
    let label: String
    let duplicateKey: Bool
    weak var parent: JSONTreeItem?
    private var children: [Int: JSONTreeItem] = [:]

    init(node: JSONNode, label: String, duplicateKey: Bool = false, parent: JSONTreeItem? = nil) {
        self.node = node
        self.label = label
        self.duplicateKey = duplicateKey
        self.parent = parent
    }

    var childCount: Int {
        switch node.value {
        case .object(let members): return members.count
        case .array(let elements): return elements.count
        default: return 0
        }
    }

    func child(at index: Int) -> JSONTreeItem {
        if let child = children[index] { return child }
        let child: JSONTreeItem
        switch node.value {
        case .object(let members):
            let member = members[index]
            child = JSONTreeItem(node: member.value, label: member.keyLexeme,
                                 duplicateKey: member.isDuplicateKey, parent: self)
        case .array(let elements):
            child = JSONTreeItem(node: elements[index], label: "[\(index)]", parent: self)
        default: preconditionFailure("A scalar JSON value has no children")
        }
        children[index] = child
        return child
    }

    private func childNode(at index: Int) -> JSONNode {
        switch node.value {
        case .object(let members): return members[index].value
        case .array(let elements): return elements[index]
        default: preconditionFailure("A scalar JSON value has no children")
        }
    }

    private func childSourceRange(at index: Int) -> NSRange {
        if case .object(let members) = node.value {
            let member = members[index]
            return NSRange(location: member.keyTokenRange.location,
                           length: NSMaxRange(member.value.tokenRange) - member.keyTokenRange.location)
        }
        return childNode(at: index).tokenRange
    }

    private func childIndex(containing location: Int) -> Int? {
        // Source-ordered, nonoverlapping ranges permit a bounded path lookup
        // without wrapping every preceding sibling in a large array.
        var lower = 0, upper = childCount
        while lower < upper {
            let middle = (lower + upper) / 2
            let range = childSourceRange(at: middle)
            if location < range.location { upper = middle }
            else if location >= NSMaxRange(range) { lower = middle + 1 }
            else { return middle }
        }
        return nil
    }

    func item(with tokenRange: NSRange) -> JSONTreeItem? {
        if node.tokenRange == tokenRange { return self }
        guard let index = childIndex(containing: tokenRange.location) else { return nil }
        return child(at: index).item(with: tokenRange)
    }

    func deepestItem(containing location: Int) -> JSONTreeItem? {
        guard location >= node.tokenRange.location, location < NSMaxRange(node.tokenRange) else { return nil }
        guard let index = childIndex(containing: location) else { return self }
        let child = child(at: index)
        return child.deepestItem(containing: location) ?? child
    }
}

enum JSONTreeSearch {
    struct Match: Sendable, Equatable {
        let nodeRange: NSRange
        let selectionRange: NSRange
    }

    static func matches(in structure: JSONStructure, query: String,
                        isCancelled: () -> Bool = { Task<Never, Never>.isCancelled }) -> [Match] {
        guard !query.isEmpty else { return [] }
        var results: [Match] = []
        func contains(_ value: String) -> Bool {
            value.range(of: query, options: [.caseInsensitive, .literal]) != nil
        }
        func visit(_ node: JSONNode, key: JSONMember? = nil) {
            guard !isCancelled() else { return }
            var selected: NSRange?
            if let key, contains(key.key) { selected = key.keyTokenRange }
            if selected == nil {
                let value: String?
                switch node.value {
                case .string(let string), .number(let string): value = string
                case .bool(let bool): value = bool ? "true" : "false"
                case .null: value = "null"
                default: value = nil
                }
                if let value, contains(value) { selected = node.tokenRange }
            }
            if let selected { results.append(Match(nodeRange: node.tokenRange, selectionRange: selected)) }
            switch node.value {
            case .object(let members): for member in members { visit(member.value, key: member) }
            case .array(let children): for child in children { visit(child) }
            default: break
            }
        }
        visit(structure.root)
        return isCancelled() ? [] : results
    }
}
