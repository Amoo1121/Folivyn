import Foundation

/// An immutable index of logical lines in one source revision. Offsets use UTF-16
/// to match NSTextView; line endings are indexed without changing the source.
public struct TextLineIndex: Sendable {
    public enum NewlineStyle: String, Sendable {
        case none, lf = "LF", crlf = "CRLF", cr = "CR", nel = "NEL"
        case lineSeparator = "LS", paragraphSeparator = "PS", mixed
    }

    public struct Limits: Sendable {
        public let maximumUTF16Units: Int
        public let maximumLines: Int

        /// Budgets may be lowered, but not raised beyond these hard ceilings.
        public init(maximumUTF16Units: Int = 10 * 1_024 * 1_024, maximumLines: Int = 1_000_000) {
            self.maximumUTF16Units = maximumUTF16Units
            self.maximumLines = maximumLines
        }
    }

    public let utf16Count: Int
    public let newlineStyle: NewlineStyle
    public var lineCount: Int { starts.count }
    private let starts: [Int]
    private let endingLengths: [UInt8]

    public static func build(
        _ source: String, limits: Limits = Limits(),
        isCancelled: @Sendable () -> Bool = { Task<Never, Never>.isCancelled }
    ) throws -> TextLineIndex {
        guard (0...(10 * 1_024 * 1_024)).contains(limits.maximumUTF16Units),
              (1...1_000_000).contains(limits.maximumLines) else { throw TextLineIndexError.invalidLimits }
        if isCancelled() { throw CancellationError() }
        var starts = [0]
        var endings: [UInt8] = []
        var offset = 0
        var pendingCR = false
        var newlineKinds: UInt8 = 0

        func appendLine(at nextStart: Int, endingLength: UInt8, kind: UInt8) throws {
            guard starts.count < limits.maximumLines else {
                throw TextLineIndexError.lineLimitExceeded(limit: limits.maximumLines)
            }
            starts.append(nextStart)
            endings.append(endingLength)
            newlineKinds |= kind
        }

        // Stream the view instead of allocating a second full UTF-16 buffer.
        // Delaying CR by one code unit keeps CRLF a single logical separator.
        for unit in source.utf16 {
            if offset.isMultiple(of: 4_096), isCancelled() { throw CancellationError() }
            guard offset < limits.maximumUTF16Units else {
                throw TextLineIndexError.sourceLimitExceeded(limit: limits.maximumUTF16Units)
            }
            offset += 1
            if pendingCR {
                pendingCR = false
                if unit == 0x0A {
                    try appendLine(at: offset, endingLength: 2, kind: 2)
                    continue
                }
                try appendLine(at: offset - 1, endingLength: 1, kind: 4)
            }
            switch unit {
            case 0x0D: pendingCR = true
            case 0x0A: try appendLine(at: offset, endingLength: 1, kind: 1)
            case 0x85: try appendLine(at: offset, endingLength: 1, kind: 8)
            case 0x2028: try appendLine(at: offset, endingLength: 1, kind: 16)
            case 0x2029: try appendLine(at: offset, endingLength: 1, kind: 32)
            default: break
            }
        }
        if pendingCR { try appendLine(at: offset, endingLength: 1, kind: 4) }
        if isCancelled() { throw CancellationError() }
        let style: NewlineStyle
        switch newlineKinds {
        case 0: style = .none
        case 1: style = .lf
        case 2: style = .crlf
        case 4: style = .cr
        case 8: style = .nel
        case 16: style = .lineSeparator
        case 32: style = .paragraphSeparator
        default: style = .mixed
        }
        return TextLineIndex(utf16Count: offset, newlineStyle: style, starts: starts, endingLengths: endings)
    }

    /// Includes EOF. At an ending's code units, returns the preceding line; at
    /// EOF after an ending, returns the final empty line. Invalid offsets fail.
    public func lineNumber(atUTF16Offset offset: Int) -> Int? {
        guard offset >= 0, offset <= utf16Count else { return nil }
        var lower = 0, upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    /// One-based line lookup; excluding the ending preserves empty-line ranges.
    public func range(forLine line: Int, includingLineEnding: Bool = false) -> NSRange? {
        guard line > 0, line <= starts.count else { return nil }
        let index = line - 1
        let start = starts[index]
        let end = line < starts.count ? starts[line] : utf16Count
        let endingLength = !includingLineEnding && index < endingLengths.count ? Int(endingLengths[index]) : 0
        return NSRange(location: start, length: end - start - endingLength)
    }

    /// A zero-length caret range for Go to Line. Clamping is explicit so callers
    /// can distinguish invalid user input from an intentional nearest-line jump.
    public func insertionRange(forLine line: Int, clamping: Bool = false) -> NSRange? {
        let chosen = clamping ? min(max(1, line), starts.count) : line
        guard let range = range(forLine: chosen) else { return nil }
        return NSRange(location: range.location, length: 0)
    }
}

public enum TextLineIndexError: Error, Equatable, Sendable {
    case invalidLimits
    case sourceLimitExceeded(limit: Int)
    case lineLimitExceeded(limit: Int)
}
