import SwiftUI
import InkCore

/// A conversation, oldest message first. Pushed onto the inbox stack on iPhone (with a floating
/// action capsule) and shown in the detail column on Mac (with toolbar actions).
struct ThreadScreen: View {
    let conversationID: String

    var body: some View {
        // A fresh identity per conversation, so expansion and scroll state never carry over
        // when the Mac detail column switches to another thread.
        ReaderThreadView(conversationID: conversationID)
            .id(conversationID)
    }
}

private struct ReaderThreadView: View {
    let conversationID: String

    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings

    /// The conversation as it was when an action took it out of the store, drawn while the
    /// screen goes away instead of flashing an empty state.
    @State private var departing: Conversation?
    @State private var awaitingSnooze = false
    @State private var expandedIDs: Set<String> = []
    @State private var didSeedExpansion = false
    @State private var revealsAllEarlier = false
    @State private var showsInlineTitle = false

    var body: some View {
        let live = store.conversation(id: conversationID)
        Group {
            if let conversation = live ?? departing {
                thread(conversation)
            } else {
                missing
            }
        }
        .background(Ink.background.ignoresSafeArea())
        .onAppear {
            if let live { opened(live) }
        }
        .onChange(of: live?.latest?.id) { _, _ in
            if let current = store.conversation(id: conversationID) { messageArrived(in: current) }
        }
        .onChange(of: app.isSnoozePickerPresented) { wasPresented, isPresented in
            if wasPresented && !isPresented { snoozePickerClosed() }
        }
    }

    // MARK: Thread

    @ViewBuilder
    private func thread(_ conversation: Conversation) -> some View {
        let actions = makeActions(for: conversation)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ReaderThreadHeader(conversation: conversation, snoozedUntil: actions.snoozedUntil)
                ForEach(items(for: conversation)) { item in
                    row(item, in: conversation)
                }
            }
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
            .padding(.bottom, InkSpace.xxl)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 56
        } action: { _, isPast in
            showsInlineTitle = isPast
        }
        .navigationTitle(conversation.subject)
        .toolbar {
            ReaderToolbar(actions: actions, subject: conversation.subject, showsTitle: showsInlineTitle)
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ReaderActionBar(actions: actions)
        }
        #endif
    }

    @ViewBuilder
    private func row(_ item: ReaderThreadItem, in conversation: Conversation) -> some View {
        switch item.kind {
        case .message(let message, let isExpanded, let index):
            MessageCard(
                message: message,
                isExpanded: isExpanded,
                isLatest: message.id == conversation.latest?.id,
                collapseQuotes: index > 0,
                showsSeparator: item.showsSeparator
            ) {
                toggle(message, in: conversation)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        case .more(let count):
            ReaderMorePill(count: count) {
                Haptics.tick()
                withAnimation(InkMotion.smooth) { revealsAllEarlier = true }
            }
            .transition(.opacity)
        }
    }

    private var missing: some View {
        EmptyStateView(
            systemImage: "tray",
            title: "Nothing to show",
            message: "This conversation was moved or deleted."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Expansion

    /// Oldest to newest, with runs of 4+ collapsed messages folded into a "N more" pill
    /// (keeping the first and last of the run visible).
    private func items(for conversation: Conversation) -> [ReaderThreadItem] {
        let expanded = didSeedExpansion ? expandedIDs : Self.defaultExpanded(conversation)
        var result: [ReaderThreadItem] = []
        var run: [(index: Int, message: MessageSummary)] = []

        func append(_ index: Int, _ message: MessageSummary, isExpanded: Bool) {
            var followsPill = false
            if case .some(.more) = result.last?.kind { followsPill = true }
            result.append(ReaderThreadItem(
                id: message.id,
                kind: .message(message, isExpanded: isExpanded, index: index),
                showsSeparator: !followsPill
            ))
        }

        func flushRun() {
            if run.count >= 4, !revealsAllEarlier, let first = run.first, let last = run.last {
                append(first.index, first.message, isExpanded: false)
                result.append(ReaderThreadItem(id: "more-\(run[1].message.id)", kind: .more(count: run.count - 2), showsSeparator: false))
                append(last.index, last.message, isExpanded: false)
            } else {
                for entry in run {
                    append(entry.index, entry.message, isExpanded: false)
                }
            }
            run.removeAll()
        }

        for (index, message) in conversation.messages.enumerated() {
            if expanded.contains(message.id) {
                flushRun()
                append(index, message, isExpanded: true)
            } else {
                run.append((index: index, message: message))
            }
        }
        flushRun()
        return result
    }

    /// The newest message and anything unread start open.
    private static func defaultExpanded(_ conversation: Conversation) -> Set<String> {
        var ids = Set(conversation.messages.filter(\.isUnread).map(\.id))
        if let latest = conversation.latest { ids.insert(latest.id) }
        return ids
    }

    private func seedExpansionIfNeeded(_ conversation: Conversation) {
        guard !didSeedExpansion else { return }
        expandedIDs = Self.defaultExpanded(conversation)
        didSeedExpansion = true
    }

    private func toggle(_ message: MessageSummary, in conversation: Conversation) {
        seedExpansionIfNeeded(conversation)
        Haptics.tick()
        withAnimation(InkMotion.smooth) {
            if expandedIDs.contains(message.id) {
                expandedIDs.remove(message.id)
            } else {
                expandedIDs.insert(message.id)
            }
        }
    }

    // MARK: Lifecycle

    private func opened(_ conversation: Conversation) {
        // Remember what was unread before marking it read, so those messages stay open.
        seedExpansionIfNeeded(conversation)
        if settings.markReadOnOpen, conversation.isUnread {
            store.markOpened(conversation)
        }
    }

    /// A new message landed while the thread is open (or the thread just finished loading).
    private func messageArrived(in conversation: Conversation) {
        guard didSeedExpansion else {
            opened(conversation)
            return
        }
        if let latest = conversation.latest, !expandedIDs.contains(latest.id) {
            withAnimation(InkMotion.smooth) { _ = expandedIDs.insert(latest.id) }
        }
        if settings.markReadOnOpen, conversation.isUnread {
            store.markOpened(conversation)
        }
    }

    private func snoozePickerClosed() {
        guard awaitingSnooze else { return }
        awaitingSnooze = false
        if let snapshot = departing, store.snoozeDate(for: snapshot) != nil {
            app.didRemoveFocusedConversation(snapshot.id)
        } else {
            departing = nil
        }
    }

    private func makeActions(for conversation: Conversation) -> ReaderActions {
        ReaderActions(
            conversation: conversation,
            app: app,
            store: store,
            willLeave: { departing = conversation },
            willSnooze: {
                departing = conversation
                awaitingSnooze = true
            }
        )
    }
}

// MARK: - Pieces

private struct ReaderThreadItem: Identifiable {
    enum Kind {
        case message(MessageSummary, isExpanded: Bool, index: Int)
        case more(count: Int)
    }

    let id: String
    let kind: Kind
    let showsSeparator: Bool
}

/// Subject in display type, then a quiet meta line: account, message count, star, snooze.
private struct ReaderThreadHeader: View {
    let conversation: Conversation
    let snoozedUntil: Date?

    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpace.s) {
            Text(conversation.subject)
                .font(settings.readingFont == .serif ? InkFont.readerSubjectSerif : InkFont.readerSubject)
                .tracking(InkTracking.title)
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            meta
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, InkSpace.gutter)
        .padding(.top, InkSpace.s)
        .padding(.bottom, InkSpace.l)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            if let account = store.account(id: conversation.accountID) {
                AccountDot(colorIndex: account.colorIndex)
                if store.accounts.count > 1 {
                    Text(account.emailAddress)
                        .lineLimit(1)
                    Text("·")
                }
            }
            Text(conversation.count == 1 ? "1 message" : "\(conversation.count) messages")
            if conversation.isFlagged {
                Image(systemName: "star.fill")
                    .foregroundStyle(Ink.star)
                    .accessibilityLabel("Starred")
            }
            if let snoozedUntil {
                Text("·")
                Label("Until \(InkDate.listTimestamp(snoozedUntil))", systemImage: "clock")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Ink.snooze)
            }
        }
        .font(InkFont.meta)
        .foregroundStyle(Ink.secondary)
    }
}

/// "3 more" sitting on a hairline, standing in for the middle of a long thread.
private struct ReaderMorePill: View {
    let count: Int
    let action: () -> Void

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Button(action: action) {
            Text("\(count) more")
                .font(InkFont.caption)
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, InkSpace.m)
                .padding(.vertical, 6)
                .background(Ink.background, in: Capsule())
                .overlay(Capsule().stroke(Ink.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(Ink.hairline)
                .frame(height: 1 / displayScale)
        }
        .padding(.vertical, InkSpace.xs)
        .accessibilityLabel("Show \(count) earlier messages")
    }
}
