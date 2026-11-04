import AppKit
import EditorCore

/// Presents recovery metadata only. The caller owns claiming, restoring and
/// discarding snapshots; displaying this prompt never touches their storage.
@MainActor
enum RecoveryPrompt {
    static let maximumDraftCount = 128

    enum Choice: Equatable {
        case restoreAll
        case later
        case discardRecoveredDrafts
    }

    struct Strings {
        var title = "Recover Unsaved Drafts"
        var restoreAll = "Restore All"
        var later = "Later"
        var discardRecoveredDrafts = "Discard Recovered Drafts"
        var untitled = "Untitled"
        var nameColumn = "Draft"
        var updatedColumn = "Last Updated"
        var noReadableDrafts = "No readable drafts are available to restore."
        var discardExplanation = "Discard removes only the listed recovered drafts. Unreadable recovery files are kept."
        var summary: (Int) -> String = {
            "\($0) unsaved draft(s) are available. Each draft opens in a separate unsaved tab. Original files will not be overwritten."
        }
        var unreadableCount: (Int) -> String = {
            "\($0) recovery item(s) could not be read. These files will be kept, whichever option you choose."
        }
        var tooManyDrafts: (Int) -> String = {
            "Only the first \($0) drafts can be shown here. Recovery has been postponed; all recovery files will be kept."
        }
        var updatedAt: (Date) -> String = {
            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
        }
    }

    /// One dialog for the entire scan, including scans with unreadable items.
    /// An empty scan needs no dialog. An oversized scan cannot authorize an
    /// action on drafts that the user has not been able to review.
    static func present(drafts: [RecoveredDraft], issueCount: Int,
                        strings: Strings = Strings()) -> Choice {
        guard !drafts.isEmpty || issueCount > 0 else { return .later }
        let response = makeAlert(drafts: drafts, issueCount: issueCount, strings: strings).runModal()
        guard !drafts.isEmpty, drafts.count <= maximumDraftCount else { return .later }
        switch response {
        case .alertFirstButtonReturn: return .restoreAll
        case .alertThirdButtonReturn: return .discardRecoveredDrafts
        default: return .later
        }
    }

    /// Builds an unpresented alert so layout and wiring can be inspected without
    /// entering a modal event loop or changing any recovery state.
    static func makeAlert(drafts: [RecoveredDraft], issueCount: Int,
                          strings: Strings = Strings()) -> NSAlert {
        let alert = NSAlert()
        let exceedsLimit = drafts.count > maximumDraftCount
        let hasActionableDrafts = !drafts.isEmpty && !exceedsLimit
        alert.alertStyle = issueCount > 0 || exceedsLimit ? .warning : .informational
        alert.messageText = strings.title

        var paragraphs = [drafts.isEmpty ? strings.noReadableDrafts : strings.summary(drafts.count)]
        if issueCount > 0 { paragraphs.append(strings.unreadableCount(issueCount)) }
        if exceedsLimit { paragraphs.append(strings.tooManyDrafts(maximumDraftCount)) }
        else if !drafts.isEmpty { paragraphs.append(strings.discardExplanation) }
        alert.informativeText = paragraphs.joined(separator: "\n\n")

        let restore = alert.addButton(withTitle: strings.restoreAll)
        restore.isEnabled = hasActionableDrafts
        restore.keyEquivalent = hasActionableDrafts ? "\r" : ""
        let later = alert.addButton(withTitle: strings.later)
        later.keyEquivalent = "\u{1B}"
        let discard = alert.addButton(withTitle: strings.discardRecoveredDrafts)
        discard.isEnabled = hasActionableDrafts
        discard.hasDestructiveAction = true
        discard.keyEquivalent = ""

        if !drafts.isEmpty {
            let rows = drafts.prefix(maximumDraftCount).map { draft in
                let filename = draft.snapshot.originPath.map { ($0 as NSString).lastPathComponent } ?? ""
                return RecoveryDraftListView.Row(
                    name: displayText(filename.isEmpty ? strings.untitled : filename),
                    updated: displayText(strings.updatedAt(draft.snapshot.updatedAt)))
            }
            alert.accessoryView = RecoveryDraftListView(rows: rows, strings: strings)
        }
        return alert
    }

    /// Snapshot metadata is untrusted display content. Keep it to a single
    /// bounded line without changing the snapshot or its recovery reference.
    private static func displayText(_ value: String) -> String {
        let limit = 160
        var result = String.UnicodeScalarView()
        var count = 0
        for scalar in value.unicodeScalars {
            guard count < limit else { result.append("…"); break }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                result.append(" ")
            } else {
                result.append(scalar)
            }
            count += 1
        }
        return String(result)
    }
}

/// The accessory owns its data source for the lifetime of the alert. Only
/// projected names and dates are retained, never draft contents or file URLs.
@MainActor
private final class RecoveryDraftListView: NSScrollView, NSTableViewDataSource {
    struct Row {
        let name: String
        let updated: String
    }

    private let rows: [Row]

    init(rows: [Row], strings: RecoveryPrompt.Strings) {
        self.rows = rows
        let height = min(288, max(96, 24 + rows.count * 26))
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: height))
        borderType = .bezelBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = false

        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 540, height: height))
        for (identifier, title, width) in [
            ("name", strings.nameColumn, CGFloat(350)),
            ("updated", strings.updatedColumn, CGFloat(190))
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.isEditable = false
            let cell = NSTextFieldCell(textCell: "")
            cell.isEditable = false
            cell.isSelectable = false
            cell.lineBreakMode = .byTruncatingMiddle
            cell.usesSingleLineMode = true
            column.dataCell = cell
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsTypeSelect = false
        table.selectionHighlightStyle = .none
        table.dataSource = self
        documentView = table
        table.reloadData()
    }

    required init?(coder: NSCoder) { nil }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard rows.indices.contains(row) else { return nil }
        return tableColumn?.identifier.rawValue == "updated" ? rows[row].updated : rows[row].name
    }
}
