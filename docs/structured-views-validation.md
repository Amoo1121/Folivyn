# Find and structured-view validation

Test date: 2026-11-03. Status: **implemented with scoped native evidence**; broader V1 acceptance remains open.

This record covers the native Find/Replace, CSV/TSV table, and JSON tree work
following the earlier [text-editor acceptance](native-validation.md). The native
observations below were made by the root agent through CUA against synthetic
fixtures. File-byte assertions supplement window observations where stated.
Screenshots were inspected through the native automation session; no screenshot files are published here.

These observations establish the fixture workflows below, not complete V1 acceptance.
Finder Space preview has a separate [validation record](quick-look-validation.md).

## Native Find and Replace

- Replaced all occurrences of `alpha` with `替换 🦊` through the native Find UI.
  One Undo restored the preceding text; Redo reapplied the replacement.
- Saved the result and checked the fixture's UTF-8 bytes against the expected
  content.
- Performed a single replacement in a second tab. The first tab's text remained
  unchanged.
- Used `Cmd-E` with a Chinese selection to populate the native find query.

These checks establish the observed fixture workflows, not every finder option
or large-file latency target.

## Native CSV table and local edits

The `table.csv` fixture opened in table view by default. The window displayed
`00123` with its leading zeros, formula-like content as strings, Chinese text,
and a field containing a quoted LF. It did not execute or coerce cell values.

The following editing sequence was observed:

1. Enabled the first-row header option. It changed the display without making
   the document dirty.
2. Double-clicked the second source record's second column. The cell editor
   sheet contained the complete value `00123`.
3. Entered this replacement value, including the actual newline:

   ```text
   00999, "中文"
   next
   ```

4. Pressed `Cmd-Q` while the sheet held that draft. Quit was refused and the
   entered value remained available.
5. Applied the cell edit. The table updated and the document became dirty.
   With table focus, `Cmd-Z` restored `00123` and cleared dirty state. Redo
   reapplied the cell change, and Save wrote the expected bytes.
6. Used Show in Source. The selection covered exactly the edited field's quoted
   source range, including its CSV escaping.
7. Changed `short` to `short edited` in Source. The first Undo reverted only
   this source edit. The next Undo reverted the earlier cell edit. Redo restored
   the saved cell version; the table and source agreed, dirty state cleared, and
   the document matched the disk version.
8. Double-clicked a missing-field placeholder. It did not open an editor or add
   a field.

The saved fixture was compared byte for byte with the expected result. Other
fields, existing CRLF record separators, and the unrelated quoted LF were
preserved. This is evidence of a local field replacement through the shared
document history, rather than whole-table serialization.

The first native pass also exposed a rendering defect: a quoted newline was
drawn across adjacent fixed-height table rows. The rebuilt Chinese interface showed each value on one line with a visible `↵` marker; the full cell editor retained the original newline.

## Native JSON tree and source navigation

- `tree.json` showed both occurrences of a duplicate key. The large integer
  retained its literal digits, and `1.2300e+04` retained its original numeric
  spelling.
- Copy Pointer was disabled for an ambiguous duplicate-key location, with a
  tooltip explaining the ambiguity.
- Searching for `needle` and choosing Next expanded the path to
  `/nested/items/2`. Search-field focus was retained while the tree navigated to
  the result.
- In Source, changed `true` to `tru`. The tree cleared and reported an error at
  line 5, UTF-16 column 27. The invalid source remained editable. Undo restored
  the valid source, clean state, and the tree.

The first native pass identified an uneven initial source/tree split and
horizontal scrolling during tree-to-source navigation. The rebuilt window showed an equal split. Keyboard tree navigation and source-to-tree selection preserved horizontal scroll at zero. An accessibility row-click can itself scroll a row horizontally; that tool behavior was distinguished from keyboard navigation.

## Automated evidence

At 20:56 on 2026-11-03, the integrated suite passed **91 tests** normally;
the same 91 passed under `(deny network*)` at 20:57. This included nine CSV
controller tests, eight JSON controller tests, three presentation tests, and
14 JSON parser tests. Later line-ruler/file-opening foundation tests and the
new CSV first-responder regression are additional work; counts from these
checkpoints must not be added together.

After the focus correction and committed line/file-opening/language foundations,
a fresh complete run passed **117 tests** at 21:10:44; the same compiled test
bundle passed **117 tests** under denied network access at 21:11:50. These are
the latest complete suite results for this increment. The normal command used
`swift test --scratch-path build/TestBuild`; the offline command used
`sandbox-exec` with `(version 1) (allow default) (deny network*)` to run Xcode's
`usr/bin/xctest` against that built test bundle.

After the CSV controller changes, its focused suite passed **9 tests** on
2026-11-03. It checks:

- header/display-row to source-record mapping and delimiter changes without
  source writes;
- leading zeros, read-only missing fields, and configuration locking while a
  cell draft is pending;
- exact local replacements through a real `NSTextView`, its existing undo
  manager, and one Undo/Redo operation;
- rejection of stale revisions and canonically equivalent but byte-distinct
  Unicode source changes;
- cancellation and late parser results, including a worker deliberately
  returning after cancellation;
- invalid-source recovery, bounded cell rendering, and visible newline markers
  without changing the full cell value or source.

Command used for this focused run:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path build/CSVUITests --filter CSVTableControllerTests
```

The focused count overlaps the integrated suite. A later first-responder
regression also passed: a newly created CSV table must accept keyboard focus
before its asynchronous first parse completes.

## Rebuilt native and offline checks

A process launched through `sandbox-exec` with `(deny network*)` and
`-AppleLanguages '(zh-Hans)'` successfully opened the CSV/JSON fixtures,
edited a CSV cell to `00007 离线`, applied and saved it, displayed localized
JSON errors, and undid an invalid JSON edit. Exact saved CSV bytes were checked;
JSON disk bytes remained unchanged. The process quit with exit code zero.
This directly covers these workflows, not every finder option or UI state.

| Defect | Correction and observed result |
| --- | --- |
| CSV quoted newlines overflowed rows | Bounded labels display `↵`; full values remain unchanged. Confirmed in the rebuilt Chinese window and focused tests. |
| Uneven JSON split | Initial divider is set after tab layout. Rebuilt window showed 50:50. |
| JSON horizontal jumps | Reveal preserves horizontal offset and skips repeated selection. Keyboard/source navigation retained offset zero. |
| CSV Reload targeted hidden source | Focus now returns to the active presentation. Reload then Down selected the first table row. |
| Save As to CSV lost focus | The table now creates its row-number column before parsing; a columnless native table refused first responder. Save As from `.txt` to `.csv` then Down selected a row. An offscreen AppKit regression verifies this before parse completion. |

Save As from CSV to text and back preserved the full source bytes, including
CRLF, the quoted LF, Chinese, and Emoji. Extension changes rebuilt the available
views without replacing the document's source or undo manager.

## Package checkpoint and limits

The 21:09 local arm64 build occupied **888 KiB** on disk and **847,106 logical
bytes across 21 files**, including the extension and translations. The main
executable SHA-256 was
`fe6ceaa1ba77d5375baec26939c7e1421ef27ef293f48aafcacc01238b0d0bc7`.
Strict nested ad-hoc signature verification passed; the packaged LICENSE
matched the root MIT license. No third-party dependency or asset was added.
This checkpoint also includes the independently committed line-ruler and file
opening foundations, before their main-window integration.

Empty/error and narrow-window states, large-input native cancellation,
CSV/JSON performance targets, minimum macOS compatibility, VoiceOver, and the
remaining [implementation map](implementation-status.md) still need their own
evidence. A local ad-hoc build is not a signed/notarized public release.
