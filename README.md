# File Editor

A lightweight, native text and code editor for macOS. Open a file, make your changes, and get on with your day.

**English** · [简体中文](README.zh-CN.md)

## Features

- **Multiple tabs.** Keep files open together, with separate undo histories, selections, and scroll positions.
- **Reload from disk.** Pick up changes made by other tools. If you have unsaved edits, cancel, discard them, or save a copy before reloading.
- **Local syntax highlighting.** Read Python, Java, JavaScript, TypeScript, JSON, JSONC, and shell scripts with basic syntax colors. Other text formats open normally.
- **Careful file handling.** Preserve supported encodings, byte-order marks, and line endings. Check for external changes before saving and report conflicts.
- **Fully offline.** Editing and highlighting work without an account, connection, or downloaded language packs. No telemetry or online services.
- **Native and compact.** Built with Swift and AppKit, using macOS system frameworks and no third-party packages.

## Build and run

Requires an Apple Silicon Mac running macOS 14 or later and Xcode with Swift 5.9 or newer. Compatibility testing on macOS 14 is still pending.

```sh
git clone https://github.com/Amoo1121/macos-file-editor.git
cd macos-file-editor
./scripts/build-app.sh
open "build/File Editor.app"
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
| Previous / next tab | `⇧⌘[` / `⇧⌘]` |

A dot next to a tab's name indicates unsaved changes. The status bar shows its encoding, language, path, and any detected external changes. External files are checked when the app becomes active and before saving; reloading is manual.

### Languages

English is the default language. Simplified Chinese is included. The interface follows your macOS language preference, with English as the fallback. All translations ship with the app.

### Supported files

- Text files up to **10 MiB**, encoded as UTF-8 (with or without BOM) or UTF-16 LE/BE with BOM.
- Basic syntax highlighting up to **200 KiB** and **20,000 lines**. Larger documents remain editable as plain text.
- CSV and JSON can be edited as text. Dedicated CSV tables and JSON tree views are planned.

Files with unsupported or invalid encodings are rejected without replacement decoding. Symbolic links are saved through to their targets; files with multiple hard links must be saved to a new location. Saving checks for external changes, but simultaneous writes by other processes can still race the final check and replacement.

## Development

Run the file-handling, editing-session, and localization tests:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path build/TestBuild
```

The code is organized into `EditorApp` (AppKit interface and highlighting) and `EditorCore` (file access and encoding). Interface strings live in each target's `Resources/en.lproj` and `Resources/zh-Hans.lproj` directories.

## Roadmap

CSV table and JSON tree views, Finder Quick Look, find and replace, line numbers, and draft recovery are planned. These features are not included in the current app.

## Contributing

Bug reports, focused pull requests, and translation improvements are welcome. Please include your macOS version and steps to reproduce an issue. For file-handling bugs, provide a small, non-sensitive sample and describe the expected encoding and line endings.
