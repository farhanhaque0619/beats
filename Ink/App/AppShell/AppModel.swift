import SwiftUI
import Observation
import InkCore

/// Scenes the app can open straight into for automated screenshots
/// (`-InkScreenshot <scene>` launch argument). They always use the in-memory demo store.
enum ScreenshotScene: String, CaseIterable {
    case welcome, inbox, swipe, thread, compose, search, settings, snooze, mailboxes
    case macInbox = "mac-inbox"

    static var current: ScreenshotScene? {
        UserDefaults.standard.string(forKey: "InkScreenshot").flatMap(ScreenshotScene.init(rawValue:))
    }
}

/// App-wide UI state: navigation, what's presented, and actions that span screens. Views read
/// it with `@Environment(AppModel.self)`; the mail itself lives in `MailStore`.
@MainActor
@Observable
final class AppModel {
    let store: MailStore
    let settings: AppSettings
    let screenshot: ScreenshotScene?

    // MARK: Navigation

    /// iPhone: conversation IDs pushed onto the inbox's NavigationStack.
    var phonePath: [String] = []
    /// Mac (and iPad): selected conversations in the list.
    var selection: Set<String> = []

    /// The one conversation shown in the Mac detail column.
    var focusedConversationID: String? { selection.count == 1 ? selection.first : nil }

    // MARK: Presentation

    /// Non-nil presents Compose.
    var composeDraft: OutgoingMessage?
    /// Conversations waiting for a snooze time; the picker is shown while this is non-empty.
    var snoozeTargets: [Conversation] = []
    var isSnoozePickerPresented = false
    var isSearchPresented = false
    var isSettingsPresented = false
    var isMailboxSwitcherPresented = false
    var isAddAccountPresented = false
    var isCommandPalettePresented = false

    init(store: MailStore, settings: AppSettings, screenshot: ScreenshotScene? = nil) {
        self.store = store
        self.settings = settings
        self.screenshot = screenshot
    }

    /// The real app: Keychain, Application Support, live connections. Or the demo store when
    /// launched for screenshots.
    static func make() -> AppModel {
        if let scene = ScreenshotScene.current {
            return forScreenshots(scene)
        }
        let settings = AppSettings()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Ink", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = MailStoreEnvironment(
            storageDirectory: directory,
            credentials: KeychainCredentialStore(),
            transportFactory: { URLSessionMailTransport() }
        )
        let store = MailStore(environment: environment)
        settings.apply(to: store)
        #if os(iOS)
        BackgroundRefresh.register(store: store, settings: settings)
        #endif
        return AppModel(store: store, settings: settings)
    }

    static func forScreenshots(_ scene: ScreenshotScene) -> AppModel {
        let store = MailStore.preview()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ink.screenshots") ?? .standard)
        settings.apply(to: store)
        let model = AppModel(store: store, settings: settings, screenshot: scene)
        model.prepareScreenshot()
        return model
    }

    @ObservationIgnored private var started = false

    /// Loads mail. Called from the root view; only the first call does anything.
    func start() async {
        guard screenshot == nil, !started else { return }
        started = true
        settings.apply(to: store)
        await store.load()
        store.startLiveUpdates()
    }

    // MARK: Actions

    func compose(_ draft: OutgoingMessage? = nil) {
        composeDraft = draft ?? store.newDraft(accountID: store.scope.accountID)
    }

    func reply(to message: MessageSummary, mode: ReplyMode) {
        composeDraft = store.draft(replyingTo: message, mode: mode, body: store.cachedBody(for: message))
    }

    /// Opens a conversation: pushes it on iPhone, selects it on Mac.
    func open(_ conversationID: String) {
        #if os(iOS)
        if phonePath.last != conversationID { phonePath.append(conversationID) }
        #else
        selection = [conversationID]
        #endif
    }

    /// Runs a swipe/shortcut action. Snooze asks for a time first.
    func perform(_ action: SwipeAction, on conversations: [Conversation]) {
        guard action != .none, !conversations.isEmpty else { return }
        if action == .snooze {
            snoozeTargets = conversations
            isSnoozePickerPresented = true
            return
        }
        if action.removesFromList { moveSelectionPast(conversations) }
        store.perform(action, on: conversations)
    }

    func snooze(until date: Date) {
        let targets = snoozeTargets
        isSnoozePickerPresented = false
        snoozeTargets = []
        guard !targets.isEmpty else { return }
        moveSelectionPast(targets)
        store.snooze(targets, until: date)
    }

    func cancelSnooze() {
        isSnoozePickerPresented = false
        snoozeTargets = []
    }

    func select(scope: MailScope) {
        store.scope = scope
        selection = []
        phonePath = []
        Task { await store.refresh() }
    }

    /// The conversation `offset` places after `id` in the current list (negative = before).
    func conversation(after id: String?, offset: Int) -> Conversation? {
        let list = store.conversations
        guard !list.isEmpty else { return nil }
        guard let id, let index = list.firstIndex(where: { $0.id == id }) else {
            return offset >= 0 ? list.first : list.last
        }
        let target = index + offset
        return list.indices.contains(target) ? list[target] : nil
    }

    /// After archiving from the reader, either advance (setting) or go back to the list.
    func didRemoveFocusedConversation(_ id: String) {
        #if os(iOS)
        if settings.advanceToNext, let next = conversation(after: id, offset: 1) {
            phonePath = [next.id]
        } else if phonePath.last == id {
            phonePath.removeLast()
        }
        #endif
    }

    /// `mailto:` links from messages open Compose.
    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "mailto" else { return }
        var draft = store.newDraft(accountID: store.scope.accountID)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let to = (components?.path ?? "").removingPercentEncoding ?? ""
        draft.to = to.split(separator: ",").map { EmailAddress(address: String($0)) }.filter(\.isValid)
        for item in components?.queryItems ?? [] {
            switch item.name.lowercased() {
            case "subject": draft.subject = item.value ?? ""
            case "body": draft.body = item.value ?? ""
            case "cc": draft.cc = (item.value ?? "").split(separator: ",").map { EmailAddress(address: String($0)) }
            case "bcc": draft.bcc = (item.value ?? "").split(separator: ",").map { EmailAddress(address: String($0)) }
            default: break
            }
        }
        composeDraft = draft
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard screenshot == nil else { return }
        switch phase {
        case .active:
            store.startLiveUpdates()
            Task { await store.refresh() }
        case .background:
            store.stopLiveUpdates()
            Task { await store.flushPendingActions() }
            #if os(iOS)
            BackgroundRefresh.schedule()
            #endif
        default:
            break
        }
    }

    /// Keeps the Mac selection on a neighbour when the selected conversation leaves the list.
    private func moveSelectionPast(_ removed: [Conversation]) {
        #if os(macOS)
        let ids = Set(removed.map(\.id))
        guard !selection.isDisjoint(with: ids) else { return }
        let list = store.conversations
        if let lastIndex = list.lastIndex(where: { ids.contains($0.id) }) {
            let after = list[(lastIndex + 1)...].first { !ids.contains($0.id) }
            let before = list[..<lastIndex].last { !ids.contains($0.id) }
            selection = (after ?? before).map { [$0.id] } ?? []
        }
        #endif
    }

    // MARK: Screenshots

    private func prepareScreenshot() {
        guard let screenshot else { return }
        let threaded = store.conversations.first { $0.count >= 3 } ?? store.conversations.first
        switch screenshot {
        case .welcome, .inbox, .swipe, .mailboxes:
            if screenshot == .mailboxes { isMailboxSwitcherPresented = true }
        case .thread:
            if let threaded { phonePath = [threaded.id] }
        case .compose:
            if let message = threaded?.messages.last {
                var draft = store.draft(replyingTo: message, mode: .reply, body: store.cachedBody(for: message))
                draft.body = "Sounds great — Thursday works for me. I'll bring the revised deck.\n\nAlex"
                composeDraft = draft
            } else {
                compose()
            }
        case .search:
            isSearchPresented = true
        case .settings:
            isSettingsPresented = true
        case .snooze:
            if let first = store.conversations.first {
                snoozeTargets = [first]
                isSnoozePickerPresented = true
            }
        case .macInbox:
            if let threaded { selection = [threaded.id] }
        }
    }
}
