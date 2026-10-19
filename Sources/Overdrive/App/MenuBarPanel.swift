import AppKit
import SwiftUI

/// The menu bar dropdown: sound, a live system readout and one-click actions.
struct MenuBarPanel: View {
    @EnvironmentObject private var model: SoundModel
    @EnvironmentObject private var updater: UpdateChecker
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let profile = model.activeProfile {
                SoundSection(profile: profile)
            } else {
                Label("No sound output found", systemImage: "speaker.slash")
                    .foregroundStyle(.secondary)
            }

            OutputPicker()

            Divider()
            SystemSection()
            Divider()
            QuickActions()

            if let release = updater.availableRelease {
                Button(action: showSettings) {
                    Label("Overdrive \(release.version) is available", systemImage: "arrow.down.circle.fill")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .glassSurface(cornerRadius: 10, tint: Theme.accent, interactive: true)
            }

            Divider()

            HStack(spacing: 4) {
                PanelButton(title: "Open Overdrive", symbol: "macwindow") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                PanelIconButton(symbol: "gearshape", help: "Settings", action: showSettings)
                PanelIconButton(symbol: "power", help: "Quit Overdrive") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
        .tint(Theme.accent)
    }

    private func showSettings() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Sound

private struct SoundSection: View {
    @EnvironmentObject private var model: SoundModel
    @EnvironmentObject private var battery: BatteryMonitor
    @Environment(\.openWindow) private var openWindow
    let profile: DeviceProfile

    var body: some View {
        let status = model.status(of: profile)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    model.selectedProfileID = model.isGroupActive ? SoundModel.groupSelectionID : profile.id
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 10) {
                DeviceBadge(symbol: profile.symbolName, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(status.color)
                        Text(status.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this device’s sound settings")
                Spacer(minLength: 8)
                Toggle("Equalizer", isOn: model.binding(profile.id, \.isEnabled, fallback: false, animation: .smooth(duration: 0.3)))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if let info = battery.battery(for: model.currentOutput?.name) {
                BatteryLabel(info: info, showCase: true)
                    .font(.caption)
                    .padding(.leading, 44)
            }

            FlowLayout(spacing: 6) {
                ForEach(model.presets(for: profile)) { preset in
                    PresetChip(title: preset.name, isSelected: preset.name == profile.presetName, tint: Theme.accent, compact: true) {
                        withAnimation(.smooth(duration: 0.4)) { model.apply(preset, to: profile.id) }
                    }
                }
            }
            .disabled(!profile.isEnabled)

            HStack(spacing: 8) {
                Text("Bass Boost")
                    .font(.callout)
                Slider(value: model.binding(profile.id, \.bassBoost, fallback: 0), in: EQBands.bassBoostRange, step: 0.5) {
                    Text("Bass Boost")
                }
                .labelsHidden()
                .controlSize(.small)
                Text(profile.bassBoost < 0.05 ? "Off" : String(format: "+%.0f dB", profile.bassBoost))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .disabled(!profile.isEnabled)
        }
        .animation(.smooth(duration: 0.3), value: status)
    }

    /// The real device name (or the group), not the product template's name.
    private var title: String {
        if model.isGroupActive { return "\(model.activeGroup.count) devices" }
        return model.currentOutput?.name ?? profile.displayName
    }
}

/// Lists every output, like the Sound menu in Control Center. Clicking a name makes it the
/// sound output; the circle on the right adds it to Multi-Output.
private struct OutputPicker: View {
    @EnvironmentObject private var model: SoundModel
    @EnvironmentObject private var battery: BatteryMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel("Output")
                Spacer()
                if model.isGroupActive {
                    Text("Playing on \(model.activeGroup.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            ForEach(model.connectedDevices) { device in
                OutputRow(device: device)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.isGroupActive)
    }
}

private struct OutputRow: View {
    @EnvironmentObject private var model: SoundModel
    @EnvironmentObject private var battery: BatteryMonitor
    let device: OutputDevice

    var body: some View {
        let profile = model.profile(for: device)
        let isCurrent = device.uid == model.currentOutput?.uid
        let isMember = model.isInGroup(device)
        HStack(spacing: 0) {
            Button {
                model.playThrough(device)
            } label: {
                HStack(spacing: 8) {
                    DeviceBadge(symbol: profile?.symbolName ?? "speaker.wave.2.fill", size: 22, dimmed: !isMember)
                    Text(device.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let level = battery.battery(for: device.name)?.headline {
                        Text("\(level)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(BatteryLabel.color(level))
                            .fixedSize()
                    }
                    if let profile, !profile.isFlat, profile.isEnabled {
                        Text("EQ")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.accent)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverRowStyle())
            .help(isCurrent ? "Sound output" : "Make this the sound output")

            Button {
                withAnimation(.smooth(duration: 0.3)) { model.toggleGroupMember(device) }
            } label: {
                Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isMember ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCurrent || !model.canAddToGroup(device))
            .help(isCurrent ? "The sound output always plays" : (isMember ? "Stop playing here" : "Also play here at the same time"))
        }
    }
}

// MARK: - System

/// A compact, readable readout of the Mac's vital signs.
private struct SystemSection: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var model: SoundModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("System")
                Spacer()
                Button("Details") { open(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                tile(.cpu, MiniStat(title: "CPU", value: Format.percent(s.cpu), fraction: s.cpu))
                tile(.gpu, MiniStat(title: "GPU", value: s.gpu.map(Format.percent) ?? "—", fraction: s.gpu))
                tile(.memory, MiniStat(title: "Memory", value: Format.percent(s.memoryFraction), fraction: s.memoryFraction, warning: s.pressure != .normal))
                tile(.temperature, MiniStat(title: "CPU Temp", value: Format.temperature(s.cpuTemperature), fraction: s.cpuTemperature.map { $0 / 100 }))
                tile(.temperature, MiniStat(title: "Fans", value: fanText(s), fraction: s.fans.map(\.fraction).max()))
                tile(.power, MiniStat(title: powerTitle(s), value: powerText(s), fraction: nil))
            }
        }
        .onAppear { monitor.start("menubar-panel") }
        .onDisappear { monitor.stop("menubar-panel") }
    }

    /// Each tile opens its own detail page in the main window.
    private func tile(_ metric: Metric, _ stat: MiniStat) -> some View {
        Button { open(metric) } label: { stat }
            .buttonStyle(.plain)
            .help("Show \(metric.title) details")
    }

    private func open(_ metric: Metric?) {
        model.selectedProfileID = Page.performance
        monitor.focusedMetric = metric
        openMain()
    }

    private func fanText(_ s: SystemSnapshot) -> String {
        guard s.hasFans else { return "None" }
        guard let fan = s.fans.max(by: { $0.rpm < $1.rpm }) else { return "—" }
        return fan.rpm < 100 ? "Off" : "\(Int(fan.rpm.rounded()))"
    }

    private func powerTitle(_ s: SystemSnapshot) -> String {
        if let battery = s.battery { return battery.isCharging ? "Charging" : (battery.onAC ? "Plugged In" : "Battery") }
        return "Power"
    }

    private func powerText(_ s: SystemSnapshot) -> String {
        if let battery = s.battery { return "\(battery.percent)%" }
        if let power = s.systemPower { return Format.watts(power) }
        return "—"
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MiniStat: View {
    let title: String
    let value: String
    let fraction: Double?
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            MeterBar(value: fraction ?? 0, height: 3, warning: warning)
                .opacity(fraction == nil ? 0 : 1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Quick actions

private struct QuickActions: View {
    @EnvironmentObject private var displays: DisplayManager
    @EnvironmentObject private var tools: ToolsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Quick Actions")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 8) {
                if displays.canBoost {
                    QuickToggle(title: "Brighter", symbol: "sun.max.fill", isOn: displays.isBoostActive) {
                        withAnimation(.smooth) { displays.setBoostEnabled(!displays.boostEnabled) }
                    }
                }
                QuickToggle(title: "Awake", symbol: "cup.and.saucer.fill", isOn: tools.isKeepingAwake) {
                    withAnimation(.smooth) {
                        if tools.isKeepingAwake { tools.stopKeepingAwake() } else { tools.keepAwake(minutes: nil) }
                    }
                }
                if tools.hasMicrophone {
                    QuickToggle(title: tools.isMicMuted ? "Mic Off" : "Mic", symbol: tools.isMicMuted ? "mic.slash.fill" : "mic.fill", isOn: tools.isMicMuted) {
                        withAnimation(.smooth) { tools.setMicMuted(!tools.isMicMuted) }
                    }
                }
                QuickToggle(title: "Dark", symbol: "circle.lefthalf.filled", isOn: tools.isDarkMode) {
                    tools.toggleDarkMode()
                }
                QuickToggle(title: "Eject All", symbol: "eject.fill", isOn: false) { tools.ejectAllDisks() }
                QuickToggle(title: "Lock", symbol: "lock.fill", isOn: false) { tools.lockScreen() }
                QuickToggle(title: "Screenshot", symbol: "camera.viewfinder", isOn: false) { tools.takeScreenshot() }
                QuickToggle(title: "Sleep Screen", symbol: "moon.fill", isOn: false) { tools.sleepDisplays() }
            }
            if let message = tools.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: tools.message)
    }
}

private struct QuickToggle: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(isHovering ? 0.14 : 0.08))))
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.2), value: isOn)
        .help(title)
    }
}

// MARK: - Shared pieces

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

private struct PanelButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

private struct PanelIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .help(help)
    }
}

/// Menu-style row highlight on hover.
private struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovering ? 0.08 : 0)))
                )
                .animation(.snappy(duration: 0.15), value: isHovering)
                .onHover { isHovering = $0 }
        }
    }
}
