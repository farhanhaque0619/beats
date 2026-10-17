import Foundation

/// Temperature sensors that Apple silicon exposes through the HID event system (the same
/// source `powermetrics` uses). Used when the SMC has no known CPU keys for this chip.
/// These functions live in IOKit but aren't in its public headers, so they're looked up at
/// runtime; if any is missing, sensors simply report nothing.
final class HIDSensors {
    static let shared = HIDSensors()

    private typealias CreateFn = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias SetMatchingFn = @convention(c) (OpaquePointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (OpaquePointer, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    private typealias GetFloatFn = @convention(c) (OpaquePointer, Int32) -> Double

    private static let temperatureEvent: Int64 = 15
    private static let temperatureField = Int32(15 << 16)

    private let client: OpaquePointer?
    private let copyServices: CopyServicesFn?
    private let copyProperty: CopyPropertyFn?
    private let copyEvent: CopyEventFn?
    private let getFloat: GetFloatFn?
    private let lock = NSLock()

    private init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        let create = symbol("IOHIDEventSystemClientCreate", CreateFn.self)
        let setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatchingFn.self)
        copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServicesFn.self)
        copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyPropertyFn.self)
        copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEventFn.self)
        getFloat = symbol("IOHIDEventGetFloatValue", GetFloatFn.self)

        if let create, let setMatching, let client = create(kCFAllocatorDefault) {
            // Vendor-defined page 0xff00, usage 5: temperature sensors.
            let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
            _ = setMatching(client, matching)
            self.client = client
        } else {
            client = nil
        }
    }

    /// Every temperature sensor by name, in °C.
    func temperatures() -> [String: Double] {
        guard let client, let copyServices, let copyProperty, let copyEvent, let getFloat,
              let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        var result: [String: Double] = [:]
        for service in services {
            let pointer = OpaquePointer(Unmanaged.passUnretained(service).toOpaque())
            guard let name = copyProperty(pointer, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEvent(pointer, Self.temperatureEvent, 0, 0) else { continue }
            let value = getFloat(event, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()
            if value > 0, value < 130 { result[name] = value }
        }
        return result
    }

    /// The hottest on-die sensor: a good stand-in for "CPU temperature" on Apple silicon.
    func chipTemperature() -> Double? {
        let dies = temperatures().filter { $0.key.lowercased().contains("tdie") }
        guard !dies.isEmpty else { return nil }
        return dies.values.max()
    }

    func batteryTemperature() -> Double? {
        temperatures().first { $0.key.lowercased().contains("battery") }?.value
    }
}
