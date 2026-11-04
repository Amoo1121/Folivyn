import Foundation
import XCTest
@testable import EditorCore

final class BracketMatcherTests: XCTestCase {
    func testNestedPairsFromEitherSideAndCaretPreference() throws {
        let source = "{[()]}"
        let expected = [pair(0, 5), pair(1, 4), pair(2, 3), pair(2, 3), pair(1, 4), pair(0, 5), pair(0, 5)]
        for caret in 0...source.utf16.count {
            XCTAssertEqual(try BracketMatcher.match(in: source, atUTF16Offset: caret), expected[caret])
        }
        XCTAssertEqual(try BracketMatcher.match(in: "()[]", atUTF16Offset: 2), pair(2, 3), "The bracket at the caret wins over one before it")
    }

    func testUnicodeOffsetsAndNoBracketCases() throws {
        let source = "中文🦊(e\u{301})👩🏽‍💻"
        XCTAssertEqual(try BracketMatcher.match(in: source, atUTF16Offset: 4), pair(4, 7))
        XCTAssertEqual(try BracketMatcher.match(in: source, atUTF16Offset: 8), pair(4, 7))
        for caret in [Int.min, -1, 0, 2, 3, 6, Int.max] {
            XCTAssertNil(try BracketMatcher.match(in: source, atUTF16Offset: caret))
        }
        XCTAssertNil(try BracketMatcher.match(in: "", atUTF16Offset: 0))
        XCTAssertNil(try BracketMatcher.match(in: "<> text", atUTF16Offset: 0))
    }

    func testLiteralPolicyDoesNotPretendToUnderstandStringsOrComments() throws {
        let source = #""[()]" // {}"#
        XCTAssertEqual(try BracketMatcher.match(in: source, atUTF16Offset: 1, policy: .literal), pair(1, 4))
        let brace = (source as NSString).range(of: "{").location
        XCTAssertEqual(try BracketMatcher.match(in: source, atUTF16Offset: brace, policy: .literal), pair(brace, brace + 1))
    }

    func testJSONQuotedBracketsAndEscapesAreOpaque() throws {
        let source = #"{"x":"[\"()]\u007b", "items":[1,2]}"#
        XCTAssertEqual(try BracketMatcher.match(in: source, atUTF16Offset: 0, policy: .json), pair(0, source.utf16.count - 1))
        let inside = (source as NSString).range(of: "[").location
        XCTAssertNil(try BracketMatcher.match(in: source, atUTF16Offset: inside, policy: .json))
        let arrayStart = (source as NSString).range(of: "[1").location
        XCTAssertEqual(try BracketMatcher.match(in: source, atUTF16Offset: arrayStart, policy: .json), pair(arrayStart, arrayStart + 4))
        XCTAssertNil(try BracketMatcher.match(in: #"["unterminated ]"#, atUTF16Offset: 0, policy: .json))
        XCTAssertThrowsError(try BracketMatcher.match(in: #"["\x41"]"#, atUTF16Offset: 0, policy: .json))
    }

    func testConservativeQuotesCommentsAndPlainBackticksAreOpaque() throws {
        let sources = [
            "(\"[}]\" + ']' + `plain template ]`)",
            "{ // ] )\n[] /* } ] */ }",
            "[ # ) }\u{2028} (0) ]",
            "{ \"\"\"multi\n }] \"\"\" [] }"
        ]
        for source in sources {
            let original = Array(source.utf16)
            XCTAssertEqual(try BracketMatcher.match(in: source, atUTF16Offset: 0, policy: .conservativeCode),
                           pair(0, source.utf16.count - 1), source)
            XCTAssertEqual(Array(source.utf16), original)
        }
        let source = "{ /* [ */ \"(\" # ]\n }"
        for marker in ["[", "(", "]"] {
            XCTAssertNil(try BracketMatcher.match(in: source, atUTF16Offset: (source as NSString).range(of: marker).location,
                                                 policy: .conservativeCode))
        }
    }

    func testConservativeModeDeclinesAmbiguousSyntax() {
        let sources = ["(a / b)", "( /[)]/ )", "(R\"tag(a\" ] )tag\")", "(r\"raw\")", "( <<EOF\n)\nEOF)",
                       #"("\u0022")"#, "( /* outer /* nested */ */ )", "('a\\'b')", "( \\\n )"]
        for source in sources {
            XCTAssertThrowsError(try BracketMatcher.match(in: source, atUTF16Offset: 0, policy: .conservativeCode), source) {
                guard case .unsupportedSyntax(let offset) = $0 as? BracketMatchError else { return XCTFail("Unexpected error: \($0)") }
                XCTAssertGreaterThanOrEqual(offset, 0)
                XCTAssertLessThan(offset, source.utf16.count)
            }
        }
        XCTAssertNil(try? BracketMatcher.match(in: "{ /* unterminated }", atUTF16Offset: 0, policy: .conservativeCode))
    }

    func testNestedInterpolationAndContinuedCommentsCannotExposeFalseClosingBrackets() {
        let sources = [
            #"(f"{value("}")}")"#,
            #"(rb"raw \" )")"#,
            #"(f'''{call("}")}''')"#,
            #"( $"value {Format("}")}" )"#,
            #"( @"verbatim "" ) "" " )"#,
            #"( `template ${`nested ${")"}`}` )"#,
            #"( "$(printf ")")" )"#,
            #"( "prefix \(")") suffix" )"#,
            #"( "before `printf ")"` after" )"#,
            "( // continued \\\n) hidden\n )",
            "( # continued \\\n) hidden\n )"
        ]
        for source in sources {
            XCTAssertThrowsError(try BracketMatcher.match(in: source, atUTF16Offset: 0, policy: .conservativeCode), source) {
                guard case .unsupportedSyntax(let offset) = $0 as? BracketMatchError else { return XCTFail("Unexpected error: \($0)") }
                XCTAssertGreaterThanOrEqual(offset, 0)
                XCTAssertLessThan(offset, source.utf16.count)
            }
        }
    }

    func testHashRawMultilineStringsRefuseHintsInsideAndAfterTheirBodies() throws {
        let delimiters = [
            ("#\"\"\"", "\"\"\"#"), ("##\"\"\"", "\"\"\"##"),
            ("r#\"", "\"#"), ("br##\"", "\"##"), ("cr#\"", "\"#")
        ]
        for (opening, closing) in delimiters {
            let source = "let 中文 = \(opening)\n🦊 () []\n\(closing);\nlet later = [0];"
            let original = Array(source.utf16)
            let body = (source as NSString).range(of: "()").location
            let later = (source as NSString).range(of: "[0]").location
            let firstHash = (source as NSString).range(of: "#").location
            for caret in [body, body + 1, later, later + 2] {
                XCTAssertThrowsError(try BracketMatcher.match(in: source, atUTF16Offset: caret,
                                                             policy: .conservativeCode), opening) {
                    XCTAssertEqual($0 as? BracketMatchError, .unsupportedSyntax(utf16Location: firstHash))
                }
            }
            // Plain text deliberately treats those same brackets as literal.
            XCTAssertEqual(try BracketMatcher.match(in: source, atUTF16Offset: body, policy: .literal),
                           pair(body, body + 1))
            XCTAssertEqual(Array(source.utf16), original)
        }
    }

    func testOrdinaryPythonAndShellHashCommentsStillAllowFollowingCodeHints() throws {
        let sources = [
            "# Python comment with () and \"quotes\"\n(value)",
            "# \"quoted prefix\" is still a comment\n(value)",
            "#!/bin/sh\r\n# shell comment { [ (\r\n(value)",
            "### heading with \"quotes\" ()\r(value)",
            "#\n(value)"
        ]
        for source in sources {
            let opening = (source as NSString).range(of: "(value)").location
            for caret in [opening, opening + 6] {
                XCTAssertEqual(try BracketMatcher.match(in: source, atUTF16Offset: caret,
                                                       policy: .conservativeCode), pair(opening, opening + 6), source)
            }
            let commentBracket = (source as NSString).range(of: "()").location
            if commentBracket != NSNotFound {
                XCTAssertNil(try BracketMatcher.match(in: source, atUTF16Offset: commentBracket,
                                                      policy: .conservativeCode), source)
            }
        }
    }

    func testLongHashPrefixRefusalRemainsCancellableAndBounded() {
        let source = String(repeating: "#", count: 2_998) + "\"\n()\n\""
        let caret = (source as NSString).range(of: "()").location
        XCTAssertThrowsError(try BracketMatcher.match(in: source, atUTF16Offset: caret,
                                                     policy: .conservativeCode)) {
            XCTAssertEqual($0 as? BracketMatchError, .unsupportedSyntax(utf16Location: 0))
        }
        let counter = BracketCancellationCounter(threshold: 8)
        XCTAssertThrowsError(try BracketMatcher.match(in: source, atUTF16Offset: caret,
                                                     policy: .conservativeCode, isCancelled: { counter.check() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try BracketMatcher.match(in: source, atUTF16Offset: 0,
                                                     policy: .conservativeCode, limits: .init(maximumUTF16Units: 2_048))) {
            XCTAssertEqual($0 as? BracketMatchError, .inputTooLarge(limit: 2_048))
        }
    }

    func testUnmatchedAndCrossedBracketsDoNotInventPairs() throws {
        for source in ["(", ")", "([)]", "{]}", "{[(]}"] {
            XCTAssertNil(try BracketMatcher.match(in: source, atUTF16Offset: 0), source)
        }
        XCTAssertEqual(try BracketMatcher.match(in: "] ()", atUTF16Offset: 2), pair(2, 3))
        XCTAssertNil(try BracketMatcher.match(in: "x ]", atUTF16Offset: 3))
    }

    func testInputAndDepthBudgetsAreHardBounds() throws {
        XCTAssertEqual(try BracketMatcher.match(in: "()", atUTF16Offset: 0, limits: .init(maximumUTF16Units: 2, maximumDepth: 1)), pair(0, 1))
        XCTAssertThrowsError(try BracketMatcher.match(in: "() ", atUTF16Offset: 0, limits: .init(maximumUTF16Units: 2))) {
            XCTAssertEqual($0 as? BracketMatchError, .inputTooLarge(limit: 2))
        }
        XCTAssertThrowsError(try BracketMatcher.match(in: "(())", atUTF16Offset: 0, limits: .init(maximumDepth: 1))) {
            XCTAssertEqual($0 as? BracketMatchError, .nestingTooDeep(limit: 1))
        }
        for limits in [BracketMatcher.Limits(maximumUTF16Units: -1), .init(maximumUTF16Units: 200 * 1_024 + 1),
                       .init(maximumDepth: 0), .init(maximumDepth: 513)] {
            XCTAssertThrowsError(try BracketMatcher.match(in: "", atUTF16Offset: 0, limits: limits)) {
                XCTAssertEqual($0 as? BracketMatchError, .invalidLimits)
            }
        }
    }

    func testCancellationDuringCollectionAndScanningIsNotWrapped() throws {
        XCTAssertThrowsError(try BracketMatcher.match(in: "()", atUTF16Offset: 0, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        let source = "(" + String(repeating: "a", count: 2_998) + ")"
        for threshold in [3, 8] {
            let counter = BracketCancellationCounter(threshold: threshold)
            XCTAssertThrowsError(try BracketMatcher.match(in: source, atUTF16Offset: 0, isCancelled: { counter.check() })) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
    }

    func testDefaultCancellationReadsTheCurrentTask() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BracketMatcher.match(in: "()", atUTF16Offset: 0)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancellationWithinOpaqueSpansRemainsBounded() {
        let body = String(repeating: "a", count: 2_998)
        for source in ["(\"" + body + "\")", "(/*" + body + "*/)", "(//" + body + "\n)"] {
            let counter = BracketCancellationCounter(threshold: 8)
            XCTAssertThrowsError(try BracketMatcher.match(in: source, atUTF16Offset: 0, policy: .conservativeCode,
                                                          isCancelled: { counter.check() })) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
    }

    private func pair(_ opening: Int, _ closing: Int) -> BracketPair {
        BracketPair(opening: NSRange(location: opening, length: 1), closing: NSRange(location: closing, length: 1))
    }
}

private final class BracketCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let threshold: Int
    init(threshold: Int) { self.threshold = threshold }
    func check() -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return count >= threshold }
}
