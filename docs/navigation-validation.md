# Daily navigation and opening validation

Dates: 2026-11-03 and 2026-11-04. Environment: Apple Silicon, macOS 26.5.1, Xcode 26.6.
Status: integrated with the scoped evidence below; complete V1 acceptance remains open.

## Observed native behavior

- JSON displayed logical line numbers 1–7 in its source pane. Cmd-L opened a
  localized-ready native dialog; choosing line 5 placed the caret before that
  line without changing text or dirty state. Its status reported UTF-8, JSON,
  and LF.
- Open Recent showed exactly one submenu, listed the successfully opened
  synthetic fixture, and reopened it by focusing the existing tab.
- A new unnamed document containing Python could be switched to Python through
  Edit > Language. Its source received keyword/string colors; the JSON tab
  retained JSON after switching tabs. Language selection did not rename files.
- Native testing found blank gutter labels after opening JSON and then creating
  a text tab, plus a divider extending into the toolbar/status area. The ruler
  now explicitly clips drawing to its bounds (macOS 14 changed the default).
  Repeating this sequence on November 4 displayed lines 1–3 correctly, with
  the divider confined to the gutter. A full-content bitmap regression checks
  real glyph pixels and the region above the ruler, not just calculated labels.
- Cmd-] indented two Python lines by four spaces, preserving Chinese and Emoji.
  Cmd-/ added a line comment after indentation. One Cmd-Z undid comments;
  the next Cmd-Z restored the original unindented source.

## Automated foundations

- TextLineIndex: seven cases for Unicode/CRLF/mixed endings, EOF, budgets and
  cancellation; LineNumberRuler: six passing viewport/bounds/stale-result
  and full-content plain-tab rendering cases.
- EditorNavigationTests: two passing integration tests for revision-checked
  jumps, invalid lines, shared undo, independent language choices and marked
  text protection.
- FileOpenSupportTests: nine passing cases for local regular-file URL
  validation, count limits, canonical deduplication, modal rejection, native
  text drag types, history and file payload refusal in a cell editor. Ordinary
  text paste remains available.
- SyntaxLanguageTests: four passing cases for manual/automatic language
  selection, clearing colors, stale requests, unchanged source/undo and limits.

- EditorTextCommandTests: seven passing tests, also repeated under denied
  network access. They verify mixed-ending source and shared native undo, plus
  controlled late worker results after selection/revision/IME/host eligibility
  changes or starting a CSV cell draft. No late result may overwrite that work.

The file-drop routing is connected to the main window, source text view and
CSV cell editor. Actual cross-window Finder dragging is not yet recorded here;
a synthetic pasteboard test is not a claim that this native gesture passed.
Recent history uses NSDocumentController's public API. The test did not clear
any existing system recent list or change file associations.

Package checkpoint before gutter repair: 952 KiB including the extension.
Final whole-suite, translated native workflow and package evidence are recorded
at the end of this document when measured.

## Final integration checkpoint — 2026-11-04

At 19:16:05 the complete worktree suite passed **168 tests**. The same compiled
bundle passed **168 tests** through `sandbox-exec` with `(deny network*)` at
19:16:59. This checkpoint includes independent recovery/bracket foundations
being developed in parallel; it does not mean their user-facing integration is
complete. Later commits must record their own results.

A separately launched network-denied app with `-AppleLanguages '(zh-Hans)'`
showed translated menus, line-range dialog, and CRLF status. It completed a line
jump, manual Python selection, multiline indentation/comment toggling and Save.
The saved synthetic file was checked against exact expected UTF-8 bytes,
including CRLF, Chinese and Emoji. No network/account/download prompt appeared.

The measured local arm64 package contains **1,195,926 logical bytes** and
occupies **1,224 KiB**. Main executable SHA-256:
`60833e7b45d8e2401549a2f500440b50075a31563785af9afdd957b3d7a51760`.
Strict nested ad-hoc signature verification passed and the packaged MIT license
matched the repository. This size includes the parallel foundations; it is not
a notarized distribution artifact or a performance result.
