# MAMEFrontend — release (v0.3.1)

Everything here runs on your Mac (Xcode can't build from the container). Steps in
order; the Gatekeeper part (step 4) is the one that actually bites when handing
the app to another machine.

## 1. Install the icon
In Xcode, open `Assets.xcassets`, delete the existing **AppIcon**, then drag the
provided `AppIcon.appiconset` folder into the asset catalog. (Or, in Finder,
replace the project's `Assets.xcassets/AppIcon.appiconset` with this one.)
Target → **General → App Icon** should read `AppIcon`.

The set was cut from your image: cropped to the rounded card, corners rounded to
Apple's squircle radius, centered on transparency with the standard margin — so
it sits right next to native icons rather than showing wood edges.

## 2. Identity & version
Target → **General**:
- Version (`CFBundleShortVersionString`): `0.3.1`
- Build: `1`
- Bundle Identifier: e.g. `com.aalien.MAMEFrontend`
- Deployment target: **macOS 14.0**

Target → **Signing & Capabilities**: confirm **App Sandbox is absent** (the app
spawns an external `mame` and reads arbitrary folders — sandbox breaks both).

## 3. Build a Release
Command line (reproducible) — or just use the `package_alpha.sh` script, which
wraps steps 3–5:

```
xcodebuild -project MAMEFrontend.xcodeproj -scheme MAMEFrontend \
  -configuration Release -derivedDataPath build clean build
```

Result: `build/Build/Products/Release/MAMEFrontend.app`.

## 4. Sign & get past Gatekeeper
This build has no Developer ID, so other Macs will refuse it by default.
Ad-hoc sign so the bundle at least has a stable signature:

```
codesign --force --deep --sign - build/Build/Products/Release/MAMEFrontend.app
```

This is **not** notarized, so each tester still clears it once, either way:
- Right-click the app → **Open** → **Open** (first launch only), **or**
- `xattr -dr com.apple.quarantine /Applications/MAMEFrontend.app`

A smoother, warning-free experience needs a paid Developer ID + notarization.
For testing across your own machines, ad-hoc + right-click-Open is enough.

## 5. Package for handoff
Use `ditto`, not Finder's "Compress" or `zip`, so the bundle and signature
survive:

```
ditto -c -k --keepParent build/Build/Products/Release/MAMEFrontend.app \
  MAMEFrontend-0.3.1.zip
```

Send the zip. Tester unzips, moves to `/Applications`, right-click → Open.

## 6. What each tester needs
No ROMs or emulator are bundled. On first launch each tester opens **Settings**
and sets:
- **MAME binary** — their own arm64 `mame` (Homebrew `mame`, or a build)
- **ROM path** — their set
- **History file** (optional) — a `history.xml` / `history.dat`

The year cache, favorites, and last-played are per-machine (stored in that Mac's
`UserDefaults`), so everyone starts fresh.

## 7. Architecture
Built on Apple Silicon, the app is **arm64**. If every test machine is M-series,
you're done. For an Intel tester, build universal (Xcode destination "Any Mac",
or set `ARCHS=x86_64 arm64`) — and remember their `mame` must match their arch
too.
