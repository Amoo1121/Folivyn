# Implementation and acceptance map

Baseline reviewed: `6b474f1` on 2026-10-27. This is a source and evidence audit,
not a new execution of the tests. Later implementation must add its own evidence
and must not treat this baseline as the status of a newer build.

The user's next goal is to verify all promised features, explicitly including
Finder's Space preview, fix defects, and continue implementing the design in
small GitHub commits. The earlier native acceptance covered the existing P0
text editor. It did not establish that Finder Quick Look or full V1 was complete.

## Scope and authority

- [Product specification](product-spec.zh-CN.md) defines P0, the complete V1
  behavior, and later exclusions. Sections 1, 2, 4, and 5 make Finder Quick Look,
  CSV tables, and JSON trees part of V1. Quick Look is explicitly required in
  V1; deferring it from P0 did not remove it from the product.
- [Technical plan](technical-plan.zh-CN.md) describes implementation direction,
  safety rules, and resource limits. `NSDocument`, tree-sitter, and a particular
  module layout are proposed architectural choices, not evidence that those
  components exist. Any different implementation must still meet the behavior
  and safety requirements.
- [Validation roadmap](validation-roadmap.zh-CN.md) supplies correctness gates,
  workloads, performance targets, and staged delivery. Targets are not measured
  results.
- [README](../README.md) currently describes shipping behavior accurately at this
  baseline: Quick Look, structured views, find/replace, line numbers, and recovery
  are planned. They must not be counted as accepted features merely because the
  existing editor passes tests.
- [Native acceptance record](native-validation.md) is the most recent evidence
  for code revision `3f93066`. Older 16-, 22-, and 27-test statements in historical
  documents do not supersede that record's 28-test result. The introductory
  status paragraphs in the product and technical plans still describe earlier
  P0 evidence; their behavior requirements remain applicable.

Status terms below: **observed** means the existing native record describes the
listed behavior; **partial** means an implementation or some evidence exists
but the whole requirement is not established; **missing** means the reviewed
source has no implementation of the required behavior; **unverified** means
implementation alone is insufficient to claim acceptance. None means full V1
is accepted.

## Existing editor requirements

| ID | Requirement and scope | Baseline state and evidence | Evidence still required |
| --- | --- | --- | --- |
| E01 | Open, edit, Save, Save As, New; P0 | **Observed.** `EditorApplication` routes native panels and `DocumentFile` performs bounded I/O. Native record covers expected file bytes and Save As preserving the source. | Regression on the final changed build, including new features using these paths. |
| E02 | Multiple tabs, duplicate-path focus, independent dirty/undo/selection/scroll/focus; P0 | **Observed.** One `EditorSession`, text view, and undo manager per tab. Native record covers three tabs, repeated open, shortcut navigation, selection/scroll persistence, and independent undo. `EditorSessionTests` cover isolation. | Include new view state and recovery state when those features are added; test many-tab overflow without losing access. |
| E03 | Dirty close/quit confirmation, cancellation and failed saves retain edits; P0 | **Observed.** Native record covers multi-tab quit cancellation, last-tab close, Save-panel cancellation, and a hard-link save failure. | Retest after introducing draft recovery and new document views; exercise the window close control as well as keyboard commands. |
| E04 | Reload Cancel / Discard / Save a Copy, load before replacing, failure preserves buffer, success clears old undo and clamps view; P0 | **Observed.** Native record includes all three branches, copy cancellation/failure, invalid/missing source, byte comparisons, and shortened-file caret handling. `EditorSessionTests` cover target-only undo clearing. | Retest derived-view invalidation and recovery baseline after Reload. |
| E05 | External-change warning on activation and conflict check before Save; P0 | **Partial.** Source calls `checkDiskChanges` from `applicationDidBecomeActive`. Save conflict has native evidence; six session tests include stale-check protection. The record expressly lacks independent evidence for activation alone. | Change a fixture externally while another app is genuinely active, return without Save or Reload, and observe the warning. Cover atomic replacement and deletion as well as ordinary writes. |
| E06 | Chinese composition, Emoji, combining text, undo/redo, selection; P0/V1 | **Partial.** Real Pinyin produced Chinese, correction and undo worked, and mixed Unicode saved exact bytes. Input tests cover marked text and completed coloring. | Real composition cancellation, candidate positioning, selection of a nondefault candidate, focus/tab switching during composition, RTL mixtures, and VoiceOver interaction remain outside the recorded evidence. |
| E07 | Local basic coloring, no text/undo changes, bounded work and stale-result rejection; P0 | **Partial.** Python colors were visible; input tests check attributes do not alter text/undo, and limits now include the 20,000-line threshold through undo/redo. `SyntaxHighlighter` debounces, cancels, and checks a revision before applying tokens. | Representative visible and token-level regressions for every advertised language and multiline/unfinished constructs; stress rapid edits and language changes. Do not describe the scanner as a parser or semantic validator. |
| E08 | Preserve supported encodings, BOM and unchanged line endings; P0 | **Observed within supported formats.** `DocumentFileTests` and native byte comparisons cover UTF-8, UTF-8 BOM, UTF-16 LE/BE BOM, CRLF and Unicode. Invalid sequences are rejected. | Mixed-newline editing/paste and explicit conversions need separate coverage. GBK/GB18030 support is not implemented. |
| E09 | Bounded opening and explicit coloring fallback; P0 | **Observed.** Exactly 10 MiB opened; 10 MiB + 1 byte was rejected; 20,001 lines and the byte limit lead to plain text. The current buffer survived rejected opens. | Long-line shapes and repeated open/edit/close resource behavior; these checks do not establish 100 MiB preview or a latency target. |
| E10 | Fully offline, no account/activation/downloaded resources/telemetry; all stages | **Observed for recorded P0 flows.** Empty package dependencies, bundled translations, 28 denied-network tests, and a denied-network Chinese GUI session with open/edit/save/copy/reload/Finder entry. | Repeat the network-denied first-use workflow for each new extension or feature. Never count an online dependency download as runtime offline behavior. |
| E11 | English default and Simplified Chinese; all stages | **Observed for existing UI.** Resource tests check matching keys/placeholders; packaged-resource fallback and a visible Chinese session were recorded. | New menus, errors, previews, empty states, and accessibility labels in both languages; verify narrow-window layouts. |
| E12 | Native compact package and bundled MIT license; all stages | **Observed for P0.** The recorded arm64 app totals 270,785 bytes, allocation 292 KiB, below the 15 MiB P0 budget. Strict ad hoc signature passed; license matches root. | Measure the final app including extensions/resources, report logical size and allocation, verify each nested signature, and repeat dependency/provenance checks. |

## Missing or incomplete product behavior

| ID | Requirement and source | Baseline state and concrete gap | Acceptance needed before claiming support |
| --- | --- | --- | --- |
| F01 | Finder Space preview; product §§2, 4 and technical §8 | **Missing.** `Package.swift` builds only the main executable and two resource bundles. No preview extension, `QLPreviewingController`, extension manifest, or embedding step exists. Main-app `CFBundleDocumentTypes` is an Open With registration, not Quick Look. | Embed/register a modern preview extension; select each published supported type in Finder and press Space; verify Folivyn's read-only content and syntax colors, not a system/provider fallback. Test extension discovery/cache/provider conflicts, reopen, Unicode/BOM, invalid inputs, large-file truncation, offline use, English/Chinese, and unchanged file bytes. Report extension resources separately. |
| F02 | Open With, open dialog, file drag/drop, unknown/extensionless text; product §§2, 5 and technical §8 | **Partial.** Native Open With and panels work. No explicit file-drop destination exists. General text UTIs are declared, but that does not prove every extension's routing. A native text view accepting a pasted filename is not a file-open workflow. | Drag supported files from Finder into the window, verify new/reused tabs, preserve an active dirty document, reject unsupported files clearly, and cover extensionless/hidden configuration files. Do not change global default associations during tests. |
| F03 | Recent files; product §5 | **Missing.** No recent-documents registration/menu exists in `EditorApplication`. | Open/reopen recent files, unavailable/moved files, clear history, and locale labels; ensure no duplicate writable tab. |
| F04 | Literal find/replace; product §§3, 5 and technical §4 | **Missing.** Menus provide editing commands but no find/replace UI or configured finder. | Find next/previous, case options if exposed, empty/no-match behavior, replace/replace-all, exact Unicode ranges, and one coherent undo transaction per operation. Verify per-document targeting and bounded long-file work. Regex is not a V1 requirement. |
| F05 | Line numbers and jump to line; product §§3, 5 and technical §4 | **Missing.** A scroll view wraps the text view without a line-number ruler or jump control. | Logical lines with CRLF/mixed newlines, soft wrapping, Unicode, scrolling, edits/undo, last empty line, invalid line input, and clamping. Keep display work proportional to the viewport. |
| F06 | Basic indentation, unindent, comment toggle, bracket matching; technical §4 | **Missing as explicit code-editor features.** System text editing is present but no language-aware commands or bracket decoration are implemented. | Selection/caret behavior, multiline and mixed newline preservation, exactly reversible edits, marked-text safety, and behavior for unknown languages or unmatched delimiters. |
| F07 | Manual language selection and broader syntax coverage; product §3 and technical §4 | **Partial.** Filename-based Python, Java, JS/TS, JSON/JSONC and Shell are implemented. No language selector; Swift, C/C++, Go, Rust, YAML, TOML, Markdown, SQL and XML/HTML/CSS are not implemented. | Explicit language override including extensionless files, persistence rules, plain-text fallback, per-language fixtures and budget measurements. The broad list is a validation candidate list; publish only languages actually accepted. Third-party grammar import needs prior provenance/license/version review. |
| F08 | Encoding/newline status and explicit conversions; product §§3, 5 and technical §7 | **Partial.** Encoding is shown and preserved; newline style is not shown. No manual decode selection, save encoding conversion or newline conversion UI exists. | Show LF/CRLF/CR/mixed status; explicit, undoable or clearly confirmed conversion without implicit save normalization. Validate supported historical encodings with exact round trips before exposing them. Preserve raw bytes on failed decoding. |
| F09 | Recognize unsupported binary formats and offer system opening; product §3 and technical §7 | **Partial.** Invalid Unicode is rejected, but valid UTF-8 bytes alone do not establish that a file is suitable editable text; there is no binary-format classifier or system-open action. | Bounded identification that handles supported UTF-16 before NUL heuristics, friendly unsupported-format UI, and a deliberate system-open action that does not execute content inside Folivyn. |
| F10 | Continuous external-file coordination and identity after replacement; technical §7 | **Missing beyond P0 checks.** Activation/save checks exist; no watcher/file coordinator or presenter exists. | External writes, git-style atomic replacement, rename/delete/recreate, same-byte replacement, local dirty state, event bursts, and race/error paths. Do not promise elimination of all concurrent-write races from a snapshot check alone. |
| F11 | Draft recovery without overwriting newer disk data; product §5 and technical §7 | **Missing.** No persistent draft storage, revision journal or restore UI exists. | Durable snapshots for unsaved/new and modified saved documents; forced-process termination and restart; exact recovered revision and Unicode bytes; deleted/changed disk source; corrupt snapshot; explicit discard/cleanup. Recovery must create an independent draft or require conflict resolution, never silently overwrite current disk contents. State the persistence interval and possible loss window. |
| F12 | CSV/TSV virtual table and source switching; product §§3–4 and technical §5 | **Missing.** Both currently use the plain text editor. No parser, range map, table UI or structured edit API exists. | Quote-aware scanning with commas/tabs, quotes/newlines/escapes, trailing/empty/missing fields, string-only values, optional header affecting display only, and explicit delimiter choice. Virtualize rows, bound columns/materialization, and keep source editable on parse failure or budget excess. |
| F13 | CSV local cell edits in the same undo chain; product §4 and technical §§3, 5 | **Missing.** There is no revision-checked structure-edit transaction. | Change one field using its UTF-16 source range; preserve every unrelated byte, delimiter/BOM/newline and original quoting where untouched. Alternate source and cell edits with undo/redo. Reject stale maps; do not edit missing-field placeholders, execute formulas, infer types, or reserialize the full table. |
| F14 | JSON tree, source mapping and key/value search; product §§3–4 and technical §6 | **Missing.** JSON has coloring only. | Lazy collapsible tree, source-to-tree and tree-to-source location, search, valid/invalid editing transitions, error location, duplicate occurrences and raw numeric/escape lexemes preserved. Bound depth/node work; keep source usable. JSONC/JSON5 fallback must be explicit. Tree structural editing is not required for V1. |
| F15 | One text source, document revision, stale-result protection across views; product §4 and technical §3 | **Partial for text only.** Per-session text/undo is present; disk and highlighter generations are separate. There is no general document revision or shared structured edit protocol. | Before F12–F14, establish revision-checked range edits that use the native text-edit protocol once, update dirty/undo coherently, respect marked text, and invalidate all derived views on text change/reload. Prove late parses cannot replace current state. |
| F16 | Large/complex-file bounded preview and graceful fallback; product §3 and roadmap §§3–4 | **Partial.** P0 rejects files above 10 MiB and disables coloring above its budgets. No 100 MiB prefix preview/read-only path exists. | Clearly labeled partial read-only preview, no accidental full-file save from a prefix, cancellation, and bounded input/line/parse work. Validate very long lines, huge row/column counts, deeply nested JSON and huge arrays. Full indexed search/scroll of giant logs is separate later work. |

## Reliability, performance and distribution gates

| ID | Gate | Current evidence and remaining requirement |
| --- | --- | --- |
| G01 | File-write durability and metadata | Existing tests cover POSIX permissions on local APFS, symlinks, refused multiple hard links, conflict checks and ordinary failed writes. ACL/xattrs, read-only volumes, disk-full behavior, termination during write, and network/cloud locations are not established. Define each policy and test it; atomic replacement alone is not a complete durability result. |
| G02 | Real startup and input latency | **Unverified.** Roadmap targets are process-cold 1 MiB visible P95 ≤800 ms / editable ≤1 s; warm-open visible P95 ≤200 ms; 10 MiB input-to-paint P95 ≤30 ms. At least 30 samples per regular startup scenario, hashes, system load, cache state, P50/P95/max, and external visible/editable timing are required. Process creation time or one CUA call is not equivalent. |
| G03 | Memory and idle CPU | Existing footprint observations are 38 MB small-file current / 92 MB peak and 94,946,288 bytes current / 174,556,144 peak for a two-tab large-file session. They are not empty-window or single-page benchmarks. Validate ≤100 MiB empty and ≤250 MiB for one ordinary 10 MiB document, steady idle CPU over a fixed interval, and report extension/parse costs separately. |
| G04 | Structured-view and huge-preview timing | **Missing features, unmeasured targets.** For 5 MiB CSV / 1 MiB JSON: first structured screen ≤500 ms and full parse target ≤2 s with source usable. For the 100 MiB bounded log preview: first screen target ≤1 s and cancellation. |
| G05 | Supported systems and accessibility | macOS 26 arm64 is the only recorded execution environment; macOS 14 minimum compatibility and VoiceOver are unverified. Intel is not promised by the current arm64 build. Test the stated minimum before claiming it verified; add architectures only after building and running them. |
| G06 | Distribution | Local ad hoc signature is verified; Developer ID, notarization, extension loading under the intended signing setup, and DMG delivery are not established. These are distribution gates, distinct from completing a locally testable prototype. Do not claim public notarized release from a successful local build. |
| G07 | Provenance, dependencies and license | The current design uses system frameworks and no third-party package/assets. Follow `AGENTS.md` and `CONTRIBUTING.md`: independent implementation; document any external component's source, fixed version, rights/notices and size before integration. MIT must be packaged. Automated tests or generated code do not establish worldwide originality. |
| G08 | Small GitHub increments with auditable evidence | Each functional increment should be a focused commit with relevant tests/build/UI observations and updated current support documentation. Verify the pushed commit and clean/intentional worktree state. A documentation-only claim cannot substitute for implementing or exercising the feature. |

## Suggested implementation sequence

1. **Finder Space end to end (F01).** The user explicitly called out this gap.
   Separate only the read-only bounded text/highlighting pieces needed by a
   preview extension, embed and sign it, then prove actual Finder invocation.
   Keep an explicit supported-type list. A custom preview inside the editor or
   `qlmanage` registration output alone does not meet this requirement.
2. **Close current evidence gaps while preserving the safety baseline
   (E05–E07).** Verify activation, composition transitions and per-language
   behavior; address defects before adding more mutation routes. Keep existing
   byte, reload, last-tab and offline regressions.
3. **Daily text workflows (F02–F08).** Add drop/recent-file entry, literal
   find/replace, line numbers/jump, and the small code-editing commands in separate
   increments. Implement a shared revision-checked edit path where a new command
   needs one; avoid parallel writable models. Add explicit newline/encoding UI
   only with exact-byte tests.
4. **Durability and recovery (F09–F11, G01).** Establish document identity,
   watcher/coordination behavior and independent durable drafts before adding
   complex editing. Each failure path must preserve local work and current disk
   data. Prefer read-only or deferred behavior when a parser/view is stale.
5. **Structured foundations and views (F12–F15).** First test original CSV/JSON
   scanners and UTF-16 source maps against adversarial fixtures. Then connect the
   JSON read-only tree and CSV virtual table; only enable cell writes after
   revision and undo correctness pass. Viewing must never reserialize text.
6. **Resource and release gates (F16, G02–G06).** Measure complete workloads on
   Release builds and enforce bounded fallback. Finish remaining input and
   accessibility coverage, minimum-system checks and the separately identified
   signing/distribution work. Re-measure package size with every added resource.

This sequence changes priority, not scope. PDF/image previews, Markdown
rendering, folder search, bulk CSV operations, JSON structural editing,
multicursor/folding, a terminal, project indexing, plugins, AI, and LSP remain
later work as specified; they are not prerequisites invented by this audit.
