# Folivyn native acceptance validation

Date: 2026-10-26. Code revision: `d4121a6`.

## Status

Automated preflight and the release build pass. Native window acceptance is
still pending: the desktop-control service reported unfinished Accessibility
and Screen Recording permissions on three connection attempts after the user
unlocked the Mac. No visible-window result is claimed from these attempts.

## Completed checks

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
| Open and tabs | Open three files through menus/Finder, reopen without duplication, retain selection/scroll/focus, and isolate undo histories. |
| Save | Save, Save As, cancel the panel, refuse an already-open destination, and compare the resulting file bytes. |
| Reload | Clean reload; dirty cancel, discard, and save-copy paths; cancelled/failed copy; deleted or invalid source; another tab remains unchanged. |
| Conflicts | Modify a file externally, return to the app, observe the warning, and confirm Save does not overwrite the external version. |
| Close and quit | Cancel/save/discard dirty tabs; verify multi-tab quit cancellation and failed saves retain all unsaved buffers. |
| Input and layout | Real Pinyin composition/selection, Emoji and combining characters, menu shortcuts, focus changes, and English/Chinese label layout. |
| Offline UI | Repeat the editing workflow with application networking denied; automated tests alone do not establish all window flows. |
| Resource use | Measure visible/editable startup, input latency, and physical memory footprint with documented samples. |

Minimum-system compatibility, Developer ID signing, notarization, CSV/JSON
specialized views, and Finder Quick Look are outside this local prototype check.
