import EditorUI

@MainActor
enum PreviewStrings {
    static func make() -> ReadOnlyPreviewController.Strings {
        ReadOnlyPreviewController.Strings(
            title: L10n.text(.readOnlyPreview), loading: L10n.text(.previewLoading),
            cancelled: L10n.text(.previewCancelled), unavailable: L10n.text(.previewUnavailable),
            empty: L10n.text(.previewEmpty), complete: L10n.text(.previewComplete),
            truncated: L10n.text(.previewPrefix), budget: L10n.text(.previewBudget),
            openWithSystem: L10n.text(.previewOpenSystem), fileSizeUnknown: L10n.text(.previewUnknownSize),
            sourceByteCount: { L10n.format(.previewFileBytes, $0) },
            previewByteCount: { L10n.format(.previewDisplayedBytes, $0) })
    }
}
