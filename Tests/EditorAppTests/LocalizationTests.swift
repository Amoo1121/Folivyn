import Foundation
import XCTest
@testable import EditorApp

final class LocalizationTests: XCTestCase {
    func testEveryInterfaceKeyExistsInEnglishAndSimplifiedChinese() throws {
        let expected = Set(L10n.Key.allCases.map(\.rawValue))
        let english = try strings(for: "en")
        let chinese = try strings(for: "zh-Hans")
        XCTAssertEqual(Set(english.keys), expected)
        XCTAssertEqual(Set(chinese.keys), expected)
        XCTAssertEqual(L10n.resourceBundle.developmentLocalization, "en")

        for key in L10n.Key.allCases {
            for language in ["en", "zh-Hans"] {
                let translated = L10n.text(key, language: language)
                XCTAssertFalse(translated.isEmpty, "Missing \(language): \(key.rawValue)")
                XCTAssertNotEqual(translated, key.rawValue, "Unresolved \(language): \(key.rawValue)")
            }
            let englishText = try XCTUnwrap(english[key.rawValue])
            let chineseText = try XCTUnwrap(chinese[key.rawValue])
            XCTAssertEqual(try placeholders(in: englishText),
                           try placeholders(in: chineseText),
                           "Mismatched placeholders: \(key.rawValue)")
        }
    }

    func testLocalizedFormatsPreserveUserFileNamesAndFileSizeLimit() {
        let fileName = "笔记 100% 📝.txt"
        XCTAssertEqual(L10n.format(.reloadTitle, fileName, language: "en"),
                       "Reload “笔记 100% 📝.txt”?")
        XCTAssertEqual(L10n.format(.reloadTitle, fileName, language: "zh-Hans"),
                       "重新加载“笔记 100% 📝.txt”？")
        for language in ["en", "zh-Hans"] {
            XCTAssertEqual(L10n.format(.windowTitle, fileName, L10n.appName, language: language),
                           "\(fileName) — \(L10n.appName)")
        }
        XCTAssertEqual(L10n.format(.openMessage, 10, language: "en"),
                       "Choose text or code files up to 10 MiB.")
        XCTAssertEqual(L10n.format(.openMessage, 10, language: "zh-Hans"),
                       "选择不超过 10 MiB 的文本或代码文件。")
    }

    func testEnglishFallbackAndSimplifiedChineseAreReadFromTheResourceBundle() {
        XCTAssertEqual(L10n.text(.plainText, language: "en"), "Plain text")
        XCTAssertEqual(L10n.text(.plainText, language: "zh-Hans"), "纯文本")
        XCTAssertEqual(L10n.text(.plainText, language: "fr"), "Plain text")
        XCTAssertEqual(L10n.format(.about, L10n.appName, language: "en"),
                       "About \(L10n.appName)")
        XCTAssertEqual(L10n.format(.about, L10n.appName, language: "zh-Hans"),
                       "关于 \(L10n.appName)")
    }

    private func strings(for language: String) throws -> [String: String] {
        let url = try XCTUnwrap(L10n.resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(propertyList as? [String: String])
    }

    private func placeholders(in value: String) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:ld|@)"#)
        let source = value as NSString
        return pattern.matches(in: value, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range) }.sorted()
    }
}
