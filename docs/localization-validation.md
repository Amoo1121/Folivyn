# Folivyn: English and Simplified Chinese validation

Date: 2026-10-26. Revalidated after adopting the Folivyn name, including the executable, app identifier, and packaged resource bundles.

Folivyn uses English as its development language and includes Simplified Chinese. Menus, toolbar actions, status messages, dialogs, file errors, and plain-text highlighting labels use bundled translations. The interface follows macOS language preferences.

## Historical results from 2026-10-26

The following counts and measurements precede the final native-acceptance fixes.
Current results are linked at the end; these figures remain unchanged for traceability.

- 27 tests passed: 12 file-handling tests, 6 editing-session tests, 3 input-safety tests, and 6 localization tests.
- The same 27 tests passed with network access denied.
- English and Simplified Chinese resource keys and format placeholders match. Tests cover Unicode filenames, percent signs, file limits, and readable errors.
- The arm64 release app builds and passes `codesign --verify --deep --strict` with a local ad hoc signature.
- The packaged app contains both SwiftPM resource bundles under `Contents/Resources`. Resource loading checks that location before falling back to SwiftPM's development path.
- A separate Foundation executable compiled from the actual localization and file-error sources was placed in a temporary app bundle with copies of the shipped resources. Its SwiftPM development-path fallback was replaced with a fatal error. In network-denied processes, `AppleLanguages` values of `en`, `zh-Hans`, and `fr` resolved to English, Simplified Chinese, and English respectively for both UI and file-error text. No desktop interaction was used for this check.
- The Folivyn release app contains 10 files totaling 270,433 bytes (264.09 KiB). Filesystem allocation reported by `du -sh` is 292 KiB. The earlier 244 KiB result predates localization.

The application now also bundles the MIT license. Its text was checked against the standard GitHub license template, the packaged copy matches the repository file, and the rebuilt app passes strict signature verification. No Swift source changed for this packaging update.

## Reproduce automated tests

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path build/TestBuild

sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun xctest \
  build/TestBuild/arm64-apple-macosx/debug/FolivynPackageTests.xctest

./scripts/build-app.sh
codesign --verify --deep --strict "build/Folivyn.app"
```

## Native acceptance update: 2026-10-26 to 2026-10-27

This round of local functional acceptance is complete at code revision `3f93066`.
All 28 tests passed normally and with network access denied. The rebuilt arm64
Release app passes strict ad hoc signature verification; its 10 files total
270,785 bytes (264.44 KiB), with 292 KiB disk allocation and a matching bundled
MIT license.

Visible checks include English interaction, Chinese menus/buttons/status in a
network-denied process, real Pinyin input, Unicode byte preservation, and native
file-safety flows. The [native acceptance record](native-validation.md) documents
the observations and final highlighting-status regression check.

Pinyin candidate-window positioning was not visible in app-bound captures.
Automatic external-change notification on activation lacks independent UI
evidence; manual Reload and save conflicts were verified. Precise startup/input
P95, macOS 14 compatibility, Developer ID signing, and notarization remain
unverified. These results do not establish completion of the full V1 roadmap.
