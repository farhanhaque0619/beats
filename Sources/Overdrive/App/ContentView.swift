import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: SoundModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsKey.accentStyle) private var accentStyle = AccentStyle.system.rawValue

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            ZStack {
                AmbientBackground(tint: Theme.accent)
                detail
                    .id(model.selectedProfileID)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.985)),
                        removal: .opacity
                    ))
            }
            .animation(.smooth(duration: 0.35), value: model.selectedProfileID)
        }
        .tint(Theme.accent)
        .id(accentStyle)
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

    @ViewBuilder
    private var detail: some View {
        switch model.selectedProfileID {
        case .some(Page.overview): OverviewView()
        case .some(Page.display): DisplayView()
        case .some(Page.performance): PerformanceView()
        case .some(Page.tools): ToolsView()
        case .some(SoundModel.appsSelectionID): AppsView()
        case .some(SoundModel.groupSelectionID): GroupView()
        case let id? where model.profile(id: id) != nil: ProfileDetailView(profileID: id)
        default:
            ContentUnavailableView(
                "Choose Something",
                systemImage: "sidebar.left",
                description: Text("Pick a section in the sidebar.")
            )
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var model: SoundModel
    @EnvironmentObject private var displays: DisplayManager
    @EnvironmentObject private var tools: ToolsManager
    @AppStorage("sidebarSoundExpanded") private var soundExpanded = true
    @AppStorage("sidebarSavedExpanded") private var savedExpanded = false

    var body: some View {
        List(selection: $model.selectedProfileID) {
            Section {
                NavRow(title: "Overview", symbol: "square.grid.2x2", subtitle: "Everything at a glance").tag(Page.overview)
            }
            Section(isExpanded: $soundExpanded) {
                MultiOutputRow().tag(SoundModel.groupSelectionID)
                AppSoundRow().tag(SoundModel.appsSelectionID)
                ForEach(model.knownProfiles) { profile in
                    DeviceRow(profile: profile).tag(profile.id)
                }
                ForEach(model.connectedOtherProfiles) { profile in
                    DeviceRow(profile: profile).tag(profile.id)
                }
            } header: {
                Text("Sound")
            }
            if !model.savedOtherProfiles.isEmpty {
                Section(isExpanded: $savedExpanded) {
                    ForEach(model.savedOtherProfiles) { profile in
                        DeviceRow(profile: profile).tag(profile.id)
                    }
                } header: {
                    Text("Saved Sound Devices")
                }
            }
            Section("Display") {
                NavRow(title: "Displays", symbol: "sun.max", subtitle: displaySubtitle).tag(Page.display)
            }
            Section("System") {
                NavRow(title: "Performance", symbol: "gauge.with.dots.needle.50percent", subtitle: "CPU, memory, heat, battery").tag(Page.performance)
                NavRow(title: "Tools", symbol: "wrench.and.screwdriver", subtitle: tools.isKeepingAwake ? "Keeping your Mac awake" : "Keep awake, Finder, quick fixes").tag(Page.tools)
            }
        }
        .listStyle(.sidebar)
        .animation(.smooth(duration: 0.3), value: model.connectedOtherProfiles.map(\.id))
        .safeAreaInset(edge: .bottom) {
            EngineFooter()
                .padding(10)
        }
    }

    private var displaySubtitle: String {
        guard displays.canBoost else { return "Brightness and resolution" }
        if displays.isBoostActive { return "Extra Brightness on" }
        return "Extra Brightness off"
    }
}

private struct NavRow: View {
    let title: String
    let symbol: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            DeviceBadge(symbol: symbol, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

private struct MultiOutputRow: View {
    @EnvironmentObject private var model: SoundModel

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

private struct AppSoundRow: View {
    @EnvironmentObject private var model: SoundModel

    var body: some View {
        let customised = model.appRules.values.filter { !$0.isDefault }.count
        HStack(spacing: 10) {
            DeviceBadge(symbol: "square.stack.3d.up.fill", tint: .appSound, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("App Sound")
                Text(customised == 0 ? "Volume and EQ per app" : "\(customised) app\(customised == 1 ? "" : "s") customised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

private struct DeviceRow: View {
    @EnvironmentObject private var model: SoundModel
    @EnvironmentObject private var battery: BatteryMonitor
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
            if let info = battery.battery(for: model.device(for: profile)?.name), let level = info.headline {
                HStack(spacing: 2) {
                    Image(systemName: BatteryLabel.symbol(level))
                        .foregroundStyle(BatteryLabel.color(level))
                    Text("\(level)%")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(batteryHelp(info))
            }
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

    private func batteryHelp(_ info: BatteryInfo) -> String {
        var parts: [String] = []
        if let left = info.left { parts.append("Left \(left)%") }
        if let right = info.right { parts.append("Right \(right)%") }
        if let caseLevel = info.caseLevel { parts.append("Case \(caseLevel)%") }
        if let main = info.main, parts.isEmpty { parts.append("Battery \(main)%") }
        return parts.joined(separator: ", ")
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
    @EnvironmentObject private var model: SoundModel

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
        case .idle: "Equalizer idle"
        case .failed: "Equalizer stopped"
        case .unsupported: "Unavailable"
        }
    }

    private var subtitle: String {
        "Output: \(model.currentOutput?.name ?? "None")"
    }
}
