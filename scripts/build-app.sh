#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build -c release --arch arm64 --disable-automatic-resolution
binary_dir="$(swift build -c release --arch arm64 --show-bin-path --disable-automatic-resolution)"
app_path="$project_root/build/Folivyn.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/Folivyn" "$app_path/Contents/MacOS/Folivyn"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp LICENSE "$app_path/Contents/Resources/LICENSE"
for component in EditorUI EditorCore; do
    ditto "$binary_dir/Folivyn_$component.bundle" "$app_path/Contents/Resources/Folivyn_$component.bundle"
done
strip -x "$app_path/Contents/MacOS/Folivyn"
codesign --force --sign - "$app_path"
codesign --verify --strict "$app_path"
du -sh "$app_path"
printf '%s\n' "$app_path"
