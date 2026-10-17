import Foundation
import IOKit

/// Read-only access to the System Management Controller, which knows the Mac's
/// temperatures, fan speeds and power draw. Opening it needs no special permission.
final class SMC {
    static let shared = SMC()

    // Mirrors the kernel's SMCKeyData_t (80 bytes). The explicit padding after keyInfo
    // keeps Swift's layout identical to the C one.
    private struct Version { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct LimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuLimit: UInt32 = 0; var gpuLimit: UInt32 = 0; var memoryLimit: UInt32 = 0 }
    private struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    private struct Param {
        var key: UInt32 = 0
        var version = Version()
        var limitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let readKey: UInt8 = 5
    private static let getKeyInfo: UInt8 = 9
    private static let handleEvent: UInt32 = 2

    private static let typeFloat = fourCC("flt ")
    private static let typeSP78 = fourCC("sp78")
    private static let typeFPE2 = fourCC("fpe2")
    private static let typeUI8 = fourCC("ui8 ")
    private static let typeUI16 = fourCC("ui16")
    private static let typeUI32 = fourCC("ui32")

    private var connection: io_connect_t = 0
    private var keyInfo: [UInt32: KeyInfo] = [:]
    private let lock = NSLock()

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != kIOReturnSuccess {
            connection = 0
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    var isAvailable: Bool { connection != 0 }

    /// The value of a four-character key, or nil if this Mac doesn't have it.
    func value(_ key: String) -> Double? {
        let code = Self.fourCC(key)
        guard connection != 0, code != 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let info: KeyInfo
        if let cached = keyInfo[code] {
            info = cached
        } else {
            var input = Param()
            input.key = code
            input.data8 = Self.getKeyInfo
            let output = call(&input)
            info = output?.keyInfo ?? KeyInfo()
            keyInfo[code] = info // remembers missing keys too, so they're never asked again
        }
        guard info.dataSize > 0 else { return nil }

        var input = Param()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.readKey
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0) }
        return Self.decode(bytes, type: info.dataType, size: Int(info.dataSize))
    }

    private func call(_ input: inout Param) -> Param? {
        var output = Param()
        var outputSize = MemoryLayout<Param>.stride
        let result = IOConnectCallStructMethod(connection, Self.handleEvent, &input, MemoryLayout<Param>.stride, &output, &outputSize)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private static func decode(_ b: [UInt8], type: UInt32, size: Int) -> Double? {
        guard b.count >= 4 else { return nil }
        switch type {
        case typeFloat where size >= 4:
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case typeSP78 where size >= 2:
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case typeFPE2 where size >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case typeUI8:
            return Double(b[0])
        case typeUI16 where size >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case typeUI32 where size >= 4:
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            return nil
        }
    }

    static func fourCC(_ text: String) -> UInt32 {
        let bytes = Array(text.utf8)
        guard bytes.count == 4 else { return 0 }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// SMC keys for CPU and GPU temperatures, by chip generation. A Mac only has some of them;
/// the rest come back empty and are skipped.
enum SMCKeys {
    static let cpu: [String] = [
        // M1
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b",
        // M2
        "Tp0f", "Tp0j", "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        // M3
        "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
        "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
        // M4
        "Te09", "Te0H", "Tp0V", "Tp0Y", "Tp0e",
        // Intel
        "TC0P", "TC0D", "TC0E", "TC0F", "TC1C", "TC2C", "TC3C", "TC4C",
    ]

    static let gpu: [String] = [
        // M1
        "Tg05", "Tg0D", "Tg0L", "Tg0T",
        // M2
        "Tg0f", "Tg0j",
        // M3
        "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",
        // M4
        "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0d", "Tg0e", "Tg0k",
        // Intel
        "TG0P", "TG0D", "TCGC",
    ]

    static let systemPower = "PSTR"
    static let fanCount = "FNum"
    static func fanActual(_ index: Int) -> String { "F\(index)Ac" }
    static func fanMinimum(_ index: Int) -> String { "F\(index)Mn" }
    static func fanMaximum(_ index: Int) -> String { "F\(index)Mx" }
}
