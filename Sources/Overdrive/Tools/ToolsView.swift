import SwiftUI

struct ToolsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case actions = "Actions"
        case switches = "Switches"
        case network = "Network"
        var id: String { rawValue }
    }

    @EnvironmentObject private var tools: ToolsManager
    @AppStorage(SettingsKey.keepAwakeAllowsDisplaySleep) private var allowDisplaySleep = false
    @AppStorage("toolsTab") private var tab: Tab = .actions

    var body: some View {
        PageScroll {
            PageHeader(
                symbol: "wrench.and.screwdriver",
                title: "Tools",
                subtitle: "Quick switches and fixes that usually live in Terminal."
            )

            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)

            if let message = tools.message {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassSurface(cornerRadius: 100)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Group {
                switch tab {
                case .actions: actions
                case .switches: switches
                case .network: network
                }
            }
            .transition(.opacity)
        }
        .navigationTitle("Tools")
        .animation(.smooth(duration: 0.3), value: tools.message)
        .animation(.smooth(duration: 0.25), value: tab)
        .onAppear {
            tools.refreshToggles()
            tools.refreshMicrophone()
            tools.refreshAddresses()
        }
    }

    @ViewBuilder
    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
            ActionButton(title: "Lock Screen", symbol: "lock", action: { tools.lockScreen() })
            ActionButton(title: "Take Screenshot", symbol: "camera.viewfinder", action: { tools.takeScreenshot() })
            ActionButton(title: "Sleep Displays", symbol: "display", action: { tools.sleepDisplays() })
            ActionButton(title: "Eject All Disks", symbol: "eject", action: { tools.ejectAllDisks() })
            ActionButton(title: "Empty Trash", symbol: "trash", action: { tools.emptyTrash() })
            ActionButton(title: "Activity Monitor", symbol: "chart.bar.xaxis", action: { tools.openActivityMonitor() })
        }
        HStack(alignment: .top, spacing: 16) {
            keepAwakeCard
            microphoneCard
        }
        Card(title: "Fix Things", symbol: "arrow.clockwise",
             info: "If the Dock, Finder or the menu bar freezes or looks wrong, restarting it usually fixes it in a second. Nothing is lost.") {
            HStack(spacing: 10) {
                ActionButton(title: "Restart Dock", symbol: "dock.rectangle", action: { tools.restartDock() })
                ActionButton(title: "Restart Finder", symbol: "folder", action: { tools.restartFinder() })
                ActionButton(title: "Restart Menu Bar", symbol: "menubar.rectangle", action: { tools.restartMenuBar() })
            }
        }
    }

    private var switches: some View {
        Card(title: "Appearance, Finder & Dock", symbol: "switch.2",
             info: "Finder or the Dock restarts for a moment to apply a change. Dark Mode asks once for permission to control System Events.") {
            VStack(spacing: 12) {
                ToggleRow(title: "Dark Mode", detail: "Light or dark, everywhere.", isOn: Binding(
                    get: { tools.isDarkMode }, set: { _ in tools.toggleDarkMode() }
                ))
                Divider()
                ToggleRow(title: "Show hidden files", detail: "Files that start with a dot.", isOn: Binding(
                    get: { tools.toggles.showHiddenFiles }, set: { tools.setShowHiddenFiles($0) }
                ))
                ToggleRow(title: "Show all file extensions", detail: "Like .png and .zip.", isOn: Binding(
                    get: { tools.toggles.showExtensions }, set: { tools.setShowExtensions($0) }
                ))
                ToggleRow(title: "Hide desktop icons", detail: "Clean desktop for screen sharing.", isOn: Binding(
                    get: { tools.toggles.hideDesktopIcons }, set: { tools.setHideDesktopIcons($0) }
                ))
                Divider()
                ToggleRow(title: "Hide the Dock automatically", detail: "It slides in at the screen edge.", isOn: Binding(
                    get: { tools.toggles.dockAutohide }, set: { tools.setDockAutohide($0) }
                ))
            }
        }
    }

    private var network: some View {
        Card(title: "Network Address", symbol: "network",
             info: "Your local address is how other devices on the same Wi-Fi reach your Mac. Your public address is what websites see; Overdrive only looks it up when you ask.") {
            AddressRow(title: "On this network", detail: "Your Wi-Fi or Ethernet address", address: tools.localAddress) {
                tools.refreshAddresses()
            }
            Divider()
            AddressRow(title: "On the internet", detail: "Looked up only when you ask", address: tools.publicAddress, isLoading: tools.isLookingUpPublicAddress) {
                tools.lookUpPublicAddress()
            }
        }
    }

    private var keepAwakeCard: some View {
        Card(title: "Keep Awake", symbol: "cup.and.saucer", trailing: {
            if tools.isKeepingAwake {
                Button("Turn Off") { withAnimation(.smooth) { tools.stopKeepingAwake() } }
                    .controlSize(.small)
            }
        }) {
            Text(keepAwakeStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(ToolsManager.keepAwakeChoices) { choice in
                    Button(choice.minutes.map { $0 >= 60 ? "\($0 / 60) h" : "\($0) min" } ?? "On") {
                        withAnimation(.smooth) { tools.keepAwake(minutes: choice.minutes) }
                    }
                    .controlSize(.small)
                    .help(choice.title)
                }
            }
            Toggle("Let the display sleep", isOn: $allowDisplaySleep)
                .onChange(of: allowDisplaySleep) { _, _ in tools.keepAwakePreferenceChanged() }
        }
    }

    private var keepAwakeStatus: String {
        guard let until = tools.keepAwakeUntil else { return "Off. Your Mac sleeps as usual." }
        if until == .distantFuture { return "On until you turn it off." }
        return "On until \(until.formatted(date: .omitted, time: .shortened))."
    }

    private var microphoneCard: some View {
        Card(title: "Microphone", symbol: tools.isMicMuted ? "mic.slash" : "mic") {
            if tools.hasMicrophone {
                Text(tools.isMicMuted ? "Muted. Apps hear silence." : "On.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation(.smooth) { tools.setMicMuted(!tools.isMicMuted) }
                } label: {
                    Label(tools.isMicMuted ? "Unmute Microphone" : "Mute Microphone", systemImage: tools.isMicMuted ? "mic" : "mic.slash")
                }
            } else {
                Text("No microphone is connected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassSurface(cornerRadius: 14, interactive: true)
        .scaleEffect(isHovering ? 1.015 : 1)
        .animation(.snappy(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private struct AddressRow: View {
    @EnvironmentObject private var tools: ToolsManager
    let title: String
    let detail: String
    let address: String?
    var isLoading = false
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            } else if let address {
                Text(address)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Button {
                    tools.copy(address)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            Button(address == nil ? "Show" : "Refresh", action: refresh)
                .controlSize(.small)
        }
    }
}
