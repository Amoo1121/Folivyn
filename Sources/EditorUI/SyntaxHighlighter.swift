import AppKit
import Foundation

/// A small, offline syntax highlighter.
/// It changes presentation attributes only; document text and undo are untouched.
@MainActor
public final class SyntaxHighlighter {
    public init() {}
    public nonisolated static let maximumUTF8Bytes = 200 * 1024
    public nonisolated static let maximumLineCount = 20_000
    public nonisolated static var highlightingLimitDescription: String {
        L10n.format(.highlightingLimit, maximumUTF8Bytes / 1024, maximumLineCount)
    }

    private var pendingTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    /// Shared with the status bar so it describes the same limit decision as coloring.
    public private(set) var isLimited = false

    public nonisolated static func languageName(for fileURL: URL?, override languageOverride: SyntaxLanguage? = nil) -> String {
        (languageOverride ?? SyntaxLanguage.forFile(fileURL) ?? .plainText).displayName
    }

    /// Safe to call for every text change and after opening/reloading a document.
    /// A short debounce keeps typing responsive; stale parses are never applied.
    /// A nil override retains filename detection. Explicit plainText disables
    /// colors without changing the document, filename or scanner budgets.
    public func highlight(textView: NSTextView, fileURL: URL?, override languageOverride: SyntaxLanguage? = nil) {
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
        let language = languageOverride ?? SyntaxLanguage.forFile(fileURL) ?? .plainText
        guard !isLimited, language != .plainText else {
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
                  textView.string.utf16.elementsEqual(snapshot.utf16) else { return }
            self.apply(tokens, to: textView)
        }
    }

    public func cancel() {
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

/// The bundled basic scanners. Raw values are stable per-document choices;
/// automatic detection is represented by a nil override, not another scanner.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case plainText, json, jsonWithComments, python, java, javascript, typescript, shell
    case swift, c, cpp, go, rust

    public static func forFile(_ url: URL?) -> Self? {
        guard let url else { return nil }
        // Uppercase .C conventionally denotes C++; do not erase that distinction.
        if url.pathExtension == "C" { return .cpp }
        switch url.pathExtension.lowercased() {
        case "json": return .json
        case "jsonc": return .jsonWithComments
        case "py", "pyw": return .python
        case "java": return .java
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "sh", "bash", "zsh", "ksh": return .shell
        case "swift": return .swift
        case "c", "h": return .c
        case "cc", "cpp", "cxx", "c++", "hh", "hpp", "hxx", "h++", "ipp", "tpp": return .cpp
        case "go": return .go
        case "rs": return .rust
        default:
            if [".bashrc", ".zshrc", ".bash_profile", ".zprofile", ".profile"].contains(url.lastPathComponent) {
                return .shell
            }
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .plainText: return L10n.text(.plainText)
        case .json: return "JSON"
        case .jsonWithComments: return "JSONC"
        case .python: return "Python"
        case .java: return "Java"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .shell: return "Shell"
        case .swift: return "Swift"
        case .c: return "C"
        case .cpp: return "C++"
        case .go: return "Go"
        case .rust: return "Rust"
        }
    }

    var isJSON: Bool { self == .json || self == .jsonWithComments }
    var hasSlashComments: Bool {
        switch self {
        case .jsonWithComments, .java, .javascript, .typescript, .swift, .c, .cpp, .go, .rust: return true
        default: return false
        }
    }

    var keywords: Set<String> {
        switch self {
        case .plainText: return []
        case .json, .jsonWithComments: return KeywordSets.json
        case .python: return KeywordSets.python
        case .java: return KeywordSets.java
        case .javascript: return KeywordSets.javascript
        case .typescript: return KeywordSets.typescript
        case .shell: return KeywordSets.shell
        case .swift: return KeywordSets.swift
        case .c: return KeywordSets.c
        case .cpp: return KeywordSets.cpp
        case .go: return KeywordSets.go
        case .rust: return KeywordSets.rust
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
    static let swift = Set("actor any as associatedtype async await borrowing break case catch class consume consuming continue convenience copy default defer deinit didSet distributed do dynamic each else enum extension fallthrough false fileprivate final for func get guard if import in indirect infix init inout internal is isolated lazy let macro mutating nil nonisolated nonmutating open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return self Self set some static struct subscript super switch throws throw true try typealias unowned var weak where while willSet".split(separator: " ").map(String.init))
    static let c = Set("alignas alignof auto bool break case char const constexpr continue default do double else enum extern false float for goto if inline int long nullptr register restrict return short signed sizeof static static_assert struct switch thread_local true typedef typeof typeof_unqual union unsigned void volatile while _Alignas _Alignof _Atomic _BitInt _Bool _Complex _Generic _Imaginary _Noreturn _Static_assert _Thread_local".split(separator: " ").map(String.init))
    static let cpp = c.union("and and_eq asm bitand bitor catch char8_t char16_t char32_t class co_await co_return co_yield compl concept consteval constinit const_cast decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not not_eq operator or or_eq private protected public reinterpret_cast requires static_cast template this throw try typeid typename using virtual wchar_t xor xor_eq".split(separator: " ").map(String.init))
    static let go = Set("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil".split(separator: " ").map(String.init))
    static let rust = Set("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type union unsafe use where while abstract become box do final gen macro override priv try typeof unsized virtual yield".split(separator: " ").map(String.init))
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
                    var depth = 1
                    while index < count {
                        if index & 1023 == 0, Task.isCancelled { return [] }
                        if (language == .swift || language == .rust), units[index] == 47,
                           index + 1 < count, units[index + 1] == 42 {
                            depth += 1
                            index += 2
                            continue
                        }
                        if units[index] == 42, index + 1 < count, units[index + 1] == 47 {
                            index += 2
                            depth -= 1
                            if depth == 0 { break }
                            continue
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

            // Language-specific delimiters must be consumed before identifiers
            // and the ordinary quote path. These are coloring spans only: no
            // interpolation evaluation, preprocessing or semantic validation.
            if language == .swift, unit == 96 {
                index += 1
                while index < count && units[index] != 96 && !isNewline(units[index]) { index += 1 }
                if index < count && units[index] == 96 { index += 1 }
                continue
            }
            if language == .swift, unit == 35 || unit == 34 {
                var quote = index
                while quote < count && units[quote] == 35 { quote += 1 }
                if quote < count && units[quote] == 34 {
                    let hashes = quote - start
                    let width = quote + 2 < count && units[quote + 1] == 34 && units[quote + 2] == 34 ? 3 : 1
                    index = quotedEnd(units, from: quote, width: width, hashes: hashes,
                                      multiline: width == 3, escapeHashes: hashes)
                    emit(start, index, .string)
                } else {
                    // Skip an unmatched run once, rather than rescanning its
                    // suffix at each '#'. This keeps malformed input linear.
                    index = quote
                }
                continue
            }

            if language == .cpp, let end = cppRawEnd(units, from: index) {
                index = end
                emit(start, index, .string)
                continue
            }
            if language == .rust {
                if let end = rustRawEnd(units, from: index) {
                    index = end
                    emit(start, index, .string)
                    continue
                }
                if unit == 114, index + 2 < count, units[index + 1] == 35, isNameStart(units[index + 2]) {
                    // r#type is an identifier, not a keyword or raw string.
                    index += 3
                    while index < count && isNameContinuation(units[index]) { index += 1 }
                    continue
                }
                if unit == 39 {
                    if let end = rustCharacterEnd(units, from: index) {
                        index = end
                        emit(start, index, .string)
                    } else {
                        // A lifetime or label is not an unterminated character
                        // literal. Never swallow the rest of the source line.
                        index += 1
                        while index < count && isNameContinuation(units[index]) { index += 1 }
                    }
                    continue
                }
            }

            // Include encoding prefixes in the same color span as their literal.
            if let quote = prefixedQuote(units, from: index, language: language) {
                index = quotedEnd(units, from: quote, multiline: language == .rust && units[quote] == 34,
                                  joinsCRLF: language == .c || language == .cpp)
                emit(start, index, .string)
                continue
            }

            let isBacktick = unit == 96 && (language == .javascript || language == .typescript || language == .shell || language == .go)
            let isQuote = unit == 34 || (unit == 39 && !language.isJSON && language != .swift) || isBacktick
            if isQuote {
                let triple = (language == .python || (language == .java && unit == 34)) &&
                    index + 2 < count && units[index + 1] == unit && units[index + 2] == unit
                let noEscapes = (language == .shell && unit == 39) || (language == .go && isBacktick)
                index = quotedEnd(units, from: index, width: triple ? 3 : 1,
                                  multiline: triple || isBacktick || language == .shell || (language == .rust && unit == 34),
                                  escapeHashes: noEscapes ? nil : 0,
                                  joinsCRLF: [.c, .cpp, .python, .javascript, .typescript].contains(language))
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
                index = numberEnd(in: units, from: index, allowRadix: !language.isJSON, apostrophe: language == .cpp || language == .c)
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

    /// Each failed delimiter probe advances by the inspected prefix. In
    /// particular, long hash delimiters cannot cause quadratic rescanning.
    private static func quotedEnd(_ units: [UInt16], from quote: Int, width: Int = 1,
                                  hashes: Int = 0, multiline: Bool = false, escapeHashes: Int? = 0,
                                  joinsCRLF: Bool = false) -> Int {
        let count = units.count, delimiter = units[quote]
        var index = quote + width
        while index < count {
            if Task.isCancelled { return count }
            if !multiline && isNewline(units[index]) { return index }
            if units[index] == 92, let escapeHashes {
                var next = index + 1
                let limit = min(count, next + escapeHashes)
                while next < limit && units[next] == 35 { next += 1 }
                if next == limit, next - index - 1 == escapeHashes {
                    if joinsCRLF, next + 1 < count, units[next] == 13, units[next + 1] == 10 {
                        index = next + 2
                    } else { index = min(next + 1, count) }
                    continue
                }
                index = next
                continue
            }
            if units[index] == delimiter {
                var next = index + 1
                while next < count && next < index + width && units[next] == delimiter { next += 1 }
                if next - index == width {
                    let afterQuote = next
                    while next < count && next - afterQuote < hashes && units[next] == 35 { next += 1 }
                    if next - afterQuote == hashes { return next }
                    index = next
                    continue
                }
                index = next
                continue
            }
            index += 1
        }
        return count
    }

    private static func prefixedQuote(_ units: [UInt16], from start: Int, language: SyntaxLanguage) -> Int? {
        let first = units[start]
        var quote = start + 1
        if language == .c || language == .cpp {
            guard first == 76 || first == 85 || first == 117 else { return nil }
            if first == 117, quote < units.count, units[quote] == 56 { quote += 1 }
        } else if language == .rust {
            guard first == 98 || first == 99 else { return nil }
        } else { return nil }
        guard quote < units.count, units[quote] == 34 || units[quote] == 39 else { return nil }
        if language == .rust, units[quote] == 39 {
            guard first == 98, rustCharacterEnd(units, from: quote) != nil else { return nil }
        }
        return quote
    }

    private static func rustRawEnd(_ units: [UInt16], from start: Int) -> Int? {
        var index = start
        if units[index] == 98 || units[index] == 99 { index += 1 }
        guard index < units.count, units[index] == 114 else { return nil }
        index += 1
        let hashStart = index
        while index < units.count && units[index] == 35 && index - hashStart <= 255 { index += 1 }
        let hashes = index - hashStart
        guard hashes <= 255, index < units.count, units[index] == 34 else { return nil }
        return quotedEnd(units, from: index, hashes: hashes, multiline: true, escapeHashes: nil)
    }

    private static func rustCharacterEnd(_ units: [UInt16], from quote: Int) -> Int? {
        var index = quote + 1
        guard index < units.count, !isNewline(units[index]), units[index] != 39 else { return nil }
        if units[index] == 92 {
            index += 1
            guard index < units.count else { return nil }
            if units[index] == 117, index + 1 < units.count, units[index + 1] == 123 {
                index += 2
                while index < units.count && (isHex(units[index]) || units[index] == 95) { index += 1 }
                guard index < units.count, units[index] == 125 else { return nil }
                index += 1
            } else if units[index] == 120 {
                guard index + 2 < units.count, isHex(units[index + 1]), isHex(units[index + 2]) else { return nil }
                index += 3
            } else {
                guard [UInt16(48), 110, 114, 116, 92, 39, 34].contains(units[index]) else { return nil }
                index += 1
            }
        } else if (0xD800...0xDBFF).contains(units[index]) {
            guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else { return nil }
            index += 2
        } else { index += 1 }
        guard index < units.count, units[index] == 39 else { return nil }
        return index + 1
    }

    private static func cppRawEnd(_ units: [UInt16], from start: Int) -> Int? {
        var index = start
        if units[index] == 76 || units[index] == 85 || units[index] == 117 {
            let utf8 = units[index] == 117 && index + 1 < units.count && units[index + 1] == 56
            index += utf8 ? 2 : 1
        }
        guard index + 1 < units.count, units[index] == 82, units[index + 1] == 34 else { return nil }
        index += 2
        let delimiterStart = index
        while index < units.count && units[index] != 40 {
            let unit = units[index]
            guard index - delimiterStart < 16, (33...126).contains(unit), unit != 41, unit != 92 else { return nil }
            index += 1
        }
        guard index < units.count else { return nil }
        let delimiter = units[delimiterStart..<index]
        index += 1
        while index < units.count {
            if index & 1023 == 0, Task.isCancelled { return units.count }
            if units[index] == 41 {
                let closingQuote = index + 1 + delimiter.count
                if closingQuote < units.count, units[closingQuote] == 34,
                   units[(index + 1)..<closingQuote].elementsEqual(delimiter) { return closingQuote + 1 }
            }
            index += 1
        }
        return units.count
    }

    private static func numberEnd(in units: [UInt16], from start: Int, allowRadix: Bool, apostrophe: Bool) -> Int {
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
                    guard isValid || character == 95 || (apostrophe && character == 39 && index + 1 < count && isHex(units[index + 1])) else { break }
                    index += 1
                }
                if radixMarker == 120 {
                    if index < count, units[index] == 46 {
                        index += 1
                        while index < count && (isHex(units[index]) || units[index] == 95 ||
                            (apostrophe && units[index] == 39 && index + 1 < count && isHex(units[index + 1]))) { index += 1 }
                    }
                    if index < count, units[index] == 112 || units[index] == 80 {
                        index = exponentEnd(in: units, from: index, apostrophe: apostrophe)
                    }
                }
                return index
            }
        }
        func digitOrSeparator(at position: Int) -> Bool {
            let unit = units[position]
            return isDigit(unit) || (allowRadix && unit == 95) ||
                (apostrophe && unit == 39 && position + 1 < count && isDigit(units[position + 1]))
        }
        while index < count && digitOrSeparator(at: index) { index += 1 }
        if index < count && units[index] == 46 {
            index += 1
            while index < count && digitOrSeparator(at: index) { index += 1 }
        }
        if index < count && (units[index] == 69 || units[index] == 101) {
            index = exponentEnd(in: units, from: index, apostrophe: apostrophe)
        }
        return index
    }

    private static func exponentEnd(in units: [UInt16], from marker: Int, apostrophe: Bool) -> Int {
        var index = marker + 1
        if index < units.count, units[index] == 43 || units[index] == 45 { index += 1 }
        guard index < units.count, isDigit(units[index]) else { return marker }
        index += 1
        while index < units.count {
            if isDigit(units[index]) { index += 1; continue }
            if apostrophe, units[index] == 39, index + 1 < units.count, isDigit(units[index + 1]) {
                index += 2
                continue
            }
            break
        }
        return index
    }

    private static func isDigit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }
    private static func isHex(_ unit: UInt16) -> Bool { isDigit(unit) || (97...102).contains(unit | 32) }
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
