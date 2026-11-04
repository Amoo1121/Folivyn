import Foundation
import EditorUI

@MainActor
enum RecoveryStrings {
    static func make() -> RecoveryPrompt.Strings {
        var strings = RecoveryPrompt.Strings()
        strings.title = L10n.text(.recoveryTitle)
        strings.restoreAll = L10n.text(.recoveryRestoreAll)
        strings.later = L10n.text(.recoveryLater)
        strings.discardRecoveredDrafts = L10n.text(.recoveryDiscard)
        strings.untitled = L10n.text(.untitled)
        strings.nameColumn = L10n.text(.recoveryNameColumn)
        strings.updatedColumn = L10n.text(.recoveryUpdatedColumn)
        strings.noReadableDrafts = L10n.text(.recoveryNoReadable)
        strings.discardExplanation = L10n.text(.recoveryDiscardExplanation)
        strings.summary = { L10n.format(.recoverySummary, $0) }
        strings.unreadableCount = { L10n.format(.recoveryUnreadableCount, $0) }
        strings.tooManyDrafts = { L10n.format(.recoveryTooMany, $0) }
        return strings
    }
}
