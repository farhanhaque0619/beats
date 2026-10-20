import Foundation
import UserNotifications
import InkCore

/// Local notifications for new mail and the app icon badge. Ink has no server, so there is no
/// push: notifications are posted by the app itself after a background refresh.
@MainActor
enum Notifier {
    /// More new messages than this arrive as one summary notification instead of a stack.
    private static let individualLimit = 5
    private static let router = NotificationRouter()
    fileprivate static var openConversation: (@MainActor (String) -> Void)?

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
    /// become a single summary.
    static func notify(newMessages: [MessageSummary], store: MailStore) {
        var seen = Set<String>()
        let fresh = newMessages
            .filter { message in
                guard message.isUnread, !message.isBulk, !message.flags.contains(.draft) else { return false }
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

    /// Opens tapped mail notifications: `handler` receives the conversation ID. Call once at
    /// launch, before the app finishes launching, so a tap that launched the app is delivered too.
    static func routeTaps(to handler: @escaping @MainActor (String) -> Void) {
        openConversation = handler
        UNUserNotificationCenter.current().delegate = router
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
        var userInfo: [AnyHashable: Any] = ["accountID": message.accountID, "messageID": message.id]
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
        let conversationID = response.notification.request.content.userInfo["conversationID"] as? String
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let conversationID {
            Task { @MainActor in
                Notifier.openConversation?(conversationID)
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
