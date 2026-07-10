import SwiftUI

@main
struct MAMEFrontendApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // ⌘, Settings (native placement)
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { post(.openMAMESettings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // File → Reload Library (⌘R)
            CommandGroup(after: .newItem) {
                Button("Reload Library") { post(.reloadLibrary) }
                    .keyboardShortcut("r", modifiers: .command)
            }
            // Edit → Find (⌘F) — focuses the search field
            CommandGroup(after: .textEditing) {
                Button("Find") { post(.focusSearch) }
                    .keyboardShortcut("f", modifiers: .command)
            }
            // View → inspector + filters
            CommandGroup(after: .sidebar) {
                Button("Toggle Details Inspector") { post(.toggleInspector) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Clear Filters") { post(.clearFilters) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

extension Notification.Name {
    static let openMAMESettings = Notification.Name("openMAMESettings")
    static let reloadLibrary    = Notification.Name("reloadLibrary")
    static let focusSearch      = Notification.Name("focusSearch")
    static let toggleInspector  = Notification.Name("toggleInspector")
    static let clearFilters     = Notification.Name("clearFilters")
}
