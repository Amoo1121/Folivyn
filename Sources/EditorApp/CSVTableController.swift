import AppKit
import EditorCore

/// The app supplies localized copy without tying the controller to resource keys.
struct CSVTableStrings {
    var loading = "Reading table…"
    var empty = "This file has no records. Add text in Source to create a table."
    var headerOnly = "Only the header row is present. Add records in Source."
    var delimiterTitle = "Delimiter:"
    var commaTitle = "Comma"
    var tabTitle = "Tab"
    var firstRowHeaderTitle = "First row as header"
    var editCell = "Edit Cell…"
    var showSource = "Show in Source"
    var apply = "Apply"
    var cancel = "Cancel"
    var missing = "Missing field — edit this row in Source to add a field."
    var stale = "The source changed. Copy your edit, close this sheet, and reopen the cell."
    var columnTitle: (Int) -> String = { "Column \($0)" }
    var summary: (Int, Int) -> String = { "\($0) records · \($1) columns. Double-click a cell to edit."
    }
    var editTitle: (Int, Int) -> String = { "Edit record \($0), column \($1)" }
    var error: (Error) -> String = { error in
        guard let error = error as? CSVDocumentError else { return error.localizedDescription }
        switch error {
        case .invalidLimits: return "The table limits are invalid. Source remains editable."
        case .cancelled: return "Table reading was cancelled. Source remains editable."
        case .byteLimitExceeded(let limit): return "Table view supports up to \(limit / 1_024 / 1_024) MiB of text. Source remains editable."
        case .recordLimitExceeded(let limit, _): return "Table view supports up to \(limit) records. Source remains editable."
        case .columnLimitExceeded(let limit, _): return "Table view supports up to \(limit) columns. Source remains editable."
        case .fieldLimitExceeded(let limit, _): return "Table view supports up to \(limit) total fields. Source remains editable."
        case .quoteInUnquotedField(let position): return "Unexpected quote at line \(position.line), column \(position.column). Fix it in Source."
        case .charactersAfterClosingQuote(let position): return "Unexpected text after a closing quote at line \(position.line), column \(position.column). Fix it in Source."
        case .unclosedQuotedField(let position): return "Unclosed quoted field at line \(position.line), column \(position.column). Fix it in Source."
        case .missingField: return "This field is missing. Add it in Source first."
        }
    }
}

/// A derived view only: the owning session remains the sole writable document.
/// The replace callback must check revision and expectedSource again, then use
/// NSTextView.shouldChangeText, textStorage.replaceCharacters, and didChangeText
/// inside one undo group. A false result leaves the sheet's draft available.
@MainActor
final class CSVTableController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum State { case idle, loading, ready, failed }
    typealias Parser = @Sendable (String, CSVDelimiter, CSVLimits, @Sendable () -> Bool) throws -> CSVDocument

    struct ParsedSnapshot {
        let text: String
        let revision: UInt64
        let document: CSVDocument
    }

    struct CellEdit {
        let snapshot: ParsedSnapshot
        let row: Int
        let column: Int
        var value: String { snapshot.document.field(row: row, column: column)!.value }
    }

    let tableView = NSTableView()
    private(set) var state: State = .idle
    private(set) var parsed: ParsedSnapshot?
    private(set) var lastError: Error?
    var stateDidChange: (() -> Void)?
    var hasPendingCellEdit: Bool { currentEdit != nil }
    private(set) var delimiter: CSVDelimiter
    private(set) var usesFirstRowAsHeader = false

    private let limits: CSVLimits
    private let strings: CSVTableStrings
    private let snapshot: () -> (String, UInt64)
    private let replace: (NSRange, String, String, UInt64) -> Bool
    private let selectSource: (NSRange) -> Void
    private let parser: Parser
    private let status = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let delimiterMenu = NSPopUpButton()
    private let headerToggle = NSButton()
    private let editButton = NSButton()
    private let sourceButton = NSButton()
    private var selectedColumn = 0
    private var generation: UInt64 = 0
    private var pendingRevision: UInt64?
    private var pendingText: String?
    private var parseTask: Task<Void, Never>?
    private var errorRange: NSRange?
    private var errorRevision: UInt64?
    private var editorSheet: NSWindow?
    private var editorText: NSTextView?
    private var editorMessage: NSTextField?
    private var currentEdit: CellEdit?
    private var preservedRecord: Int?
    private var preservedScrollOrigin: NSPoint?

    static func delimiter(for url: URL?) -> CSVDelimiter? {
        switch url?.pathExtension.lowercased() {
        case "csv": return .comma
        case "tsv": return .tab
        default: return nil
        }
    }

    init(
        delimiter: CSVDelimiter,
        limits: CSVLimits = CSVLimits(),
        strings: CSVTableStrings = CSVTableStrings(),
        parser: @escaping Parser = { source, delimiter, limits, isCancelled in
            try CSVDocument.parse(source, delimiter: delimiter, limits: limits, isCancelled: isCancelled)
        },
        snapshot: @escaping () -> (String, UInt64),
        replace: @escaping (NSRange, String, String, UInt64) -> Bool,
        selectSource: @escaping (NSRange) -> Void
    ) {
        self.delimiter = delimiter
        self.limits = limits
        self.strings = strings
        self.parser = parser
        self.snapshot = snapshot
        self.replace = replace
        self.selectSource = selectSource
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit { parseTask?.cancel() }

    override func loadView() {
        view = NSView()
        let scroll = scrollView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = tableView
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 25
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.target = self
        tableView.action = #selector(clickedCell)
        tableView.doubleAction = #selector(editSelectedCell)
        tableView.setAccessibilityIdentifier("csv-table")
        // A columnless NSTableView refuses first responder while its initial
        // parse is pending. Keep the row-number column present from the start.
        rebuildColumns(0)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editButton.title = strings.editCell
        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(editSelectedCell)
        editButton.setAccessibilityIdentifier("csv-edit-cell")
        sourceButton.title = strings.showSource
        sourceButton.bezelStyle = .rounded
        sourceButton.target = self
        sourceButton.action = #selector(showSelectedSource)
        sourceButton.setAccessibilityIdentifier("csv-show-source")
        let delimiterLabel = NSTextField(labelWithString: strings.delimiterTitle)
        delimiterLabel.font = .systemFont(ofSize: 11)
        delimiterMenu.addItems(withTitles: [strings.commaTitle, strings.tabTitle])
        delimiterMenu.selectItem(at: delimiter == .comma ? 0 : 1)
        delimiterMenu.target = self
        delimiterMenu.action = #selector(delimiterChanged)
        delimiterMenu.setAccessibilityIdentifier("csv-delimiter")
        headerToggle.title = strings.firstRowHeaderTitle
        headerToggle.setButtonType(.switch)
        headerToggle.target = self
        headerToggle.action = #selector(headerChanged)
        headerToggle.setAccessibilityIdentifier("csv-first-row-header")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [delimiterLabel, delimiterMenu, headerToggle, spacer, sourceButton, editButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        for child in [scroll, status, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            status.heightAnchor.constraint(equalToConstant: 17),
            status.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            footer.heightAnchor.constraint(equalToConstant: 28)
        ])
        updateButtons()
    }

    /// Call after every source revision, including undo, redo, and reload. Old
    /// results are cancelled and cannot regain edit authority when they finish.
    func refresh(immediately: Bool = false) {
        _ = view
        let captured = snapshot()
        if parsed?.document.delimiter == delimiter, parsed?.revision == captured.1,
           parsed?.text.utf16.elementsEqual(captured.0.utf16) == true { return }
        if state == .loading, pendingRevision == captured.1,
           pendingText?.utf16.elementsEqual(captured.0.utf16) == true { return }
        if parsed != nil {
            preservedRecord = sourceRecordIndex(forDisplayRow: tableView.selectedRow)
            preservedScrollOrigin = scrollView.contentView.bounds.origin
        }
        parseTask?.cancel()
        generation &+= 1
        let request = generation
        pendingRevision = captured.1
        pendingText = captured.0
        parsed = nil
        lastError = nil
        errorRange = nil
        errorRevision = nil
        status.stringValue = strings.loading
        tableView.reloadData()
        updateButtons()
        setState(.loading)
        let delimiter = self.delimiter
        let limits = self.limits
        let parser = self.parser
        parseTask = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(nanoseconds: 120_000_000) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { () -> Result<CSVDocument, Error> in
                Result { try parser(captured.0, delimiter, limits, { Task.isCancelled }) }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            self?.finish(result, text: captured.0, revision: captured.1, request: request)
        }
    }

    func cancelParsing() {
        parseTask?.cancel()
        parseTask = nil
        pendingRevision = nil
        pendingText = nil
        generation &+= 1
        if state == .loading {
            status.stringValue = strings.error(CSVDocumentError.cancelled)
            setState(.idle)
        }
    }

    private func finish(_ result: Result<CSVDocument, Error>, text: String, revision: UInt64, request: UInt64) {
        guard request == generation else { return }
        let current = snapshot()
        guard revision == current.1, text.utf16.elementsEqual(current.0.utf16) else {
            pendingRevision = nil
            pendingText = nil
            setState(.idle)
            refresh()
            return
        }
        pendingRevision = nil
        pendingText = nil
        parseTask = nil
        switch result {
        case .success(let document):
            parsed = ParsedSnapshot(text: text, revision: revision, document: document)
            rebuildColumns(document.maximumColumnCount)
            tableView.reloadData()
            restoreSelectionAndScroll()
            updateSummary()
            setState(.ready)
        case .failure(let error):
            lastError = error
            errorRange = Self.position(of: error).map { NSRange(location: $0.utf16Offset, length: 0) }
            errorRevision = revision
            status.stringValue = strings.error(error)
            tableView.reloadData()
            setState(.failed)
        }
        status.toolTip = status.stringValue
        updateButtons()
    }

    private func setState(_ state: State) {
        self.state = state
        stateDidChange?()
    }

    private func rebuildColumns(_ count: Int) {
        if tableView.tableColumns.count == count + 1 {
            updateColumnTitles()
            return
        }
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        let rowNumber = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        rowNumber.title = "#"
        rowNumber.width = 55
        rowNumber.minWidth = 40
        rowNumber.maxWidth = 90
        tableView.addTableColumn(rowNumber)
        for index in 0..<count {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = strings.columnTitle(index + 1)
            column.width = 190
            column.minWidth = 75
            tableView.addTableColumn(column)
        }
        selectedColumn = min(selectedColumn, max(0, count - 1))
        updateColumnTitles()
    }

    private var headerOffset: Int { usesFirstRowAsHeader ? 1 : 0 }

    func numberOfRows(in tableView: NSTableView) -> Int {
        max(0, (parsed?.document.records.count ?? 0) - headerOffset)
    }

    /// Display rows exclude the optional header; CellEdit.row always uses source
    /// record indices. Switching the header flag never alters the parsed document.
    func sourceRecordIndex(forDisplayRow row: Int) -> Int? {
        guard row >= 0, row < numberOfRows(in: tableView) else { return nil }
        return row + headerOffset
    }

    func displayRow(forSourceRecord record: Int) -> Int? {
        let row = record - headerOffset
        guard sourceRecordIndex(forDisplayRow: row) == record else { return nil }
        return row
    }

    @discardableResult
    func setDelimiter(_ delimiter: CSVDelimiter) -> Bool {
        guard !hasPendingCellEdit else { return false }
        guard self.delimiter != delimiter else { return true }
        _ = view
        cancelParsing()
        self.delimiter = delimiter
        delimiterMenu.selectItem(at: delimiter == .comma ? 0 : 1)
        refresh(immediately: true)
        return true
    }

    @discardableResult
    func setFirstRowAsHeader(_ enabled: Bool) -> Bool {
        guard !hasPendingCellEdit else { return false }
        guard usesFirstRowAsHeader != enabled else { return true }
        _ = view
        preservedRecord = sourceRecordIndex(forDisplayRow: tableView.selectedRow)
        preservedScrollOrigin = scrollView.contentView.bounds.origin
        usesFirstRowAsHeader = enabled
        headerToggle.state = enabled ? .on : .off
        updateColumnTitles()
        tableView.reloadData()
        restoreSelectionAndScroll()
        updateSummary()
        updateButtons()
        return true
    }

    @objc private func delimiterChanged() {
        if !setDelimiter(delimiterMenu.indexOfSelectedItem == 1 ? .tab : .comma) {
            delimiterMenu.selectItem(at: delimiter == .comma ? 0 : 1)
        }
    }

    @objc private func headerChanged() {
        if !setFirstRowAsHeader(headerToggle.state == .on) {
            headerToggle.state = usesFirstRowAsHeader ? .on : .off
        }
    }

    private func updateColumnTitles() {
        for column in tableView.tableColumns {
            guard let index = Int(column.identifier.rawValue) else { continue }
            let header = usesFirstRowAsHeader ? parsed?.document.field(row: 0, column: index)?.value : nil
            column.title = header.flatMap { $0.isEmpty ? nil : Self.singleLinePreview($0, scalarLimit: 120) } ?? strings.columnTitle(index + 1)
            column.headerCell.stringValue = column.title
        }
    }

    private func updateSummary() {
        guard let document = parsed?.document else { return }
        if document.records.isEmpty { status.stringValue = strings.empty }
        else if numberOfRows(in: tableView) == 0 { status.stringValue = strings.headerOnly }
        else { status.stringValue = strings.summary(numberOfRows(in: tableView), document.maximumColumnCount) }
        status.toolTip = status.stringValue
    }

    private func restoreSelectionAndScroll() {
        if let preservedRecord, let row = displayRow(forSourceRecord: preservedRecord) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        if let origin = preservedScrollOrigin {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let parsed, let record = sourceRecordIndex(forDisplayRow: row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("csv-value")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        if let column = Int(tableColumn.identifier.rawValue) {
            if let field = parsed.document.field(row: record, column: column) {
                let value = field.value
                // A virtual table still must not lay out a multi-megabyte field
                // inside one cell. The editor sheet retains the complete value.
                cell.textField?.stringValue = Self.singleLinePreview(value)
                cell.textField?.textColor = .labelColor
                cell.toolTip = String(value.unicodeScalars.prefix(300))
            } else {
                cell.textField?.stringValue = "—"
                cell.textField?.textColor = .tertiaryLabelColor
                cell.toolTip = strings.missing
            }
        } else {
            cell.textField?.stringValue = String(record + 1)
            cell.textField?.textColor = .secondaryLabelColor
            cell.toolTip = nil
        }
        return cell
    }

    /// Hard breaks can overflow a fixed-height NSTextField even when its maximum
    /// line count is one. This is display-only; CellEdit keeps the exact value.
    private static func singleLinePreview(_ value: String, scalarLimit: Int = 512) -> String {
        var preview = String(value.unicodeScalars.prefix(scalarLimit))
            .replacingOccurrences(of: "\r\n", with: " ↵ ")
        for separator in ["\r", "\n", "\u{85}", "\u{2028}", "\u{2029}"] {
            preview = preview.replacingOccurrences(of: separator, with: " ↵ ")
        }
        return preview
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc private func clickedCell() {
        let column = tableView.clickedColumn
        if tableView.tableColumns.indices.contains(column), let index = Int(tableView.tableColumns[column].identifier.rawValue) {
            selectedColumn = index
        }
        updateButtons()
    }

    private func updateButtons() {
        let hasField = sourceRecordIndex(forDisplayRow: tableView.selectedRow).flatMap {
            parsed?.document.field(row: $0, column: selectedColumn)
        } != nil
        editButton.isEnabled = hasField && !hasPendingCellEdit
        sourceButton.isEnabled = (hasField || errorRange != nil) && !hasPendingCellEdit
        delimiterMenu.isEnabled = !hasPendingCellEdit
        headerToggle.isEnabled = !hasPendingCellEdit
    }

    @objc private func showSelectedSource() {
        if let range = errorRange, errorRevision == snapshot().1 {
            selectSource(range)
            return
        }
        guard let edit = prepareEdit(row: tableView.selectedRow, column: selectedColumn),
              let field = edit.snapshot.document.field(row: edit.row, column: edit.column) else { return }
        selectSource(field.rawRange)
    }

    /// Kept separate from presenting a sheet so revision safety and real document
    /// undo integration can be tested without synthesizing window interactions.
    func prepareEdit(row: Int, column: Int) -> CellEdit? {
        guard let parsed, let record = sourceRecordIndex(forDisplayRow: row),
              parsed.document.field(row: record, column: column) != nil else { return nil }
        let current = snapshot()
        guard parsed.revision == current.1, parsed.text.utf16.elementsEqual(current.0.utf16) else {
            refresh(immediately: true)
            return nil
        }
        return CellEdit(snapshot: parsed, row: record, column: column)
    }

    func beginCellEdit(row: Int, column: Int) -> CellEdit? {
        guard !hasPendingCellEdit, let edit = prepareEdit(row: row, column: column) else { return nil }
        currentEdit = edit
        updateButtons()
        return edit
    }

    @discardableResult
    func apply(_ value: String, for edit: CellEdit) -> Bool {
        do {
            let change = try edit.snapshot.document.replacement(row: edit.row, column: edit.column, value: value)
            let current = snapshot()
            let length = current.0.utf16.count
            guard current.1 == edit.snapshot.revision,
                  edit.snapshot.document.delimiter == delimiter,
                  current.0.utf16.elementsEqual(edit.snapshot.text.utf16),
                  change.range.location <= length, change.range.length <= length - change.range.location,
                  (current.0 as NSString).substring(with: change.range).utf16.elementsEqual(change.expectedSource.utf16) else {
                showEditMessage(strings.stale)
                refresh(immediately: true)
                return false
            }
            if change.expectedSource.utf16.elementsEqual(change.escapedReplacement.utf16) { return true }
            guard replace(change.range, change.expectedSource, change.escapedReplacement, edit.snapshot.revision) else {
                showEditMessage(strings.stale)
                refresh(immediately: true)
                return false
            }
            refresh(immediately: true)
            return true
        } catch {
            showEditMessage(strings.error(error))
            return false
        }
    }

    private func showEditMessage(_ message: String) {
        editorMessage?.stringValue = message
        status.stringValue = message
        status.toolTip = message
    }

    @objc private func editSelectedCell() {
        clickedCell()
        guard !hasPendingCellEdit, let parent = view.window,
              let edit = beginCellEdit(row: tableView.selectedRow, column: selectedColumn) else { return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.title = strings.editTitle(edit.row + 1, edit.column + 1)
        panel.minSize = NSSize(width: 420, height: 260)
        panel.isReleasedWhenClosed = false
        let content = panel.contentView!
        let input = NSTextView(usingTextLayoutManager: true)
        input.isRichText = false
        input.importsGraphics = false
        input.allowsUndo = true
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.isAutomaticSpellingCorrectionEnabled = false
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.textContainerInset = NSSize(width: 10, height: 10)
        input.autoresizingMask = [.width]
        input.minSize = .zero
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.isVerticallyResizable = true
        input.textContainer?.widthTracksTextView = true
        input.string = edit.value
        input.setAccessibilityIdentifier("csv-cell-editor")
        let scroll = NSScrollView()
        scroll.documentView = input
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let message = NSTextField(wrappingLabelWithString: "")
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        let cancel = NSButton(title: strings.cancel, target: self, action: #selector(cancelCellEditor))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1B}"
        let apply = NSButton(title: strings.apply, target: self, action: #selector(applyCellEditor))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        apply.keyEquivalentModifierMask = [.command]
        apply.setAccessibilityIdentifier("csv-apply-cell")
        for child in [scroll, message, cancel, apply] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -8),
            message.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            message.heightAnchor.constraint(equalToConstant: 34),
            message.bottomAnchor.constraint(equalTo: apply.topAnchor, constant: -8),
            apply.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            apply.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            cancel.trailingAnchor.constraint(equalTo: apply.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: apply.centerYAnchor)
        ])
        editorSheet = panel
        editorText = input
        editorMessage = message
        updateButtons()
        parent.beginSheet(panel)
        panel.makeFirstResponder(input)
    }

    @objc private func applyCellEditor() {
        guard let currentEdit, let editorText else { return }
        editorText.unmarkText()
        if apply(editorText.string, for: currentEdit) { cancelCellEditor() }
    }

    @objc func cancelCellEditor() {
        if let panel = editorSheet { panel.sheetParent?.endSheet(panel); panel.orderOut(nil) }
        editorSheet = nil
        editorText = nil
        editorMessage = nil
        currentEdit = nil
        updateButtons()
    }

    private static func position(of error: Error) -> CSVSourcePosition? {
        switch error as? CSVDocumentError {
        case .recordLimitExceeded(_, let position), .columnLimitExceeded(_, let position), .fieldLimitExceeded(_, let position),
             .quoteInUnquotedField(let position), .charactersAfterClosingQuote(let position), .unclosedQuotedField(let position):
            return position
        default: return nil
        }
    }
}
