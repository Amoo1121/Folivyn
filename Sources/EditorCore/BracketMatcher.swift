import Foundation

public struct BracketPair: Equatable, Sendable {
    public let opening: NSRange
    public let closing: NSRange
}

/// Read-only delimiter assistance, not a language parser or syntax diagnostic.
/// Every returned range uses the original source's UTF-16 coordinates.
public enum BracketMatcher {
    public enum Policy: Sendable {
        /// All brackets are literal, including those inside quotes and comments.
        case literal
        /// Double-quoted strings and JSON escapes are opaque; no comments exist.
        case json
        /// Common quoted spans and #, //, /* */ comments are opaque. This mode
        /// deliberately declines ambiguous /, prefixed strings, interpolation,
        /// heredocs, Unicode escapes, continued comments and nested comments.
        /// This is a conservative generic aid, not exact language tokenization.
        case conservativeCode
    }

    public struct Limits: Sendable {
        public let maximumUTF16Units: Int
        public let maximumDepth: Int
        public init(maximumUTF16Units: Int = 200 * 1_024, maximumDepth: Int = 512) {
            self.maximumUTF16Units = maximumUTF16Units
            self.maximumDepth = maximumDepth
        }
    }

    /// Chooses the bracket at the caret, otherwise the bracket immediately before
    /// it. Returns nil for non-brackets, ignored spans and unmatched/misnested
    /// delimiters. An unsupported lexical construct or budget failure is explicit.
    /// Callers should run this off the main actor and check their source revision
    /// again before displaying the result. The matcher never modifies text.
    public static func match(
        in source: String, atUTF16Offset caret: Int, policy: Policy = .literal,
        limits: Limits = Limits(),
        isCancelled: @Sendable () -> Bool = { Task<Never, Never>.isCancelled }
    ) throws -> BracketPair? {
        guard (0...(200 * 1_024)).contains(limits.maximumUTF16Units),
              (1...512).contains(limits.maximumDepth) else { throw BracketMatchError.invalidLimits }
        if isCancelled() { throw CancellationError() }
        guard caret >= 0, caret <= limits.maximumUTF16Units else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(min(4_096, limits.maximumUTF16Units))
        for unit in source.utf16 {
            if units.count.isMultiple(of: 1_024), isCancelled() { throw CancellationError() }
            guard units.count < limits.maximumUTF16Units else {
                throw BracketMatchError.inputTooLarge(limit: limits.maximumUTF16Units)
            }
            units.append(unit)
        }
        if isCancelled() { throw CancellationError() }
        guard caret <= units.count else { return nil }
        let target: Int
        if caret < units.count, isBracket(units[caret]) { target = caret }
        else if caret > 0, isBracket(units[caret - 1]) { target = caret - 1 }
        else { return nil }

        var stack: [(unit: UInt16, offset: Int)] = []
        var position = 0
        var nextCancellationCheck = 0
        func checkpoint(_ offset: Int) throws {
            if offset >= nextCancellationCheck {
                if isCancelled() { throw CancellationError() }
                nextCancellationCheck = offset + 1_024
            }
        }
        func unsupported(_ offset: Int) -> BracketMatchError { .unsupportedSyntax(utf16Location: offset) }

        while position < units.count {
            try checkpoint(position)
            let unit = units[position]
            if policy == .conservativeCode {
                if unit == 92 || (unit == 60 && position + 1 < units.count && units[position + 1] == 60) {
                    throw unsupported(position)
                }
                if unit == 35 || (unit == 47 && position + 1 < units.count && units[position + 1] == 47) {
                    let start = position
                    while position < units.count, !isNewline(units[position]) {
                        try checkpoint(position)
                        // C-family line continuation and Unicode processing can
                        // change where a comment ends. Generic rules cannot
                        // safely expose the next line's brackets in that case.
                        if units[position] == 92 { throw unsupported(position) }
                        position += 1
                    }
                    if target >= start, target < position { return nil }
                    continue
                }
                if unit == 47 {
                    guard position + 1 < units.count, units[position + 1] == 42 else { throw unsupported(position) }
                    let start = position
                    position += 2
                    var closed = false
                    while position < units.count {
                        try checkpoint(position)
                        if units[position] == 47, position + 1 < units.count, units[position + 1] == 42 {
                            throw unsupported(position)
                        }
                        if units[position] == 92, position + 1 < units.count,
                           units[position + 1] == 117 || units[position + 1] == 85 { throw unsupported(position) }
                        if units[position] == 42, position + 1 < units.count, units[position + 1] == 47 {
                            position += 2
                            closed = true
                            break
                        }
                        position += 1
                    }
                    if !closed || (target >= start && target < position) { return nil }
                    continue
                }
            }

            let quoted = policy == .json ? unit == 34
                : policy == .conservativeCode && (unit == 34 || unit == 39 || unit == 96)
            if quoted {
                let start = position
                // Raw, byte and interpolated prefixes have language-specific
                // escape/quote rules. Refuse adjacent identifier/$/@ prefixes
                // rather than exposing a nested string's brackets as code.
                if policy == .conservativeCode, position > 0,
                   isStringPrefix(units[position - 1]) { throw unsupported(position - 1) }
                let triple = policy == .conservativeCode && unit != 96 && position + 2 < units.count &&
                    units[position + 1] == unit && units[position + 2] == unit
                let width = triple ? 3 : 1
                position += width
                var closed = false
                while position < units.count {
                    try checkpoint(position)
                    if policy == .conservativeCode {
                        // Templates, shell expansions and Swift interpolation
                        // may themselves contain quotes or nested templates.
                        // Keeping only the first quoted span opaque is unsafe.
                        if units[position] == 36, position + 1 < units.count,
                           units[position + 1] == 123 || units[position + 1] == 40 { throw unsupported(position) }
                        if units[position] == 96, unit != 96 { throw unsupported(position) }
                    }
                    if units[position] == 92 {
                        guard position + 1 < units.count else { break }
                        let escaped = units[position + 1]
                        if policy == .conservativeCode {
                            // Single-quote escape rules differ between languages
                            // (notably shell). Refuse the ambiguous case.
                            if unit == 39 || escaped == 117 || escaped == 85 || escaped == 40 { throw unsupported(position) }
                            position += 2
                        } else if escaped == 117 {
                            guard position + 5 < units.count,
                                  units[(position + 2)...(position + 5)].allSatisfy(isHexDigit) else { throw unsupported(position) }
                            position += 6
                        } else {
                            guard [UInt16(34), 92, 47, 98, 102, 110, 114, 116].contains(escaped) else { throw unsupported(position) }
                            position += 2
                        }
                        continue
                    }
                    if units[position] == unit,
                       !triple || (position + 2 < units.count && units[position + 1] == unit && units[position + 2] == unit) {
                        position += width
                        closed = true
                        break
                    }
                    if policy == .json, units[position] < 32 { throw unsupported(position) }
                    position += 1
                }
                if !closed || (target >= start && target < position) { return nil }
                continue
            }

            if let closing = closingBracket(for: unit) {
                guard stack.count < limits.maximumDepth else { throw BracketMatchError.nestingTooDeep(limit: limits.maximumDepth) }
                stack.append((closing, position))
            } else if isClosingBracket(unit) {
                guard let last = stack.last, last.unit == unit else {
                    if position == target || stack.contains(where: { $0.offset == target }) { return nil }
                    stack.removeAll(keepingCapacity: true)
                    position += 1
                    continue
                }
                stack.removeLast()
                if last.offset == target || position == target {
                    if isCancelled() { throw CancellationError() }
                    return BracketPair(opening: NSRange(location: last.offset, length: 1),
                                       closing: NSRange(location: position, length: 1))
                }
            }
            position += 1
        }
        if isCancelled() { throw CancellationError() }
        return nil
    }

    private static func closingBracket(for unit: UInt16) -> UInt16? {
        switch unit { case 40: return 41; case 91: return 93; case 123: return 125; default: return nil }
    }
    private static func isClosingBracket(_ unit: UInt16) -> Bool { unit == 41 || unit == 93 || unit == 125 }
    private static func isBracket(_ unit: UInt16) -> Bool { closingBracket(for: unit) != nil || isClosingBracket(unit) }
    private static func isHexDigit(_ unit: UInt16) -> Bool {
        (48...57).contains(unit) || (65...70).contains(unit) || (97...102).contains(unit)
    }
    private static func isStringPrefix(_ unit: UInt16) -> Bool {
        (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) ||
            unit == 95 || unit == 36 || unit == 64
    }
    private static func isNewline(_ unit: UInt16) -> Bool { [10, 13, 0x85, 0x2028, 0x2029].contains(unit) }
}

public enum BracketMatchError: Error, Equatable, Sendable {
    case invalidLimits
    case inputTooLarge(limit: Int)
    case nestingTooDeep(limit: Int)
    case unsupportedSyntax(utf16Location: Int)
}
