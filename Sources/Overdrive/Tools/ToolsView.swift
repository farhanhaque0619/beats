import SwiftUI

struct ToolsView: View {
    @EnvironmentObject private var tools: ToolsManager
    @AppStorage(SettingsKey.keepAwakeAllowsDisplaySleep) private var allowDisplaySleep = false

    var body: some View {
        PageScroll {
            PageHeader(
                symbol: "wrench.and.screwdriver",
                title: "Tools",
                subtitle: "Quick switches and fixes that usually live in Terminal."
            )

            if let message = tools.message {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassSurface(cornerRadius: 100)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(alignment: .top, spacing: 16) {
                keepAwakeCard
                microphoneCard
            }

            Card(title: "Finder & Dock", symbol: "macwindow") {
                VStack(spacing: 10) {
                    ToggleRow(title: "Show hidden files", detail: "Files and folders that start with a dot.", isOn: Binding(
                        get: { tools.toggles.showHiddenFiles }, set: { tools.setShowHiddenFiles($0) }
                    ))
                    ToggleRow(title: "Show all file extensions", detail: "Always show .png, .zip and so on.", isOn: Binding(
                        get: { tools.toggles.showExtensions }, set: { tools.setShowExtensions($0) }
                    ))
                    ToggleRow(title: "Hide desktop icons", detail: "A clean desktop for screen sharing and recordings.", isOn: Binding(
                        get: { tools.toggles.hideDesktopIcons }, set: { tools.setHideDesktopIcons($0) }
                    ))
                    ToggleRow(title: "Hide the Dock automatically", detail: "The Dock slides in when you move to the edge.", isOn: Binding(
                        get: { tools.toggles.dockAutohide }, set: { tools.setDockAutohide($0) }
                    ))
                }
                Text("Finder or the Dock restarts for a moment to apply a change.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Card(title: "Quick Actions", symbol: "bolt") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    ActionButton(title: "Sleep Displays", symbol: "display", action: { tools.sleepDisplays() })
                    ActionButton(title: "Eject All Disks", symbol: "eject", action: { tools.ejectAllDisks() })
                    ActionButton(title: "Restart Dock", symbol: "dock.rectangle", action: { tools.restartDock() })
                    ActionButton(title: "Restart Finder", symbol: "folder", action: { tools.restartFinder() })
                    ActionButton(title: "Restart Menu Bar", symbol: "menubar.rectangle", action: { tools.restartMenuBar() })
                    ActionButton(title: "Activity Monitor", symbol: "chart.bar.xaxis", action: { tools.openActivityMonitor() })
                }
            }
        }
        .navigationTitle("Tools")
        .animation(.smooth(duration: 0.3), value: tools.message)
        .onAppear {
            tools.refreshToggles()
            tools.refreshMicrophone()
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
            HStack(spacing: 8) {
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
