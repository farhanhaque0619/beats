import AppKit
import SwiftUI

struct PerformanceView: View {
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        let s = monitor.snapshot
        PageScroll {
            PageHeader(symbol: "gauge.with.dots.needle.50percent", title: "Performance", subtitle: subtitle(s)) {
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            }

            HStack(spacing: 16) {
                GaugeTile(title: "CPU", value: s.cpu, detail: Format.percent(s.cpu), caption: "of all cores busy", history: monitor.cpuHistory, maximum: 1)
                GaugeTile(title: "GPU", value: s.gpu ?? 0, detail: s.gpu.map(Format.percent) ?? "—", caption: "graphics busy", history: monitor.gpuHistory, maximum: 1)
                GaugeTile(title: "Memory", value: s.memoryFraction, detail: Format.percent(s.memoryFraction), caption: "of RAM in use", history: monitor.memoryHistory, maximum: 1)
                GaugeTile(
                    title: "CPU Temp",
                    value: min((s.cpuTemperature ?? 0) / 100, 1),
                    detail: Format.temperature(s.cpuTemperature),
                    caption: temperatureCaption(s.cpuTemperature),
                    history: monitor.temperatureHistory,
                    maximum: 100
                )
            }

            HStack(alignment: .top, spacing: 16) {
                cpuCard(s)
                memoryCard(s)
            }

            HStack(alignment: .top, spacing: 16) {
                thermalCard(s)
                powerCard(s)
            }

            HStack(alignment: .top, spacing: 16) {
                networkCard(s)
                diskCard(s)
            }

            topAppsCard(s)
        }
        .navigationTitle("Performance")
        .onAppear { monitor.start("performance", detailed: true) }
        .onDisappear { monitor.stop("performance") }
    }

    private func subtitle(_ s: SystemSnapshot) -> String {
        let machine = monitor.machine
        var parts = [machine.chip]
        if let p = machine.performanceCores, let e = machine.efficiencyCores {
            parts.append("\(p) performance + \(e) efficiency cores")
        } else {
            parts.append("\(machine.logicalCores) cores")
        }
        parts.append(Format.bytes(machine.memory) + " memory")
        parts.append(machine.osVersion)
        parts.append("on for \(Format.uptime(s.uptime))")
        return parts.joined(separator: " · ")
    }

    // MARK: Cards

    private func cpuCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Processor", symbol: "cpu") {
            HStack(spacing: 24) {
                StatValue(title: "Apps", value: Format.percent(s.cpuUser))
                StatValue(title: "macOS", value: Format.percent(s.cpuSystem))
                StatValue(title: "Free", value: Format.percent(max(1 - s.cpu, 0)))
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(s.cores.enumerated()), id: \.offset) { _, load in
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.07))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.accent)
                                .frame(height: max(geo.size.height * CGFloat(load), load > 0.01 ? 2 : 0))
                        }
                    }
                }
            }
            .frame(height: 54)
            .animation(.smooth(duration: 0.5), value: s.cores)
            Explainer("Each bar is one of the \(s.cores.count) cores. “Apps” is time spent on your apps, “macOS” on the system itself.")
        }
    }

    private func memoryCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Memory", symbol: "memorychip") {
            HStack(alignment: .firstTextBaseline) {
                StatValue(title: "In use", value: Format.bytes(s.memoryUsed), detail: "of \(Format.bytes(s.memoryTotal))")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Pressure").font(.caption).foregroundStyle(.secondary)
                    Text(s.pressure.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(s.pressure == .normal ? Color.primary : Color.orange)
                }
            }
            MeterBar(value: s.memoryFraction, warning: s.pressure != .normal)
            HStack(spacing: 18) {
                LegendValue(title: "Apps", value: Format.bytes(s.memoryApp), help: "Memory your apps are using.")
                LegendValue(title: "Wired", value: Format.bytes(s.memoryWired), help: "Memory macOS keeps for itself and can’t move.")
                LegendValue(title: "Compressed", value: Format.bytes(s.memoryCompressed), help: "Memory macOS squeezed to make room, instead of using the SSD.")
                LegendValue(title: "Swap", value: Format.bytes(s.swapUsed), help: "Memory moved to the SSD because RAM was full.")
            }
            Explainer(pressureExplanation(s))
        }
    }

    private func thermalCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Temperatures & Fans", symbol: "thermometer.medium") {
            HStack(alignment: .top, spacing: 24) {
                StatValue(title: "CPU", value: Format.temperature(s.cpuTemperature), detail: s.hottestCoreTemperature.map { "hottest core \(Format.temperature($0))" })
                if let performance = s.performanceCoreTemperature, let efficiency = s.efficiencyCoreTemperature {
                    StatValue(title: "P / E cores", value: "\(Format.temperature(performance)) / \(Format.temperature(efficiency))", detail: "performance / efficiency")
                }
                StatValue(title: "GPU", value: Format.temperature(s.gpuTemperature))
                if let battery = s.battery?.temperature {
                    StatValue(title: "Battery", value: Format.temperature(battery))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Thermal state").font(.caption).foregroundStyle(.secondary)
                    Text(thermalTitle(s.thermal))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(s.thermal == .nominal || s.thermal == .fair ? Color.primary : Color.orange)
                }
            }

            if s.fans.isEmpty {
                Explainer(s.hasFans ? "Fan speed isn’t readable on this Mac." : "This Mac has no fans and is cooled silently.")
            } else {
                VStack(spacing: 8) {
                    ForEach(s.fans) { fan in
                        HStack(spacing: 10) {
                            Image(systemName: "fan").foregroundStyle(.secondary)
                            Text(s.fans.count > 1 ? "Fan \(fan.id + 1)" : "Fan")
                                .frame(width: 50, alignment: .leading)
                            MeterBar(value: fan.fraction)
                            Text(fan.rpm < 100 ? "Off" : "\(Int(fan.rpm.rounded())) rpm")
                                .font(.callout.monospacedDigit())
                                .frame(width: 80, alignment: .trailing)
                        }
                    }
                }
                Explainer(fanExplanation(s.fans))
            }
            if s.cpuTemperature == nil {
                Explainer("Temperature sensors aren’t readable on this Mac.")
            } else {
                Explainer("Apple silicon normally runs between 35° and 95°. macOS slows the chip down by itself if it ever gets too hot.")
            }
        }
    }

    private func powerCard(_ s: SystemSnapshot) -> some View {
        Card(title: s.battery == nil ? "Power" : "Battery & Power", symbol: s.battery?.isCharging == true ? "battery.100percent.bolt" : "bolt") {
            if let battery = s.battery {
                HStack(alignment: .top, spacing: 24) {
                    StatValue(title: "Charge", value: "\(battery.percent)%", detail: chargeDetail(battery))
                    if let health = battery.healthPercent {
                        StatValue(title: "Health", value: "\(health)%", detail: battery.cycleCount.map { "\($0) charge cycles" })
                    }
                }
                MeterBar(value: Double(battery.percent) / 100, warning: battery.percent <= 20 && !battery.onAC)
            }

            HStack(alignment: .top, spacing: 24) {
                if let power = s.systemPower {
                    StatValue(title: "Mac is using", value: Format.watts(power), detail: "chip, screen and everything")
                }
                if let battery = s.battery, let flow = battery.power {
                    StatValue(
                        title: flow > 0 ? "Into battery" : "From battery",
                        value: Format.watts(abs(flow)),
                        detail: flow > 0 ? "charging" : "running on battery"
                    )
                }
                if let adapter = s.battery?.adapterWatts, s.battery?.onAC == true {
                    StatValue(title: "Charger", value: "\(adapter) W", detail: "its maximum")
                }
            }

            Explainer(powerExplanation(s))
        }
    }

    private func networkCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Network", symbol: "network") {
            HStack(spacing: 24) {
                StatValue(title: "Downloading", value: Format.rate(s.networkDown))
                StatValue(title: "Uploading", value: Format.rate(s.networkUp))
            }
            Explainer("Live speed over Wi-Fi and Ethernet right now, not your connection’s top speed.")
        }
    }

    private func diskCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Storage", symbol: "internaldrive") {
            HStack(spacing: 24) {
                StatValue(title: "Reading", value: Format.rate(s.diskRead))
                StatValue(title: "Writing", value: Format.rate(s.diskWrite))
                if let free = s.diskFree {
                    StatValue(title: "Free space", value: Format.diskBytes(free), detail: s.diskTotal.map { "of \(Format.diskBytes($0))" })
                }
            }
            if let free = s.diskFree, let total = s.diskTotal, total > 0 {
                MeterBar(value: 1 - Double(free) / Double(total), warning: Double(free) / Double(total) < 0.1)
            }
            Explainer("Free space includes room macOS can clear on its own, like caches and old backups.")
        }
    }

    private func topAppsCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Busiest Right Now", symbol: "list.number") {
            if s.topProcesses.isEmpty {
                Text("Measuring…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    HStack {
                        Text("App or process")
                        Spacer()
                        Text("Memory").frame(width: 90, alignment: .trailing)
                        Text("CPU").frame(width: 56, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                    ForEach(s.topProcesses) { process in
                        HStack(spacing: 10) {
                            Group {
                                if let path = process.bundlePath {
                                    Image(nsImage: IconCache.icon(forFile: path)).resizable()
                                } else {
                                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(process.name).lineLimit(1)
                                if let about = ProcessGlossary.describe(process.name) {
                                    Text(about).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(Format.bytes(process.memory))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            Text(String(format: "%.0f%%", process.cpu * 100))
                                .font(.callout.monospacedDigit().weight(.medium))
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                }
                Explainer("CPU here is a share of one core: 100% means one core is fully busy, so busy apps can go past 100%. This page measures your whole Mac every two seconds, which uses a little CPU itself while it’s open.")
            }
        }
    }

    // MARK: Explanations

    private func temperatureCaption(_ celsius: Double?) -> String {
        guard let celsius else { return "not available" }
        switch celsius {
        case ..<50: return "cool"
        case ..<80: return "normal"
        case ..<95: return "warm"
        default: return "hot"
        }
    }

    private func pressureExplanation(_ s: SystemSnapshot) -> String {
        switch s.pressure {
        case .normal: "Pressure is how hard macOS works to find free memory. Normal means there’s plenty, even when “in use” looks high."
        case .warning: "macOS is compressing and swapping memory to keep up. Quitting a big app will help."
        case .critical: "Memory is very tight and apps may slow down. Quit apps you aren’t using."
        }
    }

    private func fanExplanation(_ fans: [FanReading]) -> String {
        if fans.allSatisfy({ $0.rpm < 100 }) {
            return "The fans are off. Your Mac is cool enough without them."
        }
        let quiet = fans.allSatisfy { $0.minimum > 0 && $0.rpm <= $0.minimum * 1.08 }
        if quiet, let fan = fans.first {
            return "Running at their slowest speed (about \(Int(fan.minimum.rounded())) rpm), which is designed to be silent. They go up to about \(Int(fan.maximum.rounded())) rpm under heavy load."
        }
        let fastest = fans.map(\.fraction).max() ?? 0
        return "Running at \(Format.percent(fastest)) of their range to cool the chip."
    }

    private func powerExplanation(_ s: SystemSnapshot) -> String {
        var text = "“Mac is using” is the power the whole computer draws right now."
        if let battery = s.battery {
            if battery.onAC {
                text += " On the charger, that comes from the adapter, and whatever’s left over charges the battery."
            } else {
                text += " On battery, it all comes from the battery."
            }
            if battery.healthPercent != nil {
                text += " Health compares today’s full charge with when the battery was new."
            }
        }
        return text
    }

    private func chargeDetail(_ battery: BatteryHealth) -> String {
        if battery.isCharging {
            return battery.minutesRemaining.map { "full in \(Format.minutes($0))" } ?? "charging"
        }
        if battery.onAC { return "plugged in, not charging" }
        return battery.minutesRemaining.map { "\(Format.minutes($0)) left" } ?? "on battery"
    }

    private func thermalTitle(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very hot"
        @unknown default: "Unknown"
        }
    }
}

/// Plain-English names for common macOS background processes.
enum ProcessGlossary {
    private static let descriptions: [String: String] = [
        "photoanalysisd": "Photos library analysis, runs while idle",
        "mediaanalysisd": "Photos and video analysis",
        "mds": "Spotlight search indexing",
        "mds_stores": "Spotlight search indexing",
        "mdworker_shared": "Spotlight search indexing",
        "mdworker": "Spotlight search indexing",
        "suggestd": "Siri Suggestions",
        "contactsd": "Contacts sync",
        "WindowServer": "Draws everything on screen",
        "kernel_task": "macOS itself, also used to manage heat",
        "bird": "iCloud Drive sync",
        "cloudd": "iCloud sync",
        "backupd": "Time Machine backup",
        "avconferenced": "FaceTime and call audio",
        "screencapture": "Screenshots and screen recording",
        "coreaudiod": "The sound system",
        "softwareupdated": "Software Update",
        "syspolicyd": "Security checks for apps",
        "trustd": "Security certificate checks",
        "fileproviderd": "Cloud file sync",
        "spotlightknowledged": "Spotlight suggestions",
        "launchd": "Starts and stops system services",
        "XProtect": "Malware scanning",
    ]

    static func describe(_ name: String) -> String? { descriptions[name] }
}

private struct GaugeTile: View {
    let title: String
    let value: Double
    let detail: String
    let caption: String
    let history: [Double]
    let maximum: Double

    var body: some View {
        VStack(spacing: 10) {
            RingGauge(value: value, label: title, detail: detail)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Sparkline(values: history, maximum: maximum)
                .frame(height: 26)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 22)
    }
}

private struct LegendValue: View {
    let title: String
    let value: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
        .help(help)
    }
}
