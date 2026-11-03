import EditorCore
import EditorUI

@MainActor
enum StructuredViewStrings {
    static func csv() -> CSVTableStrings {
        var strings = CSVTableStrings()
        strings.loading = L10n.text(.csvLoading)
        strings.empty = L10n.text(.csvEmpty)
        strings.headerOnly = L10n.text(.csvHeaderOnly)
        strings.delimiterTitle = L10n.text(.csvDelimiter)
        strings.commaTitle = L10n.text(.csvComma)
        strings.tabTitle = L10n.text(.csvTab)
        strings.firstRowHeaderTitle = L10n.text(.csvHeader)
        strings.editCell = L10n.text(.editCell)
        strings.showSource = L10n.text(.csvShowSource)
        strings.apply = L10n.text(.apply)
        strings.cancel = L10n.text(.cancel)
        strings.missing = L10n.text(.csvMissing)
        strings.stale = L10n.text(.csvStale)
        strings.columnTitle = { L10n.format(.csvColumn, $0) }
        strings.summary = { L10n.format(.csvSummary, $0, $1) }
        strings.editTitle = { L10n.format(.csvEditTitle, $0, $1) }
        strings.error = { error in
            guard let error = error as? CSVDocumentError else { return error.localizedDescription }
            switch error {
            case .invalidLimits: return L10n.text(.csvInvalidLimits)
            case .cancelled: return L10n.text(.csvCancelled)
            case .byteLimitExceeded(let limit): return L10n.format(.csvByteLimit, limit / 1_024 / 1_024)
            case .recordLimitExceeded(let limit, _): return L10n.format(.csvRecordLimit, limit)
            case .columnLimitExceeded(let limit, _): return L10n.format(.csvColumnLimit, limit)
            case .fieldLimitExceeded(let limit, _): return L10n.format(.csvFieldLimit, limit)
            case .quoteInUnquotedField(let p): return L10n.format(.csvQuote, p.line, p.column)
            case .charactersAfterClosingQuote(let p): return L10n.format(.csvAfterQuote, p.line, p.column)
            case .unclosedQuotedField(let p): return L10n.format(.csvUnclosed, p.line, p.column)
            case .missingField: return L10n.text(.csvMissing)
            }
        }
        return strings
    }

    static func json() -> JSONTreeController.Strings {
        var strings = JSONTreeController.Strings()
        strings.keyColumn = L10n.text(.jsonKey)
        strings.valueColumn = L10n.text(.jsonValue)
        strings.root = L10n.text(.jsonRoot)
        strings.searchPlaceholder = L10n.text(.jsonSearch)
        strings.previous = L10n.text(.previous)
        strings.next = L10n.text(.next)
        strings.copyPointer = L10n.text(.jsonCopyPointer)
        strings.showError = L10n.text(.jsonShowError)
        strings.loading = L10n.text(.jsonLoading)
        strings.searching = L10n.text(.searching)
        strings.noMatches = L10n.text(.noMatches)
        strings.duplicateKey = L10n.text(.jsonDuplicate)
        strings.ambiguousPointer = L10n.text(.jsonAmbiguous)
        strings.rootPointer = L10n.text(.jsonRootPointer)
        strings.unavailable = L10n.text(.jsonUnavailable)
        strings.objectSummary = { L10n.format(.jsonObject, $0) }
        strings.arraySummary = { L10n.format(.jsonArray, $0) }
        strings.ready = { L10n.format(.jsonReady, $0) }
        strings.matchCount = { L10n.format(.matchCount, $0, $1) }
        strings.parseError = { L10n.format(.jsonParseError, jsonReason($0), $1, $2) }
        return strings
    }

    private static func jsonReason(_ kind: JSONStructureError.Kind) -> String {
        let key: L10n.Key
        switch kind {
        case .expectedValue: key = .jsonErrorExpectedValue
        case .expectedObjectKey: key = .jsonErrorExpectedObjectKey
        case .expectedColon: key = .jsonErrorExpectedColon
        case .expectedCommaOrEnd: key = .jsonErrorExpectedCommaOrEnd
        case .invalidNumber: key = .jsonErrorInvalidNumber
        case .invalidStringEscape: key = .jsonErrorInvalidStringEscape
        case .unescapedControlCharacter: key = .jsonErrorUnescapedControlCharacter
        case .invalidUnicodeEscape: key = .jsonErrorInvalidUnicodeEscape
        case .unpairedSurrogate: key = .jsonErrorUnpairedSurrogate
        case .unexpectedEnd: key = .jsonErrorUnexpectedEnd
        case .trailingContent: key = .jsonErrorTrailingContent
        case .inputTooLarge: key = .jsonErrorInputTooLarge
        case .nestingTooDeep: key = .jsonErrorNestingTooDeep
        case .tooManyNodes: key = .jsonErrorTooManyNodes
        case .cancelled: key = .jsonErrorCancelled
        case .invalidLimits: key = .jsonErrorInvalidLimits
        }
        return L10n.text(key)
    }
}
