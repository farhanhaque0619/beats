import AppKit
import Foundation

/// Checks this app's GitHub releases and can install a newer build in place.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let notes: String
        let dmgURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        case failed(String)
    }

    static let repository = "farhanhaque0619/beats"
    static let repositoryURL = URL(string: "https://github.com/\(repository)")!
    static let releasesURL = URL(string: "https://github.com/\(repository)/releases/latest")!

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    init() {
        lastChecked = UserDefaults.standard.object(forKey: SettingsKey.lastUpdateCheck) as? Date
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var availableRelease: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    /// Checks once a day in the background when automatic checks are on.
    func checkIfDue() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.autoCheckUpdates) else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 60 * 60 * 24 { return }
        Task { await check() }
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(GitHubRelease.self, from: data)

            let now = Date()
            lastChecked = now
            UserDefaults.standard.set(now, forKey: SettingsKey.lastUpdateCheck)

            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            if Self.isVersion(version, newerThan: currentVersion),
               let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
               let dmgURL = URL(string: asset.browserDownloadUrl),
               let pageURL = URL(string: release.htmlUrl) {
                state = .available(Release(version: version, notes: release.body ?? "", dmgURL: dmgURL, pageURL: pageURL))
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed("Couldn’t reach GitHub. Check your internet connection and try again.")
        }
    }

    /// Downloads the DMG, replaces this copy of the app, and relaunches it.
    func install(_ release: Release) async {
        state = .installing(release)
        let appPath = Bundle.main.bundlePath
        do {
            let (downloaded, _) = try await URLSession.shared.download(from: release.dmgURL)
            let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("Overdrive-\(release.version).dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: downloaded, to: dmg)

            try await Task.detached {
                try Self.runInstaller(dmgPath: dmg.path, appPath: appPath)
            }.value

            Self.relaunch(appPath: appPath)
        } catch {
            state = .failed("The update couldn’t be installed automatically. Download the DMG and drag Overdrive into Applications instead.")
        }
    }

    // MARK: - Helpers

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated private static func runInstaller(dmgPath: String, appPath: String) throws {
        let script = """
        set -euo pipefail
        MOUNT=$(mktemp -d /tmp/bassline-update.XXXXXX)
        hdiutil attach "$DMG" -nobrowse -noverify -noautoopen -quiet -mountpoint "$MOUNT"
        trap 'hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true' EXIT
        SRC="$MOUNT/Overdrive.app"
        [ -d "$SRC" ] || SRC=$(find "$MOUNT" -maxdepth 1 -name '*.app' -print -quit)
        [ -n "$SRC" ] && [ -d "$SRC" ]
        rm -rf "$APP.new"
        ditto "$SRC" "$APP.new"
        chflags nohidden "$APP.new" 2>/dev/null || true
        xattr -dr com.apple.quarantine "$APP.new" 2>/dev/null || true
        rm -rf "$APP"
        mv "$APP.new" "$APP"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.environment = ["DMG": dmgPath, "APP": appPath, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private static func relaunch(appPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$APP\""]
        process.environment = ["APP": appPath]
        try? process.run()
        NSApp.terminate(nil)
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
    }

    let tagName: String
    let htmlUrl: String
    let body: String?
    let assets: [Asset]
}
