import CoreAudio
import Foundation
import SwiftUI

/// Battery levels for connected Bluetooth audio devices, in percent.
struct BatteryInfo: Equatable {
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    var isEmpty: Bool { main == nil && left == nil && right == nil && caseLevel == nil }

    /// The level to show when there's room for only one number: the lower earbud.
    var headline: Int? {
        if let left, let right { return min(left, right) }
        return main ?? left ?? right
    }
}

/// Reads battery levels the way System Information does, so AirPods and Beats report
/// left, right and case. Runs in the background every two minutes and on demand.
@MainActor
final class BatteryMonitor: ObservableObject {
    /// Keyed by Bluetooth device name, which matches the audio device name.
    @Published private(set) var levels: [String: BatteryInfo] = [:]

    private var timer: Timer?
    private var isRefreshing = false
    private var lastSoon: Date?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Headphones that just connected report their battery a few seconds later.
        HAL.observeSystem(kAudioHardwarePropertyDevices) { [weak self] in
            Task { @MainActor in self?.refreshSoon() }
        }
    }

    func battery(for deviceName: String?) -> BatteryInfo? {
        guard let deviceName, let info = levels[deviceName], !info.isEmpty else { return nil }
        return info
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let result = await Task.detached(priority: .utility) { Self.read() }.value
            if let result, result != levels { levels = result }
            isRefreshing = false
        }
    }

    /// Call after Bluetooth devices connect: levels show up a few seconds later. Overdrive's
    /// own audio routing also changes the device list, so repeat calls are skipped for a while.
    func refreshSoon() {
        if let lastSoon, Date().timeIntervalSince(lastSoon) < 30 { return }
        lastSoon = Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.refresh()
        }
    }

    nonisolated private static func read() -> [String: BatteryInfo]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var result: [String: BatteryInfo] = [:]
        collectConnected(json, into: &result)
        return result
    }

    /// Walks the report for "device_connected" lists of `[name: properties]`.
    nonisolated private static func collectConnected(_ node: Any, into result: inout [String: BatteryInfo]) {
        if let dictionary = node as? [String: Any] {
            for (key, value) in dictionary {
                if key == "device_connected", let devices = value as? [[String: Any]] {
                    for entry in devices {
                        for (name, properties) in entry {
                            guard let properties = properties as? [String: Any] else { continue }
                            let info = BatteryInfo(
                                main: percent(properties["device_batteryLevelMain"] ?? properties["device_batteryLevel"]),
                                left: percent(properties["device_batteryLevelLeft"]),
                                right: percent(properties["device_batteryLevelRight"]),
                                caseLevel: percent(properties["device_batteryLevelCase"])
                            )
                            if !info.isEmpty { result[name] = info }
                        }
                    }
                } else {
                    collectConnected(value, into: &result)
                }
            }
        } else if let array = node as? [Any] {
            for item in array { collectConnected(item, into: &result) }
        }
    }

    nonisolated private static func percent(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        guard let text = value as? String else { return nil }
        return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }
}

// MARK: - Views

/// A compact battery reading: "L 80%  R 85%" for earbuds, "72%" for everything else.
struct BatteryLabel: View {
    let info: BatteryInfo
    var showCase = false

    var body: some View {
        HStack(spacing: 8) {
            if let left = info.left, let right = info.right, left != right {
                level("L", left)
                level("R", right)
            } else if let headline = info.headline {
                level(nil, headline)
            }
            if showCase, let caseLevel = info.caseLevel {
                level("Case", caseLevel)
            }
        }
        .font(.caption.monospacedDigit())
    }

    private func level(_ label: String?, _ percent: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(percent))
                .foregroundStyle(Self.color(percent))
            if let label { Text(label).foregroundStyle(.secondary) }
            Text("\(percent)%")
        }
    }

    static func symbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    static func color(_ percent: Int) -> Color {
        switch percent {
        case ..<11: .red
        case ..<21: .orange
        default: .secondary
        }
    }
}
