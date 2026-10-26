import Foundation

public enum CSVDelimiter: String, CaseIterable, Sendable {
    case comma = ","
    case tab = "\t"

    fileprivate var unit: UInt16 { self == .comma ? 0x2C : 0x09 }
}

/// Limits apply to the decoded source's UTF-8 size, not its on-disk encoding.
/// The total-field budget also bounds the index for files containing mostly commas.
public struct CSVLimits: Sendable {
    public let maximumUTF8Bytes: Int
    public let maximumRecords: Int
    public let maximumColumns: Int
    public let maximumFields: Int

    public init(
        maximumUTF8Bytes: Int = 5 * 1_024 * 1_024,
        maximumRecords: Int = 100_000,
        maximumColumns: Int = 256,
        maximumFields: Int = 250_000
    ) {
        self.maximumUTF8Bytes = maximumUTF8Bytes
        self.maximumRecords = maximumRecords
        self.maximumColumns = maximumColumns
        self.maximumFields = maximumFields
    }
}

public struct CSVSourcePosition: Equatable, Sendable {
    /// Zero-based UTF-16 offset, suitable for NSTextView selection.
    public let utf16Offset: Int
    /// One-based physical source line and UTF-16 column. CRLF counts as one break.
    public let line: Int
    public let column: Int
}

public enum CSVDocumentError: Error, Equatable, Sendable {
    case invalidLimits
    case cancelled
    case byteLimitExceeded(limit: Int)
    case recordLimitExceeded(limit: Int, position: CSVSourcePosition)
    case columnLimitExceeded(limit: Int, position: CSVSourcePosition)
    case fieldLimitExceeded(limit: Int, position: CSVSourcePosition)
    case quoteInUnquotedField(position: CSVSourcePosition)
    case charactersAfterClosingQuote(position: CSVSourcePosition)
    case unclosedQuotedField(position: CSVSourcePosition)
    case missingField(row: Int, column: Int)
}

// The NSString is created here, never exposed as a mutable object, and shared by
// immutable fields. UTF-16 substring lookup does not rescan from the file's start.
private final class CSVSource: @unchecked Sendable {
    let text: NSString

    init(_ source: String) { text = NSString(string: source) }
}

public struct CSVField: Sendable {
    /// Includes this field's original quotes and escapes, but no delimiter or break.
    public let rawRange: NSRange
    public let isQuoted: Bool
    private let source: CSVSource

    fileprivate init(rawRange: NSRange, isQuoted: Bool, source: CSVSource) {
        self.rawRange = rawRange
        self.isQuoted = isQuoted
        self.source = source
    }

    /// Decoded lazily, so table creation does not materialize every cell string.
    /// Numeric-looking values and formula-looking values are always plain strings.
    public var value: String {
        if isQuoted {
            let content = NSRange(location: rawRange.location + 1, length: rawRange.length - 2)
            return source.text.substring(with: content).replacingOccurrences(of: "\"\"", with: "\"")
        }
        return rawText
    }

    fileprivate var rawText: String { source.text.substring(with: rawRange) }
}

public struct CSVRecord: Sendable {
    public let fields: [CSVField]
    /// Includes the record's delimiters, but excludes its terminating line break.
    public let rawRange: NSRange
    /// CRLF, LF, CR, or an empty range at EOF. Quoted breaks belong to fields.
    public let terminatorRange: NSRange
}

public struct CSVFieldReplacement: Equatable, Sendable {
    public let range: NSRange
    /// The exact raw field that occupied range in the parsed snapshot.
    public let expectedSource: String
    public let escapedReplacement: String
}

/// An immutable index into one source snapshot. Parsing and viewing never rewrite
/// the source. BOM/encoding preservation belongs to DocumentFile, before/after this
/// decoded-text API. The caller must also match its document revision before edits.
public struct CSVDocument: Sendable {
    public let delimiter: CSVDelimiter
    public let records: [CSVRecord]
    public let maximumColumnCount: Int
    private let limits: CSVLimits
    private let sourceUTF8Count: Int

    /// Empty input has no records. A blank physical line has one empty field; a
    /// final delimiter adds an empty field; a final line break adds no phantom row.
    /// A missing column has no field and cannot be edited through this API.
    public static func parse(
        _ source: String,
        delimiter: CSVDelimiter,
        limits: CSVLimits = CSVLimits(),
        isCancelled: () -> Bool = { false }
    ) throws -> CSVDocument {
        guard limits.maximumUTF8Bytes > 0, limits.maximumRecords > 0,
              limits.maximumColumns > 0, limits.maximumFields > 0 else {
            throw CSVDocumentError.invalidLimits
        }
        let byteCount = try boundedUTF8Count(source, limit: limits.maximumUTF8Bytes, isCancelled: isCancelled)
        let units = Array(source.utf16)
        let snapshot = CSVSource(source)
        var scanner = Scanner(units: units, source: snapshot, delimiter: delimiter, limits: limits)
        let records = try scanner.scan(isCancelled: isCancelled)
        return CSVDocument(
            delimiter: delimiter,
            records: records,
            maximumColumnCount: records.reduce(0) { max($0, $1.fields.count) },
            limits: limits,
            sourceUTF8Count: byteCount
        )
    }

    public func field(row: Int, column: Int) -> CSVField? {
        guard records.indices.contains(row), records[row].fields.indices.contains(column) else { return nil }
        return records[row].fields[column]
    }

    /// Produces one local text replacement, never a serialized table. The caller
    /// checks revision/expectedSource and applies it through the editor's undo path.
    /// Existing quoting is retained; changed values are quoted when required.
    public func replacement(
        row: Int,
        column: Int,
        value: String,
        isCancelled: () -> Bool = { false }
    ) throws -> CSVFieldReplacement {
        guard let field = field(row: row, column: column) else {
            throw CSVDocumentError.missingField(row: row, column: column)
        }
        _ = try Self.boundedUTF8Count(value, limit: limits.maximumUTF8Bytes, isCancelled: isCancelled)
        let raw = field.rawText
        let replacement: String
        // Swift String == treats canonically equivalent Unicode as equal. Use
        // UTF-16 equality so an intentional normalization change is not discarded.
        if value.utf16.elementsEqual(field.value.utf16) {
            replacement = raw
        } else if field.isQuoted ||
            // A bare empty field at EOF would erase a single-column final row:
            // "header\nx" -> "header\n". Keep that real field explicit as "".
            (value.isEmpty && records[row].fields.count == 1 && records[row].terminatorRange.length == 0) ||
            value.utf16.contains(where: {
            $0 == delimiter.unit || $0 == 0x22 || $0 == 0x0A || $0 == 0x0D
        }) {
            replacement = "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        } else {
            replacement = value
        }
        let replacementCount = try Self.boundedUTF8Count(replacement, limit: limits.maximumUTF8Bytes, isCancelled: isCancelled)
        guard replacementCount <= limits.maximumUTF8Bytes - (sourceUTF8Count - raw.utf8.count) else {
            throw CSVDocumentError.byteLimitExceeded(limit: limits.maximumUTF8Bytes)
        }
        return CSVFieldReplacement(range: field.rawRange, expectedSource: raw, escapedReplacement: replacement)
    }

    private static func boundedUTF8Count(
        _ source: String, limit: Int, isCancelled: () -> Bool
    ) throws -> Int {
        if isCancelled() { throw CSVDocumentError.cancelled }
        var count = 0
        for _ in source.utf8 {
            guard count < limit else { throw CSVDocumentError.byteLimitExceeded(limit: limit) }
            count += 1
            if count.isMultiple(of: 4_096), isCancelled() { throw CSVDocumentError.cancelled }
        }
        if isCancelled() { throw CSVDocumentError.cancelled }
        return count
    }

    private struct Scanner {
        let units: [UInt16]
        let source: CSVSource
        let delimiter: CSVDelimiter
        let limits: CSVLimits
        var cursor = 0
        var fieldCount = 0
        var nextCancellationOffset = 0

        mutating func scan(isCancelled: () -> Bool) throws -> [CSVRecord] {
            var records = [CSVRecord]()
            try checkpoint(isCancelled)
            while cursor < units.count {
                guard records.count < limits.maximumRecords else {
                    throw CSVDocumentError.recordLimitExceeded(limit: limits.maximumRecords, position: position(cursor))
                }
                let recordStart = cursor
                var fields = [CSVField]()
                while true {
                    try checkpoint(isCancelled)
                    guard fields.count < limits.maximumColumns else {
                        throw CSVDocumentError.columnLimitExceeded(limit: limits.maximumColumns, position: position(cursor))
                    }
                    guard fieldCount < limits.maximumFields else {
                        throw CSVDocumentError.fieldLimitExceeded(limit: limits.maximumFields, position: position(cursor))
                    }
                    let fieldStart = cursor
                    let quoted = cursor < units.count && units[cursor] == 0x22
                    if quoted {
                        cursor += 1
                        var closed = false
                        while cursor < units.count {
                            try checkpoint(isCancelled)
                            if units[cursor] == 0x22 {
                                cursor += 1
                                if cursor < units.count && units[cursor] == 0x22 {
                                    cursor += 1
                                } else {
                                    closed = true
                                    break
                                }
                            } else {
                                cursor += 1
                            }
                        }
                        guard closed else {
                            throw CSVDocumentError.unclosedQuotedField(position: position(fieldStart))
                        }
                        if cursor < units.count, units[cursor] != delimiter.unit, !isBreak(units[cursor]) {
                            throw CSVDocumentError.charactersAfterClosingQuote(position: position(cursor))
                        }
                    } else {
                        while cursor < units.count, units[cursor] != delimiter.unit, !isBreak(units[cursor]) {
                            try checkpoint(isCancelled)
                            guard units[cursor] != 0x22 else {
                                throw CSVDocumentError.quoteInUnquotedField(position: position(cursor))
                            }
                            cursor += 1
                        }
                    }
                    fields.append(CSVField(
                        rawRange: NSRange(location: fieldStart, length: cursor - fieldStart),
                        isQuoted: quoted,
                        source: source
                    ))
                    fieldCount += 1
                    if cursor < units.count, units[cursor] == delimiter.unit {
                        cursor += 1
                        continue
                    }
                    let recordEnd = cursor
                    if cursor < units.count {
                        let first = units[cursor]
                        cursor += 1
                        if first == 0x0D, cursor < units.count, units[cursor] == 0x0A { cursor += 1 }
                    }
                    records.append(CSVRecord(
                        fields: fields,
                        rawRange: NSRange(location: recordStart, length: recordEnd - recordStart),
                        terminatorRange: NSRange(location: recordEnd, length: cursor - recordEnd)
                    ))
                    break
                }
            }
            if isCancelled() { throw CSVDocumentError.cancelled }
            return records
        }

        private func isBreak(_ unit: UInt16) -> Bool { unit == 0x0A || unit == 0x0D }

        private mutating func checkpoint(_ isCancelled: () -> Bool) throws {
            if cursor >= nextCancellationOffset {
                if isCancelled() { throw CSVDocumentError.cancelled }
                nextCancellationOffset = cursor + 1_024
            }
        }

        private func position(_ offset: Int) -> CSVSourcePosition {
            var line = 1
            var column = 1
            var index = 0
            while index < offset {
                let unit = units[index]
                index += 1
                if unit == 0x0D {
                    if index < offset, units[index] == 0x0A { index += 1 }
                    line += 1
                    column = 1
                } else if unit == 0x0A {
                    line += 1
                    column = 1
                } else {
                    column += 1
                }
            }
            return CSVSourcePosition(utf16Offset: offset, line: line, column: column)
        }
    }
}
