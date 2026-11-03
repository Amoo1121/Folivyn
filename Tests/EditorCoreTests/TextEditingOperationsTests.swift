import Foundation
import XCTest
@testable import EditorCore

final class TextEditingOperationsTests: XCTestCase {
    func testIndentTouchesOnlySelectedLogicalLinesAndPreservesMixedEndings() throws {
        let source = "before\nα\r\nβ\rγ\nlast"
        let start = (source as NSString).range(of: "α").location
        let end = (source as NSString).range(of: "last").location
        let edit = try XCTUnwrap(TextEditingOperations.plan(.indent(unit: "  "), in: source,
            selection: NSRange(location: start, length: end - start)))
        let result = try apply(edit, to: source)
        XCTAssertEqual(Array(result.utf8), Array("before\n  α\r\n  β\r  γ\nlast".utf8))
        XCTAssertEqual(edit.range.location, start)
        XCTAssertLessThan(NSMaxRange(edit.range), end, "The last line's unchanged content is outside the replacement")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "  α\r\n  β\r  γ\n")
        XCTAssertEqual(edit.selection, NSRange(location: start, length: end - start + 6))
    }

    func testSelectionEndingAtNextLineStartExcludesThatLine() throws {
        for ending in ["\n", "\r\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"] {
            let source = "one" + ending + "two"
            let originalSelection = NSRange(location: 0, length: 3 + ending.utf16.count)
            let edit = try XCTUnwrap(TextEditingOperations.plan(.indent(unit: "\t"), in: source,
                                                               selection: originalSelection))
            let result = try apply(edit, to: source)
            XCTAssertEqual(Array(result.utf16), Array(("\tone" + ending + "two").utf16))
            XCTAssertEqual(edit.selection, NSRange(location: 0, length: originalSelection.length + 1))
        }
    }

    func testCaretEmptyDocumentAndTrailingEmptyLine() throws {
        let empty = try XCTUnwrap(TextEditingOperations.plan(.indent(unit: "    "), in: "",
            selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(empty.range, NSRange(location: 0, length: 0))
        XCTAssertEqual(try apply(empty, to: ""), "    ")
        XCTAssertEqual(empty.selection, NSRange(location: 4, length: 0))

        let source = "🦊\r\n"
        let trailing = try XCTUnwrap(TextEditingOperations.plan(.indent(unit: "\t"), in: source,
            selection: NSRange(location: source.utf16.count, length: 0)))
        XCTAssertEqual(try apply(trailing, to: source), "🦊\r\n\t")
        XCTAssertEqual(trailing.selection, NSRange(location: 5, length: 0))

        let within = try XCTUnwrap(TextEditingOperations.plan(.indent(unit: "  "), in: "🦊 e\u{301}",
            selection: NSRange(location: 2, length: 0)))
        XCTAssertEqual(within.selection, NSRange(location: 4, length: 0))
        XCTAssertEqual(try apply(within, to: "🦊 e\u{301}"), "  🦊 e\u{301}")
    }

    func testPartialSelectionAndCaretInsideCRLFAreMappedWithoutSplittingEnding() throws {
        let source = "  alpha\r\n  beta"
        let selected = (source as NSString).range(of: "pha\r\n  be")
        let edit = try XCTUnwrap(TextEditingOperations.plan(.indent(unit: "  "), in: source, selection: selected))
        let result = try apply(edit, to: source)
        XCTAssertEqual(result, "    alpha\r\n    beta")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "pha\r\n    be")
        XCTAssertEqual(edit.selection.location, selected.location + 2)
        let crlf = try XCTUnwrap(TextEditingOperations.plan(.indent(unit: "\t"), in: "x\r\ny",
            selection: NSRange(location: 2, length: 0)))
        XCTAssertEqual(try apply(crlf, to: "x\r\ny"), "\tx\r\ny")
        XCTAssertEqual(crlf.selection, NSRange(location: 3, length: 0))
    }

    func testUnindentRemovesOneTabOrUpToConfiguredSpaces() throws {
        let source = "    a\r\n\tb\r  c\n d\nplain"
        let edit = try XCTUnwrap(TextEditingOperations.plan(.unindent(spaceWidth: 4), in: source,
            selection: NSRange(location: 0, length: source.utf16.count)))
        XCTAssertEqual(Array(try apply(edit, to: source).utf8), Array("a\r\nb\rc\nd\nplain".utf8))
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: source.utf16.count - 8))
        let mixedIndent = try XCTUnwrap(TextEditingOperations.plan(.unindent(spaceWidth: 4), in: "  \tvalue",
            selection: NSRange(location: 1, length: 0)))
        XCTAssertEqual(try apply(mixedIndent, to: "  \tvalue"), "\tvalue")
        XCTAssertEqual(mixedIndent.selection, NSRange(location: 0, length: 0), "A caret inside removed indentation clamps to its start")
        XCTAssertNil(try TextEditingOperations.plan(.unindent(spaceWidth: 4), in: "plain\n\n",
            selection: NSRange(location: 0, length: 7)))
    }

    func testCommentToggleUsesExplicitPrefixAndPreservesIndentationAndBlankLines() throws {
        let source = "  alpha\r\n\tbeta\r\n  \r\n# existing\n"
        let commented = try XCTUnwrap(TextEditingOperations.plan(.toggleLineComment(prefix: "#"), in: source,
            selection: NSRange(location: 0, length: source.utf16.count)))
        let result = try apply(commented, to: source)
        XCTAssertEqual(Array(result.utf8), Array("  # alpha\r\n\t# beta\r\n  \r\n# # existing\n".utf8))
        let uncommented = try XCTUnwrap(TextEditingOperations.plan(.toggleLineComment(prefix: "#"), in: result,
            selection: commented.selection))
        XCTAssertEqual(Array(try apply(uncommented, to: result).utf8), Array(source.utf8))
        XCTAssertEqual(uncommented.selection, NSRange(location: 0, length: source.utf16.count))
    }

    func testAlreadyCommentedLinesRemoveOnlyMarkerAndOneOptionalSpace() throws {
        let source = " // alpha\r\n\t//beta\n\n//  γ"
        let edit = try XCTUnwrap(TextEditingOperations.plan(.toggleLineComment(prefix: "//"), in: source,
            selection: NSRange(location: 0, length: source.utf16.count)))
        XCTAssertEqual(Array(try apply(edit, to: source).utf16), Array(" alpha\r\n\tbeta\n\n γ".utf16))
        let literal = try XCTUnwrap(TextEditingOperations.plan(.toggleLineComment(prefix: "--"), in: "// stays",
            selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(try apply(literal, to: "// stays"), "-- // stays", "There is no inferred language or marker")
    }

    func testBlankSelectionIsNoOpButBlankCaretCanStartAComment() throws {
        let source = "  \r\n\t\n"
        XCTAssertNil(try TextEditingOperations.plan(.toggleLineComment(prefix: "#"), in: source,
            selection: NSRange(location: 0, length: source.utf16.count)))
        let empty = try XCTUnwrap(TextEditingOperations.plan(.toggleLineComment(prefix: "#"), in: "",
            selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(try apply(empty, to: ""), "# ")
        XCTAssertEqual(empty.selection, NSRange(location: 2, length: 0))
        let indented = try XCTUnwrap(TextEditingOperations.plan(.toggleLineComment(prefix: "//"), in: "  ",
            selection: NSRange(location: 2, length: 0)))
        XCTAssertEqual(try apply(indented, to: "  "), "  // ")
        XCTAssertEqual(indented.selection, NSRange(location: 5, length: 0))
    }

    func testUnicodeSpellingAndEmojiRangesAreExact() throws {
        let source = "e\u{301}value\n中文 👩🏽‍💻"
        let edit = try XCTUnwrap(TextEditingOperations.plan(.toggleLineComment(prefix: "é"), in: source,
            selection: NSRange(location: 0, length: source.utf16.count)))
        XCTAssertEqual(Array(try apply(edit, to: source).utf16), Array("é e\u{301}value\né 中文 👩🏽‍💻".utf16),
                       "A canonically equivalent spelling is not the supplied literal marker")
        let original = "🦊e\u{301}\n"
        let emoji = try XCTUnwrap(TextEditingOperations.plan(.indent(unit: "  "), in: original,
            selection: NSRange(location: 0, length: 2)))
        XCTAssertEqual(emoji.selection, NSRange(location: 0, length: 4))
        XCTAssertEqual((try apply(emoji, to: original) as NSString).substring(with: emoji.selection), "  🦊")
    }

    func testInvalidSelectionAndParametersAreRejected() throws {
        for selection in [NSRange(location: -1, length: 0), NSRange(location: 0, length: -1),
                          NSRange(location: Int.max, length: Int.max), NSRange(location: 0, length: 3),
                          NSRange(location: 1, length: 0), NSRange(location: 0, length: 1)] {
            XCTAssertThrowsError(try TextEditingOperations.plan(.indent(unit: " "), in: "🦊", selection: selection)) {
                XCTAssertEqual($0 as? TextEditingOperationError, .invalidSelection)
            }
        }
        for unit in ["", "x", "\n", "\t ", String(repeating: " ", count: 17)] {
            XCTAssertThrowsError(try TextEditingOperations.plan(.indent(unit: unit), in: "", selection: .init(location: 0, length: 0))) {
                XCTAssertEqual($0 as? TextEditingOperationError, .invalidIndentation)
            }
        }
        for width in [0, -1, 17, Int.max] {
            XCTAssertThrowsError(try TextEditingOperations.plan(.unindent(spaceWidth: width), in: "", selection: .init(location: 0, length: 0))) {
                XCTAssertEqual($0 as? TextEditingOperationError, .invalidIndentation)
            }
        }
        for prefix in ["", "// ", "#\n", "#\r", "#\u{2028}", "\0", String(repeating: "/", count: 33)] {
            XCTAssertThrowsError(try TextEditingOperations.plan(.toggleLineComment(prefix: prefix), in: "", selection: .init(location: 0, length: 0))) {
                XCTAssertEqual($0 as? TextEditingOperationError, .invalidCommentPrefix)
            }
        }
    }

    func testResourceBudgetsFailBeforeReturningPartialEdits() throws {
        let caret = NSRange(location: 0, length: 0)
        XCTAssertThrowsError(try TextEditingOperations.plan(.indent(unit: " "), in: "abc", selection: caret,
            limits: .init(source: .init(maximumUTF16Units: 2)))) {
            XCTAssertEqual($0 as? TextLineIndexError, .sourceLimitExceeded(limit: 2))
        }
        XCTAssertThrowsError(try TextEditingOperations.plan(.indent(unit: " "), in: "a\nb\nc", selection: .init(location: 0, length: 5),
            limits: .init(maximumAffectedLines: 2))) {
            XCTAssertEqual($0 as? TextEditingOperationError, .affectedLineLimitExceeded(limit: 2))
        }
        XCTAssertThrowsError(try TextEditingOperations.plan(.indent(unit: "    "), in: "x", selection: caret,
            limits: .init(maximumReplacementUTF16Units: 3))) {
            XCTAssertEqual($0 as? TextEditingOperationError, .replacementLimitExceeded(limit: 3))
        }
        XCTAssertThrowsError(try TextEditingOperations.plan(.unindent(spaceWidth: 4), in: "    x", selection: caret,
            limits: .init(maximumReplacementUTF16Units: 3))) {
            XCTAssertEqual($0 as? TextEditingOperationError, .replacementLimitExceeded(limit: 3), "The expected-source slice is also bounded")
        }
        XCTAssertThrowsError(try TextEditingOperations.plan(.indent(unit: " "), in: "abc", selection: caret,
            limits: .init(source: .init(maximumUTF16Units: 3)))) {
            XCTAssertEqual($0 as? TextEditingOperationError, .resultLimitExceeded(limit: 3))
        }
        for limits in [TextEditingOperations.Limits(maximumAffectedLines: 0), .init(maximumAffectedLines: 100_001),
                       .init(maximumReplacementUTF16Units: -1), .init(maximumReplacementUTF16Units: 10 * 1_024 * 1_024 + 1)] {
            XCTAssertThrowsError(try TextEditingOperations.plan(.indent(unit: " "), in: "", selection: caret, limits: limits)) {
                XCTAssertEqual($0 as? TextEditingOperationError, .invalidLimits)
            }
        }
    }

    func testCancellationBeforeScanningAndDuringPlanningReturnsNoEdit() throws {
        let selection = NSRange(location: 0, length: 5)
        XCTAssertThrowsError(try TextEditingOperations.plan(.indent(unit: " "), in: "a\nb\nc", selection: selection,
            isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        // Three checks complete this short line index. The fourth check enters
        // operation planning, so cancellation is not confined to the index scan.
        let counter = EditingCancellationCounter(threshold: 4)
        XCTAssertThrowsError(try TextEditingOperations.plan(.toggleLineComment(prefix: "//"), in: "a\nb\nc", selection: selection,
            isCancelled: { counter.check() })) { XCTAssertTrue($0 is CancellationError) }
    }

    func testIndentThenUnindentRoundTripsVariedUnicodeAndSelections() throws {
        let bodies = ["中文", "🦊", "e\u{301}", "\talpha", "  β", "", "👩🏽‍💻"]
        let endings = ["\n", "\r\n", "\r", "\u{2028}"]
        for seed in 0..<40 {
            let source = (0..<7).map { bodies[($0 + seed) % bodies.count] + endings[($0 + seed) % endings.count] }.joined()
            let lines = try TextLineIndex.build(source)
            let first = 1 + seed % 5
            let last = first + 1 + seed % (7 - first)
            let start = try XCTUnwrap(lines.range(forLine: first)).location
            let end = try XCTUnwrap(lines.range(forLine: last, includingLineEnding: true))
            let selection = NSRange(location: start, length: NSMaxRange(end) - start)
            let indent = try XCTUnwrap(TextEditingOperations.plan(.indent(unit: "  "), in: source, selection: selection))
            let indented = try apply(indent, to: source)
            let unindent = try XCTUnwrap(TextEditingOperations.plan(.unindent(spaceWidth: 2), in: indented, selection: indent.selection))
            XCTAssertEqual(Array(try apply(unindent, to: indented).utf16), Array(source.utf16), "seed \(seed)")
            XCTAssertEqual(unindent.selection, selection, "seed \(seed)")
        }
    }

    private func apply(_ edit: TextEditingOperations.Edit, to source: String) throws -> String {
        let original = source as NSString
        XCTAssertEqual(Array(original.substring(with: edit.range).utf16), Array(edit.expectedSource.utf16))
        let result = original.replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertGreaterThanOrEqual(edit.selection.location, 0)
        XCTAssertGreaterThanOrEqual(edit.selection.length, 0)
        XCTAssertLessThanOrEqual(NSMaxRange(edit.selection), result.utf16.count)
        // The single-range contract leaves everything outside its bounds exact.
        let suffixStart = edit.range.location + edit.replacement.utf16.count
        XCTAssertEqual(Array((result as NSString).substring(to: edit.range.location).utf16),
                       Array(original.substring(to: edit.range.location).utf16))
        XCTAssertEqual(Array((result as NSString).substring(from: suffixStart).utf16),
                       Array(original.substring(from: NSMaxRange(edit.range)).utf16))
        return result
    }
}

private final class EditingCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let threshold: Int
    init(threshold: Int) { self.threshold = threshold }
    func check() -> Bool {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count >= threshold
    }
}
