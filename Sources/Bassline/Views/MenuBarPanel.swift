import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let profile = model.activeProfile {
                let status = model.status(of: profile)
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.accentColor.gradient)
                        Image(systemName: profile.kind.symbolName)
                            .font(.system(size: 17))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.displayName).font(.headline).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(status.color).frame(width: 6, height: 6)
                            Text(status.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Toggle("Equalizer", isOn: model.binding(profile.id, \.isEnabled, fallback: false))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                EQCurveView(profile: profile, compact: true)
                    .frame(height: 64)
                    .padding(.horizontal, 2)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Picker("Preset", selection: model.presetBinding(profile.id)) {
                    ForEach(profile.presets) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                    if !profile.presets.contains(where: { $0.name == profile.presetName }) {
                        Divider()
                        Text(profile.presetName).tag(profile.presetName)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bass Boost")
                        Spacer()
                        Text(profile.bassBoost == 0 ? "Off" : String(format: "+%.1f dB", profile.bassBoost))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    Slider(value: model.binding(profile.id, \.bassBoost, fallback: 0), in: EQBands.bassBoostRange, step: 0.5) {
                        Text("Bass Boost")
                    }
                    .labelsHidden()
                }
                .disabled(!profile.isEnabled)
            } else {
                Label("No sound output found", systemImage: "speaker.slash")
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                PanelButton(title: "Open Bassline…", symbol: "macwindow") {
                    if let id = model.activeProfile?.id { model.selectedProfileID = id }
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                PanelButton(title: "Quit Bassline", symbol: "power") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct PanelButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
