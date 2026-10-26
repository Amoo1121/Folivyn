import Foundation
import XCTest
@testable import EditorCore

final class DocumentFileLocalizationTests: XCTestCase {
    private func localizedBundle(_ language: String) throws -> Bundle {
        let stringsURL = try XCTUnwrap(CoreLocalization.bundle.url(
            forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language
        ))
        return try XCTUnwrap(Bundle(url: stringsURL.deletingLastPathComponent()))
    }

    private func strings(in bundle: Bundle) throws -> [String: String] {
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    func testPackagedEnglishAndSimplifiedChineseResourcesAreComplete() throws {
        let english = try localizedBundle("en")
        let chinese = try localizedBundle("zh-Hans")
        let englishStrings = try strings(in: english)
        let chineseStrings = try strings(in: chinese)

        XCTAssertEqual(Set(englishStrings.keys), Set(chineseStrings.keys))
        XCTAssertFalse(englishStrings.isEmpty)
        let error = DocumentFileError.invalidURL(URL(string: "https://example.invalid/file.txt")!)
        XCTAssertEqual(error.message(in: english), "Only local files can be opened.")
        XCTAssertEqual(error.message(in: chinese), "只能打开本地文件。")

        // A translation with a missing or changed format specifier can corrupt an alert.
        let specifiers = try NSRegularExpression(pattern: "%@|%ld")
        func placeholders(_ value: String) -> [String] {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return specifiers.matches(in: value, range: range).map { (value as NSString).substring(with: $0.range) }
        }
        for key in englishStrings.keys {
            let translated = try XCTUnwrap(chineseStrings[key])
            XCTAssertEqual(placeholders(englishStrings[key]!), placeholders(translated), key)
            XCTAssertFalse(translated.isEmpty, key)
        }
    }

    func testEveryFileErrorHasAHumanReadableMessageInBothLanguages() throws {
        let url = URL(fileURLWithPath: "/tmp/document.txt")
        let errors: [DocumentFileError] = [
            .invalidURL(URL(string: "https://example.invalid/file.txt")!),
            .fileNotFound(url), .notRegularFile(url),
            .tooLarge(actualBytes: Int64(DocumentFile.maximumReadBytes + 1), limitBytes: DocumentFile.maximumReadBytes),
            .unsupportedEncoding, .invalidTextEncoding, .externalConflict(url), .multipleHardLinks(url),
            .readFailed(url, reason: "Access denied"), .saveFailed(url, reason: "Disk full")
        ]
        let english = try localizedBundle("en")
        let chinese = try localizedBundle("zh-Hans")
        for error in errors {
            let englishMessage = error.message(in: english)
            let chineseMessage = error.message(in: chinese)
            XCTAssertNotEqual(englishMessage, chineseMessage, "Missing translation for \(error)")
            for message in [englishMessage, chineseMessage, try XCTUnwrap(error.errorDescription)] {
                XCTAssertFalse(message.isEmpty)
                XCTAssertFalse(message.hasPrefix("file.error."), "Unresolved localization key: \(message)")
                XCTAssertFalse(message.contains("%@"), "Unresolved filename or reason: \(message)")
                XCTAssertFalse(message.contains("%ld"), "Unresolved size limit: \(message)")
            }
        }
    }

    func testFormattedMessagesPreserveUnicodeAndPercentSignsInUserValues() throws {
        let filename = "数据 100% %@.json"
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(filename)
        let reason = "磁盘 100% full — %@ / %ld"
        for language in ["en", "zh-Hans"] {
            let bundle = try localizedBundle(language)
            for error in [DocumentFileError.fileNotFound(url), .externalConflict(url)] {
                XCTAssertTrue(error.message(in: bundle).contains(filename))
                XCTAssertFalse(error.message(in: bundle).contains("/tmp/"))
            }
            for error in [DocumentFileError.readFailed(url, reason: reason), .saveFailed(url, reason: reason)] {
                XCTAssertTrue(error.message(in: bundle).hasSuffix(reason))
            }
            let sizeError = DocumentFileError.tooLarge(actualBytes: 20 * 1_024 * 1_024, limitBytes: 10 * 1_024 * 1_024)
            XCTAssertTrue(sizeError.message(in: bundle).contains("10 MiB"))
        }
    }
}
