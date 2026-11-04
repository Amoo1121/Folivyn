# Read-only preview and file observation validation

2026-11-04, Apple M4 arm64, macOS 26.5.1, Xcode 26.6. These results
cover the local development build, not a notarized release or macOS 14.
Synthetic files live in the ignored `build/validation-runs/20261104-preview`.

## Native checks with networking denied

The main app was launched using `sandbox-exec` with `(deny network*)`, in English.

- A 100 MiB log opened in a distinct read-only tab, showing exactly 204,800
  displayed bytes and the 104,857,600-byte source size. The prefix and 200 KiB /
  2,000-line limits were visible. Save was disabled; Command-S, Shift-Command-S
  and paste left the view unchanged. The editable session's source remains empty.
- NUL/control data and invalid UTF-8 opened as unavailable previews with specific
  errors. No replacement decoding or writable document was created.
- Switching between preview and editable tabs kept each source separate. After
  an external prefix change, Reload displayed `RELOADED LARGE PREVIEW` while
  retaining the read-only limit and disabled Save state.
- With the editor frontmost, a plain write and an atomic path replacement each
  updated the external-change warning without Save, Reload or activation. Text
  stayed at the prior baseline until explicitly reloaded.
- With local edits, Reload > Save a Copy to an already-open binary preview was
  refused after the native replacement dialog. The target's original 18 bytes
  were verified unchanged. Local edits remained in the source tab.
- Replacing the source with NUL-containing data, then choosing Discard and Reload,
  produced a read-only-required message and retained the complete local draft.
  Saving that draft to a fresh path preserved exact UTF-8 and CRLF bytes.
- The Python fixture visibly showed current-line shading, correctly positioned
  paired parentheses, line numbers, Chinese and Emoji. Selection/caret navigation
  created no dirty state.

A second denied-network launch in Simplified Chinese verified the 100 MiB
prefix, byte counts, disabled Save and binary-control error in the translated UI.

Finder Space was separately rechecked after unlock against the existing 10 MiB
Python fixture. The actual Finder panel displayed `Folivyn · Read-only preview`
and the partial-preview budget. This Finder run was not independently launched
under a deny-network sandbox; the main-app offline evidence must not be treated
as extension first-use offline evidence.

## Automated coverage

FileOpeningDecision's 8 new tests cover strict UTF-8/UTF-16 classification,
control characters after decoding, oversized files and symlinks, invalid paths,
readonly session source/undo isolation, and cancellation before a task begins.
All 8 also pass with networking denied. The 18-test preview/presentation set passes.

DocumentFileObservation has 7 race/lifecycle tests; two session-integration tests
cover first-save binding and readonly exclusion. Real file tests include atomic
replacement, deletion/recreation, and parent-directory reconnection. A blocked
reader verifies one active read plus one coalesced follow-up, stale Save As/save/
reload results, stop and deallocation. The 9-test set passes.

The first combined run found one offscreen decoration test failure: the baseline
image already contained the new session-owned decoration. The fixture now
explicitly disables that controller before capturing the unadorned baseline;
the pixel assertion is retained. A production attachment check also prevents a
superseded controller from restarting. The resulting combined suite passes
208 tests (`build/decorations-complete-tests.log`). The same compiled bundle
also passes all 208 tests with network access denied (`build/preview-complete-offline.log`).
The initial offline command lacked DEVELOPER_DIR, so the two child-process
recovery tests could not locate xctest; rerunning with the explicit Xcode path
resolved that invocation error.

## Limits

Previewing is a bounded prefix, not indexed navigation/search over an entire
large file. A cancelled worker cannot publish stale results, but an already
blocked filesystem read may need to return before its worker exits. File metadata
is observed separately from prefix content. Preview tabs reload manually.

File events are hints and may be coalesced; fresh bounded reads compare against
the session baseline. This does not eliminate every cross-process save race or
establish network/cloud-volume behavior. The explicit default-app button leaves
Folivyn; when Folivyn is itself the default it reveals the file in Finder to avoid
reopening the same tab repeatedly. External third-party apps were not launched
as part of these tests.

Recovery storage is a separate foundation and does not yet establish an enabled
startup recovery flow. Broader acceptance and release gates remain in the
[implementation map](implementation-status.md).
