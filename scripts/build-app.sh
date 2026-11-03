#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build -c release --arch arm64 --disable-automatic-resolution
binary_dir="$(swift build -c release --arch arm64 --show-bin-path --disable-automatic-resolution)"
mkdir -p "$project_root/build"
packaging_dir="$(mktemp -d "$project_root/build/package.XXXXXX")"
trap 'rm -rf "$packaging_dir"' EXIT
staged_app="$packaging_dir/Folivyn.app"
preview_path="$staged_app/Contents/PlugIns/FolivynPreview.appex"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
mkdir -p "$preview_path/Contents/MacOS" "$preview_path/Contents/Resources"
cp "$binary_dir/Folivyn" "$staged_app/Contents/MacOS/Folivyn"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
cp LICENSE "$staged_app/Contents/Resources/LICENSE"
for component in EditorUI EditorCore; do
    ditto "$binary_dir/Folivyn_$component.bundle" "$staged_app/Contents/Resources/Folivyn_$component.bundle"
    ditto "$binary_dir/Folivyn_$component.bundle" "$preview_path/Contents/Resources/Folivyn_$component.bundle"
done
cp Extensions/QuickLook/Info.plist "$preview_path/Contents/Info.plist"
ditto Extensions/QuickLook/Resources "$preview_path/Contents/Resources"
xcrun swiftc -O -whole-module-optimization -swift-version 5 \
    -target arm64-apple-macosx14.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -parse-as-library -application-extension -module-name FolivynPreview \
    -I "$binary_dir/Modules" -L "$binary_dir" -lPreviewSupport \
    -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -dead_strip \
    Extensions/QuickLook/PreviewViewController.swift \
    -o "$preview_path/Contents/MacOS/FolivynPreview"
strip -x "$staged_app/Contents/MacOS/Folivyn" "$preview_path/Contents/MacOS/FolivynPreview"
codesign --force --sign - --entitlements Extensions/QuickLook/Preview.entitlements "$preview_path"
codesign --force --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"
# Replace only this generated app after the complete nested bundle has validated.
app_path="$project_root/build/Folivyn.app"
rm -rf "$app_path"
mv "$staged_app" "$app_path"
du -sh "$app_path"
printf '%s\n' "$app_path"
