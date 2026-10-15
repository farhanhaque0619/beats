import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            ZStack {
                AmbientBackground(tint: backgroundTint)

                if model.selectedProfileID == AppModel.groupSelectionID {
                    GroupView()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.985)),
                            removal: .opacity
                        ))
                } else if let id = model.selectedProfileID, model.profile(id: id) != nil {
                    ProfileDetailView(profileID: id)
                        .id(id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.985)),
                            removal: .opacity
                        ))
                } else {
                    ContentUnavailableView(
                        "Choose a Device",
                        systemImage: "headphones",
                        description: Text("Pick headphones or a speaker to shape how it sounds.")
                    )
                }
            }
            .animation(.smooth(duration: 0.35), value: model.selectedProfileID)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
    }
}

extension ContentView {
    private var backgroundTint: Color {
        if model.selectedProfileID == AppModel.groupSelectionID { return .multiOutput }
        return model.profile(id: model.selectedProfileID)?.tint ?? DeviceKind.other.tint
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selectedProfileID) {
            Section {
                MultiOutputRow().tag(AppModel.groupSelectionID)
            }
            Section("My Devices") {
                ForEach(model.knownProfiles) { profile in
                    DeviceRow(profile: profile).tag(profile.id)
                }
            }
            if !model.connectedOtherProfiles.isEmpty {
                Section("Connected") {
                    ForEach(model.connectedOtherProfiles) { profile in
                        DeviceRow(profile: profile).tag(profile.id)
                    }
                }
            }
            if !model.savedOtherProfiles.isEmpty {
                Section("Saved") {
                    ForEach(model.savedOtherProfiles) { profile in
                        DeviceRow(profile: profile).tag(profile.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .animation(.smooth(duration: 0.3), value: model.connectedOtherProfiles.map(\.id))
        .safeAreaInset(edge: .bottom) {
            EngineFooter()
                .padding(10)
        }
    }
}

private struct MultiOutputRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            DeviceBadge(symbol: "hifispeaker.2.fill", tint: .multiOutput, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Multi-Output")
                Text(model.isGroupActive ? "Playing on \(model.activeGroup.count) devices" : "Play on several devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            if model.isGroupActive {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Color.multiOutput)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 3)
        .animation(.smooth(duration: 0.3), value: model.isGroupActive)
    }
}

private struct DeviceRow: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile

    var body: some View {
        let status = model.status(of: profile)
        HStack(spacing: 10) {
            DeviceBadge(symbol: profile.symbolName, tint: profile.tint, size: 28, dimmed: status == .disconnected)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                    .lineLimit(1)
                Text(rowSubtitle(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if status == .equalizing {
                Image(systemName: "waveform")
                    .foregroundStyle(profile.tint)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .help("Equalizing now")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 3)
        .animation(.smooth(duration: 0.3), value: status)
        .contextMenu {
            if model.isConnected(profile) && !model.isCurrentOutput(profile) {
                Button("Play Through This Device") { model.playThrough(profile) }
                if let device = model.device(for: profile) {
                    Button(model.isInGroup(device) ? "Stop Playing Here Too" : "Also Play Here") {
                        model.toggleGroupMember(device)
                    }
                    .disabled(!model.canAddToGroup(device))
                }
            }
            Button("Reset EQ") {
                withAnimation(.smooth(duration: 0.45)) { model.reset(profile.id) }
            }
            if profile.kind == .other && !model.isConnected(profile) {
                Divider()
                Button("Forget This Device", role: .destructive) { model.forget(profile.id) }
            }
        }
    }

    private func rowSubtitle(_ status: DeviceStatus) -> String {
        switch status {
        case .equalizing: return "Equalizing · \(profile.presetName)"
        case .playingWithoutEQ: return profile.isEnabled ? "Playing · Flat" : "Playing · EQ off"
        default: return status.shortTitle
        }
    }
}

private struct EngineFooter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(dotColor)
                .symbolEffect(.pulse, options: .repeating, isActive: isRunning)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassSurface(cornerRadius: 14)
        .animation(.smooth(duration: 0.3), value: model.engineStatus)
    }

    private var isRunning: Bool {
        if case .running = model.engineStatus { return true }
        return false
    }

    private var dotColor: Color {
        switch model.engineStatus {
        case .running: .green
        case .idle: .gray
        case .failed, .unsupported: .orange
        }
    }

    private var title: String {
        switch model.engineStatus {
        case .running: "Equalizer on"
        case .idle: "Not processing"
        case .failed: "Equalizer stopped"
        case .unsupported: "Unavailable"
        }
    }

    private var subtitle: String {
        "Output: \(model.currentOutput?.name ?? "None")"
    }
}
