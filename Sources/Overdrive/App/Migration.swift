import AppKit
import Foundation
import ServiceManagement

/// Overdrive used to be called Bassline. Version 1.x updates itself by copying
/// `Bassline.app` out of the DMG, so the DMG carries a hidden copy under that name. When that
/// copy launches, it renames itself to Overdrive.app and relaunches from there. Settings carry
/// over because the bundle identifier never changed.
enum LegacyMigration {
    private static let legacyName = "Bassline.app"
    private static let currentName = "Overdrive.app"
    private static let migratedKey = "migratedFromBassline"

    /// Returns true when this process should exit because a relaunch is on its way.
    static func runIfNeeded() -> Bool {
        let fileManager = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        makeVisible(bundleURL)

        if bundleURL.lastPathComponent == legacyName {
            let target = bundleURL.deletingLastPathComponent().appendingPathComponent(currentName)
            do {
                if fileManager.fileExists(atPath: target.path) {
                    // Overdrive is already installed next to us: keep it and retire this copy.
                    try fileManager.trashItem(at: bundleURL, resultingItemURL: nil)
                } else {
                    try fileManager.moveItem(at: bundleURL, to: target)
                }
                makeVisible(target)
                UserDefaults.standard.set(true, forKey: migratedKey)
                relaunch(target)
                return true
            } catch {
                return false
            }
        }

        // Installed by hand next to an old Bassline.app: move the old copy to the Trash.
        let legacy = bundleURL.deletingLastPathComponent().appendingPathComponent(legacyName)
        if bundleURL.lastPathComponent == currentName,
           fileManager.fileExists(atPath: legacy.path),
           Bundle(url: legacy)?.bundleIdentifier == Bundle.main.bundleIdentifier {
            try? fileManager.trashItem(at: legacy, resultingItemURL: nil)
        }

        // The login item pointed at the old name; register it again under the new one.
        if UserDefaults.standard.bool(forKey: migratedKey) {
            UserDefaults.standard.removeObject(forKey: migratedKey)
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
                try? SMAppService.mainApp.register()
            }
        }
        return false
    }

    private static func makeVisible(_ url: URL) {
        var url = url
        guard (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true else { return }
        var values = URLResourceValues()
        values.isHidden = false
        try? url.setResourceValues(values)
    }

    private static func relaunch(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$APP\""]
        process.environment = ["APP": url.path]
        try? process.run()
    }
}
