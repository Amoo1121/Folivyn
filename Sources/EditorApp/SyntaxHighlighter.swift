import AppKit
import Foundation

/// A small, offline syntax highlighter.
/// It changes presentation attributes only; document text and undo are untouched.
@MainActor
final class SyntaxHighlighter {
    nonisolated static let maximumUTF8Bytes = 200 * 1024
    nonisolated static let maximumLineCount = 20_000
    nonisolated static var highlightingLimitDescription: String {
        L10n.format(.highlightingLimit, maximumUTF8Bytes / 1024, maximumLineCount)
    }

    private var pendingTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    /// Shared with the status bar so it describes the same limit decision as coloring.
    private(set) var isLimited = false

    nonisolated static func languageName(for fileURL: URL?) -> String {
        SyntaxLanguage.forFile(fileURL)?.displayName ?? L10n.text(.plainText)
    }

    /// Safe to call for every text change and after opening/reloading a document.
    /// A short debounce keeps typing responsive; stale parses are never applied.
    func highlight(textView: NSTextView, fileURL: URL?) {
        revision &+= 1
        pendingTask?.cancel()
        pendingTask = nil

        // Do not interfere with a Chinese/Japanese/etc. input composition.
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        // UTF-8 needs at least as many bytes as UTF-16 code units. Reject an
        // obviously oversized buffer without scanning or copying all its text.
        guard storage.length <= Self.maximumUTF8Bytes else {
            isLimited = true
            clearColors(in: textView)
            return
        }

        let snapshot = textView.string
        isLimited = Self.exceedsHighlightingLimits(snapshot)
        guard !isLimited, let language = SyntaxLanguage.forFile(fileURL) else {
            clearColors(in: textView)
            return
        }

        let requestedRevision = revision
        pendingTask = Task { @MainActor [weak self, weak textView] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            // Only immutable strings and value tokens cross the actor boundary.
            let parseTask = Task.detached(priority: .utility) {
                SyntaxScanner.tokens(in: snapshot, language: language)
            }
            let tokens = await withTaskCancellationHandler {
                await parseTask.value
            } onCancel: {
                parseTask.cancel()
            }

            guard !Task.isCancelled,
                  let self, let textView,
                  self.revision == requestedRevision,
                  !textView.hasMarkedText(),
                  textView.string == snapshot else { return }
            self.apply(tokens, to: textView)
        }
    }

    func cancel() {
        revision &+= 1
        pendingTask?.cancel()
        pendingTask = nil
    }

    private nonisolated static func exceedsHighlightingLimits(_ text: String) -> Bool {
        var bytes = 0
        var lines = 1
        var previousWasCR = false
        // One bounded pass checks both budgets. CRLF counts as one line break.
        for byte in text.utf8 {
            bytes += 1
            if bytes > maximumUTF8Bytes { return true }
            if byte == 13 || (byte == 10 && !previousWasCR) {
                lines += 1
                if lines > maximumLineCount { return true }
            }
            previousWasCR = byte == 13
        }
        return false
    }

    private func clearColors(in textView: NSTextView) {
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.textColor,
                             range: NSRange(location: 0, length: storage.length))
        textView.typingAttributes[.foregroundColor] = NSColor.textColor
    }

    private func apply(_ tokens: [SyntaxToken], to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        // Attribute-only edits do not call didChangeText or register undo actions.
        // Keep all other attributes, selected ranges and marked text unchanged.
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.textColor,
                             range: NSRange(location: 0, length: storage.length))
        for token in tokens {
            storage.addAttribute(.foregroundColor, value: token.kind.color,
                                 range: NSRange(location: token.start, length: token.length))
        }
        storage.endEditing()
        textView.typingAttributes[.foregroundColor] = NSColor.textColor
    }
}

private enum SyntaxLanguage: Sendable {
    case json, jsonWithComments, python, java, javascript, typescript, shell

    static func forFile(_ url: URL?) -> Self? {
        guard let url else { return nil }
        switch url.pathExtension.lowercased() {
        case "json": return .json
        case "jsonc": return .jsonWithComments
        case "py", "pyw": return .python
        case "java": return .java
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "sh", "bash", "zsh", "ksh": return .shell
        default:
            if [".bashrc", ".zshrc", ".bash_profile", ".zprofile", ".profile"].contains(url.lastPathComponent) {
                return .shell
            }
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .json: return "JSON"
        case .jsonWithComments: return "JSONC"
        case .python: return "Python"
        case .java: return "Java"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .shell: return "Shell"
        }
    }

    var isJSON: Bool { self == .json || self == .jsonWithComments }
    var hasSlashComments: Bool {
        self == .jsonWithComments || self == .java || self == .javascript || self == .typescript
    }

    var keywords: Set<String> {
        switch self {
        case .json, .jsonWithComments: return KeywordSets.json
        case .python: return KeywordSets.python
        case .java: return KeywordSets.java
        case .javascript: return KeywordSets.javascript
        case .typescript: return KeywordSets.typescript
        case .shell: return KeywordSets.shell
        }
    }
}

private enum KeywordSets {
    static let json: Set<String> = ["true", "false", "null"]
    static let python = Set("False None True and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield".split(separator: " ").map(String.init))
    static let java = Set("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public record return sealed short static strictfp super switch synchronized this throw throws transient try var void volatile while true false null".split(separator: " ").map(String.init))
    static let javascript = Set("as async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield".split(separator: " ").map(String.init))
    static let typescript = javascript.union("abstract any asserts bigint boolean declare enum implements infer interface is keyof module namespace never number object override private protected public readonly require satisfies string symbol type unique unknown".split(separator: " ").map(String.init))
    static let shell = Set("if then else elif fi case esac for select while until do done in function time coproc break continue return export local readonly declare typeset unset shift source".split(separator: " ").map(String.init))
}

private struct SyntaxToken: Sendable {
    let start: Int
    let length: Int
    let kind: Kind

    enum Kind: Sendable {
        case string, key, comment, keyword, number, variable

        @MainActor var color: NSColor {
            switch self {
            case .string: return .systemGreen
            case .key: return .systemTeal
            case .comment: return .secondaryLabelColor
            case .keyword: return .systemPurple
            case .number: return .systemBlue
            case .variable: return .systemOrange
            }
        }
    }
}

/// A bounded, linear scanner rather than a regular-expression grammar.
/// Tokens use UTF-16 offsets to match NSTextStorage, including emoji/surrogates.
private enum SyntaxScanner {
    static func tokens(in text: String, language: SyntaxLanguage) -> [SyntaxToken] {
        let units = Array(text.utf16)
        let count = units.count
        let keywords = language.keywords
        var result: [SyntaxToken] = []
        var index = 0

        func emit(_ start: Int, _ end: Int, _ kind: SyntaxToken.Kind) {
            result.append(SyntaxToken(start: start, length: end - start, kind: kind))
        }

        while index < count {
            if index & 1023 == 0, Task.isCancelled { return [] }
            let start = index
            let unit = units[index]

            // Comments and quoted strings consume their complete spans before
            // considering any keywords/numbers contained inside them.
            if language.hasSlashComments, unit == 47, index + 1 < count {
                if units[index + 1] == 47 {
                    index += 2
                    while index < count && !isNewline(units[index]) { index += 1 }
                    emit(start, index, .comment)
                    continue
                }
                if units[index + 1] == 42 {
                    index += 2
                    while index < count {
                        if units[index] == 42, index + 1 < count, units[index + 1] == 47 {
                            index += 2
                            break
                        }
                        index += 1
                    }
                    emit(start, index, .comment)
                    continue
                }
            }

            let isHashComment = unit == 35 && (language == .python ||
                (language == .shell && (index == 0 || isShellBoundary(units[index - 1]))))
            if isHashComment {
                while index < count && !isNewline(units[index]) { index += 1 }
                emit(start, index, .comment)
                continue
            }

            let isBacktick = unit == 96 && (language == .javascript || language == .typescript || language == .shell)
            let isQuote = unit == 34 || (unit == 39 && !language.isJSON) || isBacktick
            if isQuote {
                let triple = (language == .python || (language == .java && unit == 34)) &&
                    index + 2 < count && units[index + 1] == unit && units[index + 2] == unit
                let quoteWidth = triple ? 3 : 1
                index += quoteWidth
                while index < count {
                    if !triple && !isBacktick && language != .shell && isNewline(units[index]) { break }
                    if units[index] == 92 && !(language == .shell && unit == 39) {
                        index = min(index + 2, count)
                        continue
                    }
                    if units[index] == unit {
                        if !triple {
                            index += 1
                            break
                        }
                        if index + 2 < count && units[index + 1] == unit && units[index + 2] == unit {
                            index += 3
                            break
                        }
                    }
                    index += 1
                }
                var kind = SyntaxToken.Kind.string
                if language.isJSON {
                    var following = index
                    while following < count && isWhitespace(units[following]) { following += 1 }
                    if following < count && units[following] == 58 { kind = .key }
                }
                emit(start, index, kind)
                continue
            }

            if language == .shell && unit == 36 {
                index += 1
                if index < count && units[index] == 123 {
                    index += 1
                    while index < count && units[index] != 125 && !isNewline(units[index]) { index += 1 }
                    if index < count && units[index] == 125 { index += 1 }
                } else {
                    while index < count && isNameContinuation(units[index]) { index += 1 }
                    if index == start + 1, index < count, [UInt16(63), 35, 64, 42, 36, 33, 45].contains(units[index]) {
                        index += 1
                    }
                }
                if index > start + 1 { emit(start, index, .variable) }
                continue
            }

            let negativeNumber = unit == 45 && index + 1 < count && isDigit(units[index + 1])
            if isDigit(unit) || negativeNumber {
                index = numberEnd(in: units, from: index, allowRadix: !language.isJSON)
                emit(start, index, .number)
                continue
            }

            if isNameStart(unit) {
                index += 1
                while index < count && isNameContinuation(units[index]) { index += 1 }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                if keywords.contains(word) { emit(start, index, .keyword) }
                continue
            }
            index += 1
        }
        return result
    }

    private static func numberEnd(in units: [UInt16], from start: Int, allowRadix: Bool) -> Int {
        var index = start
        let count = units.count
        if units[index] == 45 { index += 1 }
        if allowRadix, index + 1 < count, units[index] == 48 {
            let radixMarker = units[index + 1] | 32
            if radixMarker == 120 || radixMarker == 98 || radixMarker == 111 {
                index += 2
                while index < count {
                    let character = units[index]
                    let isValid: Bool
                    if radixMarker == 120 {
                        let lower = character | 32
                        isValid = isDigit(character) || (97...102).contains(lower)
                    } else if radixMarker == 98 {
                        isValid = character == 48 || character == 49
                    } else {
                        isValid = (48...55).contains(character)
                    }
                    guard isValid || character == 95 else { break }
                    index += 1
                }
                return index
            }
        }
        while index < count && (isDigit(units[index]) || (allowRadix && units[index] == 95)) { index += 1 }
        if index < count && units[index] == 46 {
            index += 1
            while index < count && (isDigit(units[index]) || (allowRadix && units[index] == 95)) { index += 1 }
        }
        if index < count && (units[index] == 69 || units[index] == 101) {
            var exponentEnd = index + 1
            if exponentEnd < count && (units[exponentEnd] == 43 || units[exponentEnd] == 45) { exponentEnd += 1 }
            let digitsStart = exponentEnd
            while exponentEnd < count && isDigit(units[exponentEnd]) { exponentEnd += 1 }
            if exponentEnd > digitsStart { index = exponentEnd }
        }
        return index
    }

    private static func isDigit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }
    private static func isNameStart(_ unit: UInt16) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit == 36 || unit >= 128
    }
    private static func isNameContinuation(_ unit: UInt16) -> Bool { isNameStart(unit) || isDigit(unit) }
    private static func isNewline(_ unit: UInt16) -> Bool { unit == 10 || unit == 13 }
    private static func isWhitespace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 || isNewline(unit) }
    private static func isShellBoundary(_ unit: UInt16) -> Bool {
        isWhitespace(unit) || unit == 59 || unit == 124 || unit == 38 || unit == 40
    }
}
