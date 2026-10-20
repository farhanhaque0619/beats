import SwiftUI
import Observation
import InkCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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

    /// False until accounts and cached mail have been read from disk. Until then RootView shows
    /// the plain launch background, so a returning user never sees the welcome screen flash by.
    private(set) var isReady = false

    init(store: MailStore, settings: AppSettings, screenshot: ScreenshotScene? = nil) {
        self.store = store
        self.settings = settings
        self.screenshot = screenshot
        self.isReady = screenshot != nil
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
        let model = AppModel(store: store, settings: settings)
        // Tapping a new-mail notification opens that conversation.
        Notifier.routeTaps { [weak model] target in model?.openNotification(target) }
        return model
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
    /// Set when the app goes to the background; the next activation catches up.
    @ObservationIgnored private var isInBackground = false
    /// Where "go to the next conversation" lands after the open thread leaves the list, worked
    /// out before it leaves (afterwards there's nothing to count from).
    @ObservationIgnored private var advanceTarget: (leavingID: String, nextID: String?)?
    /// Mac only: the loop behind new-mail notifications.
    @ObservationIgnored private var newMailWatch: Task<Void, Never>?

    /// Loads mail. Called from the root view; only the first call does anything.
    func start() async {
        guard screenshot == nil, !started else { return }
        started = true
        settings.apply(to: store)
        await store.load()
        isReady = true
        store.startLiveUpdates()
        #if os(iOS)
        // Launched in the background for a refresh earlier: what that run loaded may be hours old.
        if BackgroundRefresh.didRunThisLaunch { Task { await store.refresh() } }
        #elseif os(macOS)
        startNewMailWatch()
        #endif
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
        if action.removesFromList {
            rememberNeighbour(leaving: conversations)
            moveSelectionPast(conversations)
        }
        store.perform(action, on: conversations)
    }

    func snooze(until date: Date) {
        let targets = snoozeTargets
        isSnoozePickerPresented = false
        snoozeTargets = []
        guard !targets.isEmpty else { return }
        rememberNeighbour(leaving: targets)
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
        let remembered = advanceTarget?.leavingID == id ? advanceTarget : nil
        advanceTarget = nil
        let nextID: String?
        if let remembered {
            nextID = remembered.nextID
        } else if store.conversations.contains(where: { $0.id == id }) {
            nextID = conversation(after: id, offset: 1)?.id
        } else {
            // Gone already and nobody noted its neighbour: the list is the safe place to land.
            nextID = nil
        }
        if settings.advanceToNext, let nextID, nextID != id {
            phonePath = [nextID]
        } else if phonePath.last == id {
            phonePath.removeLast()
        }
        #endif
    }

    /// A tapped new-mail notification. On a cold launch it waits for mail to load, then clears
    /// whatever covers the list (search, the mailbox switcher, Settings) and opens the
    /// conversation. Compose stays put so nothing being written is lost.
    func openNotification(_ target: MailNotificationTarget) {
        guard screenshot == nil else { return }
        Task {
            await store.load()
            guard let conversation = Notifier.conversation(for: target, in: store) else { return }
            isSearchPresented = false
            isMailboxSwitcherPresented = false
            isCommandPalettePresented = false
            #if os(iOS)
            isSettingsPresented = false
            #endif
            open(conversation.id)
        }
    }

    /// `mailto:` links from messages open Compose.
    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "mailto" else { return }
        // Never replace a message that's being written.
        guard composeDraft == nil else {
            store.showToast(Toast(message: "Finish or close the message you're writing first.", systemImage: "square.and.pencil"))
            return
        }
        var draft = store.newDraft(accountID: store.scope.accountID)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var to = Self.addresses(in: components?.path ?? "")
        var body: String?
        for item in components?.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "to": to += Self.addresses(in: value)
            case "subject": draft.subject = value
            case "body": body = value
            case "cc": draft.cc = Self.addresses(in: value)
            case "bcc": draft.bcc = Self.addresses(in: value)
            default: break
            }
        }
        draft.to = to
        // The new draft's body is the signature block; the link's text goes above it.
        if let body, !body.isEmpty { draft.body = body + draft.body }
        composeDraft = draft
    }

    /// Valid addresses from a comma-separated `mailto:` list.
    private static func addresses(in list: String) -> [EmailAddress] {
        list.split(separator: ",")
            .map { EmailAddress(address: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter(\.isValid)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard screenshot == nil else { return }
        switch phase {
        case .active:
            let returning = isInBackground
            isInBackground = false
            // The first activation is `start()`'s job.
            guard started else { return }
            if returning {
                store.startLiveUpdates()
                Task {
                    await store.refresh()
                    if settings.notificationsEnabled { Notifier.withdrawRead(store: store) }
                }
            } else {
                // iPhone: inactive → active (Control Center, the app switcher, an alert) has nothing
                // to catch up on. Mac: switching back to Ink refreshes only if it's been a while;
                // the inbox stays live over IDLE meanwhile.
                #if os(macOS)
                if let last = store.lastSyncedAt, Date().timeIntervalSince(last) < 120 { return }
                Task { await store.refresh() }
                #endif
            }
        case .background:
            guard !isInBackground else { return }
            isInBackground = true
            store.stopLiveUpdates()
            flushBeforeSuspension()
            if settings.notificationsEnabled { Notifier.withdrawRead(store: store) }
            Notifier.updateBadge(count: settings.notificationsEnabled ? store.unreadCount(for: .allInboxes) : 0)
            #if os(iOS)
            BackgroundRefresh.noteLeftForeground()
            if BackgroundRefresh.hasRealAccounts(store) { BackgroundRefresh.schedule() }
            #endif
        default:
            break
        }
    }

    /// Sends what's waiting out its Undo window and commits pending triage. On iPhone this asks
    /// for background time first: without it iOS suspends Ink within seconds and a message sent
    /// just before leaving would sit in the outbox until the next launch.
    private func flushBeforeSuspension() {
        #if os(iOS)
        let backgroundTime = BackgroundTime(name: "Send and save mail")
        Task {
            await store.flushPendingActions()
            backgroundTime.end()
        }
        #else
        Task { await store.flushPendingActions() }
        #endif
    }

    /// Notes where to go next if the open thread is among `removed` (iPhone).
    private func rememberNeighbour(leaving removed: [Conversation]) {
        #if os(iOS)
        let ids = Set(removed.map(\.id))
        guard let focused = phonePath.last, ids.contains(focused) else { return }
        let list = store.conversations
        guard let index = list.firstIndex(where: { $0.id == focused }) else {
            advanceTarget = (leavingID: focused, nextID: nil)
            return
        }
        let after = list[(index + 1)...].first { !ids.contains($0.id) }
        let before = list[..<index].last { !ids.contains($0.id) }
        advanceTarget = (leavingID: focused, nextID: (after ?? before)?.id)
        #endif
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

// MARK: - Mac new-mail notifications

#if os(macOS)
extension AppModel {
    /// Checks at least this often while Ink isn't the active app.
    private static let newMailCheckInterval: TimeInterval = 5 * 60

    /// The Mac has no background refresh, but Ink keeps running behind other apps and with its
    /// window closed. While it isn't the active app, check the inboxes every few minutes (within
    /// half a minute when the live connection brings in unread mail) and announce mail that
    /// arrived since you last looked.
    private func startNewMailWatch() {
        guard newMailWatch == nil else { return }
        newMailWatch = Task { [weak self] in
            var lastActive = Date()
            var lastCheck = Date()
            var lastUnread: Int?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                if NSApplication.shared.isActive {
                    lastActive = now
                    lastUnread = nil
                    continue
                }
                guard self.settings.notificationsEnabled, self.store.hasAccounts else { continue }
                let unread = self.store.unreadCount(for: .allInboxes)
                let unreadRose = lastUnread.map { unread > $0 } ?? false
                lastUnread = unread
                guard unreadRose || now.timeIntervalSince(lastCheck) >= Self.newMailCheckInterval else { continue }
                lastCheck = now
                let arrived = await self.store.refreshAllInboxes()
                lastUnread = self.store.unreadCount(for: .allInboxes)
                // Seen while Ink was in front (give or take a check): not news.
                let cutoff = lastActive.addingTimeInterval(-60)
                guard !NSApplication.shared.isActive, self.settings.notificationsEnabled else { continue }
                Notifier.notify(newMessages: arrived.filter { $0.receivedDate > cutoff }, store: self.store)
            }
        }
    }
}
#endif

#if os(iOS)
/// Background execution time for finishing work after the app leaves the screen. Ended
/// explicitly, or by iOS's expiration handler just before the time runs out.
@MainActor
private final class BackgroundTime {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Called on the main thread when the time is up: end it now or iOS ends the app.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
