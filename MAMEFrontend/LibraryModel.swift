import Foundation
import Observation

@Observable
final class LibraryModel {
    // Config (pushed in from @AppStorage in the view).
    var mameBinaryPath = ""
    var romPath = ""
    var historyPath = ""

    // Catalog state
    private(set) var games: [Game] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    // History state
    private(set) var historyIndex: [String: String] = [:]
    private(set) var historyError: String?

    // View filters
    var searchText = ""
    var showFavoritesOnly = false
    var hideClones = false

    // Persisted state
    private(set) var favorites: Set<String> = []
    private var lastPlayedByName: [String: Date] = [:]
    private var yearCache: [String: Int] = [:]

    private let favoritesKey = "favorites"
    private let lastPlayedKey = "lastPlayed"
    private let yearCacheKey = "yearCache"

    init() {
        loadUserData()
    }

    var isConfigured: Bool { !mameBinaryPath.isEmpty && !romPath.isEmpty }
    var historyConfigured: Bool { !historyPath.isEmpty }

    var filteredGames: [Game] {
        var result = games
        if showFavoritesOnly { result = result.filter { favorites.contains($0.shortName) } }
        if hideClones        { result = result.filter { !$0.isClone } }
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            result = result.filter {
                $0.description.lowercased().contains(needle) ||
                $0.shortName.lowercased().contains(needle)
            }
        }
        return result
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

        let runner = MAMERunner(binaryPath: mameBinaryPath, romPath: romPath)
        let path = romPath
        do {
            async let nameMapTask = runner.listFull()
            async let clonesTask  = runner.listClones()
            let owned = await Task.detached { Self.scanOwnedShortNames(in: path) }.value
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

            var resolved: [Game] = shortNames.map { short in
                let parent = cloneOf[short]
                let played = lastPlayedByName[short] ?? .distantPast
                let year = yearCache[short] ?? 0
                if let desc = nameMap[short] {
                    return Game(shortName: short, description: desc,
                                parent: parent, lastPlayed: played, year: year)
                } else {
                    return Game(shortName: short, description: short, isUnknown: true,
                                parent: parent, lastPlayed: played, year: year)
                }
            }
            resolved.sort {
                $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending
            }
            games = resolved
            isLoading = false

            let knownNames = resolved.filter { !$0.isUnknown }.map { $0.shortName }
            let missing = knownNames.filter { yearCache[$0] == nil }
            if !missing.isEmpty {
                await enrichYears(for: missing, runner: runner)
            }
        } catch {
            errorMessage = error.localizedDescription
            games = []
            isLoading = false
        }
    }

    @MainActor
    private func enrichYears(for names: [String], runner: MAMERunner) async {
        let chunkSize = 300
        var index = 0
        while index < names.count {
            let chunk = Array(names[index..<min(index + chunkSize, names.count)])
            index += chunkSize
            do {
                let fetched = try await runner.years(for: chunk)
                guard !fetched.isEmpty else { continue }
                yearCache.merge(fetched) { _, new in new }
                games = games.map { game in
                    if let y = fetched[game.shortName], y > 0, game.year != y {
                        var updated = game
                        updated.year = y
                        return updated
                    }
                    return game
                }
            } catch {
                // Non-fatal.
            }
        }
        saveYearCache()
    }

    /// Loads and indexes the history file (if configured), off the main thread.
    @MainActor
    func loadHistory() async {
        let path = historyPath
        guard !path.isEmpty else {
            historyIndex = [:]
            historyError = nil
            return
        }
        do {
            let idx = try await Task.detached { try HistoryStore.index(fromFileAt: path) }.value
            historyIndex = idx
            historyError = idx.isEmpty ? "No entries found in the history file." : nil
        } catch {
            historyIndex = [:]
            historyError = error.localizedDescription
        }
    }

    /// History text for a game, falling back to its parent set for clones.
    func history(for game: Game) -> String? {
        if let text = historyIndex[game.shortName] { return text }
        if let parent = game.parent { return historyIndex[parent] }
        return nil
    }

    // MARK: - Actions

    @MainActor
    func launch(_ game: Game) {
        let runner = MAMERunner(binaryPath: mameBinaryPath, romPath: romPath)
        do {
            try runner.launch(shortName: game.shortName)
            let now = Date()
            lastPlayedByName[game.shortName] = now
            if let idx = games.firstIndex(where: { $0.shortName == game.shortName }) {
                games[idx].lastPlayed = now
            }
            saveUserData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isFavorite(_ game: Game) -> Bool { favorites.contains(game.shortName) }

    func toggleFavorite(_ game: Game) {
        if favorites.contains(game.shortName) {
            favorites.remove(game.shortName)
        } else {
            favorites.insert(game.shortName)
        }
        saveUserData()
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
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            yearCache = decoded
        }
    }

    private func saveUserData() {
        let defaults = UserDefaults.standard
        defaults.set(Array(favorites), forKey: favoritesKey)
        if let data = try? JSONEncoder().encode(lastPlayedByName) {
            defaults.set(data, forKey: lastPlayedKey)
        }
    }

    private func saveYearCache() {
        if let data = try? JSONEncoder().encode(yearCache) {
            UserDefaults.standard.set(data, forKey: yearCacheKey)
        }
    }

    // MARK: - Disk scan

    static func scanOwnedShortNames(in romPath: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: romPath) else { return [] }
        let romExtensions: Set<String> = ["zip", "7z"]
        var names: Set<String> = []
        for entry in entries {
            let url = URL(fileURLWithPath: entry)
            if romExtensions.contains(url.pathExtension.lowercased()) {
                names.insert(url.deletingPathExtension().lastPathComponent)
            }
        }
        return Array(names)
    }
}
