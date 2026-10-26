#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build -c release --arch arm64 --disable-automatic-resolution
binary_dir="$(swift build -c release --arch arm64 --show-bin-path --disable-automatic-resolution)"
app_path="$project_root/build/File Editor.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/FileEditor" "$app_path/Contents/MacOS/FileEditor"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
strip -x "$app_path/Contents/MacOS/FileEditor"
codesign --force --sign - "$app_path"
codesign --verify --strict "$app_path"
du -sh "$app_path"
printf '%s\n' "$app_path"
