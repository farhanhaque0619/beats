import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps

struct FanReading: Equatable, Identifiable {
    let id: Int
    let rpm: Double
    let minimum: Double
    let maximum: Double

    var fraction: Double {
        guard maximum > minimum else { return 0 }
        return min(max((rpm - minimum) / (maximum - minimum), 0), 1)
    }
}

struct BatteryHealth: Equatable {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var minutesRemaining: Int?
    var healthPercent: Int?
    var cycleCount: Int?
    var temperature: Double?
    /// Watts flowing in (positive, charging) or out (negative).
    var power: Double?
    var adapterWatts: Int?
}

struct ProcessUsage: Equatable, Identifiable {
    let id: String
    let name: String
    let bundlePath: String?
    let cpu: Double
    let memory: UInt64
}

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "High"
        }
    }
}

struct SystemSnapshot: Equatable {
    var cpu: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cores: [Double] = []
    var gpu: Double?
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memoryApp: UInt64 = 0
    var memoryWired: UInt64 = 0
    var memoryCompressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: MemoryPressure = .normal
    var cpuTemperature: Double?
    var performanceCoreTemperature: Double?
    var efficiencyCoreTemperature: Double?
    var hottestCoreTemperature: Double?
    var gpuTemperature: Double?
    var fans: [FanReading] = []
    var hasFans = true
    var systemPower: Double?
    var networkDown: Double = 0
    var networkUp: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var diskFree: Int64?
    var diskTotal: Int64?
    var battery: BatteryHealth?
    var thermal: ProcessInfo.ThermalState = .nominal
    var topProcesses: [ProcessUsage] = []

    var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
}

/// Static facts about this Mac, read once.
struct MachineInfo {
    let chip: String
    let model: String
    let performanceCores: Int?
    let efficiencyCores: Int?
    let logicalCores: Int
    let memory: UInt64
    let osVersion: String

    static let current: MachineInfo = {
        let chip = Sysctl.string("machdep.cpu.brand_string") ?? "Mac"
        let model = Sysctl.string("hw.model") ?? ""
        let levels = Sysctl.int("hw.nperflevels") ?? 0
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return MachineInfo(
            chip: chip,
            model: model,
            performanceCores: levels > 1 ? Sysctl.int("hw.perflevel0.logicalcpu") : nil,
            efficiencyCores: levels > 1 ? Sysctl.int("hw.perflevel1.logicalcpu") : nil,
            logicalCores: ProcessInfo.processInfo.activeProcessorCount,
            memory: ProcessInfo.processInfo.physicalMemory,
            osVersion: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        )
    }()
}

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }
}

/// Samples CPU, GPU, memory, sensors, battery, network and disk on a background queue.
/// It only runs while something on screen asks for it (the Performance page, the Overview,
/// the menu bar panel or the menu bar readout), so it costs nothing when no one is looking.
@MainActor
final class SystemMonitor: ObservableObject {
    static let historyLength = 90

    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var temperatureHistory: [Double] = []

    let machine = MachineInfo.current

    private var clients: [String: Bool] = [:] // client name: wants process details
    private var timer: Timer?
    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "overdrive.system-monitor", qos: .utility)
    private var sampling = false

    /// Starts sampling for `client`. Detailed clients also get top apps and disk activity.
    func start(_ client: String, detailed: Bool = false) {
        clients[client] = detailed
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop(_ client: String) {
        clients[client] = nil
        if clients.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func sample() {
        guard !sampling else { return }
        sampling = true
        let detailed = clients.values.contains(true)
        let sampler = self.sampler
        queue.async {
            let snapshot = sampler.sample(detailed: detailed)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.publish(snapshot) }
            }
        }
    }

    private func publish(_ new: SystemSnapshot) {
        sampling = false
        snapshot = new
        append(new.cpu, to: &cpuHistory)
        append(new.gpu ?? 0, to: &gpuHistory)
        append(new.memoryFraction, to: &memoryHistory)
        if let temperature = new.cpuTemperature { append(temperature, to: &temperatureHistory) }
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }
}

/// Does the actual reading. Only ever used from the monitor's serial queue.
private final class Sampler {
    private let host = mach_host_self()
    private let pageSize = UInt64(getpagesize())
    private var previousCores: [(busy: UInt64, total: UInt64, user: UInt64, system: UInt64)] = []
    private var previousNetwork: (down: UInt64, up: UInt64, time: TimeInterval)?
    private var previousDisk: (read: UInt64, write: UInt64, time: TimeInterval)?
    private var previousProcesses: [pid_t: UInt64] = [:]
    private var previousProcessTime: TimeInterval = 0
    /// The temperature keys this Mac actually has, found on the first sample.
    private var temperatureKeys: TemperatureKeys?
    private let ticksToSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    func sample(detailed: Bool) -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        readCPU(into: &snapshot)
        readMemory(into: &snapshot)
        snapshot.gpu = readGPU()
        readSensors(into: &snapshot)
        snapshot.battery = readBattery()
        readNetwork(into: &snapshot)
        snapshot.thermal = ProcessInfo.processInfo.thermalState
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            snapshot.diskFree = values.volumeAvailableCapacityForImportantUsage
            snapshot.diskTotal = values.volumeTotalCapacity.map(Int64.init)
        }
        if detailed {
            readDisk(into: &snapshot)
            snapshot.topProcesses = readProcesses()
        }
        return snapshot
    }

    // MARK: CPU

    private func readCPU(into snapshot: inout SystemSnapshot) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var current: [(busy: UInt64, total: UInt64, user: UInt64, system: UInt64)] = []
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            current.append((user + system + nice, user + system + nice + idle, user + nice, system))
        }

        if previousCores.count == current.count {
            var busy: UInt64 = 0, total: UInt64 = 0, user: UInt64 = 0, system: UInt64 = 0
            snapshot.cores = zip(current, previousCores).map { now, before in
                let coreBusy = now.busy &- before.busy
                let coreTotal = now.total &- before.total
                busy += coreBusy
                total += coreTotal
                user += now.user &- before.user
                system += now.system &- before.system
                return coreTotal > 0 ? min(Double(coreBusy) / Double(coreTotal), 1) : 0
            }
            if total > 0 {
                snapshot.cpu = min(Double(busy) / Double(total), 1)
                snapshot.cpuUser = Double(user) / Double(total)
                snapshot.cpuSystem = Double(system) / Double(total)
            }
        } else {
            snapshot.cores = Array(repeating: 0, count: current.count)
        }
        previousCores = current
    }

    // MARK: Memory

    private func readMemory(into snapshot: inout SystemSnapshot) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        // Matches Activity Monitor: Memory Used = App Memory + Wired + Compressed.
        let app = UInt64(stats.internal_page_count &- stats.purgeable_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        snapshot.memoryApp = app
        snapshot.memoryWired = wired
        snapshot.memoryCompressed = compressed
        snapshot.memoryUsed = min(app + wired + compressed, snapshot.memoryTotal)

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            snapshot.swapUsed = swap.xsu_used
        }
        if let level = Sysctl.int("kern.memorystatus_vm_pressure_level"), let pressure = MemoryPressure(rawValue: level) {
            snapshot.pressure = pressure
        }
    }

    // MARK: GPU

    private func readGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let property = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = property as? [String: Any] else { continue }
            let value = (stats["Device Utilization %"] as? NSNumber) ?? (stats["GPU Activity(%)"] as? NSNumber)
            if let value { best = max(best ?? 0, value.doubleValue / 100) }
        }
        return best.map { min(max($0, 0), 1) }
    }

    // MARK: Sensors

    private func readSensors(into snapshot: inout SystemSnapshot) {
        let smc = SMC.shared
        if smc.isAvailable {
            let keys = resolvedTemperatureKeys(smc)
            func readings(_ list: [String]) -> [Double] {
                list.compactMap { smc.value($0) }.filter { Self.plausible($0) }
            }
            let performance = readings(keys.performanceCores)
            let efficiency = readings(keys.efficiencyCores)
            snapshot.performanceCoreTemperature = Self.average(performance)
            snapshot.efficiencyCoreTemperature = Self.average(efficiency)
            snapshot.cpuTemperature = Self.average(performance + efficiency)
            snapshot.hottestCoreTemperature = (performance + efficiency).max()
            snapshot.gpuTemperature = Self.average(readings(keys.gpu))
            if let power = smc.value(SMCKeys.systemPower), power > 0.1, power < 500 { snapshot.systemPower = power }

            let fanCount = Int(smc.value(SMCKeys.fanCount) ?? 0)
            snapshot.hasFans = fanCount > 0
            snapshot.fans = (0..<min(fanCount, 4)).compactMap { index in
                guard let rpm = smc.value(SMCKeys.fanActual(index)) else { return nil }
                return FanReading(
                    id: index,
                    rpm: max(rpm, 0),
                    minimum: smc.value(SMCKeys.fanMinimum(index)) ?? 0,
                    maximum: smc.value(SMCKeys.fanMaximum(index)) ?? 0
                )
            }
        }
        if snapshot.cpuTemperature == nil {
            snapshot.cpuTemperature = HIDSensors.shared.chipTemperature()
        }
    }

    /// Keeps only the keys that answer with a real temperature on this Mac.
    private func resolvedTemperatureKeys(_ smc: SMC) -> TemperatureKeys {
        if let temperatureKeys { return temperatureKeys }
        func present(_ list: [String]) -> [String] { list.filter { Self.plausible(smc.value($0)) } }
        func resolve(_ keys: TemperatureKeys) -> TemperatureKeys {
            TemperatureKeys(
                performanceCores: present(keys.performanceCores),
                efficiencyCores: present(keys.efficiencyCores),
                gpu: present(keys.gpu)
            )
        }
        var keys = TemperatureKeys.forChip(ChipFamily.current).map(resolve) ?? resolve(.fallback)
        if keys.cpu.isEmpty { keys = resolve(.fallback) }
        temperatureKeys = keys
        return keys
    }

    private static func plausible(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value > 10 && value < 115
    }

    private static func average(_ values: [Double]?) -> Double? {
        guard let values, !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    // MARK: Battery

    private func readBattery() -> BatteryHealth? {
        guard let status = PowerSource.current() else { return nil }
        var health = BatteryHealth(
            percent: status.percent,
            isCharging: status.isCharging,
            onAC: status.onAC,
            minutesRemaining: status.minutesRemaining
        )
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"))
        guard service != 0 else { return health }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return health }

        func number(_ key: String) -> NSNumber? { properties[key] as? NSNumber }
        health.cycleCount = number("CycleCount")?.intValue
        if let design = number("DesignCapacity")?.doubleValue, design > 0,
           let maximum = (number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity"))?.doubleValue {
            health.healthPercent = Int((maximum / design * 100).rounded())
        }
        if let temperature = number("Temperature")?.doubleValue, temperature > 0 {
            health.temperature = temperature / 100
        }
        if let voltage = number("Voltage")?.doubleValue,
           let amperage = (number("InstantAmperage") ?? number("Amperage"))?.int64Value {
            let watts = voltage * Double(amperage) / 1_000_000
            if abs(watts) > 0.05 { health.power = watts }
        }
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            health.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
        }
        return health
    }

    // MARK: Network and disk

    private func readNetwork(into snapshot: inout SystemSnapshot) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return }
        defer { freeifaddrs(addresses) }
        var down: UInt64 = 0
        var up: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let interface = entry.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               let data = interface.ifa_data {
                let name = String(cString: interface.ifa_name)
                // Physical interfaces only, so VPN tunnels don't count traffic twice.
                if name.hasPrefix("en") {
                    let stats = data.assumingMemoryBound(to: if_data.self).pointee
                    down += UInt64(stats.ifi_ibytes)
                    up += UInt64(stats.ifi_obytes)
                }
            }
            cursor = interface.ifa_next
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = previousNetwork, now > previous.time, down >= previous.down, up >= previous.up {
            snapshot.networkDown = Double(down - previous.down) / (now - previous.time)
            snapshot.networkUp = Double(up - previous.up) / (now - previous.time)
        }
        previousNetwork = (down, up, now)
    }

    private func readDisk(into snapshot: inout SystemSnapshot) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var write: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let property = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = property as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = previousDisk, now > previous.time, read >= previous.read, write >= previous.write {
            snapshot.diskRead = Double(read - previous.read) / (now - previous.time)
            snapshot.diskWrite = Double(write - previous.write) / (now - previous.time)
        }
        previousDisk = (read, write, now)
    }

    // MARK: Processes

    /// The apps using the most CPU right now, with helper processes counted under their app.
    private func readProcesses() -> [ProcessUsage] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - previousProcessTime
        var times: [pid_t: UInt64] = [:]
        var usage: [String: (name: String, path: String?, cpu: Double, memory: UInt64)] = [:]

        for pid in pids.prefix(max(found, 0)) where pid > 0 {
            var info = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard result == 0 else { continue }
            let total = info.ri_user_time &+ info.ri_system_time
            times[pid] = total
            guard previousProcessTime > 0, elapsed > 0, let before = previousProcesses[pid], total >= before else { continue }
            let cpu = Double(total - before) * ticksToSeconds / elapsed
            let identity = AppIdentity.resolve(pid: pid)
            var entry = usage[identity.key] ?? (identity.name, identity.path, 0, 0)
            entry.cpu += cpu
            entry.memory += info.ri_phys_footprint
            usage[identity.key] = entry
        }
        previousProcesses = times
        previousProcessTime = now

        return usage
            .map { ProcessUsage(id: $0.key, name: $0.value.name, bundlePath: $0.value.path, cpu: $0.value.cpu, memory: $0.value.memory) }
            .sorted { $0.cpu > $1.cpu }
            .prefix(6)
            .map { $0 }
    }
}

/// Works out which app a process belongs to: the outermost `.app` bundle in its path,
/// so browser and Electron helpers count toward the app you see.
enum AppIdentity {
    static func resolve(pid: pid_t) -> (key: String, name: String, path: String?) {
        if let url = NSRunningApplication(processIdentifier: pid)?.bundleURL ?? executableURL(pid) {
            let components = url.pathComponents
            if let index = components.firstIndex(where: { $0.hasSuffix(".app") }) {
                let appPath = NSString.path(withComponents: Array(components[...index]))
                let name = FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
                return (appPath, name, appPath)
            }
        }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return ("pid:\(name)", name.isEmpty ? "Process \(pid)" : name, nil)
    }

    private static func executableURL(_ pid: pid_t) -> URL? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
    }
}
