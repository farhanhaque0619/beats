import AppKit
import SwiftUI

/// Performance starts as a calm grid of tiles. Clicking one opens that topic on its own page
/// with the details and what they mean.
struct PerformanceView: View {
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        NavigationStack(path: Binding(
            get: { monitor.focusedMetric.map { [$0] } ?? [] },
            set: { monitor.focusedMetric = $0.last }
        )) {
            PerformanceSummary()
                .navigationDestination(for: Metric.self) { metric in
                    MetricDetailView(metric: metric)
                }
        }
        .onAppear { monitor.start("performance", detailed: true) }
        .onDisappear {
            monitor.stop("performance")
            monitor.focusedMetric = nil
        }
    }
}

private struct PerformanceSummary: View {
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        PageScroll {
            PageHeader(symbol: "gauge.with.dots.needle.50percent", title: "Performance", subtitle: subtitle) {
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                ForEach(Metric.allCases) { metric in
                    NavigationLink(value: metric) {
                        MetricTile(metric: metric, reading: monitor.reading(metric))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Click any tile to see the details and what they mean.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
        }
        .navigationTitle("Performance")
    }

    private var subtitle: String {
        let machine = monitor.machine
        var parts = [machine.chip, Format.bytes(machine.memory) + " memory", machine.osVersion]
        parts.append("on for \(Format.uptime(monitor.snapshot.uptime))")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Detail pages

struct MetricDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    let metric: Metric

    var body: some View {
        let s = monitor.snapshot
        let reading = monitor.reading(metric)
        PageScroll {
            HStack(alignment: .center, spacing: 18) {
                DeviceBadge(symbol: metric.symbol, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(reading.value)
                            .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .contentTransition(.numericText())
                        HStack(spacing: 6) {
                            Circle().fill(reading.health.color).frame(width: 8, height: 8)
                            Text(reading.status).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            .padding(20)
            .glassSurface(cornerRadius: 26)

            Text(Self.explanation(metric))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)

            switch metric {
            case .cpu: CPUDetail(s: s)
            case .gpu: GPUDetail(s: s)
            case .memory: MemoryDetail(s: s)
            case .temperature: HeatDetail(s: s)
            case .power: PowerDetail(s: s)
            case .network: NetworkDetail(s: s)
            case .storage: StorageDetail(s: s)
            case .apps: AppsDetail(s: s)
            }
        }
        .navigationTitle(metric.title)
    }

    static func explanation(_ metric: Metric) -> String {
        switch metric {
        case .cpu:
            "How much of your processor is in use. Short spikes are normal. It only matters if it stays high for a long time, which usually means one app is stuck or working hard."
        case .gpu:
            "How busy the graphics chip is. It handles everything you see, plus games, video and some AI features."
        case .memory:
            "Memory (RAM) is your Mac’s short-term workspace. macOS deliberately keeps it fairly full, so a high number is fine as long as pressure stays normal."
        case .temperature:
            "How warm the chip is and how hard the fans are working. Apple silicon is built to run warm, and macOS slows the chip down by itself if it ever gets too hot."
        case .power:
            "Your battery’s charge and health, and how much power the Mac is using right now."
        case .network:
            "How much data is moving over Wi-Fi or Ethernet right now. This is live traffic, not your connection’s top speed."
        case .storage:
            "Space left on your startup disk, and how much your Mac is reading and writing right now."
        case .apps:
            "The apps and background tasks using the most processor time right now. Background tasks like Spotlight and Photos analysis often run while your Mac is idle or charging."
        }
    }
}

private struct CPUDetail: View {
    @EnvironmentObject private var monitor: SystemMonitor
    let s: SystemSnapshot

    var body: some View {
        Card(title: "Last 3 Minutes", symbol: "chart.xyaxis.line") {
            HistoryChart(values: monitor.cpuHistory, maximum: 1, topLabel: "100%")
        }
        HStack(alignment: .top, spacing: 16) {
            Card(title: "Right Now", symbol: "chart.pie",
                 info: "“Apps” is time spent running your apps. “macOS” is time spent on the system itself, like drawing windows and managing files. “Free” is unused capacity.") {
                HStack(spacing: 24) {
                    StatValue(title: "Apps", value: Format.percent(s.cpuUser))
                    StatValue(title: "macOS", value: Format.percent(s.cpuSystem))
                    StatValue(title: "Free", value: Format.percent(max(1 - s.cpu, 0)))
                }
            }
            Card(title: "Cores", symbol: "square.grid.3x3",
                 info: "Your processor is split into cores that work in parallel. Performance cores handle demanding work, efficiency cores handle light tasks using less power.") {
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
                .frame(height: 48)
                .animation(.smooth(duration: 0.5), value: s.cores)
                Text(coreSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        JumpLink(title: "See which apps are using it", metric: .apps)
    }

    private var coreSummary: String {
        let machine = monitor.machine
        if let p = machine.performanceCores, let e = machine.efficiencyCores {
            return "\(p) performance and \(e) efficiency cores"
        }
        return "\(machine.logicalCores) cores"
    }
}

private struct GPUDetail: View {
    @EnvironmentObject private var monitor: SystemMonitor
    let s: SystemSnapshot

    var body: some View {
        Card(title: "Last 3 Minutes", symbol: "chart.xyaxis.line") {
            HistoryChart(values: monitor.gpuHistory, maximum: 1, topLabel: "100%")
        }
        if let temperature = s.gpuTemperature {
            Card(title: "Temperature", symbol: "thermometer.medium") {
                StatValue(title: "Graphics", value: Format.temperature(temperature))
            }
        }
    }
}

private struct MemoryDetail: View {
    @EnvironmentObject private var monitor: SystemMonitor
    let s: SystemSnapshot

    var body: some View {
        Card(title: "In Use", symbol: "memorychip") {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Format.bytes(s.memoryUsed)) of \(Format.bytes(s.memoryTotal))")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Spacer()
            }
            MeterBar(value: s.memoryFraction, height: 8, warning: s.pressure != .normal)
            VStack(spacing: 10) {
                DetailRow(title: "Apps", value: Format.bytes(s.memoryApp), detail: "Memory your apps are using")
                DetailRow(title: "Wired", value: Format.bytes(s.memoryWired), detail: "Kept by macOS for itself, can’t be moved")
                DetailRow(title: "Compressed", value: Format.bytes(s.memoryCompressed), detail: "Squeezed by macOS to make room")
                DetailRow(title: "Swap", value: Format.bytes(s.swapUsed), detail: "Moved to the SSD because RAM was full")
            }
        }
        Card(title: "Pressure: \(s.pressure.title)", symbol: "gauge.with.dots.needle.33percent",
             info: "Memory pressure is the best single sign of whether you need more RAM. It stays normal for most people, even with lots of apps open.") {
            Text(pressureAdvice)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Card(title: "Last 3 Minutes", symbol: "chart.xyaxis.line") {
            HistoryChart(values: monitor.memoryHistory, maximum: 1, topLabel: "100%")
        }
    }

    private var pressureAdvice: String {
        switch s.pressure {
        case .normal: "There’s plenty of memory. Nothing to do."
        case .warning: "macOS is compressing and swapping to keep up. Quitting a large app or a few browser tabs will help."
        case .critical: "Memory is very tight and apps may slow down. Quit apps you aren’t using."
        }
    }
}

private struct HeatDetail: View {
    @EnvironmentObject private var monitor: SystemMonitor
    let s: SystemSnapshot

    var body: some View {
        if !monitor.temperatureHistory.isEmpty {
            Card(title: "CPU, Last 3 Minutes", symbol: "chart.xyaxis.line") {
                HistoryChart(values: monitor.temperatureHistory, maximum: 100, topLabel: "100°", bottomLabel: "0°")
            }
        }
        HStack(alignment: .top, spacing: 16) {
            Card(title: "Sensors", symbol: "thermometer.medium",
                 info: "Most Apple silicon Macs run between 35° and 95° depending on load. Short peaks near 100° under heavy work are expected.") {
                VStack(spacing: 10) {
                    DetailRow(title: "CPU average", value: Format.temperature(s.cpuTemperature))
                    if let hottest = s.hottestCoreTemperature { DetailRow(title: "Hottest core", value: Format.temperature(hottest)) }
                    if let p = s.performanceCoreTemperature { DetailRow(title: "Performance cores", value: Format.temperature(p)) }
                    if let e = s.efficiencyCoreTemperature { DetailRow(title: "Efficiency cores", value: Format.temperature(e)) }
                    if let gpu = s.gpuTemperature { DetailRow(title: "Graphics", value: Format.temperature(gpu)) }
                    if let battery = s.battery?.temperature { DetailRow(title: "Battery", value: Format.temperature(battery)) }
                    DetailRow(title: "Thermal state", value: thermalTitle)
                }
            }
            Card(title: "Fans", symbol: "fan") {
                if s.fans.isEmpty {
                    Text(s.hasFans ? "Fan speed isn’t readable on this Mac." : "This Mac has no fans. It’s cooled silently.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(s.fans) { fan in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(s.fans.count > 1 ? "Fan \(fan.id + 1)" : "Fan")
                                Spacer()
                                Text(fan.rpm < 100 ? "Off" : "\(Int(fan.rpm.rounded())) rpm")
                                    .font(.callout.monospacedDigit().weight(.medium))
                            }
                            MeterBar(value: fan.fraction)
                            if fan.maximum > 0 {
                                Text("Range \(Int(fan.minimum.rounded()))–\(Int(fan.maximum.rounded())) rpm")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Text(fanExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var thermalTitle: String {
        switch s.thermal {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot, slowing down"
        case .critical: "Very hot, slowing down"
        @unknown default: "Unknown"
        }
    }

    private var fanExplanation: String {
        if s.fans.allSatisfy({ $0.rpm < 100 }) { return "The fans are off. Your Mac is cool enough without them." }
        if s.fans.allSatisfy({ $0.minimum > 0 && $0.rpm <= $0.minimum * 1.08 }) {
            return "Spinning at their slowest speed, which is designed to be silent."
        }
        return "Running faster to cool the chip. They slow down again once the work is done."
    }
}

private struct PowerDetail: View {
    let s: SystemSnapshot

    var body: some View {
        if let battery = s.battery {
            HStack(alignment: .top, spacing: 16) {
                Card(title: "Battery", symbol: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent") {
                    MeterBar(value: Double(battery.percent) / 100, height: 8, warning: battery.percent <= 20 && !battery.onAC)
                    VStack(spacing: 10) {
                        DetailRow(title: "Charge", value: "\(battery.percent)%", detail: chargeDetail(battery))
                        if let health = battery.healthPercent {
                            DetailRow(title: "Health", value: "\(health)%", detail: "Full charge today, compared with new")
                        }
                        if let cycles = battery.cycleCount {
                            DetailRow(title: "Charge cycles", value: "\(cycles)", detail: "One cycle is 100% used, in any number of sessions")
                        }
                        if let temperature = battery.temperature {
                            DetailRow(title: "Temperature", value: Format.temperature(temperature))
                        }
                    }
                }
                powerFlow(battery)
            }
            Button("Battery Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .padding(.horizontal, 6)
        } else {
            powerFlow(nil)
        }
    }

    private func powerFlow(_ battery: BatteryHealth?) -> some View {
        Card(title: "Power Right Now", symbol: "bolt",
             info: "“Mac is using” is everything the computer draws: chip, screen, speakers. On the charger that power comes from the adapter, and whatever’s left over charges the battery.") {
            VStack(spacing: 10) {
                if let power = s.systemPower {
                    DetailRow(title: "Mac is using", value: Format.watts(power), detail: "Chip, screen and everything else")
                }
                if let battery, let flow = battery.power {
                    DetailRow(title: flow > 0 ? "Into the battery" : "From the battery", value: Format.watts(abs(flow)),
                              detail: flow > 0 ? "Charging" : "Running on battery")
                }
                if let adapter = battery?.adapterWatts, battery?.onAC == true {
                    DetailRow(title: "Charger", value: "\(adapter) W", detail: "The most it can deliver")
                }
                if s.systemPower == nil && battery?.power == nil {
                    Text("Power readings aren’t available on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chargeDetail(_ battery: BatteryHealth) -> String {
        if battery.isCharging { return battery.minutesRemaining.map { "Full in \(Format.minutes($0))" } ?? "Charging" }
        if battery.onAC { return "Plugged in, not charging" }
        return battery.minutesRemaining.map { "\(Format.minutes($0)) left" } ?? "On battery"
    }
}

private struct NetworkDetail: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var tools: ToolsManager
    let s: SystemSnapshot

    var body: some View {
        Card(title: "Downloading, Last 3 Minutes", symbol: "chart.xyaxis.line") {
            HistoryChart(values: monitor.downloadHistory, maximum: max(monitor.downloadHistory.max() ?? 1, 1),
                         topLabel: Format.rate(max(monitor.downloadHistory.max() ?? 0, 0)).replacingOccurrences(of: "/s", with: ""))
        }
        Card(title: "Right Now", symbol: "arrow.up.arrow.down") {
            VStack(spacing: 10) {
                DetailRow(title: "Downloading", value: Format.rate(s.networkDown))
                DetailRow(title: "Uploading", value: Format.rate(s.networkUp))
                if let address = tools.localAddress {
                    DetailRow(title: "Address on this network", value: address)
                }
            }
        }
        .onAppear { tools.refreshAddresses() }
    }
}

private struct StorageDetail: View {
    let s: SystemSnapshot

    var body: some View {
        if let free = s.diskFree, let total = s.diskTotal, total > 0 {
            Card(title: "Startup Disk", symbol: "internaldrive") {
                Text("\(Format.diskBytes(free)) free of \(Format.diskBytes(total))")
                    .font(.title3.weight(.semibold).monospacedDigit())
                MeterBar(value: 1 - Double(free) / Double(total), height: 8, warning: Double(free) / Double(total) < 0.1)
                Text("Free space includes room macOS can clear by itself, like caches and old backups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Card(title: "Activity Right Now", symbol: "arrow.left.arrow.right") {
            VStack(spacing: 10) {
                DetailRow(title: "Reading", value: Format.rate(s.diskRead))
                DetailRow(title: "Writing", value: Format.rate(s.diskWrite))
            }
        }
        Button("Manage Storage…") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
                NSWorkspace.shared.open(url)
            }
        }
        .padding(.horizontal, 6)
    }
}

private struct AppsDetail: View {
    let s: SystemSnapshot
    @State private var quitting: ProcessUsage?

    var body: some View {
        Card(title: "Right Now", symbol: "list.number",
             info: "CPU is shown as a share of one core: 100% means one core fully busy, so busy apps can go past 100%. Overdrive measures your whole Mac every two seconds while this page is open, which uses a little CPU itself.") {
            if s.topProcesses.isEmpty {
                Text("Measuring…").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(s.topProcesses) { process in
                        HStack(spacing: 12) {
                            Group {
                                if let path = process.bundlePath {
                                    Image(nsImage: IconCache.icon(forFile: path)).resizable()
                                } else {
                                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(process.name).lineLimit(1)
                                Text(ProcessGlossary.describe(process.name) ?? "Uses \(Format.bytes(process.memory)) of memory")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(String(format: "%.0f%%", process.cpu * 100))
                                .font(.callout.monospacedDigit().weight(.medium))
                            if quitTarget(process) != nil {
                                Button {
                                    quitting = process
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Quit \(process.name)")
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Quit \(quitting?.name ?? "this app")?",
            isPresented: Binding(get: { quitting != nil }, set: { if !$0 { quitting = nil } })
        ) {
            Button("Quit") {
                if let process = quitting { quitTarget(process)?.terminate() }
                quitting = nil
            }
        } message: {
            Text("It quits normally, so it can ask you to save first.")
        }
    }

    /// The running app behind a row, if it's a normal app other than Overdrive.
    private func quitTarget(_ process: ProcessUsage) -> NSRunningApplication? {
        guard let path = process.bundlePath else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.path == path && $0.processIdentifier != getpid() && $0.activationPolicy == .regular
        }
    }
}

// MARK: - Pieces

/// A label on the left, a value on the right, and an optional line explaining it.
struct DetailRow: View {
    let title: String
    let value: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(value)
                .font(.body.monospacedDigit().weight(.medium))
                .contentTransition(.numericText())
        }
    }
}

/// A link to another metric's detail page.
private struct JumpLink: View {
    @EnvironmentObject private var monitor: SystemMonitor
    let title: String
    let metric: Metric

    var body: some View {
        Button {
            monitor.focusedMetric = metric
        } label: {
            Label(title, systemImage: "arrow.right.circle")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
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
        "Overdrive": "This app, measuring your Mac",
    ]

    static func describe(_ name: String) -> String? { descriptions[name] }
}
