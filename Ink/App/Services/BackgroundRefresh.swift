#if os(iOS)
import Foundation
import BackgroundTasks
import InkCore

/// Checks for new mail while Ink is in the background (BGAppRefreshTask) and posts notifications.
///
/// The app scene runs the task with `.backgroundTask(.appRefresh(BackgroundRefresh.identifier))`,
/// which also registers the identifier with BGTaskScheduler; this type only schedules requests
/// and does the work. The identifier must be listed under `BGTaskSchedulerPermittedIdentifiers`.
@MainActor
enum BackgroundRefresh {
    nonisolated static let identifier = "\(Bundle.main.bundleIdentifier ?? "io.github.farhanhaque0619.ink").refresh"

    /// How long iOS should wait at least before the next refresh.
    private static let interval: TimeInterval = 15 * 60

    private static var store: MailStore?
    private static var settings: AppSettings?

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

    /// The refresh itself: queue the next one, sync every inbox, notify about new mail, and send
    /// any triage still waiting in the undo window.
    static func handleAppRefresh() async {
        schedule()
        guard let store else { return }
        // A background launch doesn't show any UI, so nothing has loaded the accounts yet.
        if !store.hasAccounts { await store.load() }
        guard store.hasAccounts, !Task.isCancelled else { return }

        let newMessages = await store.refreshAllInboxes()
        if settings?.notificationsEnabled == true {
            Notifier.notify(newMessages: newMessages, store: store)
        }
        await store.flushPendingActions()
    }
}
#endif
