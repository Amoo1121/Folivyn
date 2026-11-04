# Save destination consent and race validation

2026-11-04, Apple M4 / macOS 26.5.1, local arm64 Release app.

## Corrected behavior

Previously, choosing any Save As location passed unconditional overwrite consent
to the file layer, even for a filename that did not exist. A separate process
could create that filename between the existence check and atomic replacement.

New destinations without overwrite consent now use an exclusive temporary file
in the same directory, complete writes and file synchronization, then an atomic
`RENAME_EXCL` publication. An occupied target produces a conflict, with no fallback
to an overwriting rename. Temporary cleanup checks descriptor identity.

The save panel captures absence or a bounded raw-byte snapshot in its confirmed
filename callback, before macOS may display Replace. It validates the final URL
against that capture and does not silently recapture after confirmation. First
Save, Save As and Reload > Save a Copy use this expectation. Same-file saves keep
their original document snapshot. A conflict on a different Save As target does
not falsely mark the open source as externally changed.

## Automated checks

- Eight new core tests cover competing files, symlinks and directories at a
  deterministic pre-publication checkpoint; abort cleanup; replaced temporary
  names; empty/Unicode content in all four encodings; existing-save behavior;
  and a parent directory allowing write/search but not directory listing.
- Seven panel-choice tests cover post-confirmation creation, changed existing
  contents, binary targets without decoding, filename and symlink mismatch,
  resource/type failures, confirmation reset and retained capture errors.
- The complete **277-test** suite passes normally and with `network*` denied:
  `build/save-choice-complete-tests.log`, `build/save-choice-complete-offline.log`.

## Native checks

The Simplified Chinese app ran with networking denied and an isolated recovery
directory. A new document containing `draft 中文 🦊\r\n` saved to a fresh path;
exact UTF-8 bytes and clean status were verified.

Save As then selected an existing synthetic target. While macOS's Replace
question was visible, the target was externally changed. Clicking Replace led to
Folivyn's conflict alert. Cancel preserved the source tab, source bytes and newer
target bytes, without adding a false external-change warning to the source.

An unchanged existing target was replaced normally after native confirmation.
Finally, a local edit was saved to a fresh copy through Reload > Save a Copy;
the copy retained exact mixed CRLF/LF Unicode text, and the source reloaded its
original clean content. The application quit normally.

## Bounds and provenance

Capturing an existing replacement target uses the current 10 MiB raw read limit.
A larger target is rejected safely instead of allocating an unbounded snapshot.
Existing-file writes remain a checked replacement, not an atomic comparison with
another process: another writer can still intervene after the final check.
This change does not establish directory-sync or power-loss durability, metadata
preservation beyond previously tested POSIX mode, or cloud/network-filesystem
guarantees. An unsupported exclusive rename fails closed. Tests simulate a failed
checkpoint; they do not fill the user's disk or prove behavior under real power loss.

The implementation was written independently using the local macOS `rename(2)`,
`open(2)` and SDK contracts and Apple's
[confirmed filename delegate callback](https://developer.apple.com/documentation/appkit/nsopensavepaneldelegate/panel(_:userenteredfilename:confirmed:)).
No external implementation or fixture was copied. These checks do not establish
worldwide originality or complete the broader durability gate.
