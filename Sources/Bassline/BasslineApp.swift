import AppKit
import SwiftUI

@main
struct BasslineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = UpdateChecker()
    @StateObject private var battery = BatteryMonitor()
    @AppStorage(SettingsKey.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        Window("Bassline", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
                .environmentObject(battery)
                .frame(minWidth: 900, minHeight: 680)
                .task { updater.checkIfDue() }
        }
        .defaultSize(width: 1040, height: 800)
        .windowToolbarStyle(.unified)
        .commands { EqualizerCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
                .environmentObject(battery)
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarPanel()
                .environmentObject(model)
                .environmentObject(updater)
                .environmentObject(battery)
                .task { updater.checkIfDue() }
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}

struct EqualizerCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Equalizer") {
            Button("Turn Equalizer On or Off") { model.toggleActiveEQ() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("More Bass Boost") { model.nudgeBassBoost(by: 1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Less Bass Boost") { model.nudgeBassBoost(by: -1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("Show Current Device") {
                if let id = model.activeProfile?.id { model.selectedProfileID = id }
            }
            .keyboardShortcut("0", modifiers: .command)
            Button("Show Multi-Output") { model.selectedProfileID = AppModel.groupSelectionID }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Show App Sound") { model.selectedProfileID = AppModel.appsSelectionID }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Auto-Sync Multi-Output") { model.autoSync() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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

    /// Closing the window leaves Bassline running in the menu bar so the EQ keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension AppModel {
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
