import AppKit
import SwiftUI

struct ProfileDetailView: View {
    @EnvironmentObject private var model: AppModel
    let profileID: String

    var body: some View {
        if let profile = model.profile(id: profileID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DeviceHeader(profile: profile)
                    StatusNotice(profile: profile)

                    GroupBox {
                        EQCurveView(profile: profile)
                            .frame(height: 200)
                            .padding(6)
                    } label: {
                        Label("Frequency Response", systemImage: "waveform.path.ecg")
                    }

                    GroupBox {
                        BandSliders(profile: profile)
                            .padding(.vertical, 8)
                    } label: {
                        Label("Bands", systemImage: "slider.vertical.3")
                    }

                    HStack(alignment: .top, spacing: 18) {
                        BassBoostBox(profile: profile)
                        OutputBox(profile: profile)
                    }

                    Label(profile.kind.tip, systemImage: "lightbulb")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(24)
                .frame(maxWidth: 940)
                .frame(maxWidth: .infinity)
                .opacity(profile.isEnabled ? 1 : 0.55)
                .animation(.easeOut(duration: 0.2), value: profile.isEnabled)
            }
            .navigationTitle(profile.displayName)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("Preset", selection: model.presetBinding(profileID)) {
                        ForEach(profile.presets) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                        if !profile.presets.contains(where: { $0.name == profile.presetName }) {
                            Divider()
                            Text(profile.presetName).tag(profile.presetName)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 150)
                    .help("Load a preset")

                    Button {
                        withAnimation(.snappy) { model.reset(profileID) }
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .help("Restore this device’s recommended settings")
                }
            }
        }
    }
}

// MARK: - Header

private struct DeviceHeader: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile

    var body: some View {
        let status = model.status(of: profile)
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.gradient)
                Image(systemName: profile.kind.symbolName)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.white)
            }
            .frame(width: 76, height: 76)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 5) {
                Text(profile.displayName)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                Text(profile.kind.category)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Toggle("Equalizer", isOn: model.binding(profile.id, \.isEnabled, fallback: false))
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .labelsHidden()
                Text(profile.isEnabled ? "Equalizer On" : "Equalizer Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Notices

private struct StatusNotice: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("hasDismissedPermissionNote") private var dismissedPermissionNote = false
    let profile: DeviceProfile

    var body: some View {
        switch model.status(of: profile) {
        case .failed(let message):
            Notice(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "The equalizer couldn’t start",
                message: "\(message). Check that Bassline is allowed to access system audio, then try again."
            ) {
                Button("Open Privacy Settings", action: openPrivacySettings)
                Button("Try Again") { model.retry() }
                    .keyboardShortcut(.defaultAction)
            }
        case .unsupported:
            Notice(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Update macOS to use Bassline",
                message: "System-wide EQ uses audio features added in macOS Sonoma 14.2."
            ) { EmptyView() }
        case .equalizing where !dismissedPermissionNote:
            Notice(
                symbol: "lock.shield",
                tint: .accentColor,
                title: "Allow Bassline to hear your Mac’s audio",
                message: "The first time it runs, macOS asks permission to access system audio. If music goes silent, allow Bassline under Privacy & Security › Screen & System Audio Recording. Turning the equalizer off restores sound instantly."
            ) {
                Button("Open Privacy Settings", action: openPrivacySettings)
                Button("Got It") { dismissedPermissionNote = true }
            }
        case .connected, .disconnected:
            Label(
                "These settings turn on automatically whenever your Mac plays through \(profile.displayName).",
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct Notice<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { actions() }
                    .controlSize(.regular)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.25))
        )
    }
}

// MARK: - Bands

private struct BandSliders: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScaleColumn()
            ForEach(EQBands.frequencies.indices, id: \.self) { band in
                VStack(spacing: 8) {
                    Text(Self.format(profile.gains[band]))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(profile.gains[band] == 0 ? Color.secondary : Color.primary)
                    VerticalGainSlider(
                        value: Binding(
                            get: { model.profile(id: profile.id)?.gains[band] ?? 0 },
                            set: { model.setGain($0, band: band, for: profile.id) }
                        ),
                        range: EQBands.range,
                        label: "\(EQBands.labels[band]) hertz"
                    )
                    .frame(height: 190)
                    Text(EQBands.labels[band])
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    static func format(_ gain: Double) -> String {
        gain == 0 ? "0" : String(format: "%+.1f", gain)
    }
}

/// dB labels aligned with the slider track.
private struct ScaleColumn: View {
    var body: some View {
        VStack(spacing: 8) {
            Text(" ").font(.caption)
            GeometryReader { geo in
                ForEach([12, 6, 0, -6, -12], id: \.self) { db in
                    Text(db > 0 ? "+\(db)" : "\(db)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .position(
                            x: geo.size.width / 2,
                            y: VerticalGainSlider.knobInset
                                + (1 - (Double(db) + 12) / 24) * (geo.size.height - 2 * VerticalGainSlider.knobInset)
                        )
                }
            }
            .frame(height: 190)
            Text(" ").font(.caption)
        }
        .frame(width: 30)
    }
}

// MARK: - Bass and output

private struct BassBoostBox: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Extra low end under 110 Hz, on top of the bands.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(profile.bassBoost == 0 ? "Off" : String(format: "+%.1f dB", profile.bassBoost))
                        .font(.body.monospacedDigit().weight(.medium))
                }
                Slider(
                    value: model.binding(profile.id, \.bassBoost, fallback: 0),
                    in: EQBands.bassBoostRange,
                    step: 0.5
                ) {
                    Text("Bass Boost")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .labelsHidden()
            }
            .padding(6)
        } label: {
            Label("Bass Boost", systemImage: "dial.high")
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OutputBox: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Prevent distortion", isOn: model.binding(profile.id, \.preventsClipping, fallback: true))
                if profile.preventsClipping {
                    Text(headroomText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Slider(value: model.binding(profile.id, \.preampDB, fallback: 0), in: -12...6, step: 0.5) {
                            Text("Preamp")
                        }
                        Text(String(format: "%+.1f dB", profile.preampDB))
                            .font(.body.monospacedDigit())
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
            .padding(6)
        } label: {
            Label("Output Level", systemImage: "speaker.wave.2")
        }
        .frame(maxWidth: .infinity)
    }

    private var headroomText: String {
        let drop = -profile.effectivePreampDB
        if drop < 0.1 { return "No level change needed for these settings." }
        return String(format: "Lowers the level by %.1f dB so boosted bass stays clean. Raise your volume to match.", drop)
    }
}
