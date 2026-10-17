import AppKit
import SwiftUI

struct PerformanceView: View {
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        let s = monitor.snapshot
        PageScroll {
            PageHeader(symbol: "gauge.with.dots.needle.50percent", title: "Performance", subtitle: subtitle) {
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            }

            // Headline gauges
            HStack(spacing: 16) {
                GaugeTile(title: "CPU", value: s.cpu, detail: Format.percent(s.cpu), history: monitor.cpuHistory, maximum: 1)
                GaugeTile(title: "GPU", value: s.gpu ?? 0, detail: s.gpu.map(Format.percent) ?? "—", history: monitor.gpuHistory, maximum: 1)
                GaugeTile(title: "Memory", value: s.memoryFraction, detail: Format.percent(s.memoryFraction), history: monitor.memoryHistory, maximum: 1)
                GaugeTile(
                    title: "Temperature",
                    value: min((s.cpuTemperature ?? 0) / 100, 1),
                    detail: Format.temperature(s.cpuTemperature),
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
                if let battery = s.battery { batteryCard(battery, s) } else { powerCard(s) }
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

    private var subtitle: String {
        let machine = monitor.machine
        var parts = [machine.chip]
        if let p = machine.performanceCores, let e = machine.efficiencyCores {
            parts.append("\(p) performance + \(e) efficiency cores")
        } else {
            parts.append("\(machine.logicalCores) cores")
        }
        parts.append(Format.bytes(machine.memory) + " memory")
        parts.append(machine.osVersion)
        return parts.joined(separator: " · ")
    }

    // MARK: Cards

    private func cpuCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Processor", symbol: "cpu") {
            HStack(spacing: 24) {
                StatValue(title: "User", value: Format.percent(s.cpuUser))
                StatValue(title: "System", value: Format.percent(s.cpuSystem))
                StatValue(title: "Idle", value: Format.percent(max(1 - s.cpu, 0)))
            }
            // One bar per core.
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
            Text("\(s.cores.count) cores")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func memoryCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Memory", symbol: "memorychip") {
            HStack(alignment: .firstTextBaseline) {
                StatValue(title: "Used", value: Format.bytes(s.memoryUsed), detail: "of \(Format.bytes(s.memoryTotal))")
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
                LegendValue(title: "Apps", value: Format.bytes(s.memoryApp))
                LegendValue(title: "Wired", value: Format.bytes(s.memoryWired))
                LegendValue(title: "Compressed", value: Format.bytes(s.memoryCompressed))
                LegendValue(title: "Swap", value: Format.bytes(s.swapUsed))
            }
        }
    }

    private func thermalCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Temperatures & Fans", symbol: "thermometer.medium") {
            HStack(spacing: 24) {
                StatValue(title: "CPU", value: Format.temperature(s.cpuTemperature))
                StatValue(title: "GPU", value: Format.temperature(s.gpuTemperature))
                if let battery = s.battery?.temperature {
                    StatValue(title: "Battery", value: Format.temperature(battery))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Thermal state").font(.caption).foregroundStyle(.secondary)
                    Text(thermalTitle(s.thermal))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(s.thermal == .nominal || s.thermal == .fair ? Color.primary : Color.orange)
                }
            }
            if s.fans.isEmpty {
                Text(s.hasFans ? "Fan speed isn’t available on this Mac." : "No fans. This Mac is cooled silently.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(s.fans) { fan in
                    HStack(spacing: 10) {
                        Image(systemName: "fan")
                            .foregroundStyle(.secondary)
                        Text(s.fans.count > 1 ? (fan.id == 0 ? "Left fan" : "Right fan") : "Fan")
                            .frame(width: 70, alignment: .leading)
                        MeterBar(value: fan.fraction)
                        Text("\(Int(fan.rpm.rounded())) rpm")
                            .font(.callout.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
            if s.cpuTemperature == nil {
                Text("Temperature sensors aren’t readable on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func batteryCard(_ battery: BatteryHealth, _ s: SystemSnapshot) -> some View {
        Card(title: "Battery & Power", symbol: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent") {
            HStack(spacing: 24) {
                StatValue(title: "Charge", value: "\(battery.percent)%", detail: chargeDetail(battery))
                if let health = battery.healthPercent {
                    StatValue(title: "Health", value: "\(health)%", detail: battery.cycleCount.map { "\($0) cycles" })
                }
                if let power = s.systemPower {
                    StatValue(title: "System power", value: String(format: "%.1f W", power))
                } else if let power = battery.power {
                    StatValue(title: power > 0 ? "Charging at" : "Using", value: String(format: "%.1f W", abs(power)))
                }
            }
            MeterBar(value: Double(battery.percent) / 100, warning: battery.percent <= 20 && !battery.onAC)
            if let adapter = battery.adapterWatts, battery.onAC {
                Text("Connected to a \(adapter) W adapter")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func powerCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Power", symbol: "bolt") {
            if let power = s.systemPower {
                StatValue(title: "System power", value: String(format: "%.1f W", power))
            } else {
                Text("Power readings aren’t available on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func networkCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Network", symbol: "network") {
            HStack(spacing: 24) {
                StatValue(title: "Download", value: Format.rate(s.networkDown))
                StatValue(title: "Upload", value: Format.rate(s.networkUp))
            }
        }
    }

    private func diskCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Storage", symbol: "internaldrive") {
            HStack(spacing: 24) {
                StatValue(title: "Read", value: Format.rate(s.diskRead))
                StatValue(title: "Write", value: Format.rate(s.diskWrite))
                if let free = s.diskFree {
                    StatValue(title: "Free", value: Format.diskBytes(free), detail: s.diskTotal.map { "of \(Format.diskBytes($0))" })
                }
            }
            if let free = s.diskFree, let total = s.diskTotal, total > 0 {
                MeterBar(value: 1 - Double(free) / Double(total), warning: Double(free) / Double(total) < 0.1)
            }
        }
    }

    private func topAppsCard(_ s: SystemSnapshot) -> some View {
        Card(title: "Busiest Apps", symbol: "list.number") {
            if s.topProcesses.isEmpty {
                Text("Measuring…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(s.topProcesses) { process in
                        HStack(spacing: 10) {
                            Group {
                                if let path = process.bundlePath {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
                                } else {
                                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 20, height: 20)
                            Text(process.name).lineLimit(1)
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
                Text("CPU is a share of one core, so busy apps can go past 100%.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Helpers

    private func chargeDetail(_ battery: BatteryHealth) -> String {
        if battery.isCharging {
            return battery.minutesRemaining.map { "Full in \(Format.minutes($0))" } ?? "Charging"
        }
        if battery.onAC { return "On power adapter" }
        return battery.minutesRemaining.map { "\(Format.minutes($0)) left" } ?? "On battery"
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

private struct GaugeTile: View {
    let title: String
    let value: Double
    let detail: String
    let history: [Double]
    let maximum: Double

    var body: some View {
        VStack(spacing: 12) {
            RingGauge(value: value, label: title, detail: detail)
            Sparkline(values: history, maximum: maximum)
                .frame(height: 28)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 22)
    }
}

private struct LegendValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}
