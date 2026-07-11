# MAMEFrontend

A fast, native **MAME launcher for macOS** — Swift/SwiftUI, built for Apple Silicon. It scans your ROM set, gives every game a real name, artwork, genre, year, manufacturer, working status, and history/trivia, and launches it in MAME with one keystroke.

No Electron, no web view — a single small `.app` wrapping the `mame` binary you already have.

> ⚠️ **No ROMs, BIOS, or CHDs are included or distributed with this project.** It is a launcher only. Bring your own, legally obtained MAME set.

![Screenshot](.github/images/screenshot.png)

---

## Features

### Library
- **Real names, not filenames** — `mslug` → *Metal Slug - Super Vehicle-001* (via `mame -listfull`).
- **Merged-set aware** — surfaces clones living inside a parent archive (`-listclones`), so a merged romset shows every playable machine, not just the parent zips.
- **CHD support** — detects CHD-only games, supports a separate CHD/extra-ROM path, and launches disk games correctly.
- **Sortable, customizable columns** — Game, Genre, Manufacturer, Short name, Year, Plays, Last played. Order, width, visibility, and sort all persist. Truncated cells show full text on hover.
- **Fast search** — debounced with precomputed keys, so a 40k-machine set stays instant.

### Search
Matches name, short name, **and manufacturer**. Year queries are understood:

| Type | Example |
|---|---|
| Exact year | `1996` |
| Decade | `199x` or `1990s` |
| Range | `1990-1995` |
| Anything else | plain text (`konami`, `metal slug`, `mslug`) |

### Metadata (from `mame -listxml`, cached to disk)
- **Year**, **manufacturer**
- **Working status** dot — good / imperfect / preliminary
- **Disk badge** — needs a CHD, and whether it's present (gray) or missing (red)
- **BIOS revisions** — resolved through the `romof` chain
- **Genres** from `catver.ini`, with a category filter

### Filters
A single **Filter** menu (its icon fills when anything is active):
- Favorites only
- Hide clones
- Hide non-working (preliminary drivers)
- Hide non-games (BIOS, devices, mechanical, computer/console systems)
- Hide mature (catver's `* Mature *` marker)

Plus a genre-category dropdown. A **status bar** shows "1,247 of 12,003 games" with a one-click **Clear**. All filters persist.

### Details inspector
- **Header** — title, short name, year, play count, manufacturer, genre, and badges (status, clone-of, CHD, mature)
- **Artwork** with a type switcher — Snap · Title · Marquee · Cabinet · Flyer · Cover · Bezel. Reads extracted folders, `.zip`, and `.7z`.
- **Launch options** (collapsible) — a **BIOS dropdown** and a free-form MAME arguments field, per game
- **Reference tabs** — **History** / **Info** (`mameinfo.dat`) / **Commands** (`command.dat`), with typographic formatting: section headings, key–value fields, and monospaced move lists

### Favorites, stats & launching
- Favorite any game; **Plays** counter and **Last played** column (sort by either for "most played" / "recently played")
- Plays only count when MAME **actually starts** — a failed launch rolls back
- **Launch feedback** — if MAME fails, its real error is surfaced in an alert instead of failing silently
- MAME runs from its own directory, so `diff/`, `cfg/`, `nvram/`, and `mame.ini` resolve exactly as they do from the command line

### Backup
**Export / Import** favorites, play counts, last-played, launch options, and BIOS choices as JSON. Import can **merge** (non-destructive: unions favorites, keeps the higher play count and newer date) or **replace**.

### Appearance
System / Light / Dark.

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

Right-click a game for **Play**, **Favorite**, **Reveal in Finder** (finds the zip *or* the CHD folder), **Copy Short Name**, **Copy Name**.

Window size/position, inspector state, and last selection are restored on relaunch.

---

## Requirements

- **macOS 14 (Sonoma) or newer**
- **A MAME binary** — an Apple-Silicon build of `mame` (`brew install mame`, or from [mamedev.org](https://www.mamedev.org)). Not included.
- A MAME ROM set (yours).

Optional, but each unlocks a feature:

| Data | Source | Setting |
|---|---|---|
| History / trivia | [History.dat project](https://www.arcade-history.com/) (`history.xml` or `history.dat`) | *History file* |
| Emulation notes | `mameinfo.dat` | *mameinfo.dat* |
| Move lists | `command.dat` | *command.dat* |
| Genres | `catver.ini` (progetto-SNAPS `pS_CatVer`) | *catver.ini* |
| Artwork | progetto-SNAPS packs, or MAME `artwork` (bezels) | *Artwork folder* |
| CHDs | disk images in `<name>/<name>.chd` subfolders | *CHD / extra ROM path* |

---

## Setup

1. Open **Settings** (`Cmd ,`).
2. **General** — set the **MAME binary** and **ROM path** (and the CHD path if your disks live elsewhere).
3. **Metadata** — optionally point at history / mameinfo / command / catver / artwork.
4. **Save.** The library scans, then metadata fills in progressively (a progress bar shows how far along). It's cached after the first pass.

**Artwork layout:** put per-type packs in one folder, named by type — `snap.7z`, `titles.7z`, `marquees.zip`, or extracted `snap/` `titles/` folders. Switch types in the inspector. *Bezel* reads per-game `<name>.zip`/`.7z` (MAME artwork packs) instead.

**Maintenance** (Settings → General): **Clear metadata cache** forces a re-read from MAME (handy after a MAME version bump). **Reset all settings** wipes everything — export a backup first.

---

## Self-contained 7-Zip (optional)

`.7z` artwork is decoded with `7zz`. To make it work on machines without Homebrew's `sevenzip`, bundle the binary:

1. `cp /opt/homebrew/bin/7zz <project>/7zz` (or the universal build from [7-zip.org](https://www.7-zip.org)).
2. Drag it into Xcode → **Copy items if needed**, target **MAMEFrontend**.
3. Confirm it's in **Build Phases → Copy Bundle Resources**.

The app prefers the bundled binary (copying it to Application Support and marking it executable if needed) and falls back to a system `7zz`/`7z`/`7za`. Without it, `.zip` and extracted folders still work everywhere (`unzip` ships with macOS).

---

## Building

```bash
git clone <your-repo-url>
cd MAMEFrontend
open MAMEFrontend.xcodeproj
```

- Xcode 15+ (developed on Xcode 26)
- Deployment target **macOS 14.0**
- **App Sandbox must be OFF** (Signing & Capabilities) — the app spawns an external binary and reads arbitrary folders; sandboxing breaks both.

### Alpha packaging

```bash
./package_alpha.sh          # or: VERSION=0.3.8 ./package_alpha.sh
```

Builds Release, ad-hoc signs, and zips with `ditto`. Alpha builds aren't notarized, so testers clear Gatekeeper once (right-click → **Open**, or `xattr -dr com.apple.quarantine /Applications/MAMEFrontend.app`).

---

## Architecture

Plain Swift + SwiftUI, `@Observable` model, no third-party Swift dependencies.

| File | Responsibility |
|---|---|
| `MAMEFrontendApp.swift` | App entry, menu-bar commands & shortcuts |
| `ContentView.swift` | Table, inspector, settings sheet, view state & persistence |
| `LibraryModel.swift` | `@Observable` model — scanning, filtering, launching, caching, backup |
| `MAMERunner.swift` | `Process` wrapper for `-listfull` / `-listclones` / `-listxml` / launch; SAX metadata parser |
| `Game.swift` | Per-machine model struct (with precomputed sort/search keys) |
| `Catver.swift` | `catver.ini` `[Category]` parser |
| `History.swift` | `history.xml` (SAX) + the shared `.dat` grammar (history / mameinfo / command) |
| `InfoFormatter.swift` | Turns `.dat` text into headings, fields, and preformatted blocks |
| `Artwork.swift` | Artwork resolution (folder / zip / 7z), `ArtworkKind`, bundled-`7zz` resolver |
| `Appearance.swift` | Light / dark / system |

**Design notes**
- `-listxml` is fetched in bounded batches scoped to *owned* machines (never the full 40k dump) and SAX-parsed for constant memory.
- The display list is computed once into a cached array; search is debounced; sort/search keys are precomputed on `Game`.
- Archive entry listings are cached per session.

### Data storage
- **UserDefaults** — small prefs only: paths, filters, sort, columns, favorites, play counts, launch options, BIOS choices, window/inspector state.
- **`~/Library/Application Support/MAMEFrontend/`** — `metaCacheV3.json` (metadata cache; far too large for UserDefaults) and the extracted `7zz`.

---

## Roadmap

- [ ] **Verify / audit** — wrap `mame -verifyroms` / `-verifychd` to flag incomplete sets before launch
- [ ] **Tile/grid view** — artwork thumbnails as an alternative to the table
- [ ] Multi-select bulk actions (favorite, verify)
- [ ] Players / controls metadata + filters
- [ ] Software-list (console/computer) titles
- [ ] Random game button

## Known limitations

- Software lists (console/computer titles) aren't supported — arcade/system machines only.
- Input remapping happens inside MAME (Tab menu), not the frontend.
- Console/computer detection keys on a machine having a `<softwarelist>`; a rare arcade system shipping one may be classified as a non-game.
- Disk "present" checks the CHD *filename* exists, not its hash — a wrong-version CHD reads as present but is caught by launch feedback.
- A launch is judged failed only if MAME exits non-zero within ~20 seconds.

---

## Credits & license

- Not affiliated with or endorsed by MAMEdev. "MAME" is a trademark of its respective owners.
- Metadata and artwork come from community projects — **History.dat**, **progetto-SNAPS**, **MASH's mameinfo.dat**, **command.dat**, and the **catver.ini** authors. Please support them.
- If you bundle `7zz`: **7-Zip** is licensed under the GNU LGPL (with BSD and unRAR-restricted portions); see [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

Released under the [MIT License](LICENSE).

---

*A hobby project. Bring your own ROMs.*
