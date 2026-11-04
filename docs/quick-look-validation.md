# Finder Quick Look validation

Native Finder checks: 2026-10-27. Environment: Apple Silicon, macOS 26.5.1 (25F80),
Xcode 26.6 (17F113). These observations cover the local development build;
they do not establish a notarized release or compatibility with macOS 14.
Cancellation review, automated retest, and rebuilt Finder smoke check: 2026-11-03.

## Additional language routing — 2026-11-04

Finder Space displayed the Folivyn header and source colors for Swift, Go and
Rust fixtures, including Chinese/emoji, nested comments, raw strings and Rust
lifetimes. The original file hashes remained unchanged. The Swift action stayed
Open with Xcode; the final Go and Rust previews showed Open with Visual Studio
Code. These Finder invocations were not independently network-denied. A separate
main-app Chinese run denied networking and verified the Rust tab and language
menu; the combined 277-test suite also passed with networking denied.

Initially Go showed only a file icon. Go/Rust had dynamic identifiers inheriting
only `public.data`, so the source/text preview types did not match. The app now
imports fallback `.go` / `.rs` declarations under its own namespace:
`io.github.amoo1121.folivyn.go-source` and `.rust-source`, conforming to source
code and text. These are not claimed to be official Go/Rust identifiers.
The extension explicitly accepts them. The metadata was independently written
from [Apple's type-declaration documentation](https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app).

An intermediate exact Editor/Alternate association made macOS choose Folivyn as
the Go opening app. That extra association was removed. The final app retains its
previous broad text/source Alternate declarations; a rebuild and targeted local
Launch Services registration restored Visual Studio Code while retaining Folivyn
previews. No default-association setter or global registry reset was used.
`Alternate` does not guarantee that macOS can never select an app; fresh installs
and other app combinations still need validation. See [Apple's handler-rank keys](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html).

The final arm64 app, including current save protections, totals **1,505,901 logical
bytes** and **1,532 KiB** allocated. Executable SHA-256:
`8623651ed72a14b74457ecdae389f224f0bfa997c68d553ccb61da89fbaf5d8f`.
Strict nested ad hoc signature verification and packaged MIT license comparison
pass. This remains a local development build, not a notarized distribution.

## What was observed in Finder

The native UI checks used Finder's Space key on files in the ignored fixture
directory `build/validation-runs/20261026T141419Z-aae6ef29`. The identifying
header **Folivyn · Read-only preview** distinguished this extension from a
system or third-party fallback. Screenshots were inspected in the native
automation session; no screenshot files are included in this report.

| Fixture / action | Observed result |
| --- | --- |
| `sample.json` | Folivyn header, readable English/Chinese/Emoji, and syntax colors. |
| `saved-as.py` | Initially used a plain system preview. After adding the exact `public.python-script` type, displayed the Folivyn header, gray comments, and green strings. |
| `source-10485760.py` (10 MiB) | A bounded prefix and the explicit partial-preview message: 200 KiB or 2,000 lines. |
| `ql-utf16.py` | UTF-16 LE BOM identified correctly; Chinese and `👩🏽‍💻` displayed correctly. |
| `ql-binary.py` | Binary-control-character error shown instead of editable or repaired content. |
| `ql-invalid.py` | Invalid-encoding error shown. |
| `ql-empty.py` | Empty-file state shown. |
| `ql-refresh.py` | Closing the preview, deliberately changing the fixture on disk, and pressing Space again displayed the new contents. |
| Source preservation | The operator compared six preview-fixture hashes before/after previewing and recorded no changes. The later deliberate refresh-fixture write was separate. |
| `sample.csv` | Finder chose a Numbers-provided table. The Folivyn header was absent, so this is **not** a Folivyn CSV-preview pass. No global default application was changed. |

The CSV observation is a provider-selection limitation. Declaring CSV support
does not prove that Finder chooses Folivyn when another provider handles the
same type. The current extension displays read-only source text, not an editable
CSV table or JSON tree. Its selection, scrolling, and text copying do not write
to the previewed file.

## Type routing

The extension declares specific text/source UTIs in
[`Extensions/QuickLook/Info.plist`](../Extensions/QuickLook/Info.plist).
Listing a broad parent type was not sufficient for the Python fixture in this
environment. Each advertised type still requires a real Finder check; the
manifest is a routing request, not evidence that all listed types have passed.

The local type database reports `.ts` primarily as
`public.mpeg-2-transport-stream`, with `com.microsoft.typescript` as another
declared type. `.mts` resolves to `public.avchd-mpeg-2-transport-stream`.
Folivyn declares `com.microsoft.typescript` but does not claim either video
type or overwrite those extension mappings. Consequently, a TypeScript file
that Finder identifies as video is not guaranteed to use this text preview.
Unknown extensions returning dynamic `dyn.*` identifiers are also not a
published coverage guarantee. Apple advises against hard-coding those dynamic
identifiers. [Uniform Type Identifiers](https://developer.apple.com/videos/play/tech-talks/10696/)

## Build, signature, and development registration

From the repository root, build the app and its embedded extension:

```sh
./scripts/build-app.sh
```

The script creates a fresh staging bundle, copies local resources and the root
MIT license, compiles the extension with the system `_NSExtensionMain` entry,
signs the extension before the containing app, and verifies the nested bundle
before replacing `build/Folivyn.app`. It produces an arm64 build only.

For local development, the following commands explicitly register and enable
only Folivyn's extension, then inspect its selected version and path:

```sh
preview_path="$PWD/build/Folivyn.app/Contents/PlugIns/FolivynPreview.appex"
pluginkit -a "$preview_path"
pluginkit -e use -i io.github.amoo1121.Folivyn.Preview
pluginkit -m -A -D -v -i io.github.amoo1121.Folivyn.Preview
codesign --verify --deep --strict build/Folivyn.app
```

Close existing previews before replacing a development build. Confirm that
`pluginkit` reports the intended path; then select a fixture in Finder and press
Space. A registry entry or a successful signature check alone is not a preview
test. On this machine, the query showed one enabled instance at the path above.

`pluginkit` documents its add/remove operations as development interventions;
macOS maintains the normal registry automatically. To remove a development
registration, use `pluginkit -r "$preview_path"`; a bundle still present in a
discoverable location may be registered again. For an installed app, Quick Look
extensions can be enabled in System Settings > General > Login Items &
Extensions > Quick Look. A fresh-user installation has not yet been tested.
[Apple's extension settings](https://support.apple.com/guide/mac-help/mtusr003/mac)

The inspected extension has **ad-hoc signing**, no TeamIdentifier, and no
notarization ticket. This was sufficient for the recorded local development
checks, not proof that an internet-downloaded copy passes Gatekeeper or loads
on another Mac. A normal external release still needs its signing,
notarization, installation, and first-launch validation.
[Apple notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Bounds, process behavior, and cancellation

The preview uses a separate `QLPreviewingController` process and immutable text
snapshot. The view is noneditable, does not enable undo, and uses only local
resources. [`TextPreview`](../Sources/EditorCore/TextPreview.swift) opens files
read-only, checks the opened descriptor is a regular file, and reads at most
200 KiB plus seven lookahead/BOM bytes. It validates only this prefix, then
limits the displayed text to 2,000 lines. It never claims that unseen bytes in
a truncated file are valid. A Unicode scalar is not split at the byte boundary;
a combining sequence can extend beyond that boundary.

The controller cancels previous tasks and checks its request revision before
applying results. Review found that the underlying reader originally did not
observe cancellation. This was corrected with cancellation checks before
opening, between 16 KiB reads, during UTF-8/UTF-16 and line scanning, and before
returning. A `CancellationError` remains a cancellation rather than becoming a
file-read error. **Cancellation cannot interrupt a synchronous kernel read
already in progress**, including a stalled network-volume read. The byte budget
is not a wall-clock deadline.

After this correction, 14 focused `TextPreviewTests` passed on 2026-11-03
at 20:43:59 +0800 with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path build/QuickLookReviewTests --filter TextPreviewTests
```

These tests cover all supported encodings and empty files, exact Unicode
boundaries, malformed encoding, newline variants, the independent line limit,
an 8 GiB sparse file with an unread invalid tail, binary controls, directories,
missing files, FIFO rejection, hard links, read-only files, unchanged bytes,
and cancellation at every checkpoint exercised by the fixtures. A separate
test confirms the default callback observes an actually cancelled Swift Task
before attempting to open a missing file.

At 21:10 on 2026-11-03, the rebuilt extension was registered at the development
bundle path and checked through Finder Space again. Python and JSON both
showed the Folivyn header and expected content. The 10 MiB Python fixture showed
`Partial preview · Limited to 200 KiB or 2,000 lines`. Closing and immediately
reopening that preview showed the same correct bounded content, without a
stale-result or crash. This smoke check is not a latency/cancellation stress
benchmark. The extension executable SHA-256 for this check was
`4e34d6b280645f314cbc54690f9b3bb421ef53f4cb087d193422c34d3f029e71`.


## Sandboxing and measured resources

Inspection of the signed extension confirmed only these entitlements:

- `com.apple.security.app-sandbox`
- `com.apple.security.files.user-selected.read-only`

No network-client/server entitlement is present, no third-party dependency is
bundled, and the inspected executable links to system libraries. This supports
the offline design, but the **Finder-hosted extension has not yet been tested
in a separate deny-network run**. Earlier denied-network checks of the editor
do not prove this new process's runtime acceptance.

Before the cancellation correction, the inspected bundle occupied 568 KiB on
disk (`du -sh`): 525,870 bytes across 21 files, including a 228,434-byte extension.
The extension executable's SHA-256 was
`662f2210d4d2c96a1c39236f7e17e58d8725f3c21e02c5aa886132751107c885`.
The manifest's SHA-256 was
`c800ba5fe7d3be105868bc2b812abbade8b70bd2510eeb7b4ad8989497709177`.
These values identify that inspected artifact; later rebuilds may differ.

On 2026-10-27 at 00:40:42 +0800, `vmmap -summary` on the live Finder-hosted `FolivynPreview`
process reported physical footprint **16.3M**, with process-history peak
**22.0M**. This was one observation after mixed preview activity. It is not a
fixed-fixture benchmark, a cold-start measurement, an idle-leak test, or a P95.
It excludes the main editor and Finder processes.

## Remaining acceptance

- Extend the rebuilt Finder smoke check to repeated rapid switching across different files and recorded cancellation timing.
- Verify the extension's first-use workflow under denied network access.
- Verify Simplified Chinese extension UI, appearance changes, and all published file types.
- Resolve or document provider selection for CSV and other overlapping types using actual Finder evidence.
- Test installation on a fresh account/Mac, minimum supported macOS, and a signed/notarized distribution artifact.
- Measure repeated latency and resource behavior using the validation roadmap's fixed scenarios.
