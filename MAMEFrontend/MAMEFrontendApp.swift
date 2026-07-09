import SwiftUI

@main
struct MAMEFrontendApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 700, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
    }
}
