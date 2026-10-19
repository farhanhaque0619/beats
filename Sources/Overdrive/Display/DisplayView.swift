import SwiftUI

struct DisplayView: View {
    @EnvironmentObject private var displays: DisplayManager

    var body: some View {
        PageScroll {
            PageHeader(
                symbol: "sun.max",
                title: "Displays",
                subtitle: "Brightness, dimming and resolution for every screen."
            ) {
                InfoButton("Extra Brightness and dimming change the display’s colour table. macOS puts it back the moment Overdrive quits, even if it quits unexpectedly. The panel’s own firmware still limits power and heat.")
            }

            if displays.canBoost {
                BoostCard()
            }

            ForEach(displays.displays) { display in
                DisplayCard(display: display)
            }

        }
        .navigationTitle("Displays")
        .onAppear { displays.refreshBrightness() }
    }
}

private struct BoostCard: View {
    @EnvironmentObject private var displays: DisplayManager

    var body: some View {
        Card(title: "Extra Brightness", symbol: "sun.max.trianglebadge.exclamationmark",
             info: "Uses your XDR display’s HDR headroom, the same way HDR video gets brighter than the rest of the screen. Turn the regular brightness all the way up first for the full effect. It pauses by itself when the Mac is hot or the battery is low, and uses more battery while it’s on.", trailing: {
            Toggle("Extra Brightness", isOn: Binding(
                get: { displays.boostEnabled },
                set: { newValue in withAnimation(.smooth) { displays.setBoostEnabled(newValue) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Go brighter than the normal maximum.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { displays.boostLevel },
                        set: { displays.setBoostLevel($0) }
                    ), in: 0...1)
                    Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                    Text("+\(Int(((displays.boostFactor - 1) * 100).rounded()))%")
                        .font(.body.monospacedDigit().weight(.medium))
                        .frame(width: 52, alignment: .trailing)
                        .contentTransition(.numericText(value: displays.boostFactor))
                }
                .disabled(!displays.boostEnabled)

                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(statusColor)
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .animation(.smooth, value: statusText)
            }
        }
    }

    private var statusText: String {
        if !displays.boostEnabled { return "Off" }
        if let reason = displays.boostPausedReason { return reason }
        return "On"
    }

    private var statusColor: Color {
        if !displays.boostEnabled { return .secondary }
        return displays.boostPausedReason == nil ? .green : .orange
    }
}

private struct DisplayCard: View {
    @EnvironmentObject private var displays: DisplayManager
    let display: DisplayInfo

    @State private var showAllModes = false
    @State private var modes: [DisplayModeOption] = []
    @State private var currentMode: Int32?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                DeviceBadge(symbol: display.symbolName, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(display.name).font(.headline)
                        if display.isXDR { Tag(text: "XDR") } else if display.supportsBoost { Tag(text: "HDR") }
                    }
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let brightness = displays.brightness[display.id] {
                ControlRow(title: "Brightness", symbol: "sun.max") {
                    Slider(value: Binding(
                        get: { displays.brightness[display.id] ?? brightness },
                        set: { displays.setBrightness($0, for: display) }
                    ), in: 0...1)
                    Text(Format.percent(displays.brightness[display.id] ?? brightness))
                        .font(.callout.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
            }

            ControlRow(title: "Dim", symbol: "moon", help: "Dims below the lowest brightness setting, handy at night. 100% is normal.") {
                Slider(value: Binding(
                    get: { displays.dimLevel(for: display) },
                    set: { displays.setDimLevel($0, for: display) }
                ), in: 0.25...1)
                Text(Format.percent(displays.dimLevel(for: display)))
                    .font(.callout.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }

            if !modes.isEmpty {
                ControlRow(title: "Resolution", symbol: "rectangle.dashed") {
                    Picker("Resolution", selection: Binding(
                        get: { currentMode ?? modes.first?.id ?? 0 },
                        set: { id in
                            guard let option = modes.first(where: { $0.id == id }) else { return }
                            if displays.setMode(option, for: display) { currentMode = id }
                        }
                    )) {
                        let markLowResolution = modes.contains(where: \.isHiDPI)
                        ForEach(modes) { mode in
                            Text(mode.title(markLowResolution: markLowResolution)).tag(mode.id)
                        }
                    }
                    .labelsHidden()
                    Toggle("Show All", isOn: $showAllModes)
                        .toggleStyle(.checkbox)
                        .help("Include low-resolution modes")
                }
            }
        }
        .glassCard()
        .onAppear(perform: loadModes)
        .onChange(of: showAllModes) { _, _ in loadModes() }
        .onChange(of: display) { _, _ in loadModes() }
    }

    private var summary: String {
        var parts: [String] = []
        if display.pixelSize.width > 0 {
            parts.append("\(Int(display.pixelSize.width)) × \(Int(display.pixelSize.height)) pixels")
        }
        parts.append("looks like \(Int(display.pointSize.width)) × \(Int(display.pointSize.height))")
        if display.refreshRate > 0 { parts.append("\(Int(display.refreshRate.rounded())) Hz") }
        return parts.joined(separator: " · ")
    }

    private func loadModes() {
        var options = displays.modes(for: display, includeLowResolution: showAllModes)
        currentMode = displays.currentModeID(for: display)
        // Keep the current mode in the list even if it's filtered out.
        if let currentMode, !options.contains(where: { $0.id == currentMode }) {
            options = displays.modes(for: display, includeLowResolution: true).filter { $0.id == currentMode } + options
        }
        modes = options
    }
}

private struct ControlRow<Content: View>: View {
    let title: String
    let symbol: String
    var help: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: symbol)
                .frame(width: 100, alignment: .leading)
                .foregroundStyle(.secondary)
                .help(help ?? title)
            content
        }
    }
}

struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(.secondary)
    }
}
