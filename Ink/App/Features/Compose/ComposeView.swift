import SwiftUI
import InkCore
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

/// Writing a message: new mail, replies and forwards. Presented as a sheet with the draft
/// already filled in; edits stay in a local copy until Send.
struct ComposeView: View {
    @Environment(AppModel.self) private var app
    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.inkAccent) private var accent

    /// The draft as it was handed in, to tell whether anything changed.
    private let original: OutgoingMessage
    @State private var draft: OutgoingMessage
    @State private var pendingTo = ""
    @State private var pendingCc = ""
    @State private var pendingBcc = ""
    @State private var showsCcBcc: Bool
    @State private var showsQuote = false
    @State private var bodySelection: TextSelection? = nil
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingNoSubject = false
    @State private var isImportingFiles = false
    @State private var isLoadingAttachments = false
    @State private var attachmentNote: String? = nil
    #if os(iOS)
    @State private var isPickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    #else
    @State private var isDropTargeted = false
    #endif
    @FocusState private var focus: ComposeField?

    init(draft: OutgoingMessage) {
        var normalized = draft
        normalized.to = draft.to.uniqued()
        normalized.cc = draft.cc.uniqued()
        normalized.bcc = draft.bcc.uniqued()
        original = normalized
        _draft = State(initialValue: normalized)
        _showsCcBcc = State(initialValue: !normalized.cc.isEmpty || !normalized.bcc.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ComposeSeparator(inset: 0)
            editor
        }
        .background(Ink.surface)
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog("Discard this draft?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("What you’ve written won’t be saved.")
        }
        .confirmationDialog("Send without a subject?", isPresented: $isConfirmingNoSubject, titleVisibility: .visible) {
            Button("Send anyway") { deliver() }
            Button("Add a subject", role: .cancel) { focus = .subject }
        }
        .fileImporter(isPresented: $isImportingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        #if os(iOS)
        .photosPicker(isPresented: $isPickingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            loadPhotos(items)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(InkRadius.sheet)
        .presentationBackground(Ink.surface)
        #else
        .frame(minWidth: 560, idealWidth: 680, minHeight: 480, idealHeight: 640)
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            withAnimation(InkMotion.snappy) { isDropTargeted = targeted }
        }
        .overlay {
            if isDropTargeted { dropHighlight }
        }
        #endif
        .task { await focusFirstField() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: InkSpace.xs) {
            IconButton("xmark", label: "Close", action: close)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: InkSpace.s)
            attachButton
            sendButton
        }
        .overlay {
            Text(title)
                .font(InkFont.headline)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.leading, InkSpace.xs)
        .padding(.trailing, InkSpace.l)
        .padding(.vertical, InkSpace.xs)
    }

    private var sendButton: some View {
        Button(action: send) {
            HStack(spacing: 6) {
                Text("Send")
                Image(systemName: "paperplane.fill")
                    .font(.footnote.weight(.semibold))
            }
        }
        .buttonStyle(.inkAccent)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .animation(InkMotion.snappy, value: canSend)
        .accessibilityLabel("Send")
        #if os(macOS)
        .help("Send (⌘↩)")
        #endif
    }

    @ViewBuilder private var attachButton: some View {
        #if os(iOS)
        Menu {
            Button {
                isPickingPhotos = true
            } label: {
                Label("Photo library", systemImage: "photo.on.rectangle")
            }
            Button {
                isImportingFiles = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Ink.primary)
                .frame(width: InkSize.hit, height: InkSize.hit)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Attach")
        #else
        IconButton("paperclip", label: "Attach files") { isImportingFiles = true }
            .keyboardShortcut("a", modifiers: [.command, .shift])
        #endif
    }

    // MARK: Editor

    @ViewBuilder private var editor: some View {
        #if os(iOS)
        // One scrolling page: the body grows with its text, like a sheet of paper.
        ScrollView {
            VStack(spacing: 0) {
                fields
                growingBody
                extras(quoteMaxHeight: nil)
            }
            .padding(.bottom, InkSpace.xxl)
        }
        #else
        // Mac: the header stays put and the body fills the window, scrolling by itself.
        VStack(spacing: 0) {
            fields
            fillingBody
            extras(quoteMaxHeight: 200)
                .padding(.bottom, InkSpace.s)
        }
        #endif
    }

    @ViewBuilder private var fields: some View {
        fromRow
        ComposeSeparator()
        RecipientField("To", recipients: $draft.to, pending: $pendingTo, field: .to, focus: $focus, isFocused: focus == .to) {
            focus = showsCcBcc ? .cc : .subject
        }
        ComposeSeparator()
        if showsCcBcc {
            RecipientField("Cc", recipients: $draft.cc, pending: $pendingCc, field: .cc, focus: $focus, isFocused: focus == .cc) {
                focus = .bcc
            }
            ComposeSeparator()
            RecipientField("Bcc", recipients: $draft.bcc, pending: $pendingBcc, field: .bcc, focus: $focus, isFocused: focus == .bcc) {
                focus = .subject
            }
            ComposeSeparator()
        } else {
            ccBccRow
            ComposeSeparator()
        }
        subjectRow
        ComposeSeparator()
    }

    private var fromRow: some View {
        HStack(spacing: InkSpace.s) {
            ComposeFieldLabel("From")
            if accounts.count > 1 {
                Menu {
                    ForEach(accounts) { account in
                        Button {
                            selectAccount(account)
                        } label: {
                            if account.id == draft.accountID {
                                Label(account.emailAddress, systemImage: "checkmark")
                            } else {
                                Text(account.emailAddress)
                            }
                        }
                    }
                } label: {
                    fromLabel(showsChevron: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("From \(draft.from.address)")
                .accessibilityHint("Choose the account to send from")
            } else {
                fromLabel(showsChevron: false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("From \(draft.from.address)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, InkSpace.gutter)
        .padding(.vertical, ComposeMetrics.rowPadding)
    }

    private func fromLabel(showsChevron: Bool) -> some View {
        HStack(spacing: 6) {
            AccountDot(colorIndex: currentAccount?.colorIndex ?? 0)
            Text(draft.from.address)
                .font(.subheadline)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .frame(minHeight: ComposeMetrics.line)
        .contentShape(Rectangle())
    }

    private var ccBccRow: some View {
        Button(action: revealCcBcc) {
            HStack(spacing: 0) {
                ComposeFieldLabel("Cc/Bcc")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, InkSpace.gutter)
            .padding(.vertical, ComposeMetrics.rowPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Cc or Bcc")
    }

    private var subjectRow: some View {
        TextField("Subject", text: $draft.subject)
            .textFieldStyle(.plain)
            .font(.body.weight(.semibold))
            .foregroundStyle(Ink.primary)
            .submitLabel(.next)
            .focused($focus, equals: .subject)
            .onSubmit { focus = .body }
            .frame(minHeight: ComposeMetrics.line)
            .padding(.horizontal, InkSpace.gutter)
            .padding(.vertical, ComposeMetrics.rowPadding)
    }

    #if os(iOS)
    /// The editor sized by an invisible copy of its text, so the whole sheet scrolls as one page
    /// instead of the editor scrolling inside it.
    private var growingBody: some View {
        Text(draft.body + "\n ")
            .font(bodyFont)
            .lineSpacing(3)
            .padding(bodyTextInsets)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
            .opacity(0)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) { bodyPlaceholder }
            .overlay {
                bodyEditor
                    .scrollDisabled(true)
            }
            .padding(.horizontal, InkSpace.gutter - 5)
            .padding(.top, InkSpace.xs)
    }
    #else
    private var fillingBody: some View {
        bodyEditor
            .overlay(alignment: .topLeading) { bodyPlaceholder }
            .padding(.horizontal, InkSpace.gutter - 5)
            .padding(.vertical, InkSpace.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    private var bodyEditor: some View {
        TextEditor(text: $draft.body, selection: $bodySelection)
            .font(bodyFont)
            .lineSpacing(3)
            .foregroundStyle(Ink.primary)
            .scrollContentBackground(.hidden)
            .focused($focus, equals: .body)
            .accessibilityLabel("Message")
    }

    @ViewBuilder private var bodyPlaceholder: some View {
        if draft.body.isEmpty {
            Text("Write your message")
                .font(bodyFont)
                .foregroundStyle(Ink.tertiary)
                .padding(bodyTextInsets)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func extras(quoteMaxHeight: CGFloat?) -> some View {
        if let quoted = draft.quotedText, !quoted.isEmpty {
            ComposeQuotedText(text: quoted, isExpanded: $showsQuote, maxExpandedHeight: quoteMaxHeight)
                .padding(.horizontal, InkSpace.gutter)
                .padding(.vertical, InkSpace.s)
        }
        if !draft.attachments.isEmpty || isLoadingAttachments || attachmentNote != nil {
            ComposeAttachmentStrip(
                attachments: draft.attachments,
                isLoading: isLoadingAttachments,
                note: attachmentNote,
                onRemove: removeAttachment
            )
            .padding(.vertical, InkSpace.s)
            .transition(.opacity)
        }
    }

    #if os(macOS)
    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous)
            .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .padding(InkSpace.s)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
    #endif

    // MARK: Derived

    private var accounts: [AccountConfig] { store.sendingAccounts }

    private var currentAccount: AccountConfig? { store.account(id: draft.accountID) }

    private var bodyFont: Font {
        settings.readingFont == .serif ? InkFont.readerBodySerif : InkFont.readerBody
    }

    /// Where the text editor draws its first glyph, so the placeholder and the sizing copy line up.
    private var bodyTextInsets: EdgeInsets {
        #if os(iOS)
        return EdgeInsets(top: 8, leading: 5, bottom: 8, trailing: 5)
        #else
        return EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5)
        #endif
    }

    private var title: String {
        switch draft.replyMode {
        case .reply?: return "Reply"
        case .replyAll?: return "Reply all"
        case .forward?: return "Forward"
        case nil: return "New message"
        }
    }

    private var hasTypedRecipients: Bool {
        !(pendingTo + pendingCc + pendingBcc).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Something worth confirming before throwing away.
    private var hasChanges: Bool {
        hasTypedRecipients || (draft != original && !draft.isEmpty)
    }

    private var canSend: Bool {
        if (draft.to + draft.cc + draft.bcc).contains(where: \.isValid) { return true }
        return [pendingTo, pendingCc, pendingBcc].contains { !ComposeAddressParsing.addresses(in: $0).isEmpty }
    }

    // MARK: Actions

    private func close() {
        if hasChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func send() {
        commitPendingRecipients()
        guard canSend else { return }
        if draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isConfirmingNoSubject = true
        } else {
            deliver()
        }
    }

    private func deliver() {
        var message = draft
        message.to = message.to.filter(\.isValid).uniqued()
        message.cc = message.cc.filter(\.isValid).uniqued()
        message.bcc = message.bcc.filter(\.isValid).uniqued()
        message.subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.hasRecipients else { return }
        store.send(message)
        Haptics.success()
        dismiss()
    }

    /// Typed-but-uncommitted addresses count as recipients when sending.
    private func commitPendingRecipients() {
        let to = ComposeAddressParsing.addresses(in: pendingTo)
        if !to.isEmpty {
            draft.to = (draft.to + to).uniqued()
            pendingTo = ""
        }
        let cc = ComposeAddressParsing.addresses(in: pendingCc)
        if !cc.isEmpty {
            draft.cc = (draft.cc + cc).uniqued()
            pendingCc = ""
        }
        let bcc = ComposeAddressParsing.addresses(in: pendingBcc)
        if !bcc.isEmpty {
            draft.bcc = (draft.bcc + bcc).uniqued()
            pendingBcc = ""
        }
    }

    private func revealCcBcc() {
        Haptics.tick()
        withAnimation(InkMotion.snappy) { showsCcBcc = true }
        Task {
            // Let the new fields exist before moving focus into them.
            try? await Task.sleep(for: .milliseconds(60))
            focus = .cc
        }
    }

    private func selectAccount(_ account: AccountConfig) {
        guard account.id != draft.accountID else { return }
        let previous = currentAccount
        draft.accountID = account.id
        draft.from = account.address
        draft.body = ComposeSignature.swap(in: draft.body, from: previous?.signature, to: account.signature)
        Haptics.tick()
    }

    private func focusFirstField() async {
        guard app.screenshot == nil else { return }
        // Wait for the sheet to settle; focusing mid-presentation is ignored on iOS.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        if draft.to.isEmpty && draft.cc.isEmpty && draft.bcc.isEmpty {
            focus = .to
        } else {
            bodySelection = TextSelection(insertionPoint: draft.body.startIndex)
            focus = .body
        }
    }

    // MARK: Attachments

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            addFiles(urls)
        case .failure(let error):
            attachmentNote = error.localizedDescription
        }
    }

    private func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isLoadingAttachments = true
        Task {
            let loaded = await ComposeAttachmentLoader.attachments(from: urls)
            isLoadingAttachments = false
            appendAttachments(loaded)
            noteFailures(urls.count - loaded.count, noun: "file")
        }
    }

    #if os(iOS)
    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        isLoadingAttachments = true
        let firstNumber = draft.attachments.count + 1
        Task {
            var loaded: [OutgoingAttachment] = []
            for (offset, item) in items.enumerated() {
                if let attachment = await ComposeAttachmentLoader.attachment(from: item, number: firstNumber + offset) {
                    loaded.append(attachment)
                }
            }
            isLoadingAttachments = false
            appendAttachments(loaded)
            noteFailures(items.count - loaded.count, noun: "item")
        }
    }
    #endif

    private func appendAttachments(_ added: [OutgoingAttachment]) {
        guard !added.isEmpty else { return }
        attachmentNote = nil
        withAnimation(InkMotion.snappy) { draft.attachments.append(contentsOf: added) }
        Haptics.tick()
    }

    private func noteFailures(_ count: Int, noun: String) {
        guard count > 0 else { return }
        attachmentNote = count == 1 ? "Couldn’t attach one \(noun)." : "Couldn’t attach \(count) \(noun)s."
        Haptics.warning()
    }

    private func removeAttachment(_ attachment: OutgoingAttachment) {
        attachmentNote = nil
        withAnimation(InkMotion.snappy) { draft.attachments.removeAll { $0.id == attachment.id } }
        Haptics.tick()
    }
}

/// Keeps the signature in step with the From account.
private enum ComposeSignature {
    /// Replaces `old` with `new` in the body when the old signature is there. With no new
    /// signature, the old one goes, along with its "-- " separator.
    static func swap(in body: String, from old: String?, to new: String?) -> String {
        let oldSignature = (old ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let newSignature = (new ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldSignature.isEmpty, oldSignature != newSignature,
              let range = body.range(of: oldSignature, options: .backwards) else { return body }
        if !newSignature.isEmpty {
            return body.replacingCharacters(in: range, with: newSignature)
        }
        var head = String(body[..<range.lowerBound])
        trimTrailingWhitespace(&head)
        if head.hasSuffix("--") {
            head.removeLast(2)
            trimTrailingWhitespace(&head)
        }
        return head + String(body[range.upperBound...])
    }

    private static func trimTrailingWhitespace(_ text: inout String) {
        while let last = text.last, last.isWhitespace {
            text.removeLast()
        }
    }
}
