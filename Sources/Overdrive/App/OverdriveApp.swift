import AppKit
import SwiftUI

@main
struct OverdriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = SoundModel()
    @StateObject private var updater = UpdateChecker()
    @StateObject private var battery = BatteryMonitor()
    @StateObject private var displays = DisplayManager()
    @StateObject private var monitor = SystemMonitor()
    @StateObject private var tools = ToolsManager()
    @AppStorage(SettingsKey.showMenuBarIcon) private var showMenuBarIcon = true

    init() {
        // An update from Bassline 1.x lands as Bassline.app; rename and relaunch first.
        if LegacyMigration.runIfNeeded() { exit(0) }
    }

    var body: some Scene {
        Window("Overdrive", id: "main") {
            ContentView()
                .environmentObjects(model, updater, battery, displays, monitor, tools)
                .frame(minWidth: 940, minHeight: 700)
                .task {
                    updater.checkIfDue()
                    appDelegate.displays = displays
                }
        }
        .defaultSize(width: 1080, height: 820)
        .windowToolbarStyle(.unified)
        .commands { OverdriveCommands(model: model, displays: displays, tools: tools) }

        Settings {
            SettingsView()
                .environmentObjects(model, updater, battery, displays, monitor, tools)
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarPanel()
                .environmentObjects(model, updater, battery, displays, monitor, tools)
                .task {
                    updater.checkIfDue()
                    appDelegate.displays = displays
                }
        } label: {
            MenuBarLabel()
                .environmentObject(monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

extension View {
    func environmentObjects(
        _ model: SoundModel, _ updater: UpdateChecker, _ battery: BatteryMonitor,
        _ displays: DisplayManager, _ monitor: SystemMonitor, _ tools: ToolsManager
    ) -> some View {
        environmentObject(model)
            .environmentObject(updater)
            .environmentObject(battery)
            .environmentObject(displays)
            .environmentObject(monitor)
            .environmentObject(tools)
    }
}

/// The menu bar icon, optionally with live CPU and temperature next to it.
struct MenuBarLabel: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @AppStorage(SettingsKey.menuBarStats) private var showStats = false

    var body: some View {
        Group {
            if showStats {
                let s = monitor.snapshot
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                    Text(statsText(s)).monospacedDigit()
                }
            } else {
                Image(systemName: "slider.vertical.3")
            }
        }
        .onAppear { if showStats { monitor.start("menubar-label") } }
        .onChange(of: showStats) { _, on in
            if on { monitor.start("menubar-label") } else { monitor.stop("menubar-label") }
        }
    }

    private func statsText(_ s: SystemSnapshot) -> String {
        var text = Format.percent(s.cpu)
        if let temperature = s.cpuTemperature { text += " " + Format.temperature(temperature) }
        return text
    }
}

struct OverdriveCommands: Commands {
    let model: SoundModel
    let displays: DisplayManager
    let tools: ToolsManager

    var body: some Commands {
        CommandMenu("Go") {
            Button("Overview") { model.selectedProfileID = Page.overview }
                .keyboardShortcut("1", modifiers: .command)
            Button("Current Sound Device") {
                if let id = model.activeProfile?.id { model.selectedProfileID = id }
            }
            .keyboardShortcut("2", modifiers: .command)
            Button("Multi-Output") { model.selectedProfileID = SoundModel.groupSelectionID }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("App Sound") { model.selectedProfileID = SoundModel.appsSelectionID }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Displays") { model.selectedProfileID = Page.display }
                .keyboardShortcut("3", modifiers: .command)
            Button("Performance") { model.selectedProfileID = Page.performance }
                .keyboardShortcut("4", modifiers: .command)
            Button("Tools") { model.selectedProfileID = Page.tools }
                .keyboardShortcut("5", modifiers: .command)
        }
        CommandMenu("Controls") {
            Button("Turn Equalizer On or Off") { model.toggleActiveEQ() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("More Bass Boost") { model.nudgeBassBoost(by: 1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Less Bass Boost") { model.nudgeBassBoost(by: -1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Auto-Sync Multi-Output") { model.autoSync() }
            Divider()
            Button("Turn Extra Brightness On or Off") { displays.setBoostEnabled(!displays.boostEnabled) }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!displays.canBoost)
            Button("Keep Awake On or Off") {
                if tools.isKeepingAwake { tools.stopKeepingAwake() } else { tools.keepAwake(minutes: nil) }
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
            Button("Mute or Unmute Microphone") { tools.setMicMuted(!tools.isMicMuted) }
                .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var displays: DisplayManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SettingsKey.showInDock) as? Bool == false {
            NSApp.setActivationPolicy(.accessory)
        }
        if defaults.object(forKey: SettingsKey.openWindowAtLaunch) as? Bool == false {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true {
                    window.close()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { displays?.restoreAll() }
    }

    /// Closing the window leaves Overdrive running in the menu bar so everything keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension SoundModel {
    /// A binding to one field of a profile that writes through `update`.
    func binding<Value>(
        _ id: String,
        _ keyPath: WritableKeyPath<DeviceProfile, Value>,
        fallback: Value,
        animation: Animation? = nil
    ) -> Binding<Value> {
        Binding(
            get: { self.profile(id: id)?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                withAnimation(animation) { self.update(id) { $0[keyPath: keyPath] = newValue } }
            }
        )
    }

    func presetBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { self.profile(id: id)?.presetName ?? EQPreset.flat.name },
            set: { name in
                guard let profile = self.profile(id: id),
                      let preset = self.presets(for: profile).first(where: { $0.name == name }) else { return }
                withAnimation(.smooth(duration: 0.5)) { self.apply(preset, to: id) }
            }
        )
    }

    func status(of profile: DeviceProfile) -> DeviceStatus {
        if isPlaying(profile) {
            if case .failed(let message) = engineStatus, profile.isEnabled { return .failed(message) }
            if case .unsupported = engineStatus { return .unsupported }
            return isProcessing(profile) ? .equalizing : .playingWithoutEQ
        }
        return isConnected(profile) ? .connected : .disconnected
    }
}

enum DeviceStatus: Equatable {
    case equalizing, playingWithoutEQ, connected, disconnected, unsupported
    case failed(String)

    var title: String {
        switch self {
        case .equalizing: "Equalizing now"
        case .playingWithoutEQ: "Playing without EQ"
        case .connected: "Connected, not the sound output"
        case .disconnected: "Not connected"
        case .unsupported: "Needs macOS 14.2 or later"
        case .failed: "EQ couldn’t start"
        }
    }

    var shortTitle: String {
        switch self {
        case .equalizing: "EQ On"
        case .playingWithoutEQ: "EQ Off"
        case .connected: "Connected"
        case .disconnected: "Not connected"
        case .unsupported: "Unsupported"
        case .failed: "Error"
        }
    }

    var color: Color {
        switch self {
        case .equalizing: .green
        case .playingWithoutEQ, .connected: .secondary
        case .disconnected: .secondary.opacity(0.6)
        case .unsupported, .failed: .orange
        }
    }
}
