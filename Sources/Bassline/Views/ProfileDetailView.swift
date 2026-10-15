import AppKit
import SwiftUI

struct ProfileDetailView: View {
    @EnvironmentObject private var model: AppModel
    let profileID: String

    var body: some View {
        if let profile = model.profile(id: profileID) {
            ScrollView {
                GlassGroup(spacing: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        DeviceHeader(profile: profile)
                        StatusNotice(profile: profile)
                        PresetStrip(profile: profile)

                        ResponseCard(profile: profile)

                        VStack(alignment: .leading, spacing: 14) {
                            CardTitle("Bands", systemImage: "slider.vertical.3")
                            BandSliders(profile: profile)
                        }
                        .glassCard()

                        HStack(alignment: .top, spacing: 16) {
                            BassBoostCard(profile: profile)
                            OutputCard(profile: profile)
                        }

                        Label(profile.kind.tip, systemImage: "lightbulb")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                    .opacity(profile.isEnabled ? 1 : 0.55)
                    .saturation(profile.isEnabled ? 1 : 0.3)
                    .animation(.smooth(duration: 0.35), value: profile.isEnabled)
                }
                .padding(24)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(profile.displayName)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.smooth(duration: 0.5)) { model.reset(profileID) }
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .help("Restore this device’s recommended settings")
                }
            }
            .tint(profile.tint)
        }
    }
}

private struct CardTitle: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Header

private struct DeviceHeader: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile

    var body: some View {
        let status = model.status(of: profile)
        HStack(alignment: .center, spacing: 18) {
            DeviceBadge(symbol: profile.symbolName, tint: profile.tint, size: 72, dimmed: status == .disconnected)
                .shadow(color: profile.tint.opacity(0.4), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text(profile.displayName)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 8) {
                    StatusPill(status: status)
                    if model.isConnected(profile) && !model.isCurrentOutput(profile) {
                        Button {
                            model.playThrough(profile)
                        } label: {
                            Label("Play Through This", systemImage: "speaker.wave.2.fill")
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .glassSurface(cornerRadius: 100, tint: profile.tint, interactive: true)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }

            Spacer(minLength: 12)

            if model.isPlaying(profile) && model.engine.isRunning {
                LevelMeter(processor: model.engine.processor, route: model.route(for: profile) ?? 0, tint: profile.tint, isActive: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .help("Output level")
            }

            VStack(alignment: .trailing, spacing: 5) {
                Toggle("Equalizer", isOn: model.binding(profile.id, \.isEnabled, fallback: false, animation: .smooth(duration: 0.35)))
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .labelsHidden()
                Text(profile.isEnabled ? "EQ On" : "EQ Off")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
        }
        .padding(20)
        .glassSurface(cornerRadius: 26, tint: profile.tint)
        .animation(.smooth(duration: 0.35), value: status)
    }
}

// MARK: - Presets

private struct PresetStrip: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile
    @State private var isSaving = false
    @State private var newName = ""
    @State private var nameTaken = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(model.presets(for: profile)) { preset in
                        PresetChip(title: preset.name, isSelected: preset.name == profile.presetName, tint: profile.tint) {
                            withAnimation(.smooth(duration: 0.5)) { model.apply(preset, to: profile.id) }
                        }
                        .contextMenu {
                            if preset.isCustom {
                                Button("Delete “\(preset.name)”", role: .destructive) {
                                    withAnimation(.smooth) { model.deleteUserPreset(preset) }
                                }
                            }
                        }
                    }
                    if profile.presetName == "Custom" {
                        PresetChip(title: "Custom", isSelected: true, tint: profile.tint) {}
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    Button {
                        newName = ""
                        nameTaken = false
                        isSaving = true
                    } label: {
                        Label("Save Preset", systemImage: "plus")
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassSurface(cornerRadius: 100, interactive: true)
                    .help("Save these settings as a preset you can use on any device")
                    .popover(isPresented: $isSaving, arrowEdge: .bottom) { savePopover }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
        }
        .animation(.smooth(duration: 0.3), value: profile.presetName == "Custom")
        .animation(.smooth(duration: 0.3), value: model.userPresets)
    }

    private var savePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save Preset").font(.headline)
            TextField("Name, like “Gym” or “Late Night”", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(save)
            if nameTaken {
                Text("Choose a name that isn’t already used.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Saves the bands and Bass Boost. Saved presets appear for every device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { isSaving = false }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func save() {
        if model.saveUserPreset(named: newName, from: profile.id) {
            isSaving = false
        } else {
            nameTaken = true
        }
    }
}

// MARK: - Response

private struct ResponseCard: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.showSpectrum) private var showSpectrum = true
    let profile: DeviceProfile

    var body: some View {
        let processing = model.isPlaying(profile) && model.engine.isRunning
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardTitle("Frequency Response", systemImage: "waveform.path.ecg")
                Spacer()
                if processing && profile.isEnabled && !profile.isFlat {
                    CompareButton(tint: profile.tint)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            ResponseCurveView(
                profile: profile,
                processor: showSpectrum && processing ? model.engine.processor : nil,
                sampleRate: model.engine.sampleRate,
                spectrumActive: processing,
                onBandChange: { band, gain in model.setGain(gain, band: band, for: profile.id) }
            )
            .frame(height: 230)
            Text("Drag the points on the curve, or use the faders below.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .glassCard()
        .animation(.smooth(duration: 0.3), value: processing)
    }
}

/// Press and hold to hear the original sound; let go to hear the EQ again.
private struct CompareButton: View {
    @EnvironmentObject private var model: AppModel
    let tint: Color

    var body: some View {
        let holding = model.isBypassed
        Label(holding ? "Original Sound" : "Hold to Compare", systemImage: holding ? "ear.fill" : "ear")
            .font(.callout.weight(.medium))
            .foregroundStyle(holding ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if holding { Capsule().fill(tint.gradient) }
            }
            .glassSurface(cornerRadius: 100, interactive: true)
            .scaleEffect(holding ? 0.96 : 1)
            .animation(.snappy(duration: 0.2), value: holding)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.setBypass(true) }
                    .onEnded { _ in model.setBypass(false) }
            )
            .onDisappear { model.setBypass(false) }
            .help("Hold to hear your music without the EQ")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Notices

private struct StatusNotice: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.dismissedPermissionNote) private var dismissedPermissionNote = false
    let profile: DeviceProfile

    var body: some View {
        Group {
            switch model.status(of: profile) {
            case .failed(let message):
                Notice(
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: "The equalizer couldn’t start",
                    message: "\(message). Check that Bassline is allowed to access system audio, then try again."
                ) {
                    Button("Open Privacy Settings", action: PrivacySettings.open)
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
                    tint: profile.tint,
                    title: "Allow Bassline to hear your Mac’s audio",
                    message: "If music goes silent, allow Bassline under Privacy & Security › Screen & System Audio Recording. Turning the equalizer off restores sound instantly."
                ) {
                    Button("Open Privacy Settings", action: PrivacySettings.open)
                    Button("Got It") { withAnimation(.smooth) { dismissedPermissionNote = true } }
                }
            case .connected, .disconnected:
                Label(
                    "These settings switch on by themselves whenever your Mac plays through \(profile.displayName).",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            default:
                EmptyView()
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

enum PrivacySettings {
    static func open() {
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
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassSurface(cornerRadius: 20, tint: tint)
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
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(abs(profile.gains[band]) < 0.05 ? Color.secondary : Color.primary)
                        .contentTransition(.numericText(value: profile.gains[band]))
                    VerticalGainSlider(
                        value: Binding(
                            get: { model.profile(id: profile.id)?.gains[band] ?? 0 },
                            set: { model.setGain($0, band: band, for: profile.id) }
                        ),
                        range: EQBands.range,
                        tint: profile.tint,
                        label: "\(EQBands.labels[band]) hertz"
                    )
                    .frame(height: 200)
                    Text(EQBands.labels[band])
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    static func format(_ gain: Double) -> String {
        abs(gain) < 0.05 ? "0" : String(format: "%+.1f", gain)
    }
}

/// dB labels aligned with the fader track.
private struct ScaleColumn: View {
    var body: some View {
        VStack(spacing: 8) {
            Text(" ").font(.caption)
            GeometryReader { geo in
                let inset = VerticalGainSlider.knobSize / 2
                ForEach([12, 6, 0, -6, -12], id: \.self) { db in
                    Text(db > 0 ? "+\(db)" : "\(db)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .position(
                            x: geo.size.width / 2,
                            y: inset + (1 - (Double(db) + 12) / 24) * (geo.size.height - 2 * inset)
                        )
                }
            }
            .frame(height: 200)
            Text(" ").font(.caption)
        }
        .frame(width: 30)
    }
}

// MARK: - Bass and output

private struct BassBoostCard: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                CardTitle("Bass Boost", systemImage: "dial.high")
                Spacer()
                Text(profile.bassBoost < 0.05 ? "Off" : String(format: "+%.1f dB", profile.bassBoost))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(profile.bassBoost < 0.05 ? Color.secondary : profile.tint)
                    .contentTransition(.numericText(value: profile.bassBoost))
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
            Text("Extra low end under 110 Hz, on top of the bands.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .glassCard()
    }
}

private struct OutputCard: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile

    var body: some View {
        let drop = -profile.effectivePreampDB
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                CardTitle("Output Level", systemImage: "speaker.wave.2")
                Spacer()
                Toggle("Prevent distortion", isOn: model.binding(profile.id, \.preventsClipping, fallback: true, animation: .smooth(duration: 0.3)))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help("Prevent distortion")
            }
            if profile.preventsClipping {
                Text(drop < 0.1
                     ? "Prevent distortion is on. No level change is needed for these settings."
                     : String(format: "Prevent distortion lowers the level by %.1f dB so boosted bass stays clean. Raise your volume to match.", drop))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else {
                HStack {
                    Slider(value: model.binding(profile.id, \.preampDB, fallback: 0), in: -12...6, step: 0.5) {
                        Text("Preamp")
                    }
                    .labelsHidden()
                    Text(String(format: "%+.1f dB", profile.preampDB))
                        .font(.body.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                        .contentTransition(.numericText(value: profile.preampDB))
                }
                .transition(.opacity)
                Text("Manual preamp. Boosts above 0 dB can distort.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .glassCard()
    }
}
