# Explicit text conversion validation

2026-11-04, Apple M4 / macOS 26.5.1, local arm64 Release app, denied-network launch.

## Native behavior

Pasted `first 中文 🦊\r\nsecond\nthird\rfourth\n`. Edit > Convert Line Endings >
CRLF changed the status from Mixed to CRLF. One Undo restored the original mixed
endings; Redo restored CRLF. The conversion itself did not save a file.

The Save panel exposed UTF-8, UTF-8 BOM, UTF-16 LE BOM and UTF-16 BE BOM. Selecting
UTF-16 BE BOM and saving to a fresh synthetic path produced exactly the expected
BOM and UTF-16 bytes, including CRLF and Unicode. A later Save As defaulted to
UTF-16 BE BOM. Selecting UTF-8 and cancelling left the file bytes, session encoding
and clean state unchanged. The accessory's final layout centers its encoding row
with side padding instead of placing the label against the panel edge.

A separate denied-network Chinese run verified the translated command, the padded
save-panel layout, CRLF-to-LF conversion and saving as UTF-8 BOM. Exact output
bytes matched the expected LF text; the prior UTF-16 CRLF file remained unchanged.

The packaged app totals 1470328 logical bytes. Its executable SHA-256 is
`3a0df9c7d0f3b3531af40d4d43dfe18616d2b8c19d4995c5d2e1d8dc998bda59`; the bundled MIT license matches the repository.

## Automated evidence

- Eight core newline tests cover mixed endings, exact Unicode preservation,
  last empty lines, no-op behavior, CRLF interior boundaries, surrogate-safe
  selections, cancellation and separate bounded input/output sizes.
- Ten session tests cover one undo transaction, no implicit save, mapped selection,
  no-op revision stability, shared pending-operation exclusion, stale source or
  selection, unreported Unicode normalization, IME, changed host, opened sheets,
  cancellation, budgets and an intervening CSV cell edit.
- Three encoding tests cover all sixteen same-path encoding pairs, empty/BOM-only
  files, and UTF-16 expansion past the encoded-byte limit preserving the original
  file and snapshot.
- The combined suite passes **249 tests** normally and with networking denied:
  `build/conversions-complete-tests.log`, `build/conversions-complete-offline.log`.
  The final side-padding change is visual only and is checked in the native panel.

Only explicit newline conversion rewrites CR/LF sequences. It retains NEL,
Unicode line/paragraph separators, embedded BOM characters and other source
characters. A document containing those separators may still report Mixed.
Input/output limits use UTF-16 units; saving independently enforces its encoded
byte limit. Unsupported legacy encodings such as GBK are not exposed or guessed.
Changing a selection or opening a sheet while conversion is running discards the
obsolete result. Encoding is applied only after confirming a save location, and
conflict routing carries the explicit choice into the next Save As panel.
