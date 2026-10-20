import SwiftUI
import InkCore

// Placeholder entry point; replaced by the real app shell.
@main
struct InkApp: App {
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ZStack {
                Ink.background.ignoresSafeArea()
                Text("Ink").inkLargeTitle()
            }
            .environment(settings)
        }
    }
}
