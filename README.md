# Folivyn

Folivyn is a lightweight, native text and code editor for macOS. Open a file, make your changes, and get on with your day.

**English** · [简体中文](README.zh-CN.md)

Folivyn is a personal project that is actively being improved. Feedback, bug reports, and ideas are welcome in [GitHub Issues](https://github.com/Amoo1121/Folivyn/issues).

## Features

- **Multiple tabs.** Keep files open together, with separate undo histories, selections, and scroll positions.
- **Reload from disk.** Pick up changes made by other tools. If you have unsaved edits, cancel, discard them, or save a copy before reloading.
- **Local syntax highlighting.** Read Python, Java, JavaScript, TypeScript, JSON, JSONC, and shell scripts with basic syntax colors. Other text formats open normally.
- **Find and replace.** Use the native find bar for literal search, next/previous matches, and replacement within the current tab.
- **Finder Quick Look.** The bundled extension provides a read-only, syntax-colored source preview. Python and JSON have been verified through Finder's Space key; provider selection for other types depends on macOS and installed apps.
- **CSV and TSV tables.** Read string-valued cells, choose comma or tab delimiters, use an optional display header, and edit one cell through the document's existing undo history.
- **JSON navigation.** Browse a collapsible tree beside the source, search keys and values, and copy unambiguous JSON Pointers. Duplicate keys and original number spellings remain intact.
- **Careful file handling.** Preserve supported encodings, byte-order marks, and line endings. Check for external changes before saving and report conflicts.
- **Fully offline.** Editing and highlighting work without an account, connection, or downloaded language packs. No telemetry or online services.
- **Native and compact.** Built with Swift and AppKit, using macOS system frameworks and no third-party packages.

## Build and run

Requires an Apple Silicon Mac running macOS 14 or later and Xcode with Swift 5.9 or newer. Compatibility testing on macOS 14 is still pending.

```sh
git clone https://github.com/Amoo1121/Folivyn.git
cd Folivyn
./scripts/build-app.sh
open "build/Folivyn.app"
```

The script builds an arm64 release app and signs it locally. It selects `/Applications/Xcode.app` when available; set `DEVELOPER_DIR` to use another Xcode installation. The local build is not notarized by Apple.

## Using the editor

| Action | Shortcut |
| --- | --- |
| New file | `⌘N` |
| Open files | `⌘O` |
| Save | `⌘S` |
| Save as | `⇧⌘S` |
| Reload from disk | `⌘R` |
| Close tab | `⌘W` |
| Find / replace | `⌘F` / `⌥⌘F` |
| Next / previous match | `⌘G` / `⇧⌘G` |
| Find selected text | `⌘E` |
| Previous / next tab | `⇧⌘[` / `⇧⌘]` |

A dot next to a tab's name indicates unsaved changes. The status bar shows its encoding, language, path, and any detected external changes. External files are checked when the app becomes active and before saving; reloading is manual.

### Languages

English is the default language. Simplified Chinese is included. The interface follows your macOS language preference, with English as the fallback. All translations ship with the app.

### Supported files

- Text files up to **10 MiB**, encoded as UTF-8 (with or without BOM) or UTF-16 LE/BE with BOM.
- Basic syntax highlighting up to **200 KiB** and **20,000 lines**. Larger documents remain editable as plain text.
- CSV/TSV table views support **5 MiB** of decoded UTF-8 text, **100,000 records**, **256 columns**, and **250,000 fields**. Each cell is text; formulas are not executed and numbers are not inferred. Missing fields must be added in Source.
- JSON trees support **1 MiB** of decoded UTF-8 text, **128 nested containers**, and **100,000 values**. Trees are read-only; edit the source to change JSON. Invalid or over-budget structures keep their source editable. JSONC remains source-only.
- Quick Look reads at most **200 KiB** of encoded text or **2,000 lines**, marks truncated previews, and rejects invalid encoding or binary controls. It never edits or runs the file.

Files with unsupported or invalid encodings are rejected without replacement decoding. Symbolic links are saved through to their targets; files with multiple hard links must be saved to a new location. Saving checks for external changes, but simultaneous writes by other processes can still race the final check and replacement.

### Finder preview

Launch the built app once, then select a supported file in Finder and press Space. The preview header says **Folivyn · Read-only preview** when this extension is active. macOS may select another installed provider; CSV currently opens with Numbers' preview on the tested Mac. Folivyn does not change your default opening app. See [Quick Look setup and verification](docs/quick-look-validation.md) for local-build registration, tested types, and limitations.

### Structured files

CSV and TSV open in Table view. Double-click an existing cell to edit its full value, including embedded line breaks, then choose Apply. The display uses `↵` for line breaks; the file keeps its original text. Use Source to edit text directly. Switching views, changing the delimiter, or using the first row as a header never rewrites the file.

JSON opens with Source and Tree side by side. Selecting a node locates its exact source token; selecting source text locates its containing node. Search the tree, then use Previous or Next to navigate results. Duplicate paths disable Copy JSON Pointer because they do not identify one unique value.

## Development

Run the file-handling, editing-session, and localization tests:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path build/TestBuild
```

The code is organized into `EditorApp` (AppKit interface), `EditorUI` (shared highlighting and interface strings), and `EditorCore` (file access and text models). Localized strings live in each target's `Resources/en.lproj` and `Resources/zh-Hans.lproj` directories.

See the [native acceptance record](docs/native-validation.md) for tested file-handling and editing flows, offline checks, and verification limits.
The [structured-view validation record](docs/structured-views-validation.md) covers CSV/JSON edits, navigation, and their remaining acceptance work.

## Roadmap

Line numbers, jump to line, more file-opening workflows, and draft recovery are in progress. See the [implementation map](docs/implementation-status.md) for the wider scope and remaining validation gates.

## Contributing

Bug reports, focused pull requests, and translation improvements are welcome. Please include your macOS version and steps to reproduce an issue. For file-handling bugs, provide a small, non-sensitive sample and describe the expected encoding and line endings.

See [Contributing](CONTRIBUTING.md) for code and asset provenance requirements.

## License

Folivyn is licensed under the [MIT License](LICENSE). Copyright (c) 2026 Amoo1121.
