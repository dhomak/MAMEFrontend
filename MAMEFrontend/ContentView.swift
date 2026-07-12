import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = LibraryModel()

    // Config
    @AppStorage("mameBinaryPath") private var mameBinaryPath = ""
    @AppStorage("romPath") private var romPath = ""
    @AppStorage("chdPath") private var chdPath = ""
    @AppStorage("historyPath") private var historyPath = ""
    @AppStorage("mameinfoPath") private var mameinfoPath = ""
    @AppStorage("commandPath") private var commandPath = ""
    @AppStorage("catverPath") private var catverPath = ""
    @AppStorage("artworkPath") private var artworkPath = ""

    // Persisted UI state
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("lastSelectionID") private var lastSelectionID = ""
    @AppStorage("sortField") private var sortField = "title"
    @AppStorage("sortAscending") private var sortAscending = true
    @AppStorage("columnsData") private var columnsData = ""
    @AppStorage("artworkKind") private var artworkKindRaw = ArtworkKind.snapshot.rawValue
    @AppStorage("infoTab") private var infoTabRaw = InfoTab.history.rawValue

    private var infoTab: InfoTab { InfoTab(rawValue: infoTabRaw) ?? .history }

    private var artworkKind: ArtworkKind { ArtworkKind(rawValue: artworkKindRaw) ?? .snapshot }

    @State private var selection: Game.ID?
    @State private var showingSettings = false
    @State private var artwork: NSImage?
    @State private var searchTask: Task<Void, Never>?
    @State private var columnCustomization = TableColumnCustomization<Game>()
    @State private var window: NSWindow?
    @State private var backupMessage: String?
    @AppStorage("launchOptionsExpanded") private var launchOptionsExpanded = false
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue

    private var preferredScheme: ColorScheme? {
        (Appearance(rawValue: appearanceRaw) ?? .system).colorScheme
    }

    private var selectedGame: Game? {
        guard let id = selection else { return nil }
        return model.game(id: id)
    }

    private var anyFilterActive: Bool {
        model.showFavoritesOnly || model.hideClones || model.hideNonWorking
            || model.hideNonGames || model.hideMature || model.chdFilter != .all
    }

    var body: some View {
        withChangeHandlers
            .preferredColorScheme(preferredScheme)
    }

    private var presentedView: some View {
        NavigationStack {
            content
                .navigationTitle("MAME")
                .toolbar { toolbarContent }
                .searchable(text: $model.searchText, prompt: "Name, maker, or year (1996, 199x, 1990-1995)")
                .inspector(isPresented: $showInspector) { detailPanel }
        }
        .background(WindowAccessor { win in
            win.setFrameAutosaveName("MAMEMainWindow")
            window = win
        })
        .sheet(isPresented: $showingSettings) {
            SettingsView(mameBinaryPath: $mameBinaryPath,
                         romPath: $romPath,
                         chdPath: $chdPath,
                         historyPath: $historyPath,
                         mameinfoPath: $mameinfoPath,
                         commandPath: $commandPath,
                         catverPath: $catverPath,
                         artworkPath: $artworkPath,
                         appearanceRaw: $appearanceRaw,
                         onClearCache: {
                             model.clearMetadataCache()
                             syncAndReload()
                         },
                         onResetAll: {
                             model.resetAllSettings()
                             resetLocalUIState()
                         },
                         onExport: { exportBackup() },
                         onImport: { merge in importBackup(merge: merge) },
                         backupMessage: $backupMessage) {
                syncAndReload()
            }
        }
        .alert("Couldn't launch game",
               isPresented: Binding(get: { model.launchError != nil },
                                    set: { if !$0 { model.launchError = nil } }),
               presenting: model.launchError) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text("\(failure.game) didn't start.\n\n\(failure.message)")
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
                await model.loadInfoFiles()
            }
            .task(id: [selection ?? "", artworkPath, artworkKindRaw]) {
                artwork = nil
                guard let game = selectedGame else { return }
                let data = await model.loadArtwork(for: game, kind: artworkKind)
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
        .onChange(of: model.hideMature) { model.filtersChanged() }
            .onChange(of: model.chdFilter) { model.filtersChanged() }
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
            VStack(spacing: 0) {
                gameTable
                if model.isEnriching { enrichBanner }
                statusBar
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Text(countText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if anyFilterActive || !model.searchText.isEmpty || model.genreFilter != nil {
                Button("Clear") { model.clearFilters() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer()
            if model.favorites.count > 0 {
                Label("\(model.favorites.count)", systemImage: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var countText: String {
        let shown = model.displayGames.count
        let total = model.games.count
        let f = NumberFormatter(); f.numberStyle = .decimal
        let s1 = f.string(from: NSNumber(value: shown)) ?? "\(shown)"
        let s2 = f.string(from: NSNumber(value: total)) ?? "\(total)"
        if shown == total { return "\(s2) games" }
        return "\(s1) of \(s2) games"
    }

    private var enrichBanner: some View {
        HStack(spacing: 8) {
            ProgressView(value: Double(model.enrichDone),
                         total: Double(max(model.enrichTotal, 1)))
                .progressViewStyle(.linear)
                .frame(maxWidth: 160)
            Text("Loading metadata… \(model.enrichDone) / \(model.enrichTotal)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
                        .help(game.description)
                    if game.isClone { cloneBadge }
                    if game.requiresDisk {
                        Image(systemName: "internaldrive")
                            .imageScale(.small)
                            .foregroundStyle(game.diskPresent ? Color.secondary : Color.red)
                            .help(game.diskPresent
                                  ? "Requires a disk (CHD) — present"
                                  : "Requires a disk (CHD) — missing")
                    }
                    if game.isUnknown {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .help("Owned on disk but not recognized by this MAME build.")
                    }
                }
            }
            .customizationID("game")

            TableColumn("Genre", value: \.genre) { game in
                Text(game.genre.isEmpty ? "—" : game.displayGenre)
                    .foregroundStyle(game.genre.isEmpty ? .tertiary : .secondary)
                    .help(game.genre)
            }
            .width(min: 120, ideal: 180)
            .customizationID("genre")

            TableColumn("Manufacturer", value: \.manufacturer) { game in
                Text(game.manufacturer.isEmpty ? "—" : game.manufacturer)
                    .foregroundStyle(game.manufacturer.isEmpty ? .tertiary : .secondary)
                    .help(game.manufacturer)
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

            TableColumn("Plays", value: \.playCount) { game in
                Text(game.playCount > 0 ? String(game.playCount) : "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(game.playCount > 0 ? .secondary : .tertiary)
            }
            .width(min: 44, ideal: 56)
            .customizationID("plays")

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
                Divider()
                Button("Reveal in Finder") { revealInFinder(game) }
                    .disabled(model.fileURL(for: game) == nil)
                Button("Copy Short Name") { copyToPasteboard(game.shortName) }
                Button("Copy Name") { copyToPasteboard(game.description) }
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
                    VStack(alignment: .leading, spacing: 14) {
                        detailHeader(for: game)
                        artworkSection
                        launchOptionsSection(for: game)
                        Divider()
                        infoBody(for: game)
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
        VStack(alignment: .leading, spacing: 5) {
            Text(game.description)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(game.shortName)
                    .font(.system(.caption, design: .monospaced))
                if game.hasYear { Text(String(game.year)).font(.caption) }
                if game.playCount > 0 {
                    Text("\(game.playCount) play\(game.playCount == 1 ? "" : "s")").font(.caption)
                }
            }
            .foregroundStyle(.secondary)

            if !game.manufacturer.isEmpty {
                Text(game.manufacturer).font(.caption).foregroundStyle(.secondary)
            }
            if !game.genre.isEmpty {
                HStack(spacing: 5) {
                    Text(game.displayGenre).font(.caption).foregroundStyle(.secondary)
                    if game.isMature {
                        Text("mature")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 6) {
                if !game.status.isEmpty {
                    HStack(spacing: 4) {
                        statusDot(game.status)
                        Text(statusLabel(game.status)).font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                if game.isClone, let parent = game.parent {
                    Text("clone of \(parent)")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if game.requiresDisk {
                    HStack(spacing: 3) {
                        Image(systemName: "internaldrive").imageScale(.small)
                        Text(game.diskPresent ? "CHD" : "CHD missing").font(.caption2)
                    }
                    .foregroundStyle(game.diskPresent ? Color.secondary : Color.red)
                }
            }
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "good":        return "Working"
        case "imperfect":   return "Imperfect"
        case "preliminary": return "Not working"
        default:            return ""
        }
    }

    @ViewBuilder
    private func launchOptionsSection(for game: Game) -> some View {
        DisclosureGroup(isExpanded: $launchOptionsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                let biosSets = model.biosOptions(for: game)
                if !biosSets.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("BIOS").font(.caption2).foregroundStyle(.secondary)
                        Picker("", selection: biosBinding(for: game.shortName)) {
                            Text("Default").tag("")
                            ForEach(biosSets) { set in
                                Text(set.isDefault ? "\(set.describedAs) (default)" : set.describedAs)
                                    .tag(set.name)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Extra arguments").font(.caption2).foregroundStyle(.secondary)
                    TextField("e.g. -fullscreen -nofilter",
                              text: optionsBinding(for: game.shortName))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }

                Text("Applied when you launch this game.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text("Launch options").font(.caption).foregroundStyle(.secondary)
                if !model.launchOption(for: game.shortName).isEmpty
                    || !model.biosChoice(for: game.shortName).isEmpty {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                }
            }
        }
    }

    private func biosBinding(for id: String) -> Binding<String> {
        Binding(get: { model.biosChoice(for: id) },
                set: { model.setBiosChoice($0, for: id) })
    }

    private func optionsBinding(for id: String) -> Binding<String> {
        Binding(get: { model.launchOption(for: id) },
                set: { model.setLaunchOption($0, for: id) })
    }

    @ViewBuilder
    private var artworkSection: some View {
        if model.artworkConfigured {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Artwork")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $artworkKindRaw) {
                        ForEach(ArtworkKind.allCases) { kind in
                            Text(kind.label).tag(kind.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
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
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.10))
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay(
                            VStack(spacing: 4) {
                                Image(systemName: "photo")
                                    .imageScale(.large)
                                    .foregroundStyle(.tertiary)
                                Text("No \(artworkKind.label.lowercased()) artwork")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func infoBody(for game: Game) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $infoTabRaw) {
                ForEach(InfoTab.allCases) { tab in
                    Text(tab.label).tag(tab.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if let text = model.info(infoTab, for: game) {
                InfoTextView(text: text, preformatOnly: infoTab == .command,
                             commandGlyphs: infoTab == .command)
            } else if !model.isConfigured(infoTab) {
                Text("Set \(infoTab.fileHint) in Settings to show this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = model.infoError(infoTab) {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No \(infoTab.label.lowercased()) entry for \(game.shortName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
                Toggle("Hide mature", isOn: $model.hideMature)
                Picker("CHD", selection: $model.chdFilter) {
                    ForEach(LibraryModel.CHDFilter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
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

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MAMEFrontend-backup.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportBackup(to: url)
            backupMessage = "Exported \(model.makeBackup().gameCount) games' data."
        } catch {
            backupMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importBackup(merge: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try model.importBackup(from: url, merge: merge)
            backupMessage = "\(merge ? "Merged" : "Restored") \(backup.gameCount) games' data."
        } catch {
            backupMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func resetLocalUIState() {
        mameBinaryPath = ""; romPath = ""; chdPath = ""
        historyPath = ""; mameinfoPath = ""; commandPath = ""
        catverPath = ""; artworkPath = ""
        artworkKindRaw = ArtworkKind.snapshot.rawValue
        infoTabRaw = InfoTab.history.rawValue
        appearanceRaw = Appearance.system.rawValue
        sortField = "title"; sortAscending = true
        columnsData = ""; lastSelectionID = ""
        showInspector = true; launchOptionsExpanded = false
        selection = nil
        artwork = nil
    }

    private func revealInFinder(_ game: Game) {
        guard let url = model.fileURL(for: game) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func syncConfig() {
        model.mameBinaryPath = mameBinaryPath
        model.romPath = romPath
        model.chdPath = chdPath
        model.historyPath = historyPath
        model.mameinfoPath = mameinfoPath
        model.commandPath = commandPath
        model.catverPath = catverPath
        model.artworkPath = artworkPath
        model.sortOrder = makeSortOrder(field: sortField, ascending: sortAscending)
    }

    private func syncAndReload() {
        syncConfig()
        Task {
            await model.reload()
            restoreSelection()
            await model.loadInfoFiles()
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
    @Binding var chdPath: String
    @Binding var historyPath: String
    @Binding var mameinfoPath: String
    @Binding var commandPath: String
    @Binding var catverPath: String
    @Binding var artworkPath: String
    @Binding var appearanceRaw: String
    var onClearCache: () -> Void
    var onResetAll: () -> Void
    var onExport: () -> Void
    var onImport: (Bool) -> Void
    @Binding var backupMessage: String?
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("settingsTab") private var selectedTab = "general"
    @State private var confirmingReset = false
    @State private var cacheCleared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title2).bold()

            Picker("", selection: $selectedTab) {
                Text("General").tag("general")
                Text("Metadata").tag("metadata")
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Group {
                if selectedTab == "general" { generalTab } else { metadataTab }
            }
            .frame(minHeight: 300, maxHeight: 420, alignment: .top)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pathRow(title: "MAME binary", text: $mameBinaryPath,
                        chooseDirectory: false, prompt: "/opt/homebrew/bin/mame")
                pathRow(title: "ROM path", text: $romPath,
                        chooseDirectory: true, prompt: "~/roms")
                pathRow(title: "CHD / extra ROM path (optional)", text: $chdPath,
                        chooseDirectory: true, prompt: "~/chds")

                Divider().padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Appearance").font(.headline)
                    Picker("", selection: $appearanceRaw) {
                        ForEach(Appearance.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Backup").font(.headline)
                    HStack(spacing: 8) {
                        Button("Export…") { onExport() }
                        Button("Import (merge)…") { onImport(true) }
                        Button("Import (replace)…") { onImport(false) }
                    }
                    if let backupMessage {
                        Text(backupMessage)
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Saves favorites, play counts, and launch options to a JSON file.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Maintenance").font(.headline)
                    HStack(spacing: 8) {
                        Button("Clear metadata cache") {
                            onClearCache()
                            cacheCleared = true
                        }
                        if cacheCleared {
                            Text("Cleared — reloading.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset all settings…", role: .destructive) {
                            confirmingReset = true
                        }
                    }
                    Text("Clearing the cache re-reads game metadata from MAME on the next reload.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 2)
        }
        .confirmationDialog("Reset all settings?",
                            isPresented: $confirmingReset,
                            titleVisibility: .visible) {
            Button("Reset Everything", role: .destructive) {
                onResetAll()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases your paths, favorites, play counts, launch options, and filters. It cannot be undone.")
        }
    }

    @ViewBuilder
    private var metadataTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pathRow(title: "History file", text: $historyPath,
                        chooseDirectory: false, prompt: "~/history.xml or history.dat")
                pathRow(title: "mameinfo.dat", text: $mameinfoPath,
                        chooseDirectory: false, prompt: "~/mameinfo.dat")
                pathRow(title: "command.dat", text: $commandPath,
                        chooseDirectory: false, prompt: "~/command.dat")
                pathRow(title: "catver.ini", text: $catverPath,
                        chooseDirectory: false, prompt: "~/catver.ini")
                pathRow(title: "Artwork folder", text: $artworkPath,
                        chooseDirectory: true, prompt: "~/mame-artwork")
                Text("All optional — each unlocks a feature (trivia, genres, artwork).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Row

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
