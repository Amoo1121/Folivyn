# Folivyn native acceptance validation

Date: 2026-10-26. Code revision: `d4121a6`.

## Status

Native window acceptance is **in progress**. Desktop-control permissions have
been restored, and visible application checks have begun on the unlocked Mac.
The earlier three connection attempts produced no window-validation evidence;
the observations below come from the subsequent successful desktop session.
Automated preflight and release-build results remain as previously recorded;
this documentation update does not represent another test or benchmark run.

## Previously completed automated checks

- All 27 tests passed both normally and in a process tree with network access
  denied: 12 file tests, 6 editor-session tests, 3 input-safety tests, and 6
  localization tests.
- Fixed an out-of-order disk-check result that could incorrectly clear a newer
  external-change warning. Each session now accepts only its latest check;
  saving or reloading invalidates earlier checks. Two deterministic regression
  tests cover reversed completions and unchanged-baseline saves/reloads.
- Input-safety tests exercise actual `NSTextView` text-input client methods:
  Unicode replacement, marked-text updates/commit, and completed highlighting.
  Text bytes, selection, dirty state, and undo/redo are checked. These tests use
  explicit undo groups and do not represent real keyboard input, system undo
  grouping, or a Pinyin candidate window.
- The arm64 Release app builds and passes strict ad hoc signature verification.
  Its 10 files total 270,433 bytes (264.09 KiB); disk allocation is 292 KiB.
  The packaged MIT license is byte-identical to the repository license.
- Reproducible, synthetic fixtures are generated into a unique ignored run
  directory. No user documents are needed or modified by fixture creation.

## Observed native checks

These checks used visible application interaction through CUA and, where noted,
byte or hash comparisons of synthetic fixture files.

- **Opening and tabs:** opened CSV, JSON, and Python fixtures together as three
  independent tabs. Reopening the CSV did not add a duplicate tab. Python syntax
  colors were visible in the captured window. `Cmd-Shift-[` / `Cmd-Shift-]`
  switched tabs and retained typing focus. Undo and redo in the JSON tab did not
  affect the Python tab's dirty state.
- **Saving and conflicts:** Save produced the expected bytes. After an external
  write, `Cmd-S` showed a conflict. Choosing Save As from that conflict and then
  cancelling preserved both the local buffer and the external disk version.
  A normal Save As to `saved-as.py` preserved the original file. Selecting an
  already-open `sample.json` as the Save As destination, including confirming
  the system Replace prompt, was rejected by the app; the JSON hash was unchanged.
- **Reload:** clean Reload and dirty Reload's Cancel, Discard, and Save a Copy
  paths were exercised, including cancelling the copy panel. Successful copy
  and reload produced the expected separate bytes in `local-copy.py` and
  `sample.py`. `Cmd-Z` after Reload did not restore the older version.
- **Rejected copy destinations:** Reload refused the source path as its own copy
  destination. Overwriting a hard-linked copy destination was also refused, and
  both links retained their original contents.
- **Copy succeeds, reload fails:** saving the local buffer to `before-invalid.txt`
  succeeded, then reading an invalid UTF-8 source reported an error. The local
  buffer remained dirty with undo available, and the invalid source bytes were
  unchanged. Separately, moving the source away and choosing Discard and Reload
  reported a missing file without clearing the local buffer; `Cmd-Z` could still
  restore its baseline.
- **Quit cancellation:** with two dirty tabs, `Cmd-Q` followed by Don't Save for
  the first tab and Cancel for the second kept both tabs open and dirty. Undo
  remained available in the first tab.
- **Last-tab close:** cancelling the close confirmation and the Save panel
  retained the last dirty tab. A hard-link-induced Save failure also kept the
  window and edits; a later quit still asked for confirmation. Saving a new
  last tab to `last-tab-saved.txt` wrote the expected bytes and exited the app.
- **Real input:** keyboard input of Pinyin `nihao` and `zhongwen` produced
  `你好中文`; Backspace correction and undo/redo worked. Mixed Chinese, Emoji,
  and a decomposed accent saved to `ime.txt` with the expected UTF-8 bytes.
  Captures showed marked-text underlining and committed text. The system Pinyin
  candidate window's position was not visually verified.

## Reproduce

```sh
python3 scripts/create-validation-fixtures.py
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path build/TestBuild
sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun xctest build/TestBuild/arm64-apple-macosx/debug/FolivynPackageTests.xctest
./scripts/build-app.sh
codesign --verify --deep --strict "build/Folivyn.app"
```

## Native checks remaining

| Area | Required observations |
| --- | --- |
| Selection and scrolling | Verify selection and scroll position across tab switches and Reload, including a shortened document. |
| Encodings through the UI | Open, edit, and save the supported BOM and UTF-16 variants through the real window; compare bytes and displayed encoding. |
| Large-file boundaries | Exercise the highlighting fallback and file-size rejection boundaries through the UI. |
| Finder entry | Complete opening a fixture from Finder; an attempted interaction has not yet established this result. |
| Input and localization | Visually verify Pinyin candidate positioning and Simplified Chinese UI labels/layout. |
| Offline UI | Repeat the editing workflow with application networking denied; automated tests alone do not establish all window flows. |
| Resource use | Measure visible/editable startup, input latency, and physical memory footprint with documented samples. |

Minimum-system compatibility, Developer ID signing, notarization, CSV/JSON
specialized views, and Finder Quick Look are outside this local prototype check.
