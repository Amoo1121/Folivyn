import AppKit
import EditorCore

@MainActor
extension EditorSession {
    /// An explicit buffer edit, never a save. The caller should weakly capture
    /// its host in isEligible so a result cannot follow a closed or replaced tab.
    /// The pending flag is shared with line commands to prevent overlapping edits.
    @discardableResult
    func applyNewlineConversion(
        _ target: NewlineConversion.Target, actionName: String,
        planner: @escaping @Sendable (String, NewlineConversion.Target, NSRange) throws -> NewlineConversion.Conversion = {
            try NewlineConversion.convert($0, to: $1, selection: $2)
        },
        isEligible: @MainActor () -> Bool = { true },
        onError: @MainActor (Error) -> Void = { _ in }
    ) async -> Bool {
        guard !Task.isCancelled, !lineEditPending, canConvertNewlines, isEligible() else { return false }
        lineEditPending = true
        defer { lineEditPending = false }
        let source = textView.string
        let selection = textView.selectedRange()
        let expectedRevision = revision
        let worker = Task.detached(priority: .userInitiated) {
            try planner(source, target, selection)
        }
        // Even direct NSTextStorage mutation without a delegate notification is
        // rejected: Swift String equality alone would allow Unicode normalization.
        func stillEligible() -> Bool {
            !Task.isCancelled && revision == expectedRevision && canConvertNewlines &&
                textView.selectedRange() == selection && isEligible() &&
                textView.string.utf16.elementsEqual(source.utf16)
        }
        do {
            let conversion = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard stillEligible(), conversion.sourceUTF16Count == source.utf16.count,
                  let mappedSelection = conversion.selection else { return false }
            guard conversion.isChanged else { return true }
            guard replaceSource(in: NSRange(location: 0, length: conversion.sourceUTF16Count),
                                expected: source, with: conversion.text,
                                revision: expectedRevision, actionName: actionName) else { return false }
            textView.setSelectedRange(mappedSelection)
            textView.scrollRangeToVisible(mappedSelection)
            return true
        } catch is CancellationError {
            return false
        } catch {
            // Errors from an obsolete operation must not present UI over a new
            // document, an IME composition, or a sheet opened while planning.
            if stillEligible() { onError(error) }
            return false
        }
    }

    private var canConvertNewlines: Bool {
        !isReadOnly && textView.isEditable && !textView.hasMarkedText() &&
            textView.selectedRanges.count == 1 &&
            presentation?.csv?.hasPendingCellEdit != true &&
            textView.window?.attachedSheet == nil && NSApp.modalWindow == nil
    }
}
