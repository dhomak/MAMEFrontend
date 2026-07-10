import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @State private var model = LibraryModel()

    // Config
    @AppStorage("mameBinaryPath") private var mameBinaryPath = ""
    @AppStorage("romPath") private var romPath = ""
    @AppStorage("historyPath") private var historyPath = ""
    @AppStorage("catverPath") private var catverPath = ""
    @AppStorage("artworkPath") private var artworkPath = ""

    // Persisted UI state
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("lastSelectionID") private var lastSelectionID = ""
    @AppStorage("sortField") private var sortField = "title"
    @AppStorage("sortAscending") private var sortAscending = true
    @AppStorage("columnsData") private var columnsData = ""

    @State private var selection: Game.ID?
    @State private var showingSettings = false
    @State private var artwork: NSImage?
    @State private var searchTask: Task<Void, Never>?
    @State private var columnCustomization = TableColumnCustomization<Game>()
    @State private var window: NSWindow?

    private var selectedGame: Game? {
        guard let id = selection else { return nil }
        return model.game(id: id)
    }

    private var anyFilterActive: Bool {
        model.showFavoritesOnly || model.hideClones || model.hideNonWorking || model.hideNonGames
    }

    var body: some View {
        withChangeHandlers
    }

    private var presentedView: some View {
        NavigationStack {
            content
                .navigationTitle("MAME")
                .toolbar { toolbarContent }
                .searchable(text: $model.searchText, prompt: "Search games")
                .inspector(isPresented: $showInspector) { detailPanel }
        }
        .background(WindowAccessor { win in
            win.setFrameAutosaveName("MAMEMainWindow")
            window = win
        })
        .sheet(isPresented: $showingSettings) {
            SettingsView(mameBinaryPath: $mameBinaryPath,
                         romPath: $romPath,
                         historyPath: $historyPath,
                         catverPath: $catverPath,
                         artworkPath: $artworkPath) {
                syncAndReload()
            }
        }
    }

    private var withCommands: some View {
        presentedView
            .onReceive(NotificationCenter.default.publisher(for: .openMAMESettings)) { _ in showingSettings = true }
            .onReceive(NotificationCenter.default.publisher(for: .reloadLibrary)) { _ in syncAndReload() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleInspector)) { _ in showInspector.toggle() }
            .onReceive(NotificationCenter.default.publisher(for: .clearFilters)) { _ in model.clearFilters() }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in focusSearchField() }
    }

    private var withTasks: some View {
        withCommands
            .task {
                decodeColumns()
                syncConfig()
                if model.isConfigured { await model.reload() }
                restoreSelection()
                await model.loadHistory()
            }
            .task(id: [selection ?? "", artworkPath]) {
                artwork = nil
                guard let game = selectedGame else { return }
                let data = await model.loadArtwork(for: game)
                if let data { artwork = NSImage(data: data) }
            }
    }

    private var withFilterHandlers: some View {
        withTasks
            .onChange(of: model.searchText) { _, newValue in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    if Task.isCancelled { return }
                    model.setSearch(newValue)
                }
            }
            .onChange(of: model.showFavoritesOnly) { model.filtersChanged() }
            .onChange(of: model.hideClones) { model.filtersChanged() }
            .onChange(of: model.hideNonWorking) { model.filtersChanged() }
            .onChange(of: model.hideNonGames) { model.filtersChanged() }
            .onChange(of: model.genreFilter) { model.filtersChanged() }
    }

    private var withChangeHandlers: some View {
        withFilterHandlers
            .onChange(of: model.sortOrder) { model.recompute(); persistSort() }
            .onChange(of: selection) { lastSelectionID = selection ?? "" }
            .onChange(of: columnCustomization) { encodeColumns() }
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
        Table(model.displayGames, selection: $selection, sortOrder: $model.sortOrder,
              columnCustomization: $columnCustomization) {
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
                    statusDot(game.status)
                    Text(game.description)
                    if game.isClone { cloneBadge }
                    if game.isUnknown {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .help("Owned on disk but not recognized by this MAME build.")
                    }
                }
            }
            .customizationID("game")

            TableColumn("Genre", value: \.genre) { game in
                Text(game.genre.isEmpty ? "—" : game.genre)
                    .foregroundStyle(game.genre.isEmpty ? .tertiary : .secondary)
            }
            .width(min: 120, ideal: 180)
            .customizationID("genre")

            TableColumn("Manufacturer", value: \.manufacturer) { game in
                Text(game.manufacturer.isEmpty ? "—" : game.manufacturer)
                    .foregroundStyle(game.manufacturer.isEmpty ? .tertiary : .secondary)
            }
            .width(min: 100, ideal: 150)
            .customizationID("manufacturer")

            TableColumn("Short name", value: \.shortName) { game in
                Text(game.shortName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)
            .customizationID("shortName")

            TableColumn("Year", value: \.year) { game in
                Text(game.hasYear ? String(game.year) : "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(game.hasYear ? .secondary : .tertiary)
            }
            .width(min: 50, ideal: 60)
            .customizationID("year")

            TableColumn("Last played", value: \.lastPlayed) { game in
                if game.hasBeenPlayed {
                    Text(game.lastPlayed.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 90, ideal: 120)
            .customizationID("lastPlayed")
        }
        .contextMenu(forSelectionType: Game.ID.self) { ids in
            if let id = ids.first, let game = model.game(id: id) {
                Button("Play \(game.description)") { model.launch(game) }
                Divider()
                Button(model.isFavorite(game) ? "Remove from Favorites" : "Add to Favorites") {
                    model.toggleFavorite(game)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let game = model.game(id: id) {
                model.launch(game)
            }
        }
        .onKeyPress(.return) {
            if let game = selectedGame { model.launch(game); return .handled }
            return .ignored
        }
        .onKeyPress(.space) {
            if let game = selectedGame { model.toggleFavorite(game); return .handled }
            return .ignored
        }
        .overlay {
            if model.displayGames.isEmpty {
                let noFavorites = model.showFavoritesOnly && model.favorites.isEmpty
                ContentUnavailableView {
                    Label(noFavorites ? "No favorites yet" : "No matches",
                          systemImage: model.showFavoritesOnly ? "star" : "magnifyingglass")
                } description: {
                    Text(noFavorites
                         ? "Star a game to add it here."
                         : "Nothing matches your current filters.")
                } actions: {
                    Button("Show all games") { model.clearFilters() }
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

    @ViewBuilder
    private func statusDot(_ status: String) -> some View {
        switch status {
        case "good":        dot(.green, "Working")
        case "imperfect":   dot(.yellow, "Working, with imperfections")
        case "preliminary": dot(.red, "Not working (preliminary)")
        default:            EmptyView()
        }
    }

    private func dot(_ color: Color, _ helpText: String) -> some View {
        Circle().fill(color).frame(width: 7, height: 7).help(helpText)
    }

    // MARK: - Detail inspector

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
                if let game = selectedGame { model.launch(game) }
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

            Menu {
                Toggle("Favorites only", isOn: $model.showFavoritesOnly)
                Toggle("Hide clones", isOn: $model.hideClones)
                Toggle("Hide non-working", isOn: $model.hideNonWorking)
                Toggle("Hide non-games", isOn: $model.hideNonGames)
            } label: {
                Label("Filter", systemImage: anyFilterActive
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }
            .help("Filters")

            Button { showingSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button { showInspector.toggle() } label: {
                Label("Details", systemImage: "info.circle")
            }
            .help("Show artwork, history & trivia")
        }
    }

    // MARK: - Persistence helpers

    private func makeSortOrder(field: String, ascending: Bool) -> [KeyPathComparator<Game>] {
        let order: SortOrder = ascending ? .forward : .reverse
        switch field {
        case "genre":        return [KeyPathComparator(\Game.genre, order: order)]
        case "manufacturer": return [KeyPathComparator(\Game.manufacturer, order: order)]
        case "shortName":    return [KeyPathComparator(\Game.shortName, order: order)]
        case "year":         return [KeyPathComparator(\Game.year, order: order)]
        case "lastPlayed":   return [KeyPathComparator(\Game.lastPlayed, order: order)]
        default:             return [KeyPathComparator(\Game.sortTitle, order: order)]
        }
    }

    private func persistSort() {
        guard let comparator = model.sortOrder.first else { return }
        sortAscending = (comparator.order == .forward)
        let kp: AnyKeyPath = comparator.keyPath
        if kp == \Game.genre { sortField = "genre" }
        else if kp == \Game.manufacturer { sortField = "manufacturer" }
        else if kp == \Game.shortName { sortField = "shortName" }
        else if kp == \Game.year { sortField = "year" }
        else if kp == \Game.lastPlayed { sortField = "lastPlayed" }
        else { sortField = "title" }
    }

    private func restoreSelection() {
        guard selection == nil, !lastSelectionID.isEmpty,
              model.game(id: lastSelectionID) != nil else { return }
        selection = lastSelectionID
    }

    private func decodeColumns() {
        guard !columnsData.isEmpty, let data = columnsData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(TableColumnCustomization<Game>.self, from: data)
        else { return }
        columnCustomization = decoded
    }

    private func encodeColumns() {
        if let data = try? JSONEncoder().encode(columnCustomization) {
            columnsData = String(decoding: data, as: UTF8.self)
        }
    }

    private func focusSearchField() {
        guard let window else { return }
        // Prefer the toolbar's search item if present.
        if let item = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            window.makeFirstResponder(item.searchField)
            return
        }
        // Fallback: find the first NSSearchField anywhere in the window.
        if let field = firstSearchField(in: window.contentView?.superview ?? window.contentView) {
            window.makeFirstResponder(field)
        }
    }

    private func firstSearchField(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is NSSearchField { return view }
        for sub in view.subviews {
            if let found = firstSearchField(in: sub) { return found }
        }
        return nil
    }

    private func syncConfig() {
        model.mameBinaryPath = mameBinaryPath
        model.romPath = romPath
        model.historyPath = historyPath
        model.catverPath = catverPath
        model.artworkPath = artworkPath
        model.sortOrder = makeSortOrder(field: sortField, ascending: sortAscending)
    }

    private func syncAndReload() {
        syncConfig()
        Task {
            await model.reload()
            restoreSelection()
            await model.loadHistory()
        }
    }
}

// MARK: - Window frame persistence

/// Reaches the hosting NSWindow to set a frame autosave name, so window size and
/// position persist across launches.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
