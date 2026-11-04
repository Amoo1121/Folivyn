import Foundation
import XCTest
@testable import EditorCore

final class EncodingConversionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncodingConversionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testEveryEncodingCanExplicitlyReplaceEveryEncodingAtTheSameURL() throws {
        // Include both normalization forms, a surrogate pair, an internal BOM,
        // mixed line endings, and an unterminated final line.
        let source = "Folivyn\u{0} 中文 👩🏽‍💻 é e\u{301}\r\n\u{FEFF}second\rthird\nlast"
        try assertEveryConversion(of: source)
    }

    func testEveryEncodingCanExplicitlyReplaceEmptyAndBOMOnlyFiles() throws {
        try assertEveryConversion(of: "")
    }

    func testUTF16ExpansionBeyondByteLimitPreservesOriginalFileAndSnapshot() throws {
        let url = directory.appendingPathComponent("expansion.txt")
        let source = String(repeating: "a", count: DocumentFile.maximumReadBytes / 2)
        let originalBytes = Data(source.utf8)
        try originalBytes.write(to: url)
        let original = try DocumentFile.read(url)
        XCTAssertEqual(original.encoding, .utf8)
        XCTAssertEqual(original.diskSnapshot.byteCount, originalBytes.count)

        // The payload alone is exactly 10 MiB in UTF-16. Its required BOM
        // pushes either endian representation two bytes beyond the limit.
        for target in [TextFileEncoding.utf16LittleEndianBOM, .utf16BigEndianBOM] {
            XCTAssertThrowsError(try DocumentFile.save(
                original.text,
                to: url,
                encoding: target,
                expectedSnapshot: original.diskSnapshot
            ), target.rawValue) { error in
                XCTAssertEqual(
                    error as? DocumentFileError,
                    .tooLarge(
                        actualBytes: Int64(DocumentFile.maximumReadBytes + 2),
                        limitBytes: DocumentFile.maximumReadBytes
                    )
                )
            }

            XCTAssertEqual(try Data(contentsOf: url), originalBytes, target.rawValue)
            let unchanged = try DocumentFile.read(url)
            XCTAssertEqual(unchanged.encoding, .utf8, target.rawValue)
            XCTAssertEqual(unchanged.diskSnapshot, original.diskSnapshot, target.rawValue)
            XCTAssertTrue(unchanged.text.utf16.elementsEqual(source.utf16), target.rawValue)

            let retried = try DocumentFile.save(
                original.text,
                to: url,
                encoding: original.encoding,
                expectedSnapshot: original.diskSnapshot
            )
            XCTAssertEqual(retried.diskSnapshot, original.diskSnapshot, target.rawValue)
            XCTAssertEqual(try Data(contentsOf: url), originalBytes, target.rawValue)
        }

        // The pre-conversion snapshot also remains usable for a real write,
        // rather than only for an unchanged save.
        let edited = source + "!"
        let saved = try DocumentFile.save(
            edited,
            to: url,
            encoding: original.encoding,
            expectedSnapshot: original.diskSnapshot
        )
        XCTAssertEqual(try Data(contentsOf: url), originalBytes + Data([0x21]))
        XCTAssertNotEqual(saved.diskSnapshot, original.diskSnapshot)
        XCTAssertEqual(try DocumentFile.read(url).diskSnapshot, saved.diskSnapshot)
        XCTAssertEqual(original.encoding, .utf8)
        XCTAssertEqual(original.diskSnapshot.byteCount, originalBytes.count)
        XCTAssertTrue(original.text.utf16.elementsEqual(source.utf16))
    }

    private func assertEveryConversion(of source: String) throws {
        let url = directory.appendingPathComponent("conversion.txt")
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()

        for originalEncoding in TextFileEncoding.allCases {
            let originalBytes = try expectedBytes(source, encoding: originalEncoding)
            for targetEncoding in TextFileEncoding.allCases {
                let context = "\(originalEncoding.rawValue) → \(targetEncoding.rawValue)"
                try originalBytes.write(to: url)
                let original = try DocumentFile.read(url)
                XCTAssertEqual(original.encoding, originalEncoding, context)
                XCTAssertTrue(original.text.utf16.elementsEqual(source.utf16), context)

                let saved = try DocumentFile.save(
                    original.text,
                    to: url,
                    encoding: targetEncoding,
                    expectedSnapshot: original.diskSnapshot
                )
                let expected = try expectedBytes(source, encoding: targetEncoding)
                XCTAssertEqual(try Data(contentsOf: url), expected, context)
                XCTAssertEqual(saved.url, canonicalURL, context)
                XCTAssertEqual(saved.encoding, targetEncoding, context)
                XCTAssertEqual(saved.diskSnapshot.byteCount, expected.count, context)
                XCTAssertTrue(saved.text.utf16.elementsEqual(source.utf16), context)

                let reloaded = try DocumentFile.read(url)
                XCTAssertEqual(reloaded.url, canonicalURL, context)
                XCTAssertEqual(reloaded.encoding, targetEncoding, context)
                XCTAssertEqual(reloaded.diskSnapshot, saved.diskSnapshot, context)
                XCTAssertTrue(reloaded.text.utf16.elementsEqual(source.utf16), context)
                if originalEncoding == targetEncoding {
                    XCTAssertEqual(saved.diskSnapshot, original.diskSnapshot, context)
                } else {
                    XCTAssertNotEqual(saved.diskSnapshot, original.diskSnapshot, context)
                }

                // A successful encoding conversion must return the snapshot
                // required by the next ordinary save to this same file.
                let savedAgain = try DocumentFile.save(
                    saved.text,
                    to: url,
                    encoding: saved.encoding,
                    expectedSnapshot: saved.diskSnapshot
                )
                XCTAssertEqual(savedAgain.diskSnapshot, saved.diskSnapshot, context)
                XCTAssertEqual(try Data(contentsOf: url), expected, context)
                XCTAssertEqual(original.encoding, originalEncoding, context)
                XCTAssertEqual(original.diskSnapshot.byteCount, originalBytes.count, context)
                XCTAssertTrue(original.text.utf16.elementsEqual(source.utf16), context)
            }
        }
    }

    private func expectedBytes(_ source: String, encoding: TextFileEncoding) throws -> Data {
        switch encoding {
        case .utf8:
            return try XCTUnwrap(source.data(using: .utf8))
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + (try XCTUnwrap(source.data(using: .utf8)))
        case .utf16LittleEndianBOM:
            return Data([0xFF, 0xFE]) + (try XCTUnwrap(source.data(using: .utf16LittleEndian)))
        case .utf16BigEndianBOM:
            return Data([0xFE, 0xFF]) + (try XCTUnwrap(source.data(using: .utf16BigEndian)))
        }
    }
}
