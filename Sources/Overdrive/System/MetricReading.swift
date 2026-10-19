import SwiftUI

/// Whether a reading needs attention.
enum Health {
    case good, notice, warning

    var color: Color {
        switch self {
        case .good: .green
        case .notice: .yellow
        case .warning: .orange
        }
    }
}

/// One metric in a single glance: its headline number and a plain-English status.
struct MetricReading {
    let value: String
    let status: String
    let health: Health
    var history: [Double]? = nil
    var maximum: Double = 1
    /// A short phrase for the Overview's health strip, like "Memory: plenty free".
    var chip: String
}

extension SystemMonitor {
    func reading(_ metric: Metric) -> MetricReading {
        let s = snapshot
        switch metric {
        case .cpu:
            let (status, health): (String, Health) = s.cpu < 0.5 ? ("Light", .good) : s.cpu < 0.8 ? ("Busy", .notice) : ("Very busy", .warning)
            return MetricReading(value: Format.percent(s.cpu), status: status, health: health, history: cpuHistory, chip: "CPU \(status.lowercased())")

        case .gpu:
            guard let gpu = s.gpu else {
                return MetricReading(value: "—", status: "Not available", health: .good, chip: "Graphics")
            }
            let (status, health): (String, Health) = gpu < 0.5 ? ("Light", .good) : gpu < 0.85 ? ("Busy", .notice) : ("Working hard", .warning)
            return MetricReading(value: Format.percent(gpu), status: status, health: health, history: gpuHistory, chip: "Graphics \(status.lowercased())")

        case .memory:
            let (status, health): (String, Health) = switch s.pressure {
            case .normal: ("Plenty free", .good)
            case .warning: ("Getting tight", .notice)
            case .critical: ("Tight", .warning)
            }
            return MetricReading(value: Format.percent(s.memoryFraction), status: status, health: health, history: memoryHistory, chip: "Memory \(status.lowercased())")

        case .temperature:
            guard let temperature = s.cpuTemperature else {
                return MetricReading(value: "—", status: "Not available", health: .good, chip: "Temperature")
            }
            var (status, health): (String, Health) = temperature < 50 ? ("Cool", .good) : temperature < 80 ? ("Normal", .good) : temperature < 95 ? ("Warm", .notice) : ("Hot", .warning)
            if s.thermal == .serious || s.thermal == .critical { (status, health) = ("Hot", .warning) }
            return MetricReading(value: Format.temperature(temperature), status: status, health: health, history: temperatureHistory, maximum: 100,
                                 chip: "\(status) · \(Format.temperature(temperature))")

        case .power:
            if let battery = s.battery {
                let status: String
                if battery.isCharging { status = "Charging" }
                else if battery.onAC { status = "Plugged in" }
                else if let minutes = battery.minutesRemaining { status = "\(Format.minutes(minutes)) left" }
                else { status = "On battery" }
                let low = !battery.onAC && battery.percent <= 20
                return MetricReading(value: "\(battery.percent)%", status: status, health: low ? .warning : .good,
                                     chip: "Battery \(battery.percent)%" + (battery.isCharging ? ", charging" : ""))
            }
            if let power = s.systemPower {
                return MetricReading(value: Format.watts(power), status: "Mac is using", health: .good, chip: "Using \(Format.watts(power))")
            }
            return MetricReading(value: "—", status: "Not available", health: .good, chip: "Power")

        case .network:
            return MetricReading(value: Format.rate(s.networkDown), status: "↑ \(Format.rate(s.networkUp))", health: .good,
                                 history: downloadHistory, maximum: max(downloadHistory.max() ?? 1, 1), chip: "↓ \(Format.rate(s.networkDown))")

        case .storage:
            guard let free = s.diskFree, let total = s.diskTotal, total > 0 else {
                return MetricReading(value: "—", status: "Not available", health: .good, chip: "Storage")
            }
            let fraction = Double(free) / Double(total)
            let (status, health): (String, Health) = fraction < 0.05 ? ("Almost full", .warning) : fraction < 0.15 ? ("Getting full", .notice) : ("Plenty of space", .good)
            return MetricReading(value: Format.diskBytes(free), status: status == "Plenty of space" ? "free" : status, health: health,
                                 chip: "\(Format.diskBytes(free)) free")

        case .apps:
            guard let top = s.topProcesses.first else {
                return MetricReading(value: "—", status: "Measuring…", health: .good, chip: "Apps")
            }
            return MetricReading(value: top.name, status: String(format: "%.0f%% of a core", top.cpu * 100), health: top.cpu > 1.5 ? .notice : .good,
                                 chip: "\(top.name) busiest")
        }
    }
}

/// A clickable summary tile for one metric.
struct MetricTile: View {
    let metric: Metric
    let reading: MetricReading
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(metric.title, systemImage: metric.symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .offset(x: isHovering ? 2 : 0)
            }
            Text(reading.value)
                .font(.system(.title, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            HStack(spacing: 6) {
                Circle().fill(reading.health.color).frame(width: 7, height: 7)
                Text(reading.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Group {
                if let history = reading.history, history.count > 1 {
                    Sparkline(values: history, maximum: reading.maximum)
                } else {
                    Color.clear
                }
            }
            .frame(height: 24)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20, interactive: true)
        .scaleEffect(isHovering ? 1.015 : 1)
        .animation(.snappy(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}
