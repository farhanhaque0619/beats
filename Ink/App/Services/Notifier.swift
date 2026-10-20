import Foundation
import UserNotifications
import InkCore

/// What a tapped new-mail notification points at. The conversation ID is the one the message had
/// when the notification was posted; the message key (`MessageSummary.dedupeKey`) finds it again
/// if threading has moved it since.
struct MailNotificationTarget: Sendable, Equatable {
    var conversationID: String?
    var messageKey: String?
}

/// Local notifications for new mail and the app icon badge. Ink has no server, so there is no
/// push: notifications are posted by the app itself after a background refresh (iPhone) or a
/// check while it isn't the active app (Mac).
@MainActor
enum Notifier {
    /// More new messages than this arrive as one summary notification instead of a stack.
    private static let individualLimit = 5
    private static let router = NotificationRouter()
    fileprivate static var openTarget: (@MainActor (MailNotificationTarget) -> Void)?

    /// Asks for permission to show alerts, play sounds and badge the icon. Returns whether alerts
    /// are allowed.
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Posts a notification for each new unread message from a person (newsletters and
    /// notifications in Other stay quiet), grouped per conversation. More than a handful at once
    /// become a single summary. Mail in the demo inbox never notifies.
    static func notify(newMessages: [MessageSummary], store: MailStore) {
        var seen = Set<String>()
        let fresh = newMessages
            .filter { message in
                guard message.isUnread, !message.isBulk, !message.flags.contains(.draft) else { return false }
                if store.account(id: message.accountID)?.isDemo ?? true { return false }
                if let sender = message.sender, store.isMe(sender) { return false }
                return seen.insert(message.dedupeKey).inserted
            }
            .sorted { $0.date < $1.date }
        guard !fresh.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        if fresh.count > individualLimit {
            center.add(summaryRequest(for: fresh)) { _ in }
        } else {
            for message in fresh {
                center.add(messageRequest(for: message, store: store)) { _ in }
            }
        }
    }

    /// Sets the number on the app icon (0 clears it).
    static func updateBadge(count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { _ in }
    }

    /// Takes back notifications for messages that have been read since (here or on another
    /// device), so Notification Center doesn't keep announcing mail you've dealt with. Leaves
    /// alone anything it can't find in the store.
    static func withdrawRead(store: MailStore) {
        guard store.hasAccounts else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let read = delivered.filter { notification in
                let info = notification.request.content.userInfo
                let target = MailNotificationTarget(
                    conversationID: info["conversationID"] as? String,
                    messageKey: info["messageKey"] as? String
                )
                guard let found = message(for: target, in: store) else { return false }
                return !found.isUnread
            }
            guard !read.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: read.map(\.request.identifier))
        }
    }

    /// Opens tapped mail notifications. Call once at launch, before the app finishes launching,
    /// so a tap that launched the app is delivered too.
    static func routeTaps(to handler: @escaping @MainActor (MailNotificationTarget) -> Void) {
        openTarget = handler
        UNUserNotificationCenter.current().delegate = router
    }

    /// The conversation a notification points at, if it's still in the store.
    static func conversation(for target: MailNotificationTarget, in store: MailStore) -> Conversation? {
        let byID = target.conversationID.flatMap { store.conversation(id: $0) }
        guard let key = target.messageKey else { return byID }
        if let byID, byID.messages.contains(where: { $0.dedupeKey == key }) { return byID }
        let byMessage = store.conversations.first { conversation in
            conversation.messages.contains { $0.dedupeKey == key }
        }
        return byMessage ?? byID
    }

    private static func message(for target: MailNotificationTarget, in store: MailStore) -> MessageSummary? {
        guard let key = target.messageKey, let conversation = conversation(for: target, in: store) else { return nil }
        return conversation.messages.first { $0.dedupeKey == key }
    }

    // MARK: Requests

    private static func messageRequest(for message: MessageSummary, store: MailStore) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = message.sender?.displayName ?? "New message"
        let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        content.subtitle = subject.isEmpty ? "(no subject)" : subject
        content.body = message.snippet
        content.threadIdentifier = message.threadKey ?? message.accountID
        content.sound = .default
        var userInfo: [AnyHashable: Any] = [
            "accountID": message.accountID,
            "messageID": message.id,
            "messageKey": message.dedupeKey,
        ]
        if let conversationID = conversationID(for: message, in: store) {
            userInfo["conversationID"] = conversationID
        }
        content.userInfo = userInfo
        return UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
    }

    private static func summaryRequest(for messages: [MessageSummary]) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "\(messages.count) new messages"
        let senders = messages.compactMap(\.sender).uniqued().shortList(maxNames: 3)
        content.body = senders.isEmpty ? "" : "From \(senders)"
        content.threadIdentifier = "ink.new-mail"
        content.sound = .default
        return UNNotificationRequest(identifier: "ink.new-mail.\(UUID().uuidString)", content: content, trigger: nil)
    }

    /// The conversation a new message landed in, so a tap can open it.
    private static func conversationID(for message: MessageSummary, in store: MailStore) -> String? {
        if let key = message.threadKey, store.conversation(id: key) != nil { return key }
        let match = store.conversations.first { conversation in
            conversation.messages.contains { $0.dedupeKey == message.dedupeKey }
        }
        return match?.id
    }
}

/// Receives notification taps and decides how notifications look while Ink is in front.
private final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let target = MailNotificationTarget(
            conversationID: info["conversationID"] as? String,
            messageKey: info["messageKey"] as? String
        )
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           target.conversationID != nil || target.messageKey != nil {
            Task { @MainActor in
                Notifier.openTarget?(target)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
