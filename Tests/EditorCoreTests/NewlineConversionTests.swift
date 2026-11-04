import Foundation
import XCTest
@testable import EditorCore

final class NewlineConversionTests: XCTestCase {
    func testMixedCRLFCRAndLFAreConvertedOnlyOnExplicitCall() throws {
        let source = "a\r\nb\rc\n"
        let original = Array(source.utf16)
        for (target, expected) in [(NewlineConversion.Target.lf, "a\nb\nc\n"),
                                   (.crlf, "a\r\nb\r\nc\r\n"), (.cr, "a\rb\rc\r")] {
            let result = try NewlineConversion.convert(source, to: target)
            XCTAssertEqual(Array(result.text.utf16), Array(expected.utf16))
            XCTAssertEqual(result.sourceUTF16Count, source.utf16.count)
            XCTAssertEqual(result.changedNewlineCount, 2)
            XCTAssertTrue(result.isChanged)
            XCTAssertNil(result.selection)
        }
        XCTAssertEqual(Array(source.utf16), original)
    }

    func testNoopAndEndingSequencesPreserveTrailingAndEmptyLines() throws {
        for target in NewlineConversion.Target.allCases {
            let ending: String
            switch target { case .lf: ending = "\n"; case .crlf: ending = "\r\n"; case .cr: ending = "\r" }
            for source in ["", "no ending", ending, ending + ending, "a" + ending] {
                let result = try NewlineConversion.convert(source, to: target)
                XCTAssertFalse(result.isChanged)
                XCTAssertEqual(Array(result.text.utf16), Array(source.utf16))
            }
        }
        XCTAssertEqual(try NewlineConversion.convert("\r\na\r\n\r\n", to: .lf).text, "\na\n\n")
        XCTAssertEqual(try NewlineConversion.convert("a\n\r", to: .crlf).text, "a\r\n\r\n")
    }

    func testUnicodeSeparatorsBOMAndCanonicalSpellingsAreNotNormalized() throws {
        let payload = "\u{FEFF}中🦊👩🏽‍💻e\u{301}é\u{85}\u{2028}\u{2029}\0"
        let result = try NewlineConversion.convert(payload + "\r\n" + payload + "\r", to: .lf)
        XCTAssertEqual(Array(result.text.utf16), Array((payload + "\n" + payload + "\n").utf16))
        XCTAssertEqual(result.changedNewlineCount, 2)
        let unchanged = try NewlineConversion.convert(payload, to: .crlf)
        XCTAssertFalse(unchanged.isChanged)
        XCTAssertEqual(Array(unchanged.text.utf16), Array(payload.utf16))
    }

    func testSelectionMappingIncludesEOFExpansionAndCRLFInteriorRule() throws {
        let source = "a\r\nb\nc\rd"
        for (target, offsets) in [(NewlineConversion.Target.lf, [0, 1, 2, 2, 3, 4, 5, 6, 7]),
                                  (.cr, [0, 1, 2, 2, 3, 4, 5, 6, 7]),
                                  (.crlf, [0, 1, 2, 3, 4, 6, 7, 9, 10])] {
            for (offset, mapped) in offsets.enumerated() {
                let result = try NewlineConversion.convert(source, to: target, selection: NSRange(location: offset, length: 0))
                XCTAssertEqual(result.selection, NSRange(location: mapped, length: 0))
            }
        }
        XCTAssertEqual(try NewlineConversion.convert(source, to: .lf, selection: NSRange(location: 0, length: 8)).selection,
                       NSRange(location: 0, length: 7))
        XCTAssertEqual(try NewlineConversion.convert(source, to: .lf, selection: NSRange(location: 1, length: 1)).selection,
                       NSRange(location: 1, length: 1))
        XCTAssertEqual(try NewlineConversion.convert(source, to: .lf, selection: NSRange(location: 2, length: 1)).selection,
                       NSRange(location: 2, length: 0))
    }

    func testSelectionRejectsInvalidAndSurrogateSplittingRanges() throws {
        let source = "🦊\r\n中"
        for range in [NSRange(location: -1, length: 0), NSRange(location: 0, length: -1),
                      NSRange(location: 6, length: 0), NSRange(location: 0, length: 6),
                      NSRange(location: Int.max, length: 1), NSRange(location: 1, length: 0),
                      NSRange(location: 0, length: 1)] {
            XCTAssertThrowsError(try NewlineConversion.convert(source, to: .lf, selection: range)) {
                XCTAssertEqual($0 as? NewlineConversionError, .invalidSelection)
            }
        }
        XCTAssertEqual(try NewlineConversion.convert(source, to: .lf, selection: NSRange(location: 2, length: 3)).selection,
                       NSRange(location: 2, length: 2))
        XCTAssertEqual(try NewlineConversion.convert("", to: .lf, selection: NSRange(location: 0, length: 0)).selection,
                       NSRange(location: 0, length: 0))
    }

    func testSeparateInputAndExpandedOutputBudgetsAreEnforced() throws {
        XCTAssertEqual(try NewlineConversion.convert("\n", to: .crlf,
            limits: .init(maximumInputUTF16Units: 1, maximumOutputUTF16Units: 2)).text, "\r\n")
        XCTAssertThrowsError(try NewlineConversion.convert("\n", to: .crlf,
            limits: .init(maximumInputUTF16Units: 1, maximumOutputUTF16Units: 1))) {
            XCTAssertEqual($0 as? NewlineConversionError, .outputLimitExceeded(limit: 1))
        }
        XCTAssertThrowsError(try NewlineConversion.convert("\r\n", to: .lf,
            limits: .init(maximumInputUTF16Units: 1, maximumOutputUTF16Units: 1))) {
            XCTAssertEqual($0 as? NewlineConversionError, .inputLimitExceeded(limit: 1))
        }
        XCTAssertThrowsError(try NewlineConversion.convert("ab", to: .lf,
            limits: .init(maximumInputUTF16Units: 1, maximumOutputUTF16Units: 2))) {
            XCTAssertEqual($0 as? NewlineConversionError, .inputLimitExceeded(limit: 1))
        }
        XCTAssertFalse(try NewlineConversion.convert("", to: .lf,
            limits: .init(maximumInputUTF16Units: 0, maximumOutputUTF16Units: 0)).isChanged)
        for limits in [NewlineConversion.Limits(maximumInputUTF16Units: -1),
                       .init(maximumOutputUTF16Units: -1), .init(maximumInputUTF16Units: 10_485_761),
                       .init(maximumOutputUTF16Units: 10_485_761)] {
            XCTAssertThrowsError(try NewlineConversion.convert("", to: .lf, limits: limits)) {
                XCTAssertEqual($0 as? NewlineConversionError, .invalidLimits)
            }
        }
    }

    func testCancellationAcrossPairedEndingsAndBeforePublishingIsNotWrapped() {
        let source = String(repeating: "\r\n", count: 10_000)
        for threshold in [1, 3, 7] {
            let counter = NewlineCancellationCounter(threshold: threshold)
            XCTAssertThrowsError(try NewlineConversion.convert(source, to: .lf, isCancelled: { counter.check() })) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
    }

    func testDefaultCancellationReadsCurrentTask() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try NewlineConversion.convert("a\r\n", to: .lf)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class NewlineCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let threshold: Int
    private var count = 0
    init(threshold: Int) { self.threshold = threshold }
    func check() -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return count >= threshold }
}
