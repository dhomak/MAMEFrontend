# MAMEFrontend — minimal skeleton

A bare native launcher: scan your rompath, show a searchable list of the games
you actually own with real names, double-click to launch. Arm-native
(SwiftUI + your arm64 MAME build); no architecture-specific code.

## Requirements
- macOS 14+ (uses `@Observable`, `ContentUnavailableView`, `Table.primaryAction`)
- Xcode 15+
- A working `mame` binary (e.g. your Homebrew SDL3 arm64 build)

## Assemble
1. Xcode → New Project → macOS → App. Name it `MAMEFrontend`, interface SwiftUI,
   language Swift. Set the deployment target to macOS 14.0.
2. Delete the auto-generated `ContentView.swift` and `MAMEFrontendApp.swift`.
3. Drag these five files into the target:
   `MAMEFrontendApp.swift`, `Game.swift`, `MAMERunner.swift`,
   `LibraryModel.swift`, `ContentView.swift`.
4. Build & Run. On first launch, open **Settings** and pick your `mame` binary
   (e.g. `/opt/homebrew/bin/mame`) and your ROM folder.

Runs **unsandboxed** — same posture as your other tools. It spawns an external
binary and reads an arbitrary folder, so keep App Sandbox / Hardened Runtime
**off**. Turning them on later means security-scoped bookmarks + entitlements.

## How it works
- `mame -listfull` → shortname→description map for every machine MAME knows
  (parsed once, cheap two-column output — deliberately *not* `-listxml`).
- Scan rompath for `*.zip` / `*.7z`, take basenames as owned short names.
- Intersect the two → the owned list, sorted by description.
- Launch = `mame -rompath <dir> <shortname>`, fire-and-forget in its own window.

## Known limitations / obvious next steps
- **Merged sets**: clones living inside a parent archive aren't listed
  individually. Enrich with `cloneof` data from `-listxml <parent>` (stream it
  with `XMLParser`/SAX on a background queue and cache — never DOM-load the full
  40k dump on the main thread).
- No artwork, genres (`catver.ini`), favorites, or last-played yet.
- Verify MAME CLI flags against `mame -help` for your build before trusting them.

## Unverified in a container
SwiftUI/AppKit can't compile or render on Linux, so UI behavior here is
untested — build in Xcode and eyeball it, same as your MusicToolsNative flow.
