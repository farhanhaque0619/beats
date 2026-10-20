import SwiftUI
import InkCore

@main
struct InkApp: App {
    @State private var app = AppModel.make()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.store)
                .environment(app.settings)
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 480)
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            app.scenePhaseChanged(phase)
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.handleAppRefresh()
        }
        #endif
        #if os(macOS)
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { InkCommands(app: app) }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(app)
                .environment(app.store)
                .environment(app.settings)
                .environment(\.inkAccent, app.settings.accent.color)
                .tint(app.settings.accent.color)
                .preferredColorScheme(app.settings.appearance.colorScheme)
        }
        #endif
    }
}
