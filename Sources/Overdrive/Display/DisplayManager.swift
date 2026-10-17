import AppKit
import CoreGraphics
import Foundation

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    /// How far above SDR white the panel can go (1 = no HDR headroom).
    let edrPotential: Double
    let pixelSize: CGSize
    let pointSize: CGSize
    let refreshRate: Double

    var supportsBoost: Bool { edrPotential > 1.05 }
    var isXDR: Bool { edrPotential >= 8 }

    var symbolName: String { isBuiltIn ? "laptopcomputer" : "display" }
}

struct DisplayModeOption: Identifiable, Hashable {
    let id: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    var isHiDPI: Bool { pixelWidth > width }

    var title: String {
        var text = "\(width) × \(height)"
        if refreshRate > 0 { text += " · \(Int(refreshRate.rounded())) Hz" }
        if !isHiDPI { text += " (low resolution)" }
        return text
    }

    init(_ mode: CGDisplayMode) {
        id = mode.ioDisplayModeID
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
    }
}

/// The display's colour lookup table, captured once so boosts and dimming always start
/// from the calibrated original instead of compounding.
private struct GammaTable {
    let red: [CGGammaValue]
    let green: [CGGammaValue]
    let blue: [CGGammaValue]

    init?(display: CGDirectDisplayID) {
        let capacity: UInt32 = 256
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success, count > 0 else { return nil }
        self.red = Array(red.prefix(Int(count)))
        self.green = Array(green.prefix(Int(count)))
        self.blue = Array(blue.prefix(Int(count)))
    }

    func apply(to display: CGDirectDisplayID, factor: Float) {
        var r = red.map { $0 * factor }
        var g = green.map { $0 * factor }
        var b = blue.map { $0 * factor }
        CGSetDisplayTransferByTable(display, UInt32(r.count), &r, &g, &b)
    }

    /// Whether the display still has this table times `factor` (macOS resets it after sleep).
    func isApplied(on display: CGDirectDisplayID, factor: Float) -> Bool {
        guard let current = GammaTable(display: display), let last = current.red.last, let original = red.last else { return false }
        return abs(last - original * factor) < 0.01
    }
}

/// Brightness for Apple displays through the system's DisplayServices framework, the same
/// path the brightness keys use. Loaded at runtime; missing on some Macs and displays.
private enum DisplayServicesBridge {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness: GetFn? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFn.self) }
    private static let setBrightness: SetFn? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFn.self) }

    static func brightness(_ display: CGDirectDisplayID) -> Double? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        return getBrightness(display, &value) == 0 ? Double(value) : nil
    }

    @discardableResult
    static func setBrightness(_ value: Double, for display: CGDirectDisplayID) -> Bool {
        guard let setBrightness else { return false }
        return setBrightness(display, Float(min(max(value, 0), 1))) == 0
    }
}

/// Extra brightness, software dimming, brightness and resolution for every display.
///
/// Extra Brightness works like BrightIntosh and Vivid: a tiny EDR pixel puts an XDR panel in
/// HDR mode, then the display's gamma table is scaled up into that headroom. Safety:
/// - the boost is capped at 1.6×, the level those apps treat as the safe maximum;
/// - it pauses when macOS reports the Mac is running hot, and when the battery is low;
/// - gamma changes belong to this process, so macOS undoes them the moment Overdrive quits
///   or crashes, and the panel's own firmware still enforces its power and heat limits.
@MainActor
final class DisplayManager: ObservableObject {
    static let maxBoostFactor = 1.6

    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var boostEnabled: Bool
    @Published private(set) var boostLevel: Double
    @Published private(set) var boostPausedReason: String?
    @Published private(set) var dimLevels: [CGDirectDisplayID: Double] = [:]
    @Published private(set) var brightness: [CGDirectDisplayID: Double] = [:]

    private let overlay = EDROverlay()
    private var baseTables: [CGDirectDisplayID: GammaTable] = [:]
    private var appliedFactors: [CGDirectDisplayID: Float] = [:]
    private var safetyTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    var canBoost: Bool { displays.contains(where: \.supportsBoost) }
    var isBoostActive: Bool { boostEnabled && boostPausedReason == nil && canBoost }
    var boostFactor: Double { 1 + (Self.maxBoostFactor - 1) * boostLevel }

    /// Battery level at which the boost pauses; 0 means never.
    var batteryFloor: Int { UserDefaults.standard.object(forKey: SettingsKey.boostBatteryFloor) as? Int ?? 20 }

    init() {
        let defaults = UserDefaults.standard
        boostEnabled = defaults.bool(forKey: SettingsKey.boostEnabled)
        boostLevel = defaults.object(forKey: SettingsKey.boostLevel) as? Double ?? 0.75

        refreshDisplays()
        checkSafety(applyChanges: false)
        apply()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreAll() }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSafety() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            })
        }
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.periodicCheck() }
        }
    }

    // MARK: - Controls

    func setBoostEnabled(_ enabled: Bool) {
        boostEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: SettingsKey.boostEnabled)
        checkSafety(applyChanges: false)
        apply()
    }

    func setBoostLevel(_ level: Double) {
        boostLevel = min(max(level, 0), 1)
        UserDefaults.standard.set(boostLevel, forKey: SettingsKey.boostLevel)
        apply()
    }

    func dimLevel(for display: DisplayInfo) -> Double { dimLevels[display.id] ?? 1 }

    /// Software dimming below the hardware minimum, from 25% to 100%.
    func setDimLevel(_ level: Double, for display: DisplayInfo) {
        let level = min(max(level, 0.25), 1)
        dimLevels[display.id] = level > 0.995 ? nil : level
        apply()
    }

    func setBrightness(_ value: Double, for display: DisplayInfo) {
        if DisplayServicesBridge.setBrightness(value, for: display.id) {
            brightness[display.id] = value
        }
    }

    func refreshBrightness() {
        var values: [CGDirectDisplayID: Double] = [:]
        for display in displays {
            values[display.id] = DisplayServicesBridge.brightness(display.id)
        }
        if values != brightness { brightness = values }
    }

    /// Restores every display to its calibrated colours. Called on quit.
    func restoreAll() {
        overlay.hideAll()
        if !appliedFactors.isEmpty { CGDisplayRestoreColorSyncSettings() }
        appliedFactors = [:]
        baseTables = [:]
    }

    // MARK: - Resolution

    private static let modeOptions = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue as Any] as CFDictionary

    func modes(for display: DisplayInfo, includeLowResolution: Bool) -> [DisplayModeOption] {
        guard let all = CGDisplayCopyAllDisplayModes(display.id, Self.modeOptions) as? [CGDisplayMode] else { return [] }
        let options = all.filter { $0.isUsableForDesktopGUI() }.map(DisplayModeOption.init)
        let hasHiDPI = options.contains(where: \.isHiDPI)
        var seen = Set<String>()
        return options
            .filter { includeLowResolution || !hasHiDPI || $0.isHiDPI }
            .filter { seen.insert("\($0.width)x\($0.height)@\(Int($0.refreshRate.rounded()))-\($0.isHiDPI)").inserted }
            .sorted { ($0.width, $0.refreshRate) > ($1.width, $1.refreshRate) }
    }

    func currentModeID(for display: DisplayInfo) -> Int32? {
        CGDisplayCopyDisplayMode(display.id)?.ioDisplayModeID
    }

    @discardableResult
    func setMode(_ option: DisplayModeOption, for display: DisplayInfo) -> Bool {
        guard let all = CGDisplayCopyAllDisplayModes(display.id, Self.modeOptions) as? [CGDisplayMode],
              let mode = all.first(where: { $0.ioDisplayModeID == option.id }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, display.id, mode, nil)
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    // MARK: - Internals

    private func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplayInfo(
                id: id,
                name: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                edrPotential: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
                pixelSize: CGSize(width: mode?.pixelWidth ?? 0, height: mode?.pixelHeight ?? 0),
                pointSize: screen.frame.size,
                refreshRate: mode?.refreshRate ?? 0
            )
        }
        let ids = Set(displays.map(\.id))
        dimLevels = dimLevels.filter { ids.contains($0.key) }
        refreshBrightness()
    }

    private func screensChanged() {
        refreshDisplays()
        // Display changes reset gamma tables, so capture fresh originals and apply again.
        baseTables = [:]
        appliedFactors = [:]
        apply()
    }

    private func periodicCheck() {
        checkSafety()
        // Re-apply if something (sleep, a colour profile change) reset the tables.
        for (id, factor) in appliedFactors where baseTables[id]?.isApplied(on: id, factor: factor) == false {
            baseTables = [:]
            appliedFactors = [:]
            apply()
            break
        }
        refreshBrightness()
    }

    private func checkSafety(applyChanges: Bool = true) {
        var reason: String?
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            reason = "Paused while your Mac cools down"
        } else if batteryFloor > 0, let battery = PowerSource.current(), !battery.onAC, battery.percent <= batteryFloor {
            reason = "Paused because the battery is below \(batteryFloor)%"
        }
        guard reason != boostPausedReason else { return }
        boostPausedReason = reason
        if applyChanges { apply() }
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    private func apply() {
        var factors: [CGDirectDisplayID: Float] = [:]
        for display in displays {
            var factor = dimLevels[display.id] ?? 1
            if isBoostActive && display.supportsBoost { factor *= boostFactor }
            if abs(factor - 1) > 0.001 { factors[display.id] = Float(factor) }
        }

        let boosted = isBoostActive ? displays.filter(\.supportsBoost) : []
        overlay.show(on: boosted.compactMap { display in screen(for: display.id).map { (display.id, $0) } }, value: boostFactor)

        guard !factors.isEmpty else {
            if !appliedFactors.isEmpty { CGDisplayRestoreColorSyncSettings() }
            appliedFactors = [:]
            baseTables = [:]
            return
        }
        if baseTables.isEmpty {
            CGDisplayRestoreColorSyncSettings()
            for display in displays { baseTables[display.id] = GammaTable(display: display.id) }
        }
        for display in displays {
            let factor = factors[display.id] ?? 1
            guard let base = baseTables[display.id], appliedFactors[display.id] != factor else { continue }
            base.apply(to: display.id, factor: factor)
        }
        appliedFactors = factors.merging(displays.filter { factors[$0.id] == nil }.map { ($0.id, Float(1)) }) { a, _ in a }
    }
}
