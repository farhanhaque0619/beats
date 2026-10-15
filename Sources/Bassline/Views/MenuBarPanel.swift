import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updater: UpdateChecker
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let profile = model.activeProfile {
                ActiveDeviceSection(profile: profile)
            } else {
                Label("No sound output found", systemImage: "speaker.slash")
                    .foregroundStyle(.secondary)
            }

            OutputPicker()

            if let release = updater.availableRelease {
                Button {
                    showSettings()
                } label: {
                    Label("Bassline \(release.version) is available", systemImage: "arrow.down.circle.fill")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .glassSurface(cornerRadius: 10, tint: .accentColor, interactive: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                PanelButton(title: "Open Bassline", symbol: "macwindow") {
                    if let id = model.activeProfile?.id { model.selectedProfileID = id }
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                PanelButton(title: "Settings…", symbol: "gearshape", action: showSettings)
                PanelButton(title: "Quit Bassline", symbol: "power") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func showSettings() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ActiveDeviceSection: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile

    var body: some View {
        let status = model.status(of: profile)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DeviceBadge(symbol: profile.symbolName, tint: profile.tint, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName).font(.headline).lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(status.color)
                        Text(status.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if model.isPlaying(profile) && model.engine.isRunning {
                    LevelMeter(processor: model.engine.processor, route: model.route(for: profile) ?? 0, tint: profile.tint, isActive: true, height: 26)
                }
                Toggle("Equalizer", isOn: model.binding(profile.id, \.isEnabled, fallback: false, animation: .smooth(duration: 0.3)))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            ResponseCurveView(profile: profile, compact: true)
                .frame(height: 70)
                .padding(4)
                .glassSurface(cornerRadius: 14, tint: profile.tint)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.presets(for: profile)) { preset in
                        PresetChip(title: preset.name, isSelected: preset.name == profile.presetName, tint: profile.tint) {
                            withAnimation(.smooth(duration: 0.5)) { model.apply(preset, to: profile.id) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Bass Boost")
                    Spacer()
                    Text(profile.bassBoost < 0.05 ? "Off" : String(format: "+%.1f dB", profile.bassBoost))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: profile.bassBoost))
                }
                .font(.callout)
                Slider(value: model.binding(profile.id, \.bassBoost, fallback: 0), in: EQBands.bassBoostRange, step: 0.5) {
                    Text("Bass Boost")
                }
                .labelsHidden()
            }
            .disabled(!profile.isEnabled)
        }
        .tint(profile.tint)
        .animation(.smooth(duration: 0.3), value: status)
    }
}

/// Lists every output, like the Sound menu in Control Center. Clicking a name makes it the
/// sound output; the circle on the right adds it to Multi-Output.
private struct OutputPicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isGroupActive {
                    Text("Playing on \(model.activeGroup.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.multiOutput)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 8)

            ForEach(model.connectedDevices) { device in
                let profile = model.profile(for: device)
                let isCurrent = device.uid == model.currentOutput?.uid
                let isMember = model.isInGroup(device)
                HStack(spacing: 0) {
                    Button {
                        model.playThrough(device)
                    } label: {
                        HStack(spacing: 10) {
                            DeviceBadge(
                                symbol: profile?.symbolName ?? "speaker.wave.2.fill",
                                tint: profile?.tint ?? DeviceKind.other.tint,
                                size: 24,
                                dimmed: !isMember
                            )
                            Text(device.name).lineLimit(1)
                            Spacer(minLength: 0)
                            if let profile, !profile.isFlat, profile.isEnabled {
                                Text("EQ")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(profile.tint)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                    .help(isCurrent ? "Sound output" : "Make this the sound output")

                    Button {
                        withAnimation(.smooth(duration: 0.3)) { model.toggleGroupMember(device) }
                    } label: {
                        Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17))
                            .foregroundStyle(isMember ? AnyShapeStyle(profile?.tint ?? .accentColor) : AnyShapeStyle(.tertiary))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isCurrent || !model.canAddToGroup(device))
                    .help(isCurrent ? "The sound output always plays" : (isMember ? "Stop playing here" : "Also play here"))
                }
            }

            if model.connectedDevices.count > 1 {
                Text("Tick more than one device to play on all of them at once.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.isGroupActive)
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
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovering ? 0.08 : 0)))
                )
                .animation(.snappy(duration: 0.15), value: isHovering)
                .onHover { isHovering = $0 }
        }
    }
}
