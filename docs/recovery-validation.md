# Draft recovery validation

2026-11-04, Apple M4 arm64, macOS 26.5.1 / Xcode 26.6. Local arm64 release app.
The native acceptance process ran with `(deny network*)` and an isolated private
recovery directory under the ignored `build/validation-runs` directory. The
`FOLIVYN_RECOVERY_DIRECTORY` development override changes only that location;
the same store validation and limits apply.

## Observed native flows

- Created an unsaved new document and edited a saved Python fixture. Both acquired
  private mode-0600 snapshots. Killed only this test app process with SIGKILL.
- Modified the original Python file externally before restarting. The startup
  dialog listed both drafts. Later kept both, and File > Recover Drafts reopened
  the list. Restore All created independent unsaved tabs with Reload disabled.
- The recovered new draft contained Chinese, Emoji, decomposed e + combining
  accent, CRLF and LF. Its first Save displayed a location panel. The resulting
  bytes exactly matched `Unsaved recovery 中文 🦊\r\ne\u0301 exact\n` encoded as UTF-8.
- The recovered saved-file draft retained its older local text and Python hint.
  The source still contained the newer external disk version; recovery did not
  read it into the draft or overwrite it.
- With two dirty tabs, chose Don't Save in the first quit prompt and Cancel in
  the second. Both tabs and both snapshots remained. Repeating quit and accepting
  both Don't Save prompts exited normally with zero remaining draft snapshots.
- A subsequent Chinese launch showed no recovery prompt for those cleared drafts.
  Opened UTF-16 BE BOM text and deleted its whole body without saving. After a
  second SIGKILL/restart, the Chinese prompt recovered an empty, dirty, independent
  tab with its UTF-16 BE BOM hint. Saving to a new path produced exactly `FE FF`;
  the original source bytes were unchanged. The window close button also completed
  cleanup and exited normally.

No personal documents were used. Test snapshots and sources are synthetic.

## Automated evidence

- Store: 24 focused tests cover exact UTF-16 content, generation checks, durable
  atomic replacement, directory permissions/identity, quota limits, live-process
  locks, damaged snapshots, and real child termination during an in-progress write.
  Closing an empty instance removes only its own empty directory; unknown or
  incomplete files are retained for inspection.
- Coordinator: 15 tests cover one serial writer, debounce/coalescing, late results,
  clear/capture ordering, bounded waits, retry, cancellation of quit, explicit
  recovery deletion, and saving an adopted copy before deleting its old reference.
- Session: 3 tests cover restored empty text, encoding hints, exact selection and
  Unicode, source independence, undo and withholding unfinished IME composition.
- The complete pre-cleanup checkpoint passes 247 tests normally and with all
  networking denied (`build/recovery-complete-tests.log`,
  `build/recovery-complete-offline.log`). After the two empty-directory tests,
  the 48-test focused store/coordinator/session/localization group passes in
  both Debug and Release (`build/recovery-focused-final.log`,
  `build/recovery-focused-release.log`).

## Behavior and limits

Snapshots are scheduled after 750 ms without edits, with a 5-second maximum
batching window. This is scheduling behavior, not a promise that storage I/O will
finish by a fixed deadline. Pending input-method composition is deferred. An
unapplied CSV cell editor is separate transient UI and is not snapshotted.

Recovery always creates a new UUID and an unsaved session without a file URL.
The original path supplies a name and syntax hint only. A successful claim first
persists a new copy, then removes the old one. A crash or cleanup failure between
those steps may leave duplicate recoverable copies instead of losing the only one.
Unreadable snapshots are kept, not silently deleted.

Quit cleanup begins only after all document close decisions succeed. It is
serialized with any outstanding save; a failed or timed-out cleanup leaves the
app open and re-schedules dirty drafts. No cross-process filesystem call is
claimed to be forcibly cancellable. Completed snapshots resist process death;
power loss, disk corruption/full-volume behavior and cloud filesystems are not
established by this record. Developer ID/notarization and minimum-macOS validation
remain separate gates.
