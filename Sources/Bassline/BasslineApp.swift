import SwiftUI

@main
struct BasslineApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Bassline", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 640)
        }
        .defaultSize(width: 1000, height: 760)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppModel {
    /// A binding to one field of a profile that writes through `update`.
    func binding<Value>(_ id: String, _ keyPath: WritableKeyPath<DeviceProfile, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { self.profile(id: id)?[keyPath: keyPath] ?? fallback },
            set: { newValue in self.update(id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    func presetBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { self.profile(id: id)?.presetName ?? EQPreset.flat.name },
            set: { name in
                guard let preset = self.profile(id: id)?.presets.first(where: { $0.name == name }) else { return }
                self.update(id) { $0.apply(preset) }
            }
        )
    }

    func status(of profile: DeviceProfile) -> DeviceStatus {
        if isCurrentOutput(profile) {
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
