# MAMEFrontend

A fast, native **MAME launcher for macOS** — built in Swift/SwiftUI for Apple Silicon. It scans your ROM set, gives every game a real name, artwork, genre, release year, working status, and history/trivia, and launches it in MAME with one keystroke.

No Electron, no web view — a single small `.app` that wraps the `mame` command-line binary you already have.

> ⚠️ **No ROMs, BIOS, or CHDs are included or distributed with this project.** It is a launcher only. You must supply your own, legally obtained MAME set.

![Screenshot](.github/images/screenshot.png)

---

## Features

### Library
- **Real names, not filenames** — resolves `mslug` → *Metal Slug - Super Vehicle-001* via `mame -listfull`.
- **Merged-set aware** — surfaces clones that live inside a parent archive (via `-listclones`), so a merged romset shows every playable machine, not just the parent zips.
- **CHD support** — detects CHD-only games (subfolders containing a `.chd`), supports a separate CHD/extra-ROM path, and launches disk games correctly.
- **Sortable, resizable columns** — Game, Genre, Manufacturer, Short name, Year, Last played. Column order/visibility/width and sort are remembered.
- **Fast search** — debounced, with precomputed keys, so filtering a 40k-machine set stays instant.

### Metadata (from `mame -listxml`, cached to disk)
- **Year** and **manufacturer**
- **Working status** dot — good / imperfect / preliminary
- **Disk badge** — shows which games need a CHD and whether it's present (gray) or missing (red)
- **Genres** from `catver.ini`, with a top-level category filter

### Filters
- Genre (category) dropdown
- A **Filter** menu: *Favorites only*, *Hide clones*, *Hide non-working*, *Hide non-games* (BIOS, devices, mechanical, and computer/console systems)
- All filters, plus search and sort, persist across launches

### Details inspector
- **Artwork** with a type switcher — Snap / Title / Marquee / Cabinet / Flyer / Cover / Bezel. Reads extracted folders, `.zip` (system `unzip`), and `.7z` (self-contained; see below).
- **History & trivia** from the History.dat project (`history.xml` or legacy `history.dat`), with parent fallback for clones.

### Favorites & recents
- Favorite any game (persisted)
- **Last played** column, stamped on launch

### Launching
- Runs MAME from its own directory so `diff/`, `cfg/`, `nvram/`, and `mame.ini` resolve exactly as they do from the command line.
- **Launch feedback** — if MAME fails to start (missing ROM/CHD, bad dump), the actual error is surfaced in an alert instead of failing silently.
- Deep-link into MAME's own input remapper via its Tab menu.

### Keyboard & menus
| Shortcut | Action |
|---|---|
| `Cmd F` | Focus search |
| `Return` | Launch selected game |
| `Space` | Toggle favorite |
| `Up / Down` | Navigate list |
| `Cmd R` | Reload library |
| `Cmd ,` | Settings |
| `Cmd Opt I` | Toggle details inspector |
| `Cmd Shift K` | Clear filters |

Window size/position, inspector state, and last selection are all restored on relaunch.

---

## Requirements

- **macOS 14 (Sonoma) or newer**
- **A MAME binary** — an Apple-Silicon build of `mame` (e.g. `brew install mame`, or a build from [mamedev.org](https://www.mamedev.org)). The frontend does not include MAME.
- A MAME ROM set (yours).

Everything below is **optional** but recommended:

| Data | Where to get it | Points the app at |
|---|---|---|
| History / trivia | [History.dat project](https://www.arcade-history.com/) (`history.xml` or `history.dat`) | *History file* |
| Genres | `catver.ini` (progetto-SNAPS `pS_CatVer`) | *catver.ini* |
| Artwork | progetto-SNAPS packs (`snap`, `titles`, `marquees`, …) as folders / `.zip` / `.7z`; or MAME `artwork` (bezels) | *Artwork folder* |
| CHDs | your disk images, in `<name>/<name>.chd` subfolders | *CHD / extra ROM path* |

---

## Setup

1. Launch the app, open **Settings** (`Cmd ,`).
2. Set the **MAME binary** (e.g. `/opt/homebrew/bin/mame` or `~/mame0288-arm64/mame`) and your **ROM path**.
3. Optionally set the CHD path, history file, `catver.ini`, and artwork folder.
4. **Save** — the library scans, then metadata fills in progressively (once; it's cached after).

**Artwork layout:** put your per-type packs in one folder and name them by type — `snap.7z`, `titles.7z`, `marquees.zip`, etc. (or extracted `snap/`, `titles/` folders). Use the dropdown in the inspector to switch types. *Bezel* reads per-game `<name>.zip`/`.7z` (MAME artwork packs) instead.

---

## Self-contained 7-Zip (optional)

`.7z` artwork is decoded with the `7zz` binary. To make it work on machines without Homebrew's `sevenzip`, **bundle `7zz` in the app**:

1. `cp /opt/homebrew/bin/7zz <project>/7zz` (or grab the universal console build from [7-zip.org](https://www.7-zip.org)).
2. Drag `7zz` into the Xcode project → check **Copy items if needed** and the **MAMEFrontend** target.
3. Ensure it's in **Build Phases → Copy Bundle Resources**.

The app finds the bundled binary first (copying it to Application Support and marking it executable if needed), and falls back to a system `7zz`/`7z`/`7za` otherwise. Without it, `.zip` and extracted-folder artwork still work everywhere. (`unzip` ships with macOS, so `.zip` needs no bundling.)

---

## Building

```bash
git clone <your-repo-url>
cd MAMEFrontend
open MAMEFrontend.xcodeproj
```

- Xcode 15+ (developed on Xcode 26).
- Deployment target **macOS 14.0**.
- **App Sandbox must be OFF** (Signing & Capabilities) — the app spawns an external binary and reads arbitrary folders; sandboxing breaks both.

### Alpha packaging

`package_alpha.sh` builds Release, ad-hoc signs, and zips the app with `ditto`:

```bash
./package_alpha.sh          # or: VERSION=0.1.1 ./package_alpha.sh
```

Since alpha builds aren't notarized, testers clear Gatekeeper once (right-click -> **Open**, or `xattr -dr com.apple.quarantine /Applications/MAMEFrontend.app`).

---

## Architecture

Plain Swift + SwiftUI, `@Observable` model, no third-party Swift dependencies.

| File | Responsibility |
|---|---|
| `MAMEFrontendApp.swift` | App entry point, menu-bar commands & shortcuts |
| `ContentView.swift` | Table, details inspector, settings sheet, all view state & persistence |
| `LibraryModel.swift` | `@Observable` model — scanning, filtering, launching, caching |
| `MAMERunner.swift` | `Process` wrapper for `-listfull` / `-listclones` / `-listxml` / launch; SAX metadata parser |
| `Game.swift` | The per-machine model struct |
| `Catver.swift` | `catver.ini` `[Category]` parser |
| `History.swift` | `history.xml` (SAX) and legacy `history.dat` parser |
| `Artwork.swift` | Artwork resolution (folder / zip / 7z), `ArtworkKind`, bundled-`7zz` resolver |

**Design notes**
- Metadata is fetched from `-listxml` in bounded batches (scoped to owned machines, not the full 40k dump) and SAX-parsed for constant memory.
- The display list is computed once into a cached array; search is debounced.
- MAME's giant `-listxml` is never DOM-loaded; archive listings are cached per session.

### Data storage
- **UserDefaults** (`com.aalien.MAMEFrontend`) — small prefs only: paths, filters, sort, columns, favorites, last-played, window/inspector state.
- **`~/Library/Application Support/MAMEFrontend/`** — `metaCacheV3.json` (the metadata cache; too large for UserDefaults) and the extracted `7zz` (if bundled). Delete `metaCacheV3.json` to force a metadata re-fetch.

---

## Roadmap

- [ ] **Cover-grid view** — thumbnail grid toggled against the table
- [ ] **Verify action** — wrap `mame -verifyroms` / `-verifychd` to flag incomplete sets
- [ ] More inspector tabs — `mameinfo.dat`, `command.dat`
- [ ] Software-list (console/computer) titles
- [ ] "Hide mature" and "hide missing-disk" filters

## Known limitations

- Software lists (console/computer game titles) are not yet supported — arcade/system machines only.
- Input remapping is done inside MAME (Tab menu), not in the frontend.
- Console/computer detection keys on a machine having a `<softwarelist>`; a rare arcade system that ships one may be classified as a non-game.
- Disk "present" checks the CHD filename exists, not its hash — a wrong-version CHD reads as present but is caught by launch feedback.

---

## Credits & license

- Not affiliated with or endorsed by the MAME project or MAMEdev. "MAME" is a trademark of its respective owners.
- Metadata/artwork come from community projects — **History.dat**, **progetto-SNAPS**, and **catver.ini** authors. Please support them.
- If you bundle `7zz`, note that **7-Zip** is licensed under the GNU LGPL (with BSD and unRAR-restricted portions); see [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

This project is released under the [MIT License](LICENSE) — see the file for details.

---

*A hobby project. Bring your own ROMs.*
