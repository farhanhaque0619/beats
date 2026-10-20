#if os(macOS)
import SwiftUI
import InkCore

/// ⌘K: one field for every command, mailbox and conversation. Arrow keys move, Return runs,
/// Esc (or a click outside) closes. Shown as an overlay over a dimmed window.
struct CommandPalette: View {
    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(\.inkAccent) private var accent
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var items: [MacPaletteItem] = []
    @State private var highlighted = 0
    @State private var appeared = false
    /// Keyboard scrolling moves rows under a still pointer; ignore hover for a moment after.
    @State private var lastKeyboardMove = Date.distantPast
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityLabel("Close command palette")
                .accessibilityAddTraits(.isButton)
            panel
                .padding(.top, 64)
                .padding(.horizontal, InkSpace.xl)
                .scaleEffect(appeared ? 1 : 0.96, anchor: .top)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            items = Self.results(for: "", app: app, store: store)
            withAnimation(InkMotion.snappy) { appeared = true }
        }
        .task { isFieldFocused = true }
        .onChange(of: query) { _, newValue in
            items = Self.results(for: newValue, app: app, store: store)
            highlighted = 0
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            InkSearchField(text: $query, prompt: "Search commands, mailboxes and mail", onSubmit: { runHighlighted() }, focus: $isFieldFocused)
                .padding(InkSpace.m)
                .onKeyPress(.upArrow) {
                    move(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    move(1)
                    return .handled
                }
                .onKeyPress(.return) {
                    runHighlighted()
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
                .onExitCommand { close() }
            Rectangle().fill(Ink.hairline).frame(height: 0.5)
            if items.isEmpty {
                Text("No matches for “\(query)”")
                    .font(.subheadline)
                    .foregroundStyle(Ink.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, InkSpace.xxl)
            } else {
                resultsList
            }
            footer
        }
        .frame(maxWidth: 600)
        .background(Ink.elevated)
        .clipShape(RoundedRectangle(cornerRadius: InkRadius.large, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: InkRadius.large, style: .continuous).stroke(Ink.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 40, y: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id(Self.topID)
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || items[index - 1].group != item.group {
                            Text(item.group.title)
                                .font(.system(.caption2, design: .default, weight: .semibold))
                                .tracking(0.8)
                                .textCase(.uppercase)
                                .foregroundStyle(Ink.tertiary)
                                .padding(.horizontal, InkSpace.l)
                                .padding(.top, index == 0 ? InkSpace.s : InkSpace.m)
                                .padding(.bottom, InkSpace.xs)
                                .accessibilityAddTraits(.isHeader)
                        }
                        Button {
                            run(item)
                        } label: {
                            MacPaletteRow(item: item, isHighlighted: index == highlighted, accent: accent)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .onHover { hovering in
                            guard hovering, Date().timeIntervalSince(lastKeyboardMove) > 0.35 else { return }
                            highlighted = index
                        }
                    }
                }
                .padding(.horizontal, InkSpace.s)
                .padding(.bottom, InkSpace.s)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlighted) { _, index in
                guard items.indices.contains(index) else { return }
                proxy.scrollTo(items[index].id)
            }
            .onChange(of: items) { _, _ in
                // New results start from the top, where the highlight is.
                proxy.scrollTo(Self.topID, anchor: .top)
            }
        }
    }

    private static let topID = "palette-top"

    private var footer: some View {
        HStack(spacing: InkSpace.m) {
            hint(keys: ["↑", "↓"], label: "to move")
            hint(keys: ["↩"], label: "to run")
            hint(keys: ["esc"], label: "to close")
            Spacer(minLength: 0)
        }
        .font(InkFont.caption)
        .foregroundStyle(Ink.tertiary)
        .padding(.horizontal, InkSpace.l)
        .padding(.vertical, InkSpace.s)
        .background(Ink.fill.opacity(0.5))
    }

    private func hint(keys: [String], label: String) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { KeyCap($0) }
            Text(label)
        }
    }

    // MARK: Actions

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        lastKeyboardMove = Date()
        highlighted = (highlighted + delta + items.count) % items.count
    }

    private func runHighlighted() {
        guard items.indices.contains(highlighted) else { return }
        run(items[highlighted])
    }

    private func run(_ item: MacPaletteItem) {
        guard app.isCommandPalettePresented else { return }
        Haptics.tick()
        app.isCommandPalettePresented = false
        switch item.action {
        case .command(let command):
            MacActions(app: app).run(command)
        case .scope(let scope):
            app.select(scope: scope)
        case .conversation(let id):
            app.open(id)
        case .settings:
            openSettings()
        }
    }

    private func close() {
        guard app.isCommandPalettePresented else { return }
        app.isCommandPalettePresented = false
    }

    // MARK: Results

    /// Commands first, then mailboxes, then conversations (only once there's a query), each
    /// ranked: title prefix, then word prefix, then substring, then keyword matches.
    @MainActor
    private static func results(for rawQuery: String, app: AppModel, store: MailStore) -> [MacPaletteItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let actions = MacActions(app: app)

        var commands = MacCommand.paletteCommands
            .filter { actions.isAvailable($0) }
            .map { command in
                MacPaletteItem(id: "command:\(command.rawValue)", group: .commands, action: .command(command),
                            title: actions.title(for: command),
                            // "Undo" says what it undoes ("Archived 3 conversations").
                            subtitle: command == .undo ? store.toast?.message : nil,
                            systemImage: actions.systemImage(for: command),
                            hint: command.paletteHint, keywords: command.keywords)
            }
        commands.append(MacPaletteItem(id: "settings", group: .commands, action: .settings, title: "Settings…",
                                    systemImage: "gearshape", hint: "⌘,", keywords: "preferences options swipes accent theme"))

        let mailboxes = MacSidebarCatalog.all(store: store)
            .filter(\.isSelectable)
            .enumerated()
            .map { index, item in
                MacPaletteItem(id: "mailbox:\(index):\(item.qualifiedTitle)", group: .mailboxes, action: .scope(item.scope),
                            title: item.qualifiedTitle, systemImage: item.systemImage,
                            hint: index < 9 ? "⌘\(index + 1)" : nil, keywords: "go to open mailbox folder")
            }

        guard !query.isEmpty else { return commands + mailboxes }

        var conversations: [MacPaletteItem] = []
        for conversation in store.searchLocal(rawQuery).prefix(8) {
            let sender = conversation.latest?.sender?.displayName ?? ""
            let subtitle = sender.isEmpty ? InkDate.listTimestamp(conversation.date)
                : "\(sender) · \(InkDate.listTimestamp(conversation.date))"
            conversations.append(MacPaletteItem(id: "conversation:\(conversation.id)", group: .conversations,
                                             action: .conversation(conversation.id), title: conversation.subject,
                                             subtitle: subtitle, systemImage: conversation.isUnread ? "envelope.badge" : "envelope",
                                             hint: nil, keywords: ""))
        }
        return rank(commands, query) + rank(mailboxes, query) + conversations
    }

    private static func rank(_ items: [MacPaletteItem], _ query: String) -> [MacPaletteItem] {
        items.enumerated()
            .compactMap { index, item in score(item, query).map { (score: $0, index: index, item: item) } }
            .sorted { ($0.score, $0.index) < ($1.score, $1.index) }
            .map { $0.item }
    }

    private static func score(_ item: MacPaletteItem, _ query: String) -> Int? {
        let title = item.title.lowercased()
        if title.hasPrefix(query) { return 0 }
        let words = title.split(whereSeparator: { $0 == " " || $0 == "·" || $0 == "/" })
        if words.contains(where: { $0.hasPrefix(query) }) { return 1 }
        if title.contains(query) { return 2 }
        if item.keywords.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 3 }
        return nil
    }
}

/// One palette result.
private struct MacPaletteItem: Identifiable, Equatable {
    enum Group: Equatable {
        case commands, mailboxes, conversations

        var title: String {
            switch self {
            case .commands: return "Commands"
            case .mailboxes: return "Mailboxes"
            case .conversations: return "Mail"
            }
        }
    }

    enum Action: Equatable {
        case command(MacCommand)
        case scope(MailScope)
        case conversation(String)
        case settings
    }

    let id: String
    let group: Group
    let action: Action
    let title: String
    var subtitle: String?
    let systemImage: String
    var hint: String?
    var keywords: String

    init(id: String, group: Group, action: Action, title: String, subtitle: String? = nil, systemImage: String, hint: String?, keywords: String) {
        self.id = id
        self.group = group
        self.action = action
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.hint = hint
        self.keywords = keywords
    }
}

private struct MacPaletteRow: View {
    let item: MacPaletteItem
    let isHighlighted: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: InkSpace.m) {
            Image(systemName: item.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHighlighted ? accent : Ink.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(.body, design: .default, weight: isHighlighted ? .medium : .regular))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(InkFont.caption)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: InkSpace.s)
            if let hint = item.hint {
                KeyCap(hint)
            }
        }
        .padding(.horizontal, InkSpace.m)
        .padding(.vertical, 7)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: InkRadius.small, style: .continuous)
                    .fill(Ink.selection)
            }
        }
        .contentShape(Rectangle())
        .animation(InkMotion.snappy, value: isHighlighted)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}
#endif
