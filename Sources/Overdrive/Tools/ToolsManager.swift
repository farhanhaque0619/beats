import AppKit
import CoreAudio
import Foundation
import IOKit.pwr_mgt

/// Small power-user switches: keep the Mac awake, mute the microphone, Finder and Dock
/// preferences, and one-click fixes like restarting the Dock.
@MainActor
final class ToolsManager: ObservableObject {
    struct Toggles: Equatable {
        var showHiddenFiles = false
        var showExtensions = false
        var hideDesktopIcons = false
        var dockAutohide = false
    }

    struct KeepAwakeChoice: Identifiable {
        let title: String
        let minutes: Int?
        var id: String { title }
    }

    static let keepAwakeChoices: [KeepAwakeChoice] = [
        KeepAwakeChoice(title: "15 Minutes", minutes: 15),
        KeepAwakeChoice(title: "30 Minutes", minutes: 30),
        KeepAwakeChoice(title: "1 Hour", minutes: 60),
        KeepAwakeChoice(title: "2 Hours", minutes: 120),
        KeepAwakeChoice(title: "4 Hours", minutes: 240),
        KeepAwakeChoice(title: "Until I Turn It Off", minutes: nil),
    ]

    @Published private(set) var keepAwakeUntil: Date?
    @Published private(set) var isMicMuted = false
    @Published private(set) var hasMicrophone = false
    @Published private(set) var toggles = Toggles()
    @Published private(set) var message: String?
    @Published private(set) var isDarkMode = false
    @Published private(set) var localAddress: String?
    @Published private(set) var publicAddress: String?
    @Published private(set) var isLookingUpPublicAddress = false

    private var assertionID: IOPMAssertionID = 0
    private var expiryTimer: Timer?
    private var savedInputVolume: Float32?
    private var messageTask: Task<Void, Never>?

    var isKeepingAwake: Bool { keepAwakeUntil != nil }
    var allowsDisplaySleep: Bool { UserDefaults.standard.bool(forKey: SettingsKey.keepAwakeAllowsDisplaySleep) }

    init() {
        refreshMicrophone()
        refreshToggles()
        refreshAppearance()
        HAL.observeSystem(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            Task { @MainActor in self?.refreshMicrophone() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAppearance() }
        }
    }

    // MARK: - Keep Awake

    /// Keeps the Mac (and, unless allowed to sleep, the display) awake. nil means indefinitely.
    func keepAwake(minutes: Int?) {
        releaseAssertion()
        let type = allowsDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Overdrive Keep Awake" as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            show("Couldn’t keep the Mac awake.")
            return
        }
        if let minutes {
            let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
            keepAwakeUntil = until
            expiryTimer = Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.stopKeepingAwake() }
            }
        } else {
            keepAwakeUntil = .distantFuture
        }
    }

    func stopKeepingAwake() {
        releaseAssertion()
        keepAwakeUntil = nil
    }

    /// Re-creates the assertion after the display-sleep preference changes.
    func keepAwakePreferenceChanged() {
        guard let until = keepAwakeUntil else { return }
        let minutes = until == .distantFuture ? nil : max(Int(until.timeIntervalSinceNow / 60), 1)
        keepAwake(minutes: minutes)
    }

    private func releaseAssertion() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    // MARK: - Microphone

    func refreshMicrophone() {
        guard let input = HAL.defaultInputDeviceID() else {
            hasMicrophone = false
            isMicMuted = false
            return
        }
        hasMicrophone = true
        if let muted = HAL.inputMuted(input) {
            isMicMuted = muted
        } else {
            isMicMuted = (HAL.inputVolume(input) ?? 1) < 0.001
        }
    }

    func setMicMuted(_ muted: Bool) {
        guard let input = HAL.defaultInputDeviceID() else { return }
        if HAL.setInputMuted(input, muted) {
            isMicMuted = muted
            return
        }
        // No mute switch on this device: set its input volume to zero instead.
        if muted {
            savedInputVolume = HAL.inputVolume(input)
            HAL.setInputVolume(input, 0)
        } else {
            HAL.setInputVolume(input, savedInputVolume ?? 0.75)
        }
        refreshMicrophone()
    }

    // MARK: - Finder and Dock

    func refreshToggles() {
        toggles = Toggles(
            showHiddenFiles: Self.bool("AppleShowAllFiles", app: "com.apple.finder"),
            showExtensions: Self.globalBool("AppleShowAllExtensions"),
            hideDesktopIcons: !(Self.optionalBool("CreateDesktop", app: "com.apple.finder") ?? true),
            dockAutohide: Self.bool("autohide", app: "com.apple.dock")
        )
    }

    func setShowHiddenFiles(_ on: Bool) {
        toggles.showHiddenFiles = on
        run(["/usr/bin/defaults", "write", "com.apple.finder", "AppleShowAllFiles", "-bool", on ? "true" : "false"], then: ["/usr/bin/killall", "Finder"])
    }

    func setShowExtensions(_ on: Bool) {
        toggles.showExtensions = on
        run(["/usr/bin/defaults", "write", "-g", "AppleShowAllExtensions", "-bool", on ? "true" : "false"], then: ["/usr/bin/killall", "Finder"])
    }

    func setHideDesktopIcons(_ hide: Bool) {
        toggles.hideDesktopIcons = hide
        run(["/usr/bin/defaults", "write", "com.apple.finder", "CreateDesktop", "-bool", hide ? "false" : "true"], then: ["/usr/bin/killall", "Finder"])
    }

    func setDockAutohide(_ on: Bool) {
        toggles.dockAutohide = on
        run(["/usr/bin/defaults", "write", "com.apple.dock", "autohide", "-bool", on ? "true" : "false"], then: ["/usr/bin/killall", "Dock"])
    }

    // MARK: - Quick actions

    func sleepDisplays() { run(["/usr/bin/pmset", "displaysleepnow"]) }

    func restartDock() {
        run(["/usr/bin/killall", "Dock"])
        show("Restarted the Dock.")
    }

    func restartFinder() {
        run(["/usr/bin/killall", "Finder"])
        show("Restarted Finder.")
    }

    func restartMenuBar() {
        run(["/usr/bin/killall", "SystemUIServer", "ControlCenter"])
        show("Restarted the menu bar.")
    }

    func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    func ejectAllDisks() {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let ejectable = volumes.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsRootFileSystem != true else { return false }
            return values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false
        }
        guard !ejectable.isEmpty else {
            show("There are no disks to eject.")
            return
        }
        Task {
            let failures = await Task.detached(priority: .userInitiated) { () -> Int in
                var failures = 0
                for url in ejectable {
                    do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch { failures += 1 }
                }
                return failures
            }.value
            let ejected = ejectable.count - failures
            if failures == 0 {
                show(ejected == 1 ? "Ejected 1 disk." : "Ejected \(ejected) disks.")
            } else {
                show("Ejected \(ejected) of \(ejectable.count). A disk that’s in use can’t be ejected.")
            }
        }
    }

    // MARK: - Appearance and session

    func refreshAppearance() {
        let style = CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        isDarkMode = style == "Dark"
    }

    /// Switches the whole Mac between light and dark. macOS asks once for permission to
    /// control System Events, the app that owns this setting.
    func toggleDarkMode() {
        let target = !isDarkMode
        isDarkMode = target
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                Self.execute(["/usr/bin/osascript", "-e",
                              "tell application \"System Events\" to tell appearance preferences to set dark mode to \(target)"])
            }.value
            if !ok {
                refreshAppearance()
                show("Allow Overdrive to control System Events in Privacy & Security › Automation.")
            }
        }
    }

    /// Locks the Mac the same way Control Center's Lock Screen does.
    func lockScreen() {
        typealias LockFn = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: LockFn.self)()
        } else {
            sleepDisplays()
        }
    }

    func takeScreenshot() {
        run(["/usr/bin/open", "-a", "Screenshot"])
    }

    func emptyTrash() {
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                Self.execute(["/usr/bin/osascript", "-e", "tell application \"Finder\" to empty trash"])
            }.value
            show(ok ? "Emptied the Trash." : "Allow Overdrive to control Finder in Privacy & Security › Automation.")
        }
    }

    // MARK: - Network

    func refreshAddresses() {
        localAddress = Self.localIPv4()
    }

    func lookUpPublicAddress() {
        guard !isLookingUpPublicAddress else { return }
        isLookingUpPublicAddress = true
        Task {
            defer { isLookingUpPublicAddress = false }
            guard let url = URL(string: "https://api.ipify.org") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text.count < 64 {
                publicAddress = text
            } else {
                show("Couldn’t look up your public address. Check your internet connection.")
            }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("Copied \(text).")
    }

    /// The Mac's address on the local network (Wi-Fi or Ethernet).
    private static func localIPv4() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var found: [(name: String, address: String)] = []
        while let entry = cursor {
            let interface = entry.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if name.hasPrefix("en"),
                   getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found.append((name, String(cString: host)))
                }
            }
            cursor = interface.ifa_next
        }
        return found.sorted { $0.name < $1.name }.first?.address
    }

    // MARK: - Helpers

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    private func run(_ command: [String], then next: [String]? = nil) {
        Task.detached(priority: .userInitiated) {
            Self.execute(command)
            if let next { Self.execute(next) }
        }
    }

    @discardableResult
    nonisolated private static func execute(_ command: [String]) -> Bool {
        guard let path = command.first else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Array(command.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func optionalBool(_ key: String, app: String) -> Bool? {
        CFPreferencesAppSynchronize(app as CFString)
        return CFPreferencesCopyAppValue(key as CFString, app as CFString) as? Bool
    }

    private static func bool(_ key: String, app: String) -> Bool {
        optionalBool(key, app: app) ?? false
    }

    private static func globalBool(_ key: String) -> Bool {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool ?? false
    }
}

extension HAL {
    static func defaultInputDeviceID() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func inputMuted(_ id: AudioObjectID) -> Bool? {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    static func setInputMuted(_ id: AudioObjectID, _ muted: Bool) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    static func inputVolume(_ id: AudioObjectID) -> Float32? {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setInputVolume(_ id: AudioObjectID, _ volume: Float32) {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput)
        var value = min(max(volume, 0), 1)
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}
