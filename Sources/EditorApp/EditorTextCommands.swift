import AppKit
import EditorCore
import EditorUI

@MainActor
extension EditorSession {
    var lineCommentPrefix: String? {
        switch languageOverride ?? SyntaxLanguage.forFile(file?.url) ?? .plainText {
        case .python, .shell: return "#"
        case .java, .javascript, .typescript, .jsonWithComments: return "//"
        case .plainText, .json: return nil
        }
    }

    /// Build the immutable edit away from the UI, then require the same source
    /// revision and selection before using the single native undo transaction.
    @discardableResult
    func applyLineOperation(_ operation: TextEditingOperations.Operation, actionName: String,
        planner: @escaping @Sendable (TextEditingOperations.Operation, String, NSRange) throws -> TextEditingOperations.Edit? = {
            try TextEditingOperations.plan($0, in: $1, selection: $2)
        }, isEligible: @MainActor () -> Bool = { true }) async throws -> Bool {
        guard !lineEditPending, !textView.hasMarkedText(), textView.isEditable,
              presentation?.csv?.hasPendingCellEdit != true, isEligible() else { return false }
        lineEditPending = true
        defer { lineEditPending = false }
        let source = textView.string, selection = textView.selectedRange(), expectedRevision = revision
        let worker = Task.detached(priority: .userInitiated) {
            try planner(operation, source, selection)
        }
        let edit = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, revision == expectedRevision, textView.selectedRange() == selection,
              !textView.hasMarkedText(), presentation?.csv?.hasPendingCellEdit != true,
              isEligible() else { return false }
        guard let edit else { return true }
        guard replaceSource(in: edit.range, expected: edit.expectedSource, with: edit.replacement,
                            revision: expectedRevision, actionName: actionName) else { return false }
        textView.setSelectedRange(edit.selection)
        textView.scrollRangeToVisible(edit.selection)
        return true
    }
}
