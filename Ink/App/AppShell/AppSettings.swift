import SwiftUI
import Observation
import InkCore

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum ReadingFont: String, CaseIterable, Identifiable, Codable {
    case sans, serif
    var id: String { rawValue }
    var title: String { self == .sans ? "SF Pro" : "New York" }
}

enum ListDensity: String, CaseIterable, Identifiable, Codable {
    case comfortable, compact
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// User preferences, saved to UserDefaults. Read them from the environment:
/// `@Environment(AppSettings.self) private var settings`.
@MainActor
@Observable
final class AppSettings {
    var accent: AccentTint { didSet { save(accent.rawValue, "accent") } }
    var appearance: AppearanceMode { didSet { save(appearance.rawValue, "appearance") } }
    var swipes: SwipeConfiguration { didSet { saveCodable(swipes, "swipes") } }
    /// Seconds before a sent message actually leaves (0 turns Undo Send off).
    var undoSendDelay: Int { didSet { save(undoSendDelay, "undoSendDelay") } }
    /// Off by default: remote images are how senders track opens.
    var loadRemoteImages: Bool { didSet { save(loadRemoteImages, "loadRemoteImages") } }
    var readingFont: ReadingFont { didSet { save(readingFont.rawValue, "readingFont") } }
    var density: ListDensity { didSet { save(density.rawValue, "density") } }
    var showAvatars: Bool { didSet { save(showAvatars, "showAvatars") } }
    /// Split the inbox into Focus (people) and Other (newsletters, notifications).
    var focusedInbox: Bool { didSet { save(focusedInbox, "focusedInbox") } }
    /// Lines of preview text in the list (0, 1 or 2).
    var previewLines: Int { didSet { save(previewLines, "previewLines") } }
    var markReadOnOpen: Bool { didSet { save(markReadOnOpen, "markReadOnOpen") } }
    var notificationsEnabled: Bool { didSet { save(notificationsEnabled, "notificationsEnabled") } }
    /// After archiving from the reader, go to the next conversation instead of back to the list.
    var advanceToNext: Bool { didSet { save(advanceToNext, "advanceToNext") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: String) -> String? { defaults.string(forKey: "ink.\(key)") }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: "ink.\(key)") as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: "ink.\(key)") as? Int ?? fallback }

        accent = string("accent").flatMap(AccentTint.init(rawValue:)) ?? .electric
        appearance = string("appearance").flatMap(AppearanceMode.init(rawValue:)) ?? .system
        if let data = defaults.data(forKey: "ink.swipes"), let decoded = try? JSONDecoder().decode(SwipeConfiguration.self, from: data) {
            swipes = decoded
        } else {
            swipes = .standard
        }
        undoSendDelay = int("undoSendDelay", 5)
        loadRemoteImages = bool("loadRemoteImages", false)
        readingFont = string("readingFont").flatMap(ReadingFont.init(rawValue:)) ?? .sans
        density = string("density").flatMap(ListDensity.init(rawValue:)) ?? .comfortable
        showAvatars = bool("showAvatars", true)
        focusedInbox = bool("focusedInbox", true)
        previewLines = int("previewLines", 2)
        markReadOnOpen = bool("markReadOnOpen", true)
        notificationsEnabled = bool("notificationsEnabled", false)
        advanceToNext = bool("advanceToNext", false)
    }

    /// Pushes the settings the store cares about into it.
    func apply(to store: MailStore) {
        store.undoSendDelay = TimeInterval(undoSendDelay)
        store.focusedInboxEnabled = focusedInbox
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: "ink.\(key)") }
    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "ink.\(key)") }
    }
}
