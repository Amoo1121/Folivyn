# Source provenance review

Date: 2026-10-26

Reviewed revision: `d44b57d8b01d7c3b1866b3ba012ce208ba7c3eef`

## Result

The review found no indication of uncredited third-party implementation code or
third-party media in the reviewed repository or inspected application bundle.
This is a finding within the scope below, not proof that every line is unique or
a guarantee of legal clearance.

## Scope and evidence

Two agents separately performed read-only reviews of the application and its
resources, and of the core implementation and tests. The review also covered
package configuration, the build script, tracked-file inventory, Git history,
documentation references, and the built application's linked libraries.

- The reviewed revision contains 24 tracked files, all text, and four commits.
  Its history has no merge commits or Git submodules.
- `Package.swift` declares no external package dependencies. The inspected
  SwiftPM workspace state also has empty dependency, artifact, and prebuilt
  inventories. No `Package.resolved` file is present.
- No vendored libraries, language grammars, query files, themes, images, icons,
  or fonts were found in the tracked files.
- The inspected `Folivyn.app` contains nine files: its executable, configuration,
  signing metadata, and English and Simplified Chinese localization resources.
  It contains no bundled third-party framework or media assets.
- `otool -L` lists only libraries under `/System/Library/Frameworks` or `/usr/lib`,
  including AppKit, Foundation, CryptoKit, and the system Swift runtime. The
  project uses these platform APIs; it does not claim ownership of them.
- The application uses AppKit/TextKit directly. Its syntax highlighting uses a
  small character scanner. No copied upstream copyright header or identifiable
  external implementation was found in the reviewed source.
- The technical plan cites Apple documentation, standards, and projects such as
  Scintilla, STTextView, CodeEdit, and tree-sitter. These are research references;
  those editor libraries and parsing packages are not integrated in this revision.

## Limits

A small number of exact searches for distinctive source phrases and identifier
combinations did not identify a matching external implementation. Search results
are incomplete: they do not cover all public code, unindexed material, private
code, or code with different wording. No exhaustive similarity scan was performed.

The initial implementation entered Git in one commit. Commit authorship and
timestamps establish repository history, but cannot independently establish the
origin of every line before that commit. Ordinary API usage, language keyword
lists, and common programming patterns are not, by themselves, copying evidence.

This review does not provide a legal opinion, a warranty of originality, or a
patent or trademark clearance. Future contributions and dependency changes need
their own provenance and license review. License and policy documents added after
the reviewed revision are outside this snapshot; a standard license text is not
third-party application implementation code.
