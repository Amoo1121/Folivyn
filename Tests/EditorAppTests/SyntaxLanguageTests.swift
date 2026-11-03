import AppKit
import EditorUI
import XCTest

final class SyntaxLanguageTests: XCTestCase {
    func testAutomaticDetectionAndNamesRemainCompatible() {
        let cases: [(String, SyntaxLanguage)] = [
            ("a.json", .json), ("a.jsonc", .jsonWithComments), ("a.PY", .python),
            ("a.pyw", .python), ("a.java", .java), ("a.jsx", .javascript),
            ("a.mjs", .javascript), ("a.tsx", .typescript), ("a.cts", .typescript),
            ("a.sh", .shell), (".zshrc", .shell)
        ]
        for (name, language) in cases {
            let url = URL(fileURLWithPath: "/fixtures/" + name)
            XCTAssertEqual(SyntaxLanguage.forFile(url), language)
            XCTAssertEqual(SyntaxHighlighter.languageName(for: url), language.displayName)
        }
        XCTAssertNil(SyntaxLanguage.forFile(nil))
        XCTAssertNil(SyntaxLanguage.forFile(URL(fileURLWithPath: "/fixtures/unknown")))
        XCTAssertEqual(SyntaxHighlighter.languageName(for: nil), SyntaxLanguage.plainText.displayName)
        XCTAssertEqual(Set(SyntaxLanguage.allCases.map(\.rawValue)).count, SyntaxLanguage.allCases.count)
        XCTAssertTrue(SyntaxLanguage.allCases.contains(.plainText))
    }

    @MainActor
    func testExplicitLanguageHighlightsExtensionlessTextAndPlainTextClearsIt() async throws {
        _ = NSApplication.shared
        let view = NSTextView(usingTextLayoutManager: true)
        view.allowsUndo = true
        view.string = "def greet():\n    return \"中文 🦊\"\n"
        let source = Array(view.string.utf16)
        let selection = NSRange(location: 4, length: 5)
        view.setSelectedRange(selection)
        let highlighter = SyntaxHighlighter()
        defer { highlighter.cancel() }
        highlighter.highlight(textView: view, fileURL: nil, override: .python)
        try await waitUntil { self.color(in: view, at: 0) == NSColor.systemPurple }
        XCTAssertEqual(SyntaxHighlighter.languageName(for: nil, override: .python), "Python")
        let stringRange = (view.string as NSString).range(of: "\"中文")
        XCTAssertEqual(color(in: view, at: stringRange.location), NSColor.systemGreen)
        highlighter.highlight(textView: view, fileURL: URL(fileURLWithPath: "/fixtures/a.py"), override: .plainText)
        XCTAssertEqual(color(in: view, at: 0), NSColor.textColor)
        XCTAssertEqual(SyntaxHighlighter.languageName(for: URL(fileURLWithPath: "/fixtures/a.py"), override: .plainText),
                       SyntaxLanguage.plainText.displayName)
        XCTAssertEqual(Array(view.string.utf16), source)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
    }

    @MainActor
    func testChangingOverrideCancelsOldWorkAndAutomaticModeCanBeRestored() async throws {
        _ = NSApplication.shared
        let view = NSTextView(usingTextLayoutManager: true)
        view.string = "def sample(): pass"
        let highlighter = SyntaxHighlighter()
        defer { highlighter.cancel() }
        let pythonURL = URL(fileURLWithPath: "/fixtures/a.py")
        highlighter.highlight(textView: view, fileURL: pythonURL, override: .python)
        highlighter.highlight(textView: view, fileURL: pythonURL, override: .javascript)
        // Wait beyond the former request's debounce and worker to check that an
        // older Python request cannot restore its keyword color.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(color(in: view, at: 0), NSColor.textColor)
        highlighter.highlight(textView: view, fileURL: pythonURL, override: nil)
        try await waitUntil { self.color(in: view, at: 0) == NSColor.systemPurple }
        highlighter.highlight(textView: view, fileURL: pythonURL, override: .python)
        highlighter.highlight(textView: view, fileURL: pythonURL, override: .plainText)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(color(in: view, at: 0), NSColor.textColor)
    }

    @MainActor
    func testManualOverrideKeepsExistingResourceLimits() {
        _ = NSApplication.shared
        let view = NSTextView(usingTextLayoutManager: true)
        view.string = String(repeating: "a", count: SyntaxHighlighter.maximumUTF8Bytes + 1)
        let highlighter = SyntaxHighlighter()
        defer { highlighter.cancel() }
        highlighter.highlight(textView: view, fileURL: nil, override: .python)
        XCTAssertTrue(highlighter.isLimited)
        XCTAssertEqual(color(in: view, at: 0), NSColor.textColor)
    }

    @MainActor
    private func color(in view: NSTextView, at location: Int) -> NSColor? {
        view.textStorage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for syntax coloring"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
