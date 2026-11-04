import AppKit
import EditorUI
import XCTest

final class ExpandedSyntaxTests: XCTestCase {
    @MainActor
    func testNewLanguagesColorBasicSpansWithoutChangingTextSelectionOrUndo() async throws {
        let fixtures: [(SyntaxLanguage, String, String)] = [
            (.swift, "let answer = \"中文 🦊 e\u{301}\" // note\r\nreturn answer", "let"),
            (.c, "int answer = 42; /* note */\r\nreturn \"中文 🦊 e\u{301}\";", "int"),
            (.cpp, "auto answer = \"中文 🦊 e\u{301}\"; // note\r\nreturn answer;", "auto"),
            (.go, "var answer = \"中文 🦊 e\u{301}\" // note\r\nreturn answer", "var"),
            (.rust, "let answer = \"中文 🦊 e\u{301}\"; // note\r\nreturn answer;", "let")
        ]
        for (language, source, keyword) in fixtures {
            try await assertHighlights(source, language: language, expected: [
                (keyword, .systemPurple), ("中文 🦊 e\u{301}", .systemGreen),
                ("note", .secondaryLabelColor), ("return", .systemPurple)
            ])
        }
    }

    @MainActor
    func testSwiftAndRustNestBlockCommentsWhileCPlusPlusAndGoEndAtFirstClose() async throws {
        for language in [SyntaxLanguage.swift, .rust] {
            try await assertHighlights("/* outer /* inner */ let hidden = 1; */\nlet visible = 2;",
                                       language: language, expected: [
                ("inner", .secondaryLabelColor, 5), ("let hidden", .secondaryLabelColor, 10),
                ("let visible", .systemPurple, 3)
            ])
        }
        for (language, keyword) in [(SyntaxLanguage.c, "int"), (.cpp, "auto"), (.go, "var")] {
            try await assertHighlights("/* outer /* inner */ \(keyword) visible; */\nreturn visible;",
                                       language: language, expected: [
                ("inner", .secondaryLabelColor), (keyword, .systemPurple), ("return", .systemPurple)
            ])
        }
    }

    @MainActor
    func testGoRawBacktickClosesAfterLiteralBackslash() async throws {
        let source = #"var raw = `tail\` + "after" // outside"# + "\nreturn raw"
        try await assertHighlights(source, language: .go, expected: [
            (#"`tail\`"#, .systemGreen), ("after", .systemGreen),
            ("outside", .secondaryLabelColor), ("return", .systemPurple)
        ])
    }

    @MainActor
    func testSwiftHashDelimitedAndMultilineStringsKeepInternalQuotesOpaque() async throws {
        let source = ###"""
        let raw = ##"inner "# quote \##n"## // outside raw
        let multiline = """
        first " quote
        second line
        """
        let `class` = raw
        return raw
        """###
        try await assertHighlights(source, language: .swift, expected: [
            ("inner \"# quote", .systemGreen), ("outside raw", .secondaryLabelColor),
            ("first \" quote", .systemGreen), ("second line", .systemGreen), ("`class`", .textColor),
            ("return", .systemPurple)
        ])
    }

    @MainActor
    func testRustLifetimesDoNotConsumeCharacterOrRawStringSpans() async throws {
        let source = ###"""
        fn borrow<'a>(value: &'a str) -> &'a str {
            let character = '🦊';
            let escaped = '\n';
            let raw = r##"inner "# quote"##;
            return value;
        }
        """###
        try await assertHighlights(source, language: .rust, expected: [
            ("fn", .systemPurple), ("value:", .textColor),
            ("'🦊'", .systemGreen), (#"'\n'"#, .systemGreen),
            ("inner \"# quote", .systemGreen), ("return", .systemPurple)
        ])
    }

    @MainActor
    func testCppNumbersRawDelimitersAndCContinuedLiteralsPreserveFollowingCode() async throws {
        let source = ##"""
        auto raw = u8R"tag(first " )wrong" tail \)tag";
        auto count = 1'000'000;
        auto decimal = 1e1'0;
        auto hexadecimal = 0x1.fp1'0;
        return count;
        """##
        try await assertHighlights(source, language: .cpp, expected: [
            ("auto raw", .systemPurple, 4), ("u8R\"tag(", .systemGreen, 8),
            ("first \" )wrong\" tail", .systemGreen, 20), ("1'000'000", .systemBlue, 9),
            ("1e1'0", .systemBlue, 5), ("0x1.fp1'0", .systemBlue, 9),
            ("return", .systemPurple, 6)
        ])
        let continued = "const char *value = u8\"first\\\r\nsecond\"; // outside\nreturn value;"
        try await assertHighlights(continued, language: .c, expected: [
            ("const", .systemPurple), ("u8\"first\\\r\nsecond\"", .systemGreen),
            ("outside", .secondaryLabelColor), ("return", .systemPurple)
        ])
    }

    @MainActor
    func testExistingLanguagesRetainQuotedCommentsKeywordsAndJSONKeys() async throws {
        let python = "def sample():\n    text = \"\"\"first \" quote\nsecond\n\"\"\"\n    # note\n    return text"
        try await assertHighlights(python, language: .python, expected: [
            ("def", .systemPurple), ("first \" quote", .systemGreen), ("second", .systemGreen),
            ("note", .secondaryLabelColor), ("return", .systemPurple)
        ])
        let java = "class Sample {\nString text = \"\"\"\nfirst \" quote\nsecond\n\"\"\";\n// note\nreturn text;\n}"
        try await assertHighlights(java, language: .java, expected: [
            ("class", .systemPurple), ("first \" quote", .systemGreen), ("second", .systemGreen),
            ("note", .secondaryLabelColor), ("return", .systemPurple)
        ])
        try await assertHighlights("const value = `中文 ${name}`; // note\nreturn value;",
                                   language: .javascript, expected: [
            ("const", .systemPurple), ("中文 ${name}", .systemGreen),
            ("note", .secondaryLabelColor), ("return", .systemPurple)
        ])
        try await assertHighlights("interface Item {}\nconst value: string = \"中文\"; /* note */\nreturn value;",
                                   language: .typescript, expected: [
            ("interface", .systemPurple), ("string", .systemPurple), ("中文", .systemGreen),
            ("note", .secondaryLabelColor), ("return", .systemPurple)
        ])
        for language in [SyntaxLanguage.json, .jsonWithComments] {
            let comment = language == .jsonWithComments ? "/* note */ " : ""
            var expected: [(String, NSColor)] = [
                ("\"key\"", .systemTeal), ("中文", .systemGreen), ("true", .systemPurple)
            ]
            if language == .jsonWithComments { expected.append(("note", .secondaryLabelColor)) }
            try await assertHighlights("{\"key\": \"中文\", \(comment)\"flag\": true}",
                                       language: language, expected: expected)
        }
        try await assertHighlights("if true; then\nvalue='中文'\n# note\nprintf $value\nfi",
                                   language: .shell, expected: [
            ("if", .systemPurple), ("then", .systemPurple), ("中文", .systemGreen),
            ("note", .secondaryLabelColor), ("$value", .systemOrange), ("fi", .systemPurple)
        ])
    }

    @MainActor
    func testUnfinishedSpansAndLongMalformedHashRunRemainBoundedAndEditable() async throws {
        let unfinished: [(SyntaxLanguage, String, String)] = [
            (.swift, "let raw = ##\"unfinished \" # still", "##\"unfinished \" # still"),
            (.swift, "let text = \"\"\"\nline with \" quote", "\"\"\"\nline with \" quote"),
            (.rust, "let text = r##\"line\nnext \"# still", "r##\"line\nnext \"# still"),
            (.cpp, "auto text = R\"tag(first\nnext )wrong\";", "R\"tag(first\nnext )wrong\";"),
            (.go, "var text = `first\nnext \\", "`first\nnext \\")
        ]
        for (language, source, span) in unfinished {
            try await assertHighlights(source, language: language, expected: [(span, .systemGreen)])
        }
        for language in [SyntaxLanguage.swift, .rust, .c, .cpp, .go] {
            let source = language == .swift || language == .rust
                ? "/* outer /* inner */ remains" : "/* unfinished comment"
            try await assertHighlights(source, language: language, expected: [(source, .secondaryLabelColor)])
        }
        // This is below the shared 200 KiB limit. A malformed prefix must not
        // rescan every hash suffix or swallow the ordinary code that follows.
        let source = String(repeating: "#", count: 120_000) + "\nlet value = 1"
        XCTAssertLessThan(source.utf8.count, SyntaxHighlighter.maximumUTF8Bytes)
        try await assertHighlights(source, language: .swift, expected: [
            ("let", .systemPurple), ("value", .textColor), ("1", .systemBlue)
        ])
    }

    @MainActor
    func testNewLanguageRequestsPreserveActiveMarkedTextAndCancelQueuedColors() async throws {
        _ = NSApplication.shared
        for language in [SyntaxLanguage.swift, .c, .cpp, .go, .rust] {
            let view = NSTextView(usingTextLayoutManager: true)
            view.string = "return \"value\""
            let highlighter = SyntaxHighlighter()
            highlighter.highlight(textView: view, fileURL: nil, override: language)
            view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: 0, length: 0))
            let source = Array(view.string.utf16)
            let selected = view.selectedRange(), marked = view.markedRange()
            view.textStorage?.addAttribute(.foregroundColor, value: NSColor.systemRed,
                range: NSRange(location: 0, length: source.count))
            highlighter.highlight(textView: view, fileURL: nil, override: language)
            try await Task.sleep(for: .milliseconds(230))
            XCTAssertTrue(view.hasMarkedText(), "\(language)")
            XCTAssertEqual(view.markedRange(), marked, "\(language)")
            XCTAssertEqual(view.selectedRange(), selected, "\(language)")
            XCTAssertEqual(Array(view.string.utf16), source, "\(language)")
            XCTAssertEqual(color(in: view, at: source.count - 1), .systemRed, "\(language)")
            highlighter.cancel()
            view.unmarkText()
        }
    }

    @MainActor
    private func assertHighlights(_ source: String, language: SyntaxLanguage,
                                  expected: [(String, NSColor)], file: StaticString = #filePath,
                                  line: UInt = #line) async throws {
        try await assertHighlights(source, language: language,
                                   expected: expected.map { ($0.0, $0.1, $0.0.utf16.count) }, file: file, line: line)
    }

    @MainActor
    private func assertHighlights(_ source: String, language: SyntaxLanguage,
                                  expected: [(String, NSColor, Int)], file: StaticString = #filePath,
                                  line: UInt = #line) async throws {
        _ = NSApplication.shared
        let view = NSTextView(usingTextLayoutManager: true)
        let delegate = HighlightUndoDelegate()
        view.delegate = delegate
        view.allowsUndo = true
        view.string = source + "\n"
        // An actual prior text edit must survive styling as the sole undo item.
        delegate.stack.beginUndoGrouping()
        view.insertText("", replacementRange: NSRange(location: source.utf16.count, length: 1))
        delegate.stack.endUndoGrouping()
        view.breakUndoCoalescing()
        XCTAssertTrue(delegate.stack.canUndo, file: file, line: line)
        let selection = NSRange(location: 0, length: min(3, source.utf16.count))
        view.setSelectedRange(selection)
        view.textStorage?.addAttribute(.foregroundColor, value: NSColor.systemRed,
                                      range: NSRange(location: 0, length: source.utf16.count))
        let highlighter = SyntaxHighlighter()
        defer { highlighter.cancel(); view.delegate = nil }
        highlighter.highlight(textView: view, fileURL: nil, override: language)
        XCTAssertFalse(highlighter.isLimited, file: file, line: line)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while color(in: view, at: 0) == .systemRed {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(language) colors", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        for (needle, expectedColor, length) in expected {
            let range = (source as NSString).range(of: needle)
            guard range.location != NSNotFound else {
                XCTFail("Fixture lacks \(needle)", file: file, line: line); continue
            }
            for offset in range.location..<(range.location + min(length, range.length)) {
                XCTAssertEqual(color(in: view, at: offset), expectedColor,
                               "\(language) \(needle) at UTF-16 offset \(offset)", file: file, line: line)
            }
        }
        XCTAssertEqual(Array(view.string.utf16), Array(source.utf16), file: file, line: line)
        XCTAssertEqual(view.selectedRange(), selection, file: file, line: line)
        XCTAssertTrue(delegate.stack.canUndo, file: file, line: line)
        delegate.stack.undo()
        XCTAssertEqual(Array(view.string.utf16), Array((source + "\n").utf16), file: file, line: line)
        XCTAssertFalse(delegate.stack.canUndo, "Styling must not add undo entries", file: file, line: line)
        delegate.stack.redo()
        XCTAssertEqual(Array(view.string.utf16), Array(source.utf16), file: file, line: line)
    }

    @MainActor
    private func color(in view: NSTextView, at location: Int) -> NSColor? {
        view.textStorage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }
}

@MainActor
private final class HighlightUndoDelegate: NSObject, NSTextViewDelegate {
    let stack = UndoManager()
    override init() {
        super.init()
        stack.groupsByEvent = false
    }
    func undoManager(for view: NSTextView) -> UndoManager? { stack }
}
