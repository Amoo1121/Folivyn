import Foundation

/// Plans small, literal line-prefix edits. The caller owns the source revision,
/// validates expectedSource, and applies the returned edit as one undoable action.
/// No operation parses a language or normalizes text, Unicode, or line endings.
public enum TextEditingOperations {
    public enum Operation: Sendable {
        /// One tab or one to sixteen ASCII spaces, supplied by the caller.
        case indent(unit: String)
        /// Removes one leading tab, or up to this many leading ASCII spaces.
        case unindent(spaceWidth: Int)
        /// A language's explicit line-comment marker, without surrounding spaces.
        /// Nonblank lines are uncommented only when every such line has this
        /// prefix after its indentation; otherwise all nonblank lines get it.
        case toggleLineComment(prefix: String)
    }

    public struct Limits: Sendable {
        public let source: TextLineIndex.Limits
        public let maximumAffectedLines: Int
        public let maximumReplacementUTF16Units: Int

        /// Restricts both input scanning and the one contiguous edit returned to
        /// the UI. Callers may lower budgets, not raise them past hard ceilings.
        public init(source: TextLineIndex.Limits = .init(), maximumAffectedLines: Int = 10_000,
                    maximumReplacementUTF16Units: Int = 1_048_576) {
            self.source = source
            self.maximumAffectedLines = maximumAffectedLines
            self.maximumReplacementUTF16Units = maximumReplacementUTF16Units
        }
    }

    public struct Edit: Sendable, Equatable {
        /// One minimal enclosing range for all prefix changes, in the old source.
        public let range: NSRange
        public let expectedSource: String
        public let replacement: String
        /// The original selection mapped into the resulting source. A nonempty
        /// selection includes insertions at its start and excludes those at its
        /// end; a caret moves after an insertion at the caret itself.
        public let selection: NSRange

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.range == rhs.range && lhs.selection == rhs.selection &&
                lhs.expectedSource.utf16.elementsEqual(rhs.expectedSource.utf16) &&
                lhs.replacement.utf16.elementsEqual(rhs.replacement.utf16)
        }
    }

    /// The end of a nonempty selection is exclusive: ending at the next line's
    /// start does not edit that next line. A caret operates on its current line,
    /// including the final empty line after a newline. Mixed endings are retained.
    /// Returns nil when there is nothing to change. Blank lines are left alone by
    /// a multi-line comment command; a caret on a blank line inserts a comment.
    public static func plan(
        _ operation: Operation, in source: String, selection: NSRange,
        limits: Limits = Limits(),
        isCancelled: @Sendable () -> Bool = { Task<Never, Never>.isCancelled }
    ) throws -> Edit? {
        guard (1...100_000).contains(limits.maximumAffectedLines),
              (0...(10 * 1_024 * 1_024)).contains(limits.maximumReplacementUTF16Units) else {
            throw TextEditingOperationError.invalidLimits
        }
        try validate(operation)
        let lines = try TextLineIndex.build(source, limits: limits.source, isCancelled: isCancelled)
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= lines.utf16Count,
              selection.length <= lines.utf16Count - selection.location else {
            throw TextEditingOperationError.invalidSelection
        }
        let text = source as NSString
        let end = NSMaxRange(selection)
        guard isScalarBoundary(selection.location, in: text), isScalarBoundary(end, in: text) else {
            throw TextEditingOperationError.invalidSelection
        }
        // Validated offsets always resolve, including an empty document's caret.
        let firstLine = lines.lineNumber(atUTF16Offset: selection.location)!
        let lastLine = lines.lineNumber(atUTF16Offset: selection.length == 0 ? end : end - 1)!
        guard lastLine - firstLine < limits.maximumAffectedLines else {
            throw TextEditingOperationError.affectedLineLimitExceeded(limit: limits.maximumAffectedLines)
        }

        var changes: [PrefixEdit] = []
        switch operation {
        case .indent(let unit):
            for line in firstLine...lastLine {
                if isCancelled() { throw CancellationError() }
                changes.append(PrefixEdit(range: NSRange(location: lines.range(forLine: line)!.location, length: 0),
                                          replacement: unit))
            }
        case .unindent(let width):
            for line in firstLine...lastLine {
                if isCancelled() { throw CancellationError() }
                let range = lines.range(forLine: line)!
                guard range.length > 0 else { continue }
                var length = 0
                if text.character(at: range.location) == 9 {
                    length = 1
                } else {
                    while length < min(width, range.length), text.character(at: range.location + length) == 32 {
                        length += 1
                    }
                }
                if length > 0 {
                    changes.append(PrefixEdit(range: NSRange(location: range.location, length: length), replacement: ""))
                }
            }
        case .toggleLineComment(let prefix):
            let marker = Array(prefix.utf16)
            var candidates: [CommentLine] = []
            for line in firstLine...lastLine {
                if isCancelled() { throw CancellationError() }
                let range = lines.range(forLine: line)!
                var start = range.location
                while start < NSMaxRange(range) {
                    if (start - range.location).isMultiple(of: 4_096), isCancelled() { throw CancellationError() }
                    let unit = text.character(at: start)
                    guard unit == 9 || unit == 32 else { break }
                    start += 1
                }
                let blank = start == NSMaxRange(range)
                if blank && selection.length > 0 { continue }
                let hasPrefix = !blank && marker.count <= NSMaxRange(range) - start &&
                    marker.enumerated().allSatisfy { text.character(at: start + $0.offset) == $0.element }
                candidates.append(CommentLine(start: start, end: NSMaxRange(range), hasPrefix: hasPrefix))
            }
            let remove = !candidates.isEmpty && candidates.allSatisfy(\.hasPrefix)
            for line in candidates {
                if isCancelled() { throw CancellationError() }
                if remove {
                    var length = marker.count
                    if line.start + length < line.end, text.character(at: line.start + length) == 32 { length += 1 }
                    changes.append(PrefixEdit(range: NSRange(location: line.start, length: length), replacement: ""))
                } else {
                    changes.append(PrefixEdit(range: NSRange(location: line.start, length: 0), replacement: prefix + " "))
                }
            }
        }
        guard let first = changes.first, let last = changes.last else { return nil }
        let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let delta = changes.reduce(0) { $0 + $1.replacement.utf16.count - $1.range.length }
        let replacementLength = range.length + delta
        guard range.length <= limits.maximumReplacementUTF16Units,
              replacementLength <= limits.maximumReplacementUTF16Units else {
            throw TextEditingOperationError.replacementLimitExceeded(limit: limits.maximumReplacementUTF16Units)
        }
        guard lines.utf16Count + delta <= limits.source.maximumUTF16Units else {
            throw TextEditingOperationError.resultLimitExceeded(limit: limits.source.maximumUTF16Units)
        }

        var pieces: [String] = []
        pieces.reserveCapacity(changes.count * 2 + 1)
        var cursor = range.location
        for change in changes {
            if isCancelled() { throw CancellationError() }
            if change.range.location > cursor {
                pieces.append(text.substring(with: NSRange(location: cursor, length: change.range.location - cursor)))
            }
            pieces.append(change.replacement)
            cursor = NSMaxRange(change.range)
        }
        let mappedStart = map(selection.location, through: changes, afterInsertion: selection.length == 0)
        let mappedEnd = selection.length == 0 ? mappedStart : map(end, through: changes, afterInsertion: false)
        let edit = Edit(range: range, expectedSource: text.substring(with: range), replacement: pieces.joined(),
                        selection: NSRange(location: mappedStart, length: mappedEnd - mappedStart))
        if isCancelled() { throw CancellationError() }
        return edit
    }

    private struct PrefixEdit {
        let range: NSRange
        let replacement: String
    }

    private struct CommentLine {
        let start: Int
        let end: Int
        let hasPrefix: Bool
    }

    private static func validate(_ operation: Operation) throws {
        switch operation {
        case .indent(let unit):
            let units = Array(unit.utf16.prefix(17))
            guard units == [9] || (!units.isEmpty && units.count <= 16 && units.allSatisfy { $0 == 32 }) else {
                throw TextEditingOperationError.invalidIndentation
            }
        case .unindent(let width):
            guard (1...16).contains(width) else { throw TextEditingOperationError.invalidIndentation }
        case .toggleLineComment(let prefix):
            let units = Array(prefix.utf16.prefix(33))
            guard !units.isEmpty, units.count <= 32,
                  !prefix.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
                throw TextEditingOperationError.invalidCommentPrefix
            }
        }
    }

    private static func isScalarBoundary(_ offset: Int, in text: NSString) -> Bool {
        guard offset > 0, offset < text.length else { return true }
        return !((0xD800...0xDBFF).contains(text.character(at: offset - 1)) &&
                 (0xDC00...0xDFFF).contains(text.character(at: offset)))
    }

    private static func map(_ offset: Int, through changes: [PrefixEdit], afterInsertion: Bool) -> Int {
        var delta = 0
        for change in changes {
            if offset < change.range.location { break }
            if offset == change.range.location {
                return offset + delta + (afterInsertion ? change.replacement.utf16.count : 0)
            }
            if offset < NSMaxRange(change.range) { return change.range.location + delta }
            delta += change.replacement.utf16.count - change.range.length
        }
        return offset + delta
    }
}

public enum TextEditingOperationError: Error, Equatable, Sendable {
    case invalidSelection
    case invalidIndentation
    case invalidCommentPrefix
    case invalidLimits
    case affectedLineLimitExceeded(limit: Int)
    case replacementLimitExceeded(limit: Int)
    case resultLimitExceeded(limit: Int)
}
