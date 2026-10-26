import Foundation

/// Read-only JSON structure. The source remains the only authoritative text.
public struct JSONStructure: Sendable {
    public struct Limits: Sendable {
        public let maximumUTF8Bytes: Int
        /// Number of enclosing arrays/objects; a scalar root has depth zero.
        public let maximumDepth: Int
        /// Counts values, including containers, but not object member keys.
        public let maximumNodes: Int

        /// Callers may request smaller budgets. Values above the product's hard
        /// ceilings are rejected when parsing, rather than permitting unbounded work.
        public init(maximumUTF8Bytes: Int = 1_048_576, maximumDepth: Int = 128,
                    maximumNodes: Int = 100_000) {
            self.maximumUTF8Bytes = maximumUTF8Bytes
            self.maximumDepth = maximumDepth
            self.maximumNodes = maximumNodes
        }
    }

    public let source: String
    public let root: JSONNode
    public let nodeCount: Int

    /// Parses strict JSON without normalization, number conversion, or recovery.
    /// Cancellation is checked during scanning as well as between nodes.
    public static func parse(
        _ source: String, limits: Limits = Limits(),
        isCancelled: @escaping @Sendable () -> Bool = { Task<Never, Never>.isCancelled }
    ) throws -> JSONStructure {
        guard (0...1_048_576).contains(limits.maximumUTF8Bytes),
              (0...128).contains(limits.maximumDepth),
              (1...100_000).contains(limits.maximumNodes) else {
            throw JSONStructureError(kind: .invalidLimits, utf16Location: 0)
        }
        var bytes = 0
        for _ in source.utf8 {
            if bytes & 1023 == 0, isCancelled() {
                throw JSONStructureError(kind: .cancelled, utf16Location: 0)
            }
            guard bytes < limits.maximumUTF8Bytes else {
                throw JSONStructureError(kind: .inputTooLarge, utf16Location: 0)
            }
            bytes += 1
        }
        var parser = JSONStructureParser(units: Array(source.utf16), limits: limits,
                                         isCancelled: isCancelled)
        let root = try parser.parse()
        return JSONStructure(source: source, root: root, nodeCount: parser.nodeCount)
    }

    /// Extracts the exact token spelling, including quotes/escapes and whitespace
    /// inside containers. Only use nodes from this immutable source revision.
    public func rawToken(for node: JSONNode) -> String? {
        rawToken(in: node.tokenRange)
    }

    public func rawToken(in range: NSRange) -> String? {
        let text = source as NSString
        guard range.location >= 0, range.length >= 0, range.location <= text.length,
              range.length <= text.length - range.location else { return nil }
        return text.substring(with: range)
    }

    /// Computes a pointer only when requested. Storing a full ancestor path on
    /// every node would multiply memory use for deeply nested documents.
    public func pointer(to node: JSONNode) -> JSONPointer? {
        pointer(to: node.tokenRange)
    }

    public func pointer(to tokenRange: NSRange) -> JSONPointer? {
        func visit(_ node: JSONNode, path: String, ambiguous: Bool) -> JSONPointer? {
            if node.tokenRange == tokenRange {
                return JSONPointer(value: path, isAmbiguous: ambiguous)
            }
            guard tokenRange.location >= node.tokenRange.location,
                  tokenRange.length >= 0,
                  tokenRange.location <= NSMaxRange(node.tokenRange),
                  tokenRange.length <= NSMaxRange(node.tokenRange) - tokenRange.location else { return nil }
            switch node.value {
            case .object(let members):
                for member in members {
                    let escaped = member.key.replacingOccurrences(of: "~", with: "~0")
                        .replacingOccurrences(of: "/", with: "~1")
                    if let result = visit(member.value, path: path + "/" + escaped,
                                          ambiguous: ambiguous || member.isDuplicateKey) { return result }
                }
            case .array(let elements):
                for (index, child) in elements.enumerated() {
                    if let result = visit(child, path: path + "/\(index)", ambiguous: ambiguous) { return result }
                }
            default: break
            }
            return nil
        }
        return visit(root, path: "", ambiguous: false)
    }
}

public struct JSONPointer: Equatable, Sendable {
    /// RFC 6901 string form. The root pointer is the empty string.
    public let value: String
    /// Duplicate members on this path prevent the pointer from uniquely naming it.
    public let isAmbiguous: Bool
}

public struct JSONNode: Sendable {
    /// UTF-16 offsets into JSONStructure.source, suitable for NSTextView selection.
    public let tokenRange: NSRange
    public let value: JSONValue
}

public indirect enum JSONValue: Sendable {
    case object([JSONMember])
    case array([JSONNode])
    case string(String)
    /// Exact original number token; never converted to a floating-point value.
    case number(String)
    case bool(Bool)
    case null
}

public struct JSONMember: Sendable {
    public let key: String
    public let keyTokenRange: NSRange
    /// Original quoted spelling, which can differ even for duplicate decoded keys.
    public let keyLexeme: String
    public let value: JSONNode
    /// All occurrences of a duplicate key are flagged, including the first.
    public fileprivate(set) var isDuplicateKey: Bool
}

/// Stable reasons are separate from presentation so callers can localize errors.
public struct JSONStructureError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case expectedValue, expectedObjectKey, expectedColon, expectedCommaOrEnd
        case invalidNumber, invalidStringEscape, unescapedControlCharacter
        case invalidUnicodeEscape, unpairedSurrogate, unexpectedEnd, trailingContent
        case inputTooLarge, nestingTooDeep, tooManyNodes, cancelled, invalidLimits
    }

    public let kind: Kind
    /// A zero-length selection here points at the error, or EOF when incomplete.
    public let utf16Location: Int
}

private struct JSONStructureParser {
    let units: [UInt16]
    let limits: JSONStructure.Limits
    let isCancelled: @Sendable () -> Bool
    var index = 0
    var nodeCount = 0
    private var lastCancellationCheck = 0

    init(units: [UInt16], limits: JSONStructure.Limits,
         isCancelled: @escaping @Sendable () -> Bool) {
        self.units = units
        self.limits = limits
        self.isCancelled = isCancelled
    }

    mutating func parse() throws -> JSONNode {
        try checkCancellation(force: true)
        try skipWhitespace()
        let root = try parseValue(depth: 0)
        try skipWhitespace()
        guard index == units.count else { throw error(.trailingContent) }
        try checkCancellation(force: true)
        return root
    }

    mutating func parseValue(depth: Int) throws -> JSONNode {
        try checkCancellation(force: true)
        guard index < units.count else { throw error(.unexpectedEnd) }
        guard nodeCount < limits.maximumNodes else { throw error(.tooManyNodes) }
        nodeCount += 1
        let start = index
        let value: JSONValue
        switch units[index] {
        case 123, 91:
            guard depth < limits.maximumDepth else { throw error(.nestingTooDeep) }
            value = units[index] == 123 ? try parseObject(depth: depth + 1) : try parseArray(depth: depth + 1)
        case 34: value = .string(try parseString())
        case 45, 48...57: value = .number(try parseNumber())
        case 116: try consumeLiteral([116, 114, 117, 101]); value = .bool(true)
        case 102: try consumeLiteral([102, 97, 108, 115, 101]); value = .bool(false)
        case 110: try consumeLiteral([110, 117, 108, 108]); value = .null
        default: throw error(.expectedValue)
        }
        return JSONNode(tokenRange: NSRange(location: start, length: index - start), value: value)
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        try skipWhitespace()
        var members: [JSONMember] = []
        // Swift String equality normalizes canonically equivalent Unicode. JSON
        // names instead compare decoded code units, so use UTF-16 arrays as keys.
        var occurrences: [[UInt16]: [Int]] = [:]
        if take(125) { return .object(members) }
        while true {
            guard index < units.count else { throw error(.unexpectedEnd) }
            guard units[index] == 34 else { throw error(.expectedObjectKey) }
            let keyStart = index
            let key = try parseString()
            let keyRange = NSRange(location: keyStart, length: index - keyStart)
            let lexeme = String(decoding: units[keyStart..<index], as: UTF16.self)
            try skipWhitespace()
            guard take(58) else { throw error(.expectedColon) }
            try skipWhitespace()
            let child = try parseValue(depth: depth)
            occurrences[Array(key.utf16), default: []].append(members.count)
            members.append(JSONMember(key: key, keyTokenRange: keyRange, keyLexeme: lexeme,
                                      value: child, isDuplicateKey: false))
            try skipWhitespace()
            if take(125) { break }
            guard take(44) else { throw error(.expectedCommaOrEnd) }
            try skipWhitespace()
        }
        for indices in occurrences.values where indices.count > 1 {
            for memberIndex in indices { members[memberIndex].isDuplicateKey = true }
        }
        return .object(members)
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        try skipWhitespace()
        var children: [JSONNode] = []
        if take(93) { return .array(children) }
        while true {
            children.append(try parseValue(depth: depth))
            try skipWhitespace()
            if take(93) { return .array(children) }
            guard take(44) else { throw error(.expectedCommaOrEnd) }
            try skipWhitespace()
        }
    }

    mutating func parseString() throws -> String {
        index += 1 // Opening quote has already been checked.
        var decoded: [UInt16] = []
        while index < units.count {
            try checkCancellation()
            let unit = units[index]
            if unit == 34 {
                index += 1
                return String(decoding: decoded, as: UTF16.self)
            }
            guard unit >= 32 else { throw error(.unescapedControlCharacter) }
            if unit != 92 {
                // The input is a Swift String, so its unescaped UTF-16 is valid.
                decoded.append(unit)
                index += 1
                continue
            }
            index += 1
            guard index < units.count else { throw error(.unexpectedEnd) }
            let escaped = units[index]
            index += 1
            switch escaped {
            case 34, 47, 92: decoded.append(escaped)
            case 98: decoded.append(8)
            case 102: decoded.append(12)
            case 110: decoded.append(10)
            case 114: decoded.append(13)
            case 116: decoded.append(9)
            case 117:
                let firstLocation = index
                let first = try parseHexQuad()
                if (0xD800...0xDBFF).contains(first) {
                    guard index + 1 < units.count, units[index] == 92, units[index + 1] == 117 else {
                        throw JSONStructureError(kind: .unpairedSurrogate, utf16Location: firstLocation)
                    }
                    index += 2
                    let secondLocation = index
                    let second = try parseHexQuad()
                    guard (0xDC00...0xDFFF).contains(second) else {
                        throw JSONStructureError(kind: .unpairedSurrogate, utf16Location: secondLocation)
                    }
                    decoded.append(contentsOf: [first, second])
                } else if (0xDC00...0xDFFF).contains(first) {
                    throw JSONStructureError(kind: .unpairedSurrogate, utf16Location: firstLocation)
                } else {
                    decoded.append(first)
                }
            default:
                throw JSONStructureError(kind: .invalidStringEscape, utf16Location: index - 1)
            }
        }
        throw error(.unexpectedEnd)
    }

    mutating func parseHexQuad() throws -> UInt16 {
        var result: UInt16 = 0
        for _ in 0..<4 {
            guard index < units.count else { throw error(.unexpectedEnd) }
            let digit: UInt16
            switch units[index] {
            case 48...57: digit = units[index] - 48
            case 65...70: digit = units[index] - 65 + 10
            case 97...102: digit = units[index] - 97 + 10
            default: throw error(.invalidUnicodeEscape)
            }
            result = result * 16 + digit
            index += 1
        }
        return result
    }

    mutating func parseNumber() throws -> String {
        let start = index
        _ = take(45)
        guard index < units.count else { throw error(.invalidNumber) }
        if take(48) {
            if isDigit { throw error(.invalidNumber) }
        } else {
            guard (49...57).contains(units[index]) else { throw error(.invalidNumber) }
            try consumeDigits()
        }
        if take(46) {
            guard isDigit else { throw error(.invalidNumber) }
            try consumeDigits()
        }
        if take(101) || take(69) {
            if !take(43) { _ = take(45) }
            guard isDigit else { throw error(.invalidNumber) }
            try consumeDigits()
        }
        return String(decoding: units[start..<index], as: UTF16.self)
    }

    mutating func consumeDigits() throws {
        while isDigit {
            index += 1
            try checkCancellation()
        }
    }

    var isDigit: Bool { index < units.count && (48...57).contains(units[index]) }

    mutating func consumeLiteral(_ expected: [UInt16]) throws {
        for unit in expected {
            guard index < units.count else { throw error(.unexpectedEnd) }
            guard take(unit) else { throw error(.expectedValue) }
        }
    }

    mutating func take(_ unit: UInt16) -> Bool {
        guard index < units.count, units[index] == unit else { return false }
        index += 1
        return true
    }

    mutating func skipWhitespace() throws {
        while index < units.count, [9, 10, 13, 32].contains(units[index]) {
            index += 1
            try checkCancellation()
        }
    }

    mutating func checkCancellation(force: Bool = false) throws {
        if force || index - lastCancellationCheck >= 1024 {
            lastCancellationCheck = index
            if isCancelled() { throw error(.cancelled) }
        }
    }

    func error(_ kind: JSONStructureError.Kind) -> JSONStructureError {
        JSONStructureError(kind: kind, utf16Location: index)
    }
}
