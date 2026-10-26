# Folivyn native acceptance validation

Test dates: 2026-10-26 to 2026-10-27. Final code revision: `3f93066`.

Environment: macOS 26.5.1 (25F80), arm64, Mac16,10, 16 GiB RAM;
Xcode 26.6 (17F113).

## Status

**This round of local functional acceptance is complete** for the current text
editor scope. Visible application checks, fixture-byte comparisons, automated
tests, and the final Release build are recorded below. This does not establish
completion of the full V1 roadmap or the unverified items listed at the end.
The earlier three failed desktop-control connection attempts produced no window
evidence; native observations were made after permissions were restored.

## Automated checks and final build

- All 28 tests passed both normally and in a process tree with network access
  denied: 12 file tests, 6 editor-session tests, 4 input-safety tests, and 6
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
  Its 10 files total 270,785 bytes (264.44 KiB); disk allocation is 292 KiB.
  The packaged MIT license is byte-identical to the repository license.
- Reproducible, synthetic fixtures are generated into a unique ignored run
  directory. No user documents are needed or modified by fixture creation.

The earlier `d4121a6` preflight passed 27 tests and measured 270,433 bytes
(264.09 KiB), with the same 292 KiB disk allocation. Those measurements precede
the final highlighting-status fix and are retained here as historical results.

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
  candidate window's position was not visually verified: it could not be
  captured in the app-bound screenshots used for this session.
- **Restricted Chinese-language session:** launched the Release app under
  `sandbox-exec` with `(deny network*)` and `-AppleLanguages '(zh-Hans)'`.
  Chinese menus, buttons, and status text displayed correctly with no obvious
  clipping in the observed windows. This restricted process opened a UTF-16 LE
  file, edited and saved it, saved a copy as `offline-copy.txt`, and reloaded an
  external edit with `Cmd-R`.
- **Encoding and rejected inputs:** in that restricted process, saving the three
  supported BOM variants (UTF-8, UTF-16 LE, and UTF-16 BE) preserved the expected
  BOM, CRLF, Emoji, and combining-character bytes. Opening invalid UTF-8 and a
  file of 10 MiB plus one byte produced Chinese error messages. The existing
  unsaved Untitled buffer remained intact.
- **Selection and scrolling:** in a 300-line `scroll.py`, selected the unique
  line 0200 and scrolled to the bottom. Switching to another tab and back retained
  the selection and the scrollbar value of 1. After shortening the source,
  Reload displayed its new first line and clamped the caret to the new end.
- **Finder entry:** in a new Finder test window, Open With > Folivyn delivered
  `sample.py` to the same network-restricted process and added a tab. The default
  file association was not changed.
- **Large-file boundaries:** the rebuilt app opened `many-lines.py` with 20,001
  lines (140,007 bytes) and showed the Large text status. Replacing it with short
  code cleared that status; `Cmd-Z` restored the long text and status, and
  `Cmd-Shift-Z` restored the short text without the status. The exactly 10 MiB
  `source-10485760.py` opened, allowed editing and undo, and showed plain-text
  fallback. The earlier check rejected 10 MiB plus one byte.
- **Earlier small-file memory observation:** `footprint -p 25625 --noCategories`
  reported a current
  footprint of 38 MB and a peak of 92 MB. This was one process sample with four
  small-file tabs, after opening panels and a system preview. It is not a memory
  benchmark or evidence of a performance target being met.
- **Final large-file memory observation:** in a new process with two tabs
  (`many-lines.py` and the 10 MiB file), after editing and undoing in the large
  file, five `footprint` samples at one-second intervals each reported
  `phys_footprint` of 94,946,288 bytes. The recorded peak was 174,556,144 bytes.
  These samples describe that process and workload; they do not establish P95
  timing or compliance with the roadmap's performance targets.

## Issue fixed during acceptance

The 20,000-line highlighting limit initially triggered plain-text fallback
without the corresponding status message. Revision `3f93066` unifies the
highlighting-limit decision and cached status, including undo/redo updates.
The additional regression test and the rebuilt-window checks described above
passed.

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

## Verification boundaries

| Area | Unverified scope |
| --- | --- |
| Pinyin candidate window | Visually verify candidate positioning with an appropriate capture surface; app-bound screenshots have not established this result. |
| Automatic activation warning | There is no reliable independent native observation that app activation alone displayed the external-change warning. Manual Reload and the save-conflict paths were verified; the stale-check logic has automated coverage. |
| Performance | Precise visible/editable startup and input-latency measurements, including P95, were not performed. The footprint observations are not a performance acceptance result. |
| Supported systems and distribution | macOS 14 compatibility, Intel execution, Developer ID signing, and notarization were not validated. Only the local arm64 build and its ad hoc signature were verified. |

CSV/JSON specialized views, Finder Quick Look, and other remaining V1 features
are outside this round of local functional acceptance.
