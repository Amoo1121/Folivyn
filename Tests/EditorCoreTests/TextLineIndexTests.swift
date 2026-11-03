import Foundation
import XCTest
@testable import EditorCore

final class TextLineIndexTests: XCTestCase {
    func testEmptySingleAndTrailingEmptyLines() throws {
        let empty = try TextLineIndex.build("")
        XCTAssertEqual(empty.lineCount, 1)
        XCTAssertEqual(empty.newlineStyle, .none)
        XCTAssertEqual(empty.range(forLine: 1), NSRange(location: 0, length: 0))
        XCTAssertEqual(empty.lineNumber(atUTF16Offset: 0), 1)
        let single = try TextLineIndex.build("abc")
        XCTAssertEqual(single.lineCount, 1)
        XCTAssertEqual(single.range(forLine: 1), NSRange(location: 0, length: 3))
        XCTAssertEqual(single.lineNumber(atUTF16Offset: 3), 1)
        let trailing = try TextLineIndex.build("abc\n\n")
        XCTAssertEqual(trailing.lineCount, 3)
        XCTAssertEqual(trailing.range(forLine: 1), NSRange(location: 0, length: 3))
        XCTAssertEqual(trailing.range(forLine: 2), NSRange(location: 4, length: 0))
        XCTAssertEqual(trailing.range(forLine: 3), NSRange(location: 5, length: 0))
        XCTAssertEqual(trailing.lineNumber(atUTF16Offset: 5), 3)
    }

    func testEveryEndingAndMixedStylesPreserveSourceRanges() throws {
        let cases: [(String, TextLineIndex.NewlineStyle)] = [
            ("\n", .lf), ("\r\n", .crlf), ("\r", .cr), ("\u{85}", .nel),
            ("\u{2028}", .lineSeparator), ("\u{2029}", .paragraphSeparator)
        ]
        for (ending, style) in cases {
            let text = "a" + ending + "b" + ending
            let original = Array(text.utf16)
            let index = try TextLineIndex.build(text)
            XCTAssertEqual(index.newlineStyle, style)
            XCTAssertEqual(index.lineCount, 3)
            XCTAssertEqual(index.range(forLine: 1), NSRange(location: 0, length: 1))
            XCTAssertEqual(index.range(forLine: 1, includingLineEnding: true), NSRange(location: 0, length: 1 + ending.utf16.count))
            XCTAssertEqual(index.range(forLine: 2), NSRange(location: 1 + ending.utf16.count, length: 1))
            XCTAssertEqual(index.range(forLine: 3), NSRange(location: text.utf16.count, length: 0))
            XCTAssertEqual(Array(text.utf16), original)
        }
        let mixed = try TextLineIndex.build("a\r\nb\rc\nd\u{85}e\u{2028}f\u{2029}")
        XCTAssertEqual(mixed.newlineStyle, .mixed)
        XCTAssertEqual(mixed.lineCount, 7)
        XCTAssertEqual(try TextLineIndex.build("a\r\nb\r\n").newlineStyle, .crlf)
    }

    func testCRLFBoundaryBelongsToPrecedingLineAndStandaloneCRIsResolved() throws {
        let index = try TextLineIndex.build("x\r\ny\r\r\nz\r")
        XCTAssertEqual(index.lineCount, 5)
        XCTAssertEqual((0...index.utf16Count).map { index.lineNumber(atUTF16Offset: $0) },
                       [1, 1, 1, 2, 2, 3, 3, 4, 4, 5])
        XCTAssertEqual(index.range(forLine: 3), NSRange(location: 5, length: 0))
        XCTAssertEqual(index.range(forLine: 3, includingLineEnding: true), NSRange(location: 5, length: 2))
    }

    func testUnicodeOffsetsAndExplicitJumpClamping() throws {
        let index = try TextLineIndex.build("🦊e\u{301}\r\n中文\u{2028}👩🏽‍💻")
        XCTAssertEqual(index.range(forLine: 1), NSRange(location: 0, length: 4))
        XCTAssertEqual(index.range(forLine: 2), NSRange(location: 6, length: 2))
        XCTAssertEqual(index.range(forLine: 3), NSRange(location: 9, length: 7))
        XCTAssertEqual(index.insertionRange(forLine: 3), NSRange(location: 9, length: 0))
        XCTAssertNil(index.insertionRange(forLine: 0))
        XCTAssertNil(index.range(forLine: -1))
        XCTAssertNil(index.range(forLine: Int.max))
        XCTAssertNil(index.lineNumber(atUTF16Offset: -1))
        XCTAssertNil(index.lineNumber(atUTF16Offset: Int.max))
        XCTAssertEqual(index.insertionRange(forLine: Int.min, clamping: true), NSRange(location: 0, length: 0))
        XCTAssertEqual(index.insertionRange(forLine: Int.max, clamping: true), NSRange(location: 9, length: 0))
        for offset in 0...5 { XCTAssertEqual(index.lineNumber(atUTF16Offset: offset), 1) }
    }

    func testBudgetsRejectWithoutPublishingPartialIndex() throws {
        XCTAssertNoThrow(try TextLineIndex.build("", limits: .init(maximumUTF16Units: 0, maximumLines: 1)))
        XCTAssertNoThrow(try TextLineIndex.build("🦊", limits: .init(maximumUTF16Units: 2)))
        XCTAssertThrowsError(try TextLineIndex.build("🦊", limits: .init(maximumUTF16Units: 1))) {
            XCTAssertEqual($0 as? TextLineIndexError, .sourceLimitExceeded(limit: 1))
        }
        XCTAssertNoThrow(try TextLineIndex.build("a\r\nb", limits: .init(maximumLines: 2)))
        XCTAssertThrowsError(try TextLineIndex.build("a\r\nb\r", limits: .init(maximumLines: 2))) {
            XCTAssertEqual($0 as? TextLineIndexError, .lineLimitExceeded(limit: 2))
        }
        for limits in [TextLineIndex.Limits(maximumUTF16Units: -1), .init(maximumUTF16Units: 10 * 1_024 * 1_024 + 1),
                       .init(maximumLines: 0), .init(maximumLines: 1_000_001)] {
            XCTAssertThrowsError(try TextLineIndex.build("", limits: limits)) {
                XCTAssertEqual($0 as? TextLineIndexError, .invalidLimits)
            }
        }
    }

    func testCancellationBeforeDuringAndAfterScanIsNotWrapped() throws {
        XCTAssertThrowsError(try TextLineIndex.build("", isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        let counter = LineCancellationCounter(threshold: 3)
        XCTAssertThrowsError(try TextLineIndex.build(String(repeating: "a", count: 20_000), isCancelled: { counter.check() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        let final = LineCancellationCounter(threshold: 3)
        XCTAssertThrowsError(try TextLineIndex.build("a", isCancelled: { final.check() })) { XCTAssertTrue($0 is CancellationError) }
    }

    func testLargeIndexSupportsBoundedLookups() throws {
        let source = String(repeating: "a\r\n", count: 99_999)
        let index = try TextLineIndex.build(source)
        XCTAssertEqual(index.lineCount, 100_000)
        XCTAssertEqual(index.newlineStyle, .crlf)
        XCTAssertEqual(index.insertionRange(forLine: 100_000), NSRange(location: source.utf16.count, length: 0))
        for line in stride(from: 1, through: index.lineCount, by: 997) {
            let start = try XCTUnwrap(index.insertionRange(forLine: line))
            XCTAssertEqual(index.lineNumber(atUTF16Offset: start.location), line)
        }
    }
}

private final class LineCancellationCounter: @unchecked Sendable {
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
