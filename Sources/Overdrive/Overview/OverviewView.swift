import SwiftUI

/// The landing page: the state of the Mac at a glance, with the most-used switches.
struct OverviewView: View {
    @EnvironmentObject private var sound: SoundModel
    @EnvironmentObject private var displays: DisplayManager
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var tools: ToolsManager
    @EnvironmentObject private var battery: BatteryMonitor

    var body: some View {
        PageScroll {
            PageHeader(symbol: "square.grid.2x2", title: greeting, subtitle: "\(monitor.machine.chip) · \(monitor.machine.osVersion)")

            HealthStrip()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                soundTile
                systemTile
                displayTile
                toolsTile
            }
        }
        .navigationTitle("Overview")
        .onAppear { monitor.start("overview") }
        .onDisappear { monitor.stop("overview") }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    // MARK: Tiles

    private var soundTile: some View {
        Tile(title: "Sound", symbol: "speaker.wave.2", open: { sound.selectedProfileID = sound.activeProfile?.id ?? SoundModel.groupSelectionID }) {
            if let profile = sound.activeProfile {
                HStack(spacing: 12) {
                    DeviceBadge(symbol: profile.symbolName, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sound.isGroupActive ? "\(sound.activeGroup.count) devices" : (sound.currentOutput?.name ?? profile.displayName))
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(sound.status(of: profile).title)
                            if let info = battery.battery(for: sound.currentOutput?.name) {
                                BatteryLabel(info: info)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Equalizer", isOn: sound.binding(profile.id, \.isEnabled, fallback: false, animation: .smooth))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                ResponseCurveView(profile: profile, compact: true)
                    .frame(height: 56)
                Text("Preset: \(profile.presetName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No sound output found.").foregroundStyle(.secondary)
            }
        }
    }

    private var systemTile: some View {
        let s = monitor.snapshot
        return Tile(title: "System", symbol: "gauge.with.dots.needle.50percent", open: { sound.selectedProfileID = Page.performance }) {
            HStack(spacing: 14) {
                ringButton(.cpu, RingGauge(value: s.cpu, label: "CPU", detail: Format.percent(s.cpu), size: 76))
                ringButton(.memory, RingGauge(value: s.memoryFraction, label: "Memory", detail: Format.percent(s.memoryFraction), size: 76))
                ringButton(.gpu, RingGauge(value: s.gpu ?? 0, label: "GPU", detail: s.gpu.map(Format.percent) ?? "—", size: 76))
                ringButton(.temperature, RingGauge(value: min((s.cpuTemperature ?? 0) / 100, 1), label: "Temp", detail: Format.temperature(s.cpuTemperature), size: 76))
            }
            .frame(maxWidth: .infinity)
            HStack {
                if let fan = s.fans.first {
                    Label("\(Int(fan.rpm.rounded())) rpm", systemImage: "fan")
                } else if !s.hasFans {
                    Label("Fanless", systemImage: "fan.slash")
                }
                Spacer()
                if let level = s.battery {
                    Label("\(level.percent)%", systemImage: level.isCharging ? "battery.100percent.bolt" : BatteryLabel.symbol(level.percent))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func ringButton(_ metric: Metric, _ gauge: RingGauge) -> some View {
        Button {
            sound.selectedProfileID = Page.performance
            monitor.focusedMetric = metric
        } label: {
            gauge
        }
        .buttonStyle(.plain)
        .help("Open \(metric.title)")
    }

    private var displayTile: some View {
        Tile(title: "Display", symbol: "sun.max", open: { sound.selectedProfileID = Page.display }) {
            if displays.canBoost {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Extra Brightness").font(.headline)
                        Text(displays.boostEnabled ? (displays.boostPausedReason ?? "On, +\(Int(((displays.boostFactor - 1) * 100).rounded()))%") : "Off")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Extra Brightness", isOn: Binding(
                        get: { displays.boostEnabled },
                        set: { newValue in withAnimation(.smooth) { displays.setBoostEnabled(newValue) } }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                Slider(value: Binding(get: { displays.boostLevel }, set: { displays.setBoostLevel($0) }), in: 0...1) {
                    Text("Boost")
                } minimumValueLabel: {
                    Image(systemName: "sun.min")
                } maximumValueLabel: {
                    Image(systemName: "sun.max.fill")
                }
                .disabled(!displays.boostEnabled)
            } else if let main = displays.displays.first {
                Text(main.name).font(.headline)
                if let brightness = displays.brightness[main.id] {
                    Slider(value: Binding(get: { displays.brightness[main.id] ?? brightness }, set: { displays.setBrightness($0, for: main) }), in: 0...1) {
                        Text("Brightness")
                    } minimumValueLabel: {
                        Image(systemName: "sun.min")
                    } maximumValueLabel: {
                        Image(systemName: "sun.max.fill")
                    }
                }
                Text("Extra Brightness needs an XDR or HDR display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var toolsTile: some View {
        Tile(title: "Tools", symbol: "wrench.and.screwdriver", open: { sound.selectedProfileID = Page.tools }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Awake").font(.headline)
                    Text(tools.isKeepingAwake ? "On" : "Off").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Keep Awake", isOn: Binding(
                    get: { tools.isKeepingAwake },
                    set: { on in withAnimation(.smooth) { on ? tools.keepAwake(minutes: nil) : tools.stopKeepingAwake() } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            if tools.hasMicrophone {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone").font(.headline)
                        Text(tools.isMicMuted ? "Muted" : "On").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Mute Microphone", isOn: Binding(
                        get: { tools.isMicMuted },
                        set: { muted in withAnimation(.smooth) { tools.setMicMuted(muted) } }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Mute the microphone")
                }
            }
        }
    }
}

/// A dashboard tile: title, a jump to its page, and its content.
private struct Tile<Content: View>: View {
    let title: String
    let symbol: String
    let open: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: open) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(title)")
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .glassSurface(cornerRadius: 22)
    }
}

/// One line that says whether anything needs attention, with a chip per vital sign.
/// Clicking a chip opens its detail page.
private struct HealthStrip: View {
    @EnvironmentObject private var sound: SoundModel
    @EnvironmentObject private var monitor: SystemMonitor

    private let metrics: [Metric] = [.cpu, .memory, .temperature, .power, .storage]

    var body: some View {
        let attention = metrics.filter { monitor.reading($0).health != .good }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: attention.isEmpty ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(attention.isEmpty ? Color.green : Color.orange)
                Text(attention.isEmpty ? "Everything looks good" : "\(attention.count) thing\(attention.count == 1 ? "" : "s") worth a look")
                    .font(.headline)
            }
            FlowLayout(spacing: 8) {
                ForEach(metrics) { metric in
                    let reading = monitor.reading(metric)
                    Button {
                        sound.selectedProfileID = Page.performance
                        monitor.focusedMetric = metric
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(reading.health.color).frame(width: 7, height: 7)
                            Text(reading.chip)
                                .font(.callout)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassSurface(cornerRadius: 100, interactive: true)
                    .help("Open \(metric.title)")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22)
    }
}
