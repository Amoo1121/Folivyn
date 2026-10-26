import Foundation
import XCTest
@testable import EditorCore

final class JSONStructureTests: XCTestCase {
    func testDuplicateMembersPreserveEveryOccurrenceAndExactSpellings() throws {
        let source = #" { "a": 1, "\u0061" : 2, "b": false, "a": null } "#
        let structure = try JSONStructure.parse(source)
        let members = try object(structure.root)
        XCTAssertEqual(members.map(\.key), ["a", "a", "b", "a"])
        XCTAssertEqual(members.map(\.keyLexeme), [#""a""#, #""\u0061""#, #""b""#, #""a""#])
        XCTAssertEqual(members.map(\.isDuplicateKey), [true, true, false, true])
        XCTAssertEqual(members.compactMap { structure.rawToken(for: $0.value) }, ["1", "2", "false", "null"])
        XCTAssertEqual(structure.nodeCount, 5)
        XCTAssertEqual(Array(structure.source.utf8), Array(source.utf8))
        XCTAssertEqual(structure.rawToken(for: structure.root), String(source.dropFirst().dropLast()))
    }

    func testCanonicallyEquivalentButDifferentUnicodeKeysAreNotDuplicates() throws {
        let source = "{\"é\":1,\"e\u{301}\":2,\"\\u00e9\":3}"
        let members = try object(JSONStructure.parse(source).root)
        XCTAssertEqual(members.map(\.isDuplicateKey), [true, false, true])
        XCTAssertEqual(Array(members[0].key.utf16), [0xE9])
        XCTAssertEqual(Array(members[1].key.utf16), [0x65, 0x301])
    }

    func testNumbersKeepLargeIntegersExponentsAndNegativeZeroVerbatim() throws {
        let numbers = ["900719925474099312345678901234567890", "1.2300e+9999", "-0", "-0.00E-01", "1e-999999"]
        let source = "[" + numbers.joined(separator: ", \r\n") + "]"
        let structure = try JSONStructure.parse(source)
        let children = try array(structure.root)
        for (node, spelling) in zip(children, numbers) {
            guard case .number(let lexeme) = node.value else { return XCTFail("Expected number") }
            XCTAssertEqual(lexeme, spelling)
            XCTAssertEqual(structure.rawToken(for: node), spelling)
        }
        XCTAssertEqual(Array(structure.source.utf8), Array(source.utf8))
    }

    func testEscapedAndEmojiStringsHaveExactUTF16RangesAndDecodedValues() throws {
        let source = #"{"🦊/\u007e":"\uD83E\uDD8A", "text":"line\n\t\b\f\r\u0000\/\\\""}"#
        let structure = try JSONStructure.parse(source)
        let members = try object(structure.root)
        XCTAssertEqual(members[0].key, "🦊/~")
        XCTAssertEqual(members[0].keyTokenRange, (source as NSString).range(of: #""🦊/\u007e""#))
        XCTAssertEqual(members[0].value.tokenRange, (source as NSString).range(of: #""\uD83E\uDD8A""#))
        guard case .string(let fox) = members[0].value.value,
              case .string(let text) = members[1].value.value else { return XCTFail("Expected strings") }
        XCTAssertEqual(fox, "🦊")
        XCTAssertEqual(text, "line\n\t\u{8}\u{C}\r\0/\\\"")
        XCTAssertEqual(structure.rawToken(for: members[0].value), #""\uD83E\uDD8A""#)
        XCTAssertEqual(structure.pointer(to: members[0].value)?.value, "/🦊~1~0")
    }

    func testPointersEscapeComponentsAndPropagateDuplicateAncestorAmbiguity() throws {
        let structure = try JSONStructure.parse(#"{"a/b~":[{"":true}],"dup":{"x":1},"dup":{"x":2}}"#)
        let members = try object(structure.root)
        let firstArray = try array(members[0].value)
        let nested = try object(firstArray[0])
        XCTAssertEqual(structure.pointer(to: structure.root), JSONPointer(value: "", isAmbiguous: false))
        XCTAssertEqual(structure.pointer(to: nested[0].value), JSONPointer(value: "/a~1b~0/0/", isAmbiguous: false))
        for duplicate in members.dropFirst() {
            let child = try object(duplicate.value)[0].value
            XCTAssertEqual(structure.pointer(to: child), JSONPointer(value: "/dup/x", isAmbiguous: true))
        }
        XCTAssertNil(structure.pointer(to: NSRange(location: 1, length: 0)))
        XCTAssertNil(structure.rawToken(in: NSRange(location: Int.max, length: Int.max)))
    }

    func testStrictJSONAcceptsScalarRootsWhitespaceAndValidSurrogatePairs() throws {
        let valid = ["null", "true", "false", "123", "[]", "{}", "\t\r\n [true, false, null] ",
                     #""\uD800\uDC00""#, #""\uDBFF\uDFFF""#, #""𐀀é🦊""#]
        for source in valid {
            XCTAssertNoThrow(try JSONStructure.parse(source), source)
        }
    }

    func testStrictJSONRejectsCommentsTrailingCommasAndNonJSONNumbers() {
        let invalid = ["", " ", "[1,]", #"{"a":1,}"#, "[1 2]", #"{"a" 1}"#,
                       "// comment\n1", "/* comment */1", "{'a':1}", "{a:1}",
                       "NaN", "Infinity", "-Infinity", "+1", "01", "-01", "1.", ".1", "1e", "1e+", "1e-",
                       "0x10", "1_000", "true false", "undefined", "True", "nul", "[", "{",
                       "\u{FEFF}null", "\u{00A0}1", "[1\u{000B},2]", "\"raw\nline\"", "\"\u{0}\"",
                       #""\x41""#, #""\v""#, #""\uZZZZ""#, #""\u12""#]
        for source in invalid {
            XCTAssertThrowsError(try JSONStructure.parse(source), source) { error in
                guard let error = error as? JSONStructureError else { return XCTFail("Wrong error: \(error)") }
                XCTAssertGreaterThanOrEqual(error.utf16Location, 0)
                XCTAssertLessThanOrEqual(error.utf16Location, source.utf16.count)
            }
        }
    }

    func testUnpairedEscapedSurrogatesAreRejectedRatherThanReplaced() {
        for source in [#""\uD800""#, #""\uDC00""#, #""\uD800\u0041""#, #""\uD800a""#,
                       #""\uD800\n""#, #""\uDC00\uD800""#] {
            XCTAssertThrowsError(try JSONStructure.parse(source), source) { error in
                XCTAssertEqual((error as? JSONStructureError)?.kind, .unpairedSurrogate)
            }
        }
    }

    func testErrorLocationUsesUTF16IncludingBeforeAndAfterEmoji() {
        let source = #"["🦊", truX]"#
        XCTAssertThrowsError(try JSONStructure.parse(source)) { error in
            XCTAssertEqual((error as? JSONStructureError)?.utf16Location, (source as NSString).range(of: "X").location)
        }
        let missing = #"{"🦊": [1"#
        XCTAssertThrowsError(try JSONStructure.parse(missing)) { error in
            XCTAssertEqual((error as? JSONStructureError)?.utf16Location, missing.utf16.count)
        }
    }

    func testByteDepthAndNodeLimitsRejectWithoutPartialResults() throws {
        let defaults = JSONStructure.Limits()
        XCTAssertEqual(defaults.maximumUTF8Bytes, 1_048_576)
        XCTAssertEqual(defaults.maximumDepth, 128)
        XCTAssertEqual(defaults.maximumNodes, 100_000)
        let text = #""🦊""#
        XCTAssertNoThrow(try JSONStructure.parse(text, limits: .init(maximumUTF8Bytes: 6)))
        assertFailure(text, limits: .init(maximumUTF8Bytes: 5), kind: .inputTooLarge, location: 0)
        let deep = String(repeating: "[", count: 128) + "0" + String(repeating: "]", count: 128)
        XCTAssertEqual(try JSONStructure.parse(deep).nodeCount, 129)
        assertFailure("[" + deep + "]", kind: .nestingTooDeep, location: 128)
        XCTAssertNoThrow(try JSONStructure.parse("[0,1]", limits: .init(maximumNodes: 3)))
        assertFailure("[0,1]", limits: .init(maximumNodes: 2), kind: .tooManyNodes, location: 3)
        XCTAssertNoThrow(try JSONStructure.parse("0", limits: .init(maximumDepth: 0)))
        assertFailure("[]", limits: .init(maximumDepth: 0), kind: .nestingTooDeep, location: 0)
        assertFailure("0", limits: .init(maximumNodes: 0), kind: .invalidLimits, location: 0)
        assertFailure("0", limits: .init(maximumUTF8Bytes: 1_048_577), kind: .invalidLimits, location: 0)
        assertFailure("0", limits: .init(maximumDepth: 129), kind: .invalidLimits, location: 0)
        assertFailure("0", limits: .init(maximumNodes: 100_001), kind: .invalidLimits, location: 0)
    }

    func testDefaultInputAndNodeBudgetsAreEnforced() throws {
        let exact = "\"" + String(repeating: "a", count: 1_048_574) + "\""
        XCTAssertNoThrow(try JSONStructure.parse(exact))
        assertFailure(exact + " ", kind: .inputTooLarge, location: 0)
        let source = "[" + Array(repeating: "0", count: 100_000).joined(separator: ",") + "]"
        assertFailure(source, kind: .tooManyNodes, location: 199_999)
    }

    func testCancellationBeforeAndDuringScanningProducesNoTree() {
        XCTAssertThrowsError(try JSONStructure.parse("null", isCancelled: { true })) { error in
            XCTAssertEqual((error as? JSONStructureError)?.kind, .cancelled)
        }
        let cancellation = CancellationCounter(threshold: 25)
        let source = "[" + String(repeating: " ", count: 20_000) + "0]"
        XCTAssertThrowsError(try JSONStructure.parse(source, isCancelled: { cancellation.check() })) { error in
            let failure = error as? JSONStructureError
            XCTAssertEqual(failure?.kind, .cancelled)
            XCTAssertGreaterThan(failure?.utf16Location ?? 0, 0)
        }
    }

    private func object(_ node: JSONNode, file: StaticString = #filePath, line: UInt = #line) throws -> [JSONMember] {
        guard case .object(let members) = node.value else {
            XCTFail("Expected object", file: file, line: line)
            throw UnexpectedNode()
        }
        return members
    }

    private func array(_ node: JSONNode, file: StaticString = #filePath, line: UInt = #line) throws -> [JSONNode] {
        guard case .array(let children) = node.value else {
            XCTFail("Expected array", file: file, line: line)
            throw UnexpectedNode()
        }
        return children
    }

    private func assertFailure(_ source: String, limits: JSONStructure.Limits = .init(),
                               kind: JSONStructureError.Kind, location: Int,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try JSONStructure.parse(source, limits: limits), file: file, line: line) { error in
            XCTAssertEqual(error as? JSONStructureError, JSONStructureError(kind: kind, utf16Location: location),
                           file: file, line: line)
        }
    }

    private struct UnexpectedNode: Error {}
}

private final class CancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let threshold: Int
    private var count = 0

    init(threshold: Int) { self.threshold = threshold }

    func check() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count >= threshold
    }
}
