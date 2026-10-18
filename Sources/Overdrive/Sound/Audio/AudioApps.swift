import AppKit
import CoreAudio
import Foundation
import UniformTypeIdentifiers

/// An app that uses audio, with every process that plays sound for it. Browsers and
/// Electron apps play from helper processes, which are grouped under the app they belong to.
struct AudioApp: Identifiable, Equatable {
    let id: String
    let name: String
    let bundlePath: String?
    var processObjects: [AudioObjectID]
    var isPlaying: Bool

    var icon: NSImage {
        if let bundlePath { return IconCache.icon(forFile: bundlePath) }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

/// How one app should sound. Stored by app key (usually its bundle identifier).
struct AppRule: Codable, Equatable {
    var name: String
    var volume: Double = 1
    var useEQ = true

    var isDefault: Bool { abs(volume - 1) < 0.005 && useEQ }
}

extension HAL {
    static func processObjectIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func processPID(_ id: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    static func processIsRunningOutput(_ id: AudioObjectID) -> Bool {
        (uint32(id, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
    }
}

enum AudioAppScanner {
    /// Every app that has registered with Core Audio, playing apps first.
    static func scan() -> [AudioApp] {
        let ownPID = getpid()
        var apps: [String: AudioApp] = [:]
        for object in HAL.processObjectIDs() {
            guard let pid = HAL.processPID(object), pid != ownPID,
                  let identity = identity(pid: pid, bundleID: HAL.string(object, kAudioProcessPropertyBundleID))
            else { continue }
            let playing = HAL.processIsRunningOutput(object)
            if var app = apps[identity.key] {
                app.processObjects.append(object)
                app.isPlaying = app.isPlaying || playing
                apps[identity.key] = app
            } else {
                apps[identity.key] = AudioApp(
                    id: identity.key, name: identity.name, bundlePath: identity.path,
                    processObjects: [object], isPlaying: playing
                )
            }
        }
        return apps.values.sorted { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Finds the app a process belongs to: the outermost `.app` bundle in its path.
    private static func identity(pid: pid_t, bundleID: String?) -> (key: String, name: String, path: String?)? {
        if let url = NSRunningApplication(processIdentifier: pid)?.bundleURL ?? NSRunningApplication(processIdentifier: pid)?.executableURL {
            let components = url.pathComponents
            if let index = components.firstIndex(where: { $0.hasSuffix(".app") }) {
                let appPath = NSString.path(withComponents: Array(components[...index]))
                let key = Bundle(path: appPath)?.bundleIdentifier ?? appPath
                let name = FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
                return (key, name, appPath)
            }
        }
        // Safari and other WebKit apps play web audio from a shared system process.
        if let bundleID, bundleID.hasPrefix("com.apple.WebKit") {
            let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")?.path
            return ("com.apple.Safari", "Safari & Web Views", safari)
        }
        return nil
    }
}
