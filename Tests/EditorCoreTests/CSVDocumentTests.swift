import Foundation
import XCTest
@testable import EditorCore

final class CSVDocumentTests: XCTestCase {
    func testValuesStayStringsAndUnicodeRangesUseUTF16() throws {
        let source = "中文🦊,00123,9223372036854775808123,2026-10-27,\"=SUM(1,2)\",e\u{301}"
        let document = try CSVDocument.parse(source, delimiter: .comma)
        XCTAssertEqual(document.records.count, 1)
        XCTAssertEqual(document.records[0].fields.map(\.value), [
            "中文🦊", "00123", "9223372036854775808123", "2026-10-27", "=SUM(1,2)", "e\u{301}"
        ])
        XCTAssertEqual(document.records[0].fields[0].rawRange, NSRange(location: 0, length: 4))
        XCTAssertEqual(document.records[0].fields[1].rawRange, NSRange(location: 5, length: 5))
        let nsSource = source as NSString
        for field in document.records[0].fields {
            let raw = nsSource.substring(with: field.rawRange)
            XCTAssertEqual(try CSVDocument.parse(raw, delimiter: .comma).records[0].fields[0].value, field.value)
        }
    }

    func testQuotedEscapesAndEmbeddedLineBreaksDoNotSplitRecords() throws {
        let source = "id,text\r\n1,\"first\r\n第二行 🦊\nthird\"\r\n2,\"say \"\"hello\"\"\"\n3,last\r"
        let document = try CSVDocument.parse(source, delimiter: .comma)
        XCTAssertEqual(document.records.count, 4)
        XCTAssertEqual(document.records[1].fields[1].value, "first\r\n第二行 🦊\nthird")
        XCTAssertEqual(document.records[2].fields[1].value, "say \"hello\"")
        XCTAssertEqual(document.records.map { (source as NSString).substring(with: $0.terminatorRange) }, ["\r\n", "\r\n", "\n", "\r"])
        XCTAssertEqual((source as NSString).substring(with: document.records[2].rawRange), "2,\"say \"\"hello\"\"\"")
    }

    func testDelimiterIsExplicitAndTSVUsesTheSameQuoteRules() throws {
        let source = "a,b\t\"c\td\"\t\"e\"\"f\"\n1\t2\t"
        let document = try CSVDocument.parse(source, delimiter: .tab)
        XCTAssertEqual(document.records[0].fields.map(\.value), ["a,b", "c\td", "e\"f"])
        XCTAssertEqual(document.records[1].fields.map(\.value), ["1", "2", ""])
        XCTAssertThrowsError(try CSVDocument.parse(source, delimiter: .comma))
        let edit = try document.replacement(row: 1, column: 1, value: "x\ty")
        XCTAssertEqual(edit.escapedReplacement, "\"x\ty\"")
    }

    func testEmptyQuotedEmptyMissingAndTrailingFieldsRemainDistinct() throws {
        let source = "a,b,c\n1,,\n2\n\"\",x\n\n"
        let document = try CSVDocument.parse(source, delimiter: .comma)
        XCTAssertEqual(document.records.map(\.fields.count), [3, 3, 1, 2, 1])
        XCTAssertEqual(document.maximumColumnCount, 3)
        XCTAssertEqual(document.field(row: 1, column: 1)?.value, "")
        XCTAssertEqual(document.field(row: 1, column: 2)?.value, "")
        XCTAssertEqual(document.field(row: 1, column: 2)?.rawRange.length, 0)
        XCTAssertNil(document.field(row: 2, column: 1))
        XCTAssertEqual(document.field(row: 3, column: 0)?.value, "")
        XCTAssertEqual(document.field(row: 3, column: 0)?.rawRange.length, 2)
        XCTAssertTrue(try XCTUnwrap(document.field(row: 3, column: 0)).isQuoted)
        XCTAssertThrowsError(try document.replacement(row: 2, column: 1, value: "new")) {
            XCTAssertEqual($0 as? CSVDocumentError, .missingField(row: 2, column: 1))
        }
        XCTAssertTrue(try CSVDocument.parse("", delimiter: .comma).records.isEmpty)
        XCTAssertEqual(try CSVDocument.parse(",", delimiter: .comma).records[0].fields.map(\.value), ["", ""])
        XCTAssertEqual(try CSVDocument.parse("\n", delimiter: .comma).records.count, 1)
    }

    func testSingleFieldReplacementPreservesEveryUneditedByte() throws {
        let source = "\"header\",n,formula\r\n\"中文 🦊\",00123,=A1\nlast,,\r\n"
        let document = try CSVDocument.parse(source, delimiter: .comma)
        let edit = try document.replacement(row: 1, column: 1, value: "new,\"value\"\nnext")
        XCTAssertEqual(edit.expectedSource, "00123")
        XCTAssertEqual(edit.escapedReplacement, "\"new,\"\"value\"\"\nnext\"")
        let edited = (source as NSString).replacingCharacters(in: edit.range, with: edit.escapedReplacement)
        let expected = "\"header\",n,formula\r\n\"中文 🦊\",\"new,\"\"value\"\"\nnext\",=A1\nlast,,\r\n"
        XCTAssertEqual(Data(edited.utf8), Data(expected.utf8))
        let reparsed = try CSVDocument.parse(edited, delimiter: .comma)
        XCTAssertEqual(reparsed.records.count, document.records.count)
        XCTAssertEqual(reparsed.records[1].fields[1].value, "new,\"value\"\nnext")
        let unchanged = try document.replacement(row: 0, column: 0, value: "header")
        XCTAssertEqual(unchanged.escapedReplacement, "\"header\"")
        XCTAssertEqual(Data((source as NSString).replacingCharacters(in: unchanged.range, with: unchanged.escapedReplacement).utf8), Data(source.utf8))
    }

    func testCanonicalUnicodeChangeIsNotMistakenForAnUnchangedCell() throws {
        let source = "id,e\u{301}\n"
        let document = try CSVDocument.parse(source, delimiter: .comma)
        let edit = try document.replacement(row: 0, column: 1, value: "é")
        XCTAssertEqual(Array(edit.expectedSource.utf16), [0x65, 0x301])
        XCTAssertEqual(Array(edit.escapedReplacement.utf16), [0xE9])
    }

    func testEmptyingTheOnlyFieldInFinalRowDoesNotDeleteTheRecord() throws {
        for source in ["x", "header\nx", "header\r\nx"] {
            let document = try CSVDocument.parse(source, delimiter: .comma)
            let lastRow = document.records.count - 1
            let edit = try document.replacement(row: lastRow, column: 0, value: "")
            XCTAssertEqual(edit.escapedReplacement, "\"\"")
            let edited = (source as NSString).replacingCharacters(in: edit.range, with: edit.escapedReplacement)
            let reparsed = try CSVDocument.parse(edited, delimiter: .comma)
            XCTAssertEqual(reparsed.records.count, document.records.count)
            XCTAssertEqual(reparsed.records[lastRow].fields.count, 1)
            XCTAssertEqual(reparsed.records[lastRow].fields[0].value, "")
        }
        let terminated = try CSVDocument.parse("x\n", delimiter: .comma)
        XCTAssertEqual(try terminated.replacement(row: 0, column: 0, value: "").escapedReplacement, "")
        let trailingColumn = try CSVDocument.parse("x,y", delimiter: .comma)
        XCTAssertEqual(try trailingColumn.replacement(row: 0, column: 1, value: "").escapedReplacement, "")
    }

    func testLocalReplacementPreservesBOMAndEncodingThroughDocumentFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CSVDocumentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = "\"中文🦊\",00123,\r\nlast,x\n"
        let expected = "\"中文🦊\",00099,\r\nlast,x\n"
        for encoding in TextFileEncoding.allCases {
            let url = directory.appendingPathComponent(encoding.rawValue)
            _ = try DocumentFile.save(original, to: url, encoding: encoding)
            let loaded = try DocumentFile.read(url)
            let parsed = try CSVDocument.parse(loaded.text, delimiter: .comma)
            let edit = try parsed.replacement(row: 0, column: 1, value: "00099")
            let newText = (loaded.text as NSString).replacingCharacters(in: edit.range, with: edit.escapedReplacement)
            _ = try DocumentFile.save(newText, to: url, encoding: loaded.encoding, expectedSnapshot: loaded.diskSnapshot)
            let expectedURL = directory.appendingPathComponent("expected-\(encoding.rawValue)")
            _ = try DocumentFile.save(expected, to: expectedURL, encoding: encoding)
            XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: expectedURL))
        }
    }

    func testInvalidQuotesReportPhysicalLineAndUTF16Position() throws {
        let cases: [(String, CSVDocumentError)] = [
            ("a,b\"c", .quoteInUnquotedField(position: CSVSourcePosition(utf16Offset: 3, line: 1, column: 4))),
            ("🙂,\"x\"oops", .charactersAfterClosingQuote(position: CSVSourcePosition(utf16Offset: 6, line: 1, column: 7))),
            ("first\r\n\"good\nbad", .unclosedQuotedField(position: CSVSourcePosition(utf16Offset: 7, line: 2, column: 1))),
            ("\"a\" ,b", .charactersAfterClosingQuote(position: CSVSourcePosition(utf16Offset: 3, line: 1, column: 4))),
            ("a\r\nb\n  \"c", .quoteInUnquotedField(position: CSVSourcePosition(utf16Offset: 7, line: 3, column: 3)))
        ]
        for (source, expected) in cases {
            XCTAssertThrowsError(try CSVDocument.parse(source, delimiter: .comma)) {
                XCTAssertEqual($0 as? CSVDocumentError, expected)
            }
        }
    }

    func testByteRecordColumnAndTotalFieldBudgetsFailSafely() throws {
        XCTAssertThrowsError(try CSVDocument.parse("中", delimiter: .comma, limits: CSVLimits(maximumUTF8Bytes: 2))) {
            XCTAssertEqual($0 as? CSVDocumentError, .byteLimitExceeded(limit: 2))
        }
        XCTAssertNoThrow(try CSVDocument.parse("中", delimiter: .comma, limits: CSVLimits(maximumUTF8Bytes: 3)))
        XCTAssertThrowsError(try CSVDocument.parse("a\nb\nc", delimiter: .comma, limits: CSVLimits(maximumRecords: 2))) {
            XCTAssertEqual($0 as? CSVDocumentError, .recordLimitExceeded(limit: 2, position: CSVSourcePosition(utf16Offset: 4, line: 3, column: 1)))
        }
        XCTAssertNoThrow(try CSVDocument.parse("a\nb\n", delimiter: .comma, limits: CSVLimits(maximumRecords: 2)))
        XCTAssertThrowsError(try CSVDocument.parse("a,b,", delimiter: .comma, limits: CSVLimits(maximumColumns: 2))) {
            XCTAssertEqual($0 as? CSVDocumentError, .columnLimitExceeded(limit: 2, position: CSVSourcePosition(utf16Offset: 4, line: 1, column: 5)))
        }
        XCTAssertThrowsError(try CSVDocument.parse("a,b\nc,d", delimiter: .comma, limits: CSVLimits(maximumFields: 3))) {
            XCTAssertEqual($0 as? CSVDocumentError, .fieldLimitExceeded(limit: 3, position: CSVSourcePosition(utf16Offset: 6, line: 2, column: 3)))
        }
        XCTAssertThrowsError(try CSVDocument.parse("", delimiter: .comma, limits: CSVLimits(maximumRecords: 0))) {
            XCTAssertEqual($0 as? CSVDocumentError, .invalidLimits)
        }
        let document = try CSVDocument.parse("a,b", delimiter: .comma, limits: CSVLimits(maximumUTF8Bytes: 4))
        XCTAssertThrowsError(try document.replacement(row: 0, column: 0, value: ",")) {
            XCTAssertEqual($0 as? CSVDocumentError, .byteLimitExceeded(limit: 4))
        }
    }

    func testCancellationIsObservedBeforeAndDuringLongQuotedFields() throws {
        XCTAssertThrowsError(try CSVDocument.parse("x", delimiter: .comma, isCancelled: { true })) {
            XCTAssertEqual($0 as? CSVDocumentError, .cancelled)
        }
        let source = "\"" + String(repeating: "a\"\"b", count: 5_000) + "\""
        var checks = 0
        XCTAssertThrowsError(try CSVDocument.parse(source, delimiter: .comma, isCancelled: {
            checks += 1
            // Initial + UTF-8-count checks complete first; this cancels inside
            // the quoted-field state machine, including its two-unit escapes.
            return checks == 12
        })) {
            XCTAssertEqual($0 as? CSVDocumentError, .cancelled)
        }
        XCTAssertEqual(checks, 12)
        let document = try CSVDocument.parse("x", delimiter: .comma)
        XCTAssertThrowsError(try document.replacement(row: 0, column: 0, value: "y", isCancelled: { true })) {
            XCTAssertEqual($0 as? CSVDocumentError, .cancelled)
        }
    }
}
