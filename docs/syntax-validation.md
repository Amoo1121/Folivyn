# Basic syntax coloring validation

2026-11-04, Apple M4 / macOS 26.5.1. The language expansion is committed as
`1384198`; conservative raw-string bracket refusal follows in `2e419f6`.

## Implemented behavior

Filename detection and the per-tab Language menu now include Swift, C, C++, Go
and Rust. Lowercase `.c` and `.h` select C; uppercase `.C` and common C++ source
and header extensions select C++. An ambiguous header can use the manual menu.
Each new language uses `//` for the existing line-comment command.

The independently implemented scanner colors common keywords, numbers, strings
and comments. It handles Swift/Rust nested block comments, Swift hash-delimited
and multiline strings, Go raw backticks, Rust character literals versus lifetime
names, Rust raw strings, and C++ prefixed raw strings and numeric separators.
The quote scanner also retains coverage for all previously listed languages.
No grammar, runtime, asset or package was downloaded into the app.

These are basic presentation colors, not a compiler lexer or semantic parser.
Interpolation expressions, regex literals, macro/preprocessor interpretation and
context-sensitive syntax are not fully parsed. The budget stays at 200 KiB UTF-8
and 20,000 lines, with plain-text fallback. Coloring does not drive source edits
or structured ranges. Conservative bracket hints use a separate bounded matcher;
hash-delimited raw syntax now suppresses a hint instead of guessing inside it.

## Automated evidence

- Nine expanded-language tests exercise new and existing languages, exact token
  color spans, Unicode and CRLF, unterminated constructs, a 120,000-character
  malformed hash prefix, active IME text, selection and existing undo/redo.
- Review found and fixed C/C++ string continuation across escaped CRLF and C++
  numeric separators in decimal/hexadecimal exponents. Regressions require the
  following code to retain its correct colors.
- The `1384198` suite passes **259 tests** normally and with network access denied:
  `build/syntax-complete-tests.log`, `build/syntax-complete-offline.log`.
- The following bracket correction passes **15 focused matcher tests**, including
  raw-string bodies and later code, ordinary Python/Shell comments, cancellation
  and limits: `build/bracket-raw-string-tests.log`.

## Native evidence

The English Release app was launched with `sandbox-exec` denying `network*`, using
an isolated recovery directory. Five original synthetic files were opened in
separate tabs. Screenshots showed the expected keyword, number, string and
comment colors for Swift, C, C++, Go and Rust. Swift and Rust nested comments
remained opaque; C++ and Go multiline raw strings ended at the correct delimiter.
Rust lifetime names did not swallow later text. Chinese and emoji remained visible.

The C tab's line-comment command made one dirty change; Undo restored its clean
state. Choosing C++ manually changed only that tab's language, and the Swift tab
kept Swift. All five disk files retained their original SHA-256 hashes. The app
quit normally with no remaining unsaved text.

Finder's actual Space key showed **Folivyn · Read-only preview** for the Swift
fixture, with matching source colors and its existing Open with Xcode action.
This Finder invocation was not independently network-denied. A Go fixture at
this checkpoint showed only the system file icon: its dynamic type inherited
`public.data`, not `public.text`. Main-window coloring alone therefore does not
establish Finder routing for the new language types.

This checkpoint's signed app totals **1,486,776 logical bytes**, **1,512 KiB**
allocated. Main executable SHA-256:
`e40ffd88b2ba62667bc186c5efd7f08222a0e8a77c084f27df6bb3caf124a931`.
Strict nested ad hoc signature verification passes; the bundled MIT license
matches the root file. These measurements precede later file-save changes.

## Reference provenance and remaining scope

Language rules were checked against the [Swift lexical reference](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/lexicalstructure/),
[Rust tokens](https://doc.rust-lang.org/reference/tokens.html) and
[comments](https://doc.rust-lang.org/reference/comments.html), the
[Go specification](https://go.dev/ref/spec), and the
[C++ working draft's string section](https://eel.is/c++draft/lex.string).
Implementations and test fixtures were written independently; no source examples
or editor grammars were copied. This review does not prove worldwide originality.

YAML, TOML, XML/HTML/CSS, Markdown and SQL coloring remain candidate work.
First-use extension offline behavior, other installed preview providers,
remaining IME/accessibility checks, performance targets, minimum macOS and
distribution gates remain separate from these coloring results.
