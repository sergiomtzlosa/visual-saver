import SwiftUI

@main
struct VisualSaverApp: App {
    init() {
        // Screen saver previews try to hide the mouse pointer as if they owned
        // the display; keep the pointer stable inside the app.
        CursorGuard.install()
    }

    var body: some Scene {
        Window("Visual Saver", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
    }
}
