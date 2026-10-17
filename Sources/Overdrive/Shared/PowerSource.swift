import Foundation
import IOKit.ps

/// The Mac's internal battery, as the menu bar battery icon sees it.
struct PowerSourceStatus: Equatable {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    /// Minutes until empty (on battery) or full (charging), when macOS has an estimate.
    var minutesRemaining: Int?
}

enum PowerSource {
    static func current() -> PowerSourceStatus? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (description[key] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return PowerSourceStatus(
                percent: Int((Double(current) / Double(maximum) * 100).rounded()),
                isCharging: charging,
                onAC: onAC,
                minutesRemaining: minutes
            )
        }
        return nil
    }
}
