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
    var catverPath = ""
    var artworkPath = ""

    // Catalog state
    private(set) var games: [Game] = []            // full library
    private(set) var displayGames: [Game] = []     // filtered + sorted (what the table shows)
    private(set) var categories: [String] = []     // distinct genre categories (cached)
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var launchError: LaunchFailure?

    // History state
    private(set) var historyIndex: [String: String] = [:]
    private(set) var historyError: String?

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
    var historyConfigured: Bool { !historyPath.isEmpty }
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
                let meta = metaCache[short]
                let genre = genreIndex[short] ?? (parent.flatMap { genreIndex[$0] }) ?? ""
                let requiresDisk = meta?.requiresDisk ?? false
                let diskPresent = requiresDisk
                    ? isDiskPresent(shortName: short, parent: parent, diskNames: meta?.diskNames ?? [])
                    : false
                if let desc = nameMap[short] {
                    return Game(shortName: short, description: desc,
                                parent: parent, lastPlayed: played,
                                year: meta?.year ?? 0, genre: genre,
                                manufacturer: meta?.manufacturer ?? "", status: meta?.status ?? "",
                                isNonGame: meta?.nonGame ?? false,
                                requiresDisk: requiresDisk, diskPresent: diskPresent)
                } else {
                    return Game(shortName: short, description: short, isUnknown: true,
                                parent: parent, lastPlayed: played,
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

    @MainActor
    func loadHistory() async {
        let path = historyPath
        guard !path.isEmpty else { historyIndex = [:]; historyError = nil; return }
        do {
            let idx = try await Task.detached { try HistoryStore.index(fromFileAt: path) }.value
            historyIndex = idx
            historyError = idx.isEmpty ? "No entries found in the history file." : nil
        } catch {
            historyIndex = [:]
            historyError = error.localizedDescription
        }
    }

    func history(for game: Game) -> String? {
        if let text = historyIndex[game.shortName] { return text }
        if let parent = game.parent { return historyIndex[parent] }
        return nil
    }

    // MARK: - Artwork

    @MainActor
    func loadArtwork(for game: Game) async -> Data? {
        guard artworkConfigured else { return nil }
        let base = artworkPath
        let names = [game.shortName] + (game.parent.map { [$0] } ?? [])

        if let data = await Task.detached(operation: {
            ArtworkStore.extractedFile(base: base, names: names)
        }).value {
            return data
        }

        let baseURL = URL(fileURLWithPath: base)
        let fm = FileManager.default
        for zipName in ArtworkStore.zipNames {
            let zipURL = baseURL.appendingPathComponent(zipName)
            guard fm.fileExists(atPath: zipURL.path) else { continue }
            let entries = await entrySet(for: zipURL)
            for name in names {
                for ext in ArtworkStore.exts {
                    guard let entry = ArtworkStore.entry(in: entries,
                                                         matchingBasename: "\(name).\(ext)")
                    else { continue }
                    if let data = await Task.detached(operation: {
                        ArtworkStore.unzipEntry(archive: zipURL, entry: entry)
                    }).value {
                        return data
                    }
                }
            }
        }

        for name in names {
            let gameZip = baseURL.appendingPathComponent("\(name).zip")
            guard fm.fileExists(atPath: gameZip.path) else { continue }
            let entries = await entrySet(for: gameZip)
            guard let entry = ArtworkStore.bestImageEntry(in: entries, preferNames: names)
            else { continue }
            if let data = await Task.detached(operation: {
                ArtworkStore.unzipEntry(archive: gameZip, entry: entry)
            }).value {
                return data
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

    @MainActor
    func launch(_ game: Game) {
        // Record play time optimistically.
        let now = Date()
        lastPlayedByName[game.shortName] = now
        if let i = games.firstIndex(where: { $0.shortName == game.shortName }) {
            games[i].lastPlayed = now
        }
        if let i = displayGames.firstIndex(where: { $0.shortName == game.shortName }) {
            displayGames[i].lastPlayed = now
        }
        if var g = gamesByID[game.shortName] { g.lastPlayed = now; gamesByID[game.shortName] = g }
        saveUserData()

        // Spawn and watch for a fast failure without blocking the UI.
        let runner = MAMERunner(binaryPath: mameBinaryPath, romPath: combinedRomPath)
        let title = game.description
        Task {
            do {
                if let failure = try await runner.launchMonitored(shortName: game.shortName) {
                    launchError = LaunchFailure(game: title, message: String(failure.prefix(800)))
                }
            } catch {
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
        if let data = defaults.data(forKey: yearCacheKey),
           let decoded = try? JSONDecoder().decode([String: MachineMeta].self, from: data) {
            metaCache = decoded
        }
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
        if let data = try? JSONEncoder().encode(lastPlayedByName) {
            defaults.set(data, forKey: lastPlayedKey)
        }
    }

    private func saveMetaCache() {
        if let data = try? JSONEncoder().encode(metaCache) {
            UserDefaults.standard.set(data, forKey: yearCacheKey)
        }
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
