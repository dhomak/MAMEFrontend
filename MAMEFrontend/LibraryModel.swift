import Foundation
import Observation

/// A failed game launch, surfaced to the user as an alert.
struct LaunchFailure: Identifiable {
    let id = UUID()
    let game: String
    let message: String
}

@Observable
final class LibraryModel {
    // Config (pushed in from @AppStorage in the view).
    var mameBinaryPath = ""
    var romPath = ""
    var chdPath = ""
    var historyPath = ""
    var mameinfoPath = ""
    var commandPath = ""
    var catverPath = ""
    var artworkPath = ""

    // Catalog state
    private(set) var games: [Game] = []            // full library
    private(set) var displayGames: [Game] = []     // filtered + sorted (what the table shows)
    private(set) var categories: [String] = []     // distinct genre categories (cached)
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var launchError: LaunchFailure?

    // Reference-text state, keyed by tab
    private(set) var infoIndexes: [InfoTab: [String: String]] = [:]
    private(set) var infoErrors: [InfoTab: String] = [:]

    // View filters (mutated by the view; view calls recompute() on change)
    var searchText = ""
    var showFavoritesOnly = false
    var hideClones = false
    var hideNonWorking = false
    var hideNonGames = false
    var genreFilter: String?
    var sortOrder: [KeyPathComparator<Game>] = [KeyPathComparator(\.sortTitle)]

    // Persisted state
    private(set) var favorites: Set<String> = []
    private var lastPlayedByName: [String: Date] = [:]
    private var playCountByName: [String: Int] = [:]
    private var launchOptionsByName: [String: String] = [:]
    private var metaCache: [String: MachineMeta] = [:]
    private var zipEntryCache: [String: Set<String>] = [:]

    // Fast lookups / applied search
    private var gamesByID: [String: Game] = [:]
    private var appliedSearch = ""

    private let favoritesKey = "favorites"
    private let lastPlayedKey = "lastPlayed"
    private let yearCacheKey = "metaCacheV3"

    init() { loadUserData() }

    var isConfigured: Bool { !mameBinaryPath.isEmpty && !romPath.isEmpty }

    /// Semicolon-joined rompath so MAME searches both the ROM folder and the
    /// (optional) CHD folder for disks.
    private var combinedRomPath: String {
        chdPath.isEmpty ? romPath : "\(romPath);\(chdPath)"
    }
    var artworkConfigured: Bool { !artworkPath.isEmpty }

    func game(id: String) -> Game? { gamesByID[id] }

    // MARK: - Display list

    /// Rebuilds `displayGames` from the current filters + sort. Called only when
    /// something actually changes — never per keystroke (search is debounced).
    @MainActor
    func recompute() {
        var result = games
        if showFavoritesOnly { result = result.filter { favorites.contains($0.shortName) } }
        if hideClones        { result = result.filter { !$0.isClone } }
        if hideNonWorking    { result = result.filter { $0.isWorking } }
        if hideNonGames      { result = result.filter { !$0.isNonGame } }
        if let category = genreFilter { result = result.filter { $0.category == category } }
        if !appliedSearch.isEmpty {
            let needle = appliedSearch.lowercased()
            result = result.filter { $0.searchKey.contains(needle) }
        }
        result.sort(using: sortOrder)
        displayGames = result
    }

    /// Applies a (debounced) search term.
    @MainActor
    func setSearch(_ text: String) {
        appliedSearch = text
        recompute()
    }

    @MainActor
    func clearFilters() {
        showFavoritesOnly = false
        hideClones = false
        hideNonWorking = false
        hideNonGames = false
        genreFilter = nil
        searchText = ""
        appliedSearch = ""
        recompute()
        persistFilters()
    }

    // MARK: - Loading

    @MainActor
    func reload() async {
        guard isConfigured else {
            errorMessage = "Set the MAME binary and ROM path first."
            return
        }
        isLoading = true
        errorMessage = nil
        zipEntryCache = [:]

        let runner = MAMERunner(binaryPath: mameBinaryPath, romPath: combinedRomPath)
        let scanPaths = [romPath, chdPath].filter { !$0.isEmpty }
        let catver = catverPath
        do {
            async let nameMapTask = runner.listFull()
            async let clonesTask  = runner.listClones()
            let owned = await Task.detached { Self.scanOwnedShortNames(in: scanPaths) }.value
            let genreIndex: [String: String] = catver.isEmpty
                ? [:]
                : (await Task.detached { (try? CatverStore.index(fromFileAt: catver)) ?? [:] }.value)
            let nameMap = try await nameMapTask
            let cloneOf = try await clonesTask

            var clonesByParent: [String: [String]] = [:]
            for (clone, parent) in cloneOf {
                clonesByParent[parent, default: []].append(clone)
            }

            var shortNames = Set(owned)
            for name in owned {
                for clone in clonesByParent[name] ?? [] { shortNames.insert(clone) }
            }

            let resolved: [Game] = shortNames.map { short in
                let parent = cloneOf[short]
                let played = lastPlayedByName[short] ?? .distantPast
                let plays = playCountByName[short] ?? 0
                let meta = metaCache[short]
                let genre = genreIndex[short] ?? (parent.flatMap { genreIndex[$0] }) ?? ""
                let requiresDisk = meta?.requiresDisk ?? false
                let diskPresent = requiresDisk
                    ? isDiskPresent(shortName: short, parent: parent, diskNames: meta?.diskNames ?? [])
                    : false
                if let desc = nameMap[short] {
                    return Game(shortName: short, description: desc,
                                parent: parent, lastPlayed: played, playCount: plays,
                                year: meta?.year ?? 0, genre: genre,
                                manufacturer: meta?.manufacturer ?? "", status: meta?.status ?? "",
                                isNonGame: meta?.nonGame ?? false,
                                requiresDisk: requiresDisk, diskPresent: diskPresent)
                } else {
                    return Game(shortName: short, description: short, isUnknown: true,
                                parent: parent, lastPlayed: played, playCount: plays,
                                year: meta?.year ?? 0, genre: genre,
                                manufacturer: meta?.manufacturer ?? "", status: meta?.status ?? "",
                                isNonGame: meta?.nonGame ?? false,
                                requiresDisk: requiresDisk, diskPresent: diskPresent)
                }
            }

            games = resolved
            gamesByID = Dictionary(resolved.map { ($0.shortName, $0) }, uniquingKeysWith: { a, _ in a })
            categories = Array(Set(resolved.map { $0.category })).filter { !$0.isEmpty }.sorted()
            recompute()
            isLoading = false

            let knownNames = resolved.filter { !$0.isUnknown }.map { $0.shortName }
            let missing = knownNames.filter { metaCache[$0] == nil }
            if !missing.isEmpty {
                await enrichMeta(for: missing, runner: runner)
            }
        } catch {
            errorMessage = error.localizedDescription
            games = []; displayGames = []; gamesByID = [:]; categories = []
            isLoading = false
        }
    }

    @MainActor
    private func enrichMeta(for names: [String], runner: MAMERunner) async {
        let chunkSize = 300
        var index = 0
        while index < names.count {
            let chunk = Array(names[index..<min(index + chunkSize, names.count)])
            index += chunkSize
            do {
                let fetched = try await runner.meta(for: chunk)
                guard !fetched.isEmpty else { continue }
                metaCache.merge(fetched) { _, new in new }
                applyMeta(fetched)
            } catch {
                // Non-fatal.
            }
        }
        saveMetaCache()
    }

    /// Folds fetched metadata into games / displayGames / index in place.
    @MainActor
    private func applyMeta(_ fetched: [String: MachineMeta]) {
        func updated(_ g: Game) -> Game {
            guard let m = fetched[g.shortName] else { return g }
            var n = g
            if m.year > 0 { n.year = m.year }
            if !m.manufacturer.isEmpty { n.manufacturer = m.manufacturer }
            if !m.status.isEmpty { n.status = m.status }
            n.isNonGame = m.nonGame
            n.requiresDisk = m.requiresDisk
            n.diskPresent = m.requiresDisk
                ? isDiskPresent(shortName: n.shortName, parent: n.parent, diskNames: m.diskNames)
                : false
            return n
        }
        games = games.map(updated)
        displayGames = displayGames.map(updated)
        for (name, m) in fetched {
            if var g = gamesByID[name] {
                if m.year > 0 { g.year = m.year }
                if !m.manufacturer.isEmpty { g.manufacturer = m.manufacturer }
                if !m.status.isEmpty { g.status = m.status }
                g.isNonGame = m.nonGame
                g.requiresDisk = m.requiresDisk
                g.diskPresent = m.requiresDisk
                    ? isDiskPresent(shortName: name, parent: g.parent, diskNames: m.diskNames)
                    : false
                gamesByID[name] = g
            }
        }
        // Newly-learned kinds/statuses may change a filtered view.
        if hideNonWorking || hideNonGames { recompute() }
    }

    /// True if every required disk is found at `<path>/<machine or parent>/<disk>.chd`.
    private func isDiskPresent(shortName: String, parent: String?, diskNames: [String]) -> Bool {
        guard !diskNames.isEmpty else { return true }
        let paths = [romPath, chdPath].filter { !$0.isEmpty }
        let folders = [shortName] + (parent.map { [$0] } ?? [])
        let fm = FileManager.default
        for disk in diskNames {
            var found = false
            search: for path in paths {
                for folder in folders {
                    let url = URL(fileURLWithPath: path)
                        .appendingPathComponent(folder)
                        .appendingPathComponent("\(disk).chd")
                    if fm.fileExists(atPath: url.path) { found = true; break search }
                }
            }
            if !found { return false }
        }
        return true
    }

    func path(for tab: InfoTab) -> String {
        switch tab {
        case .history:  return historyPath
        case .mameinfo: return mameinfoPath
        case .command:  return commandPath
        }
    }

    func isConfigured(_ tab: InfoTab) -> Bool { !path(for: tab).isEmpty }

    /// Loads and indexes every configured reference file, off the main thread.
    @MainActor
    func loadInfoFiles() async {
        for tab in InfoTab.allCases {
            let path = self.path(for: tab)
            guard !path.isEmpty else {
                infoIndexes[tab] = [:]
                infoErrors[tab] = nil
                continue
            }
            do {
                let idx = try await Task.detached { try HistoryStore.index(fromFileAt: path) }.value
                infoIndexes[tab] = idx
                infoErrors[tab] = idx.isEmpty ? "No entries found in \(tab.fileHint)." : nil
            } catch {
                infoIndexes[tab] = [:]
                infoErrors[tab] = error.localizedDescription
            }
        }
    }

    /// Text for a game from a given source, falling back to its parent set.
    func info(_ tab: InfoTab, for game: Game) -> String? {
        guard let index = infoIndexes[tab] else { return nil }
        if let text = index[game.shortName] { return text }
        if let parent = game.parent { return index[parent] }
        return nil
    }

    func infoError(_ tab: InfoTab) -> String? { infoErrors[tab] ?? nil }

    // MARK: - Artwork

    @MainActor
    func loadArtwork(for game: Game, kind: ArtworkKind) async -> Data? {
        guard artworkConfigured else { return nil }
        let baseURL = URL(fileURLWithPath: artworkPath)
        let names = [game.shortName] + (game.parent.map { [$0] } ?? [])
        let fm = FileManager.default

        // Bezel: per-game archive, pick the best image inside.
        if kind == .bezel {
            for name in names {
                for ext in ["zip", "7z"] {
                    let arc = baseURL.appendingPathComponent("\(name).\(ext)")
                    guard fm.fileExists(atPath: arc.path) else { continue }
                    let entries = await entrySet(for: arc)
                    guard let entry = ArtworkStore.bestImageEntry(in: entries, preferNames: names)
                    else { continue }
                    if let data = await Task.detached(operation: {
                        ArtworkStore.extractEntry(archive: arc, entry: entry)
                    }).value {
                        return data
                    }
                }
            }
            return nil
        }

        // Per-type container: extracted folder, then .zip, then .7z.
        for container in kind.containers {
            let dir = baseURL.appendingPathComponent(container)
            if let data = await Task.detached(operation: {
                ArtworkStore.extractedFile(dir: dir, names: names)
            }).value {
                return data
            }
            for ext in ["zip", "7z"] {
                let arc = baseURL.appendingPathComponent("\(container).\(ext)")
                guard fm.fileExists(atPath: arc.path) else { continue }
                let entries = await entrySet(for: arc)
                for name in names {
                    for imgExt in ArtworkStore.exts {
                        guard let entry = ArtworkStore.entry(in: entries,
                                                             matchingBasename: "\(name).\(imgExt)")
                        else { continue }
                        if let data = await Task.detached(operation: {
                            ArtworkStore.extractEntry(archive: arc, entry: entry)
                        }).value {
                            return data
                        }
                    }
                }
            }
        }
        return nil
    }

    @MainActor
    private func entrySet(for zipURL: URL) async -> Set<String> {
        if let cached = zipEntryCache[zipURL.path] { return cached }
        let set = await Task.detached(operation: {
            ArtworkStore.listEntries(archive: zipURL)
        }).value
        zipEntryCache[zipURL.path] = set
        return set
    }

    // MARK: - Actions

    func launchOption(for id: String) -> String { launchOptionsByName[id] ?? "" }

    @MainActor
    func setLaunchOption(_ value: String, for id: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { launchOptionsByName[id] = nil } else { launchOptionsByName[id] = trimmed }
        UserDefaults.standard.set(launchOptionsByName, forKey: "launchOptions")
    }

    /// Writes play stats for one machine into the maps, the current rows, and the
    /// lookup index, then persists.
    @MainActor
    private func applyPlayStats(_ shortName: String, lastPlayed: Date?, count: Int) {
        lastPlayedByName[shortName] = lastPlayed
        playCountByName[shortName] = count > 0 ? count : nil
        let effectiveLast = lastPlayed ?? .distantPast
        func apply(_ g: Game) -> Game { var n = g; n.lastPlayed = effectiveLast; n.playCount = count; return n }
        if let i = games.firstIndex(where: { $0.shortName == shortName }) { games[i] = apply(games[i]) }
        if let i = displayGames.firstIndex(where: { $0.shortName == shortName }) { displayGames[i] = apply(displayGames[i]) }
        if let g = gamesByID[shortName] { gamesByID[shortName] = apply(g) }
        saveUserData()
    }

    @MainActor
    func launch(_ game: Game) {
        // Stamp optimistically for instant feedback; undo if the launch fails fast.
        let prevLast = lastPlayedByName[game.shortName]
        let prevCount = playCountByName[game.shortName] ?? 0
        applyPlayStats(game.shortName, lastPlayed: Date(), count: prevCount + 1)

        let runner = MAMERunner(binaryPath: mameBinaryPath, romPath: combinedRomPath)
        let extra = MAMERunner.tokenize(launchOptionsByName[game.shortName] ?? "")
        let shortName = game.shortName
        let title = game.description
        Task {
            do {
                if let failure = try await runner.launchMonitored(shortName: shortName, extraArgs: extra) {
                    applyPlayStats(shortName, lastPlayed: prevLast, count: prevCount)   // undo
                    launchError = LaunchFailure(game: title, message: String(failure.prefix(800)))
                }
            } catch {
                applyPlayStats(shortName, lastPlayed: prevLast, count: prevCount)       // undo
                launchError = LaunchFailure(game: title, message: error.localizedDescription)
            }
        }
    }

    func isFavorite(_ game: Game) -> Bool { favorites.contains(game.shortName) }

    @MainActor
    func toggleFavorite(_ game: Game) {
        if favorites.contains(game.shortName) {
            favorites.remove(game.shortName)
        } else {
            favorites.insert(game.shortName)
        }
        saveUserData()
        if showFavoritesOnly { recompute() }   // membership affects the filtered view
    }

    // MARK: - Persistence

    private func loadUserData() {
        let defaults = UserDefaults.standard
        if let arr = defaults.array(forKey: favoritesKey) as? [String] {
            favorites = Set(arr)
        }
        if let data = defaults.data(forKey: lastPlayedKey),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            lastPlayedByName = decoded
        }
        launchOptionsByName = defaults.dictionary(forKey: "launchOptions") as? [String: String] ?? [:]
        playCountByName = defaults.dictionary(forKey: "playCounts") as? [String: Int] ?? [:]
        loadMetaCache()
        showFavoritesOnly = defaults.bool(forKey: "fFavorites")
        hideClones = defaults.bool(forKey: "fHideClones")
        hideNonWorking = defaults.bool(forKey: "fHideNonWorking")
        hideNonGames = defaults.bool(forKey: "fHideNonGames")
        let g = defaults.string(forKey: "fGenre") ?? ""
        genreFilter = g.isEmpty ? nil : g
    }

    /// Recompute + persist filter state. Called from the view on filter changes.
    @MainActor
    func filtersChanged() {
        recompute()
        persistFilters()
    }

    private func persistFilters() {
        let d = UserDefaults.standard
        d.set(showFavoritesOnly, forKey: "fFavorites")
        d.set(hideClones, forKey: "fHideClones")
        d.set(hideNonWorking, forKey: "fHideNonWorking")
        d.set(hideNonGames, forKey: "fHideNonGames")
        d.set(genreFilter ?? "", forKey: "fGenre")
    }

    private func saveUserData() {
        let defaults = UserDefaults.standard
        defaults.set(Array(favorites), forKey: favoritesKey)
        defaults.set(playCountByName, forKey: "playCounts")
        if let data = try? JSONEncoder().encode(lastPlayedByName) {
            defaults.set(data, forKey: lastPlayedKey)
        }
    }

    // The metadata cache can be many MB for a full set — far past the UserDefaults
    // limit — so it lives in a file, not NSUserDefaults.
    private var metaCacheURL: URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true) else { return nil }
        let dir = support.appendingPathComponent("MAMEFrontend", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metaCacheV3.json")
    }

    private func loadMetaCache() {
        // Purge metadata blobs older builds wrote to UserDefaults. Any one of
        // these can exceed the 4 MB domain limit and wedge *all* preference
        // writes (favorites, paths, everything), so remove them unconditionally.
        for key in ["yearCache", "metaCache", "metaCacheV2", "metaCacheV3"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        guard let url = metaCacheURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: MachineMeta].self, from: data)
        else { return }
        metaCache = decoded
    }

    private func saveMetaCache() {
        guard let url = metaCacheURL, let data = try? JSONEncoder().encode(metaCache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Disk scan

    /// Collects owned machine short names across the given paths: `.zip`/`.7z`
    /// archive base names, plus subfolders containing a `.chd` (CHD-only sets).
    static func scanOwnedShortNames(in paths: [String]) -> [String] {
        let fm = FileManager.default
        let romExtensions: Set<String> = ["zip", "7z"]
        var names: Set<String> = []
        for path in paths where !path.isEmpty {
            let base = URL(fileURLWithPath: path)
            guard let entries = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if folderContainsCHD(url) { names.insert(url.lastPathComponent) }
                } else if romExtensions.contains(url.pathExtension.lowercased()) {
                    names.insert(url.deletingPathExtension().lastPathComponent)
                }
            }
        }
        return Array(names)
    }

    private static func folderContainsCHD(_ dir: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return items.contains { $0.lowercased().hasSuffix(".chd") }
    }
}
