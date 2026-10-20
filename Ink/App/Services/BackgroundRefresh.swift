#if os(iOS)
import Foundation
import BackgroundTasks
import InkCore

/// Checks for new mail while Ink is in the background (BGAppRefreshTask) and posts notifications.
///
/// The app scene runs the task with `.backgroundTask(.appRefresh(BackgroundRefresh.identifier))`,
/// which also registers the identifier with BGTaskScheduler; this type only schedules requests
/// and does the work. The identifier must be listed under `BGTaskSchedulerPermittedIdentifiers`.
/// When iOS ends the run early, SwiftUI cancels the task, which closes any open connection.
@MainActor
enum BackgroundRefresh {
    nonisolated static let identifier = "\(Bundle.main.bundleIdentifier ?? "io.github.farhanhaque0619.ink").refresh"

    /// How long iOS should wait at least before the next refresh.
    private static let interval: TimeInterval = 15 * 60
    /// When Ink last left the screen. Mail that arrived before then was in the list already.
    private static let leftForegroundKey = "ink.leftForegroundAt"
    /// Mail that arrived this close before leaving may not have reached the list yet: still announce it.
    private static let foregroundGrace: TimeInterval = 60

    private static var store: MailStore?
    private static var settings: AppSettings?

    /// True once a refresh has run in this process. The app was then launched in the background
    /// and its first screen should catch up rather than trust what that run loaded.
    private(set) static var didRunThisLaunch = false

    /// Remembers the app's store and settings for refreshes that run without UI.
    static func register(store: MailStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    /// Asks iOS for the next refresh. Replaces any pending request; failures (simulator,
    /// Background App Refresh turned off) are ignored because there's nothing to do about them.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Called as Ink goes to the background, so the next refresh doesn't announce mail that was
    /// already on screen (still unread, but seen).
    static func noteLeftForeground(at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: leftForegroundKey)
    }

    /// The refresh itself: queue the next one, sync every inbox, notify about new mail, and send
    /// any triage still waiting in the undo window.
    static func handleAppRefresh() async {
        schedule()
        guard let store else { return }
        didRunThisLaunch = true
        // A background launch doesn't show any UI, so nothing has loaded the accounts yet.
        if !store.hasAccounts { await store.load() }
        guard hasRealAccounts(store) else {
            // Nothing to check (no accounts, or only the demo inbox): stop waking up for it.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        guard !Task.isCancelled else { return }

        let newMessages = await store.refreshAllInboxes()
        let notificationsOn = settings?.notificationsEnabled == true
        if notificationsOn {
            Notifier.notify(newMessages: unseen(newMessages), store: store)
            Notifier.withdrawRead(store: store)
        }
        Notifier.updateBadge(count: notificationsOn ? store.unreadCount(for: .allInboxes) : 0)
        await store.flushPendingActions()
    }

    /// Whether there's a mail account worth checking (the demo inbox never gets new mail).
    static func hasRealAccounts(_ store: MailStore) -> Bool {
        store.accounts.contains { !$0.isDemo }
    }

    /// Drops messages that arrived while Ink was on screen.
    private static func unseen(_ messages: [MessageSummary]) -> [MessageSummary] {
        guard let left = UserDefaults.standard.object(forKey: leftForegroundKey) as? Date else { return messages }
        let cutoff = left.addingTimeInterval(-foregroundGrace)
        return messages.filter { $0.receivedDate > cutoff }
    }
}
#endif
