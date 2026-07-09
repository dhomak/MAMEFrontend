import SwiftUI
import AppKit

struct ContentView: View {
    @State private var model = LibraryModel()

    @AppStorage("mameBinaryPath") private var mameBinaryPath = ""
    @AppStorage("romPath") private var romPath = ""
    @AppStorage("historyPath") private var historyPath = ""
    @AppStorage("catverPath") private var catverPath = ""
    @AppStorage("artworkPath") private var artworkPath = ""

    @State private var selection: Game.ID?
    @State private var showingSettings = false
    @State private var showInspector = true
    @State private var sortOrder: [KeyPathComparator<Game>] = [KeyPathComparator(\.sortTitle)]
    @State private var artwork: NSImage?

    private var sortedGames: [Game] { model.filteredGames.sorted(using: sortOrder) }

    private var selectedGame: Game? {
        guard let id = selection else { return nil }
        return model.games.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("MAME")
                .toolbar { toolbarContent }
                .searchable(text: $model.searchText, prompt: "Search games")
                .inspector(isPresented: $showInspector) { detailPanel }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(mameBinaryPath: $mameBinaryPath,
                         romPath: $romPath,
                         historyPath: $historyPath,
                         catverPath: $catverPath,
                         artworkPath: $artworkPath) {
                syncAndReload()
            }
        }
        .task {
            syncConfig()
            if model.isConfigured { await model.reload() }
            await model.loadHistory()
        }
        .task(id: [selection ?? "", artworkPath]) {
            artwork = nil
            guard let game = selectedGame else { return }
            let data = await model.loadArtwork(for: game)
            if let data { artwork = NSImage(data: data) }
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if !model.isConfigured {
            ContentUnavailableView {
                Label("Not configured", systemImage: "gearshape")
            } description: {
                Text("Point the app at your MAME binary and ROM folder to get started.")
            } actions: {
                Button("Open Settings") { showingSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.isLoading {
            ProgressView("Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            ContentUnavailableView {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { syncAndReload() }
            }
        } else if model.games.isEmpty {
            ContentUnavailableView {
                Label("No games found", systemImage: "tray")
            } description: {
                Text("No ROM archives matched machines this MAME build recognizes in \(romPath).")
            }
        } else {
            gameTable
        }
    }

    private var gameTable: some View {
        Table(sortedGames, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { game in
                Button {
                    model.toggleFavorite(game)
                } label: {
                    Image(systemName: model.isFavorite(game) ? "star.fill" : "star")
                        .foregroundStyle(model.isFavorite(game) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(model.isFavorite(game) ? "Remove from favorites" : "Add to favorites")
            }
            .width(28)

            TableColumn("Game", value: \.sortTitle) { game in
                HStack(spacing: 6) {
                    Text(game.description)
                    if game.isClone { cloneBadge }
                    if game.isUnknown {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .help("Owned on disk but not recognized by this MAME build.")
                    }
                }
            }

            TableColumn("Genre", value: \.genre) { game in
                Text(game.genre.isEmpty ? "—" : game.genre)
                    .foregroundStyle(game.genre.isEmpty ? .tertiary : .secondary)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Short name", value: \.shortName) { game in
                Text(game.shortName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)

            TableColumn("Year", value: \.year) { game in
                Text(game.hasYear ? String(game.year) : "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(game.hasYear ? .secondary : .tertiary)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Last played", value: \.lastPlayed) { game in
                if game.hasBeenPlayed {
                    Text(game.lastPlayed.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 90, ideal: 120)
        }
        .contextMenu(forSelectionType: Game.ID.self) { ids in
            if let id = ids.first, let game = game(for: id) {
                Button("Play \(game.description)") { model.launch(game) }
                Divider()
                Button(model.isFavorite(game) ? "Remove from Favorites" : "Add to Favorites") {
                    model.toggleFavorite(game)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let game = game(for: id) {
                model.launch(game)
            }
        }
        .overlay {
            if model.filteredGames.isEmpty {
                let noFavorites = model.showFavoritesOnly && model.favorites.isEmpty
                ContentUnavailableView {
                    Label(noFavorites ? "No favorites yet" : "No matches",
                          systemImage: model.showFavoritesOnly ? "star" : "magnifyingglass")
                } description: {
                    Text(noFavorites
                         ? "Star a game to add it here."
                         : "Nothing matches your current filters.")
                } actions: {
                    Button("Show all games") {
                        model.showFavoritesOnly = false
                        model.hideClones = false
                        model.genreFilter = nil
                        model.searchText = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var cloneBadge: some View {
        Text("clone")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    // MARK: - Detail inspector (artwork + history)

    @ViewBuilder
    private var detailPanel: some View {
        Group {
            if let game = selectedGame {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let artwork {
                            Image(nsImage: artwork)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                                )
                        }
                        detailHeader(for: game)
                        Divider()
                        historyBody(for: game)
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView("No selection",
                                       systemImage: "hand.point.up.left",
                                       description: Text("Select a game to see its details."))
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 340, max: 560)
    }

    @ViewBuilder
    private func detailHeader(for game: Game) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(game.description)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(game.shortName)
                    .font(.system(.caption, design: .monospaced))
                if game.hasYear { Text(String(game.year)).font(.caption) }
                if game.isClone, let parent = game.parent {
                    Text("clone of \(parent)").font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            if !game.genre.isEmpty {
                Text(game.genre).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func historyBody(for game: Game) -> some View {
        if let text = model.history(for: game) {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if !model.historyConfigured {
            Text("Set a history file in Settings to show history and trivia.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let error = model.historyError {
            Text(error).font(.caption).foregroundStyle(.secondary)
        } else {
            Text("No history entry for \(game.shortName).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                if let id = selection, let game = game(for: id) { model.launch(game) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(selection == nil)

            Button { syncAndReload() } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(!model.isConfigured || model.isLoading)

            if !model.categories.isEmpty {
                Picker("Genre", selection: $model.genreFilter) {
                    Text("All genres").tag(String?.none)
                    ForEach(model.categories, id: \.self) { category in
                        Text(category).tag(String?.some(category))
                    }
                }
                .pickerStyle(.menu)
                .help("Filter by genre")
            }

            Toggle(isOn: $model.showFavoritesOnly) {
                Label("Favorites only", systemImage: model.showFavoritesOnly ? "star.fill" : "star")
            }
            .toggleStyle(.button)
            .help("Show only favorites")

            Toggle(isOn: $model.hideClones) {
                Label("Hide clones", systemImage: "square.on.square.dashed")
            }
            .toggleStyle(.button)
            .help("Hide clone machines")

            Button { showingSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button { showInspector.toggle() } label: {
                Label("Details", systemImage: "info.circle")
            }
            .help("Show artwork, history & trivia")
        }
    }

    // MARK: - Helpers

    private func game(for id: Game.ID) -> Game? {
        model.filteredGames.first { $0.id == id } ?? model.games.first { $0.id == id }
    }

    private func syncConfig() {
        model.mameBinaryPath = mameBinaryPath
        model.romPath = romPath
        model.historyPath = historyPath
        model.catverPath = catverPath
        model.artworkPath = artworkPath
    }

    private func syncAndReload() {
        syncConfig()
        Task {
            await model.reload()
            await model.loadHistory()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Binding var mameBinaryPath: String
    @Binding var romPath: String
    @Binding var historyPath: String
    @Binding var catverPath: String
    @Binding var artworkPath: String
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title2).bold()

            pathRow(title: "MAME binary", text: $mameBinaryPath,
                    chooseDirectory: false, prompt: "/opt/homebrew/bin/mame")
            pathRow(title: "ROM path", text: $romPath,
                    chooseDirectory: true, prompt: "~/roms")
            pathRow(title: "History file (optional)", text: $historyPath,
                    chooseDirectory: false, prompt: "~/history.xml or history.dat")
            pathRow(title: "catver.ini (optional)", text: $catverPath,
                    chooseDirectory: false, prompt: "~/catver.ini")
            pathRow(title: "Artwork folder (optional)", text: $artworkPath,
                    chooseDirectory: true, prompt: "~/mame-artwork")

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    @ViewBuilder
    private func pathRow(title: String, text: Binding<String>,
                         chooseDirectory: Bool, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            HStack {
                TextField(prompt, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Choose…") { choose(into: text, directory: chooseDirectory) }
            }
        }
    }

    private func choose(into text: Binding<String>, directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            text.wrappedValue = url.path
        }
    }
}
