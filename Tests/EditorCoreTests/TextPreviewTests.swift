import Darwin
import Foundation
import XCTest
@testable import EditorCore

final class TextPreviewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TextPreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func file(_ bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        return url
    }

    func testEncodingsBOMAndEmptyFiles() throws {
        for text in ["", "中文 🦊 e\u{301}\r\nsecond"] {
            let variants: [(TextFileEncoding, Data)] = [
                (.utf8, Data(text.utf8)),
                (.utf8BOM, Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)),
                (.utf16LittleEndianBOM, Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!),
                (.utf16BigEndianBOM, Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!)
            ]
            for (encoding, bytes) in variants {
                let url = try file(bytes)
                let preview = try TextPreview.read(url)
                XCTAssertEqual(preview.text, text)
                XCTAssertEqual(preview.encoding, encoding)
                XCTAssertFalse(preview.truncated)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
    }

    func testUTF8BudgetCutsOnlyAtScalarBoundariesIncludingWithBOM() throws {
        for bom in [Data(), Data([0xEF, 0xBB, 0xBF])] {
            let url = try file(bom + Data("a中🦊z".utf8))
            let expected = [1: "a", 2: "a", 3: "a", 4: "a中", 5: "a中", 6: "a中", 7: "a中", 8: "a中🦊", 9: "a中🦊z"]
            for budget in 1...9 {
                let preview = try TextPreview.read(url, byteLimit: budget)
                XCTAssertEqual(preview.text, expected[budget])
                XCTAssertEqual(preview.truncated, budget < 9)
            }
        }
    }

    func testUTF16BudgetCutsOnlyAtUnitAndSurrogateBoundaries() throws {
        for (bom, encoding) in [(Data([0xFF, 0xFE]), String.Encoding.utf16LittleEndian), (Data([0xFE, 0xFF]), .utf16BigEndian)] {
            let url = try file(bom + "a🦊z".data(using: encoding)!)
            let expected = [1: "", 2: "a", 3: "a", 4: "a", 5: "a", 6: "a🦊", 7: "a🦊", 8: "a🦊z"]
            for budget in 1...8 {
                let preview = try TextPreview.read(url, byteLimit: budget)
                XCTAssertEqual(preview.text, expected[budget])
                XCTAssertEqual(preview.truncated, budget < 8)
            }
        }
    }

    func testInvalidEncodingInsidePrefixAndAcrossBoundaryIsNeverRepaired() throws {
        let invalid: [(Data, Int)] = [
            (Data([0x61, 0xC0, 0xAF, 0x62]), 20),
            (Data([0x61, 0xE0, 0x80, 0x80]), 2),
            (Data([0x61, 0xED, 0xA0, 0x80]), 2),
            (Data([0x61, 0xF0, 0x80, 0x80, 0x80]), 2),
            (Data([0x61, 0xF4, 0x90, 0x80, 0x80]), 2),
            (Data([0x61, 0xE4, 0x62, 0x63]), 2),
            (Data([0x61, 0xF0, 0x9F]), 2),
            (Data([0x61, 0x80, 0x62]), 20),
            (Data([0xFF, 0xFE, 0x61]), 20),
            (Data([0xFF, 0xFE, 0x00, 0xD8]), 1),
            (Data([0xFF, 0xFE, 0x00, 0xD8, 0x61, 0]), 1),
            (Data([0xFE, 0xFF, 0xDC, 0x00]), 20)
        ]
        for (bytes, budget) in invalid {
            let url = try file(bytes)
            XCTAssertThrowsError(try TextPreview.read(url, byteLimit: budget)) {
                XCTAssertEqual($0 as? DocumentFileError, .invalidTextEncoding)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testLineBudgetPreservesLFCRLFAndCR() throws {
        for separator in ["\n", "\r\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"] {
            let firstTwo = "first\(separator)second\(separator)"
            let complete = try file(Data(firstTwo.utf8))
            let additional = try file(Data((firstTwo + "third").utf8))
            let exact = try TextPreview.read(complete, lineLimit: 2)
            XCTAssertEqual(exact.text, firstTwo)
            XCTAssertFalse(exact.truncated)
            let cut = try TextPreview.read(additional, lineLimit: 2)
            XCTAssertEqual(cut.text, firstTwo)
            XCTAssertTrue(cut.truncated)
        }
    }

    func testHugeSparseFileUsesOnlyBoundedPrefixWithoutReadingInvalidTail() throws {
        let prefix = String(repeating: "a", count: TextPreview.defaultByteLimit + 8)
        let url = try file(Data(prefix.utf8))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 8 * 1_024 * 1_024 * 1_024)
        try handle.write(contentsOf: Data([0xFF]))
        try handle.close()
        let preview = try TextPreview.read(url)
        XCTAssertEqual(preview.text, String(repeating: "a", count: TextPreview.defaultByteLimit))
        XCTAssertTrue(preview.truncated)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, 8 * 1_024 * 1_024 * 1_024 + 1)
    }

    func testDefaultLineLimitAlsoAppliesWhenByteLimitIsNotReached() throws {
        let url = try file(Data(String(repeating: "line\n", count: 3_000).utf8))
        let preview = try TextPreview.read(url)
        XCTAssertEqual(preview.text, String(repeating: "line\n", count: 2_000))
        XCTAssertTrue(preview.truncated)
    }

    func testBinaryControlsAreRejectedInUTF8AndUTF16() throws {
        for text in ["prefix\0suffix", "prefix\u{01}suffix", "MZ\u{07}"] {
            for bytes in [Data(text.utf8), Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!] {
                let url = try file(bytes)
                XCTAssertThrowsError(try TextPreview.read(url)) {
                    XCTAssertEqual($0 as? TextPreviewError, .binaryContent)
                }
            }
        }
        let whitespace = "\t\r\n\u{0C}text"
        XCTAssertEqual(try TextPreview.read(file(Data(whitespace.utf8))).text, whitespace)
        let splitNUL = try file(Data([0xFF, 0xFE, 0x00, 0x00]))
        XCTAssertThrowsError(try TextPreview.read(splitNUL, byteLimit: 1)) {
            XCTAssertEqual($0 as? TextPreviewError, .binaryContent)
        }
    }

    func testBinaryErrorIsLocalizedInBothShippedLanguages() throws {
        for (language, expected) in [
            ("en", "This file contains binary control characters and cannot be previewed as text."),
            ("zh-Hans", "文件包含二进制控制字符，无法作为文本预览。")
        ] {
            let url = try XCTUnwrap(CoreLocalization.bundle.url(
                forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language
            ))
            let bundle = try XCTUnwrap(Bundle(url: url.deletingLastPathComponent()))
            XCTAssertEqual(TextPreviewError.binaryContent.message(in: bundle), expected)
        }
    }

    func testNonregularAndMissingFilesFailWithoutWaitingForFIFOWriter() throws {
        XCTAssertThrowsError(try TextPreview.read(directory)) {
            guard case .notRegularFile = $0 as? DocumentFileError else { return XCTFail("Unexpected error: \($0)") }
        }
        let fifo = directory.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try TextPreview.read(fifo)) {
            guard case .notRegularFile = $0 as? DocumentFileError else { return XCTFail("Unexpected error: \($0)") }
        }
        let missing = directory.appendingPathComponent("missing")
        XCTAssertThrowsError(try TextPreview.read(missing)) {
            guard case .fileNotFound = $0 as? DocumentFileError else { return XCTFail("Unexpected error: \($0)") }
        }
        let remote = URL(string: "https://example.invalid/preview.txt")!
        XCTAssertThrowsError(try TextPreview.read(remote)) {
            XCTAssertEqual($0 as? DocumentFileError, .invalidURL(remote))
        }
    }

    func testHardLinksAndReadOnlyFilesCanBePreviewedWithoutChanges() throws {
        let original = Data("read only 中文".utf8)
        let url = try file(original)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.linkItem(at: url, to: link)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        XCTAssertEqual(try TextPreview.read(link).text, String(data: original, encoding: .utf8))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try Data(contentsOf: link), original)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o400)
    }
}
