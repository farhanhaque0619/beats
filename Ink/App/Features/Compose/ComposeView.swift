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
    /// Recipients that can't be sent to (invalid tokens, leftover text), asked about on Send.
    @State private var recipientProblems: [String] = []
    @State private var isConfirmingProblems = false
    @State private var isImportingFiles = false
    /// Imports still reading files (several can overlap).
    @State private var attachmentLoads = 0
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
            // Dialogs hang off the control that opened them, so on iOS 26 they point at it.
            IconButton("xmark", label: "Close", action: close)
                .keyboardShortcut(.cancelAction)
                .confirmationDialog("Discard this draft?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                    Button("Discard", role: .destructive) { dismiss() }
                    Button("Keep editing", role: .cancel) {}
                } message: {
                    Text("What you’ve written won’t be saved.")
                }
            Spacer(minLength: InkSpace.s)
            attachButton
            sendButton
        }
        .overlay {
            Text(title)
                .font(InkFont.headline)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                // Centred, but never under the buttons on either side.
                .padding(.horizontal, 128)
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
        .confirmationDialog(problemTitle, isPresented: $isConfirmingProblems, titleVisibility: .visible) {
            Button(recipientProblems.count == 1 ? "Send without it" : "Send without them") { dropProblemsAndSend() }
            Button("Fix", role: .cancel) { focusFirstProblem() }
        } message: {
            Text(problemMessage)
        }
        .background {
            // Its own view: two dialogs on one view can clash.
            Color.clear
                .confirmationDialog("Send without a subject?", isPresented: $isConfirmingNoSubject, titleVisibility: .visible) {
                    Button("Send anyway") { deliver() }
                    Button("Add a subject", role: .cancel) { focus = .subject }
                }
        }
        #if os(macOS)
        .background {
            // Mail's other Send shortcut, ⇧⌘D.
            Button(action: send) { EmptyView() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!canSend)
                .frame(width: 0, height: 0)
                .opacity(0)
                .focusable(false)
                .accessibilityHidden(true)
        }
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
            // Room to tap into, but a reply's quote stays close under what you write.
            .frame(maxWidth: .infinity, minHeight: hasQuote ? 140 : 240, alignment: .topLeading)
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
        if !draft.attachments.isEmpty || attachmentLoads > 0 || attachmentNote != nil {
            ComposeAttachmentStrip(
                attachments: draft.attachments,
                isLoading: attachmentLoads > 0,
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

    private var hasQuote: Bool { !(draft.quotedText ?? "").isEmpty }

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
        // A red token or half-typed text would otherwise just be left out without a word.
        let problems = currentRecipientProblems
        if !problems.isEmpty {
            recipientProblems = problems
            isConfirmingProblems = true
            Haptics.warning()
            return
        }
        confirmSubjectThenDeliver()
    }

    private func confirmSubjectThenDeliver() {
        if draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isConfirmingNoSubject = true
        } else {
            deliver()
        }
    }

    /// Invalid tokens and typed text that isn't an address, as the person wrote them.
    private var currentRecipientProblems: [String] {
        let invalid = (draft.to + draft.cc + draft.bcc).filter { !$0.isValid }.map(\.address)
        let leftovers = [pendingTo, pendingCc, pendingBcc]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return invalid + leftovers
    }

    private var problemTitle: String {
        if recipientProblems.count == 1 { return "“\(recipientProblems[0])” isn’t an email address" }
        return "\(recipientProblems.count) recipients aren’t email addresses"
    }

    private var problemMessage: String {
        recipientProblems.count == 1
            ? "Ink can’t send to it. Send to the others, or fix it first."
            : "Ink can’t send to them: \(recipientProblems.joined(separator: ", ")). Send to the others, or fix them first."
    }

    private func dropProblemsAndSend() {
        draft.to.removeAll { !$0.isValid }
        draft.cc.removeAll { !$0.isValid }
        draft.bcc.removeAll { !$0.isValid }
        pendingTo = ""
        pendingCc = ""
        pendingBcc = ""
        guard draft.hasRecipients else { return }
        if draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                // Let this dialog finish closing before the next one opens.
                try? await Task.sleep(for: .milliseconds(450))
                isConfirmingNoSubject = true
            }
        } else {
            deliver()
        }
    }

    private func focusFirstProblem() {
        let fields: [(ComposeField, [EmailAddress], String)] = [
            (.to, draft.to, pendingTo), (.cc, draft.cc, pendingCc), (.bcc, draft.bcc, pendingBcc),
        ]
        let first = fields.first { _, tokens, pending in
            tokens.contains { !$0.isValid } || !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let target = first?.0 ?? .to
        guard target != .to, !showsCcBcc else {
            focus = target
            return
        }
        withAnimation(InkMotion.snappy) { showsCcBcc = true }
        Task {
            // Let the new fields exist before moving focus into them.
            try? await Task.sleep(for: .milliseconds(60))
            focus = target
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

    /// Typed-but-uncommitted addresses count as recipients when sending. Text that isn't an
    /// address stays in its field, for `send()` to ask about.
    private func commitPendingRecipients() {
        if let to = Self.committing(pendingTo, into: draft.to) {
            draft.to = to.recipients
            pendingTo = to.pending
        }
        if let cc = Self.committing(pendingCc, into: draft.cc) {
            draft.cc = cc.recipients
            pendingCc = cc.pending
        }
        if let bcc = Self.committing(pendingBcc, into: draft.bcc) {
            draft.bcc = bcc.recipients
            pendingBcc = bcc.pending
        }
    }

    /// `recipients` plus the addresses in `pending`, and what's left of `pending`; nil when
    /// `pending` holds no address.
    private static func committing(_ pending: String, into recipients: [EmailAddress]) -> (recipients: [EmailAddress], pending: String)? {
        let parsed = ComposeAddressParsing.split(pending)
        guard !parsed.addresses.isEmpty else { return nil }
        return ((recipients + parsed.addresses).uniqued(), parsed.leftovers.joined(separator: " "))
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
        draft.body = ComposeSignature.swap(
            in: draft.body,
            from: previous?.signature,
            to: account.signature,
            block: store.signatureBlock(for: account)
        )
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
        withAnimation(InkMotion.snappy) { attachmentLoads += 1 }
        Task {
            let results = await ComposeAttachmentLoader.attachments(from: urls)
            finishLoading(results, noun: "file")
        }
    }

    #if os(iOS)
    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        withAnimation(InkMotion.snappy) { attachmentLoads += 1 }
        let firstNumber = draft.attachments.count + 1
        Task {
            var results: [ComposeAttachmentLoad] = []
            for (offset, item) in items.enumerated() {
                results.append(await ComposeAttachmentLoader.attachment(from: item, number: firstNumber + offset))
            }
            finishLoading(results, noun: "item")
        }
    }
    #endif

    private func finishLoading(_ results: [ComposeAttachmentLoad], noun: String) {
        withAnimation(InkMotion.snappy) { attachmentLoads = max(attachmentLoads - 1, 0) }
        appendAttachments(results.compactMap(\.attachment))
        var oversized: [(name: String, bytes: Int)] = []
        var failed = 0
        for result in results {
            switch result {
            case .attached: break
            case .tooLarge(let name, let bytes): oversized.append((name: name, bytes: bytes))
            case .failed: failed += 1
            }
        }
        noteProblems(tooLarge: oversized, failed: failed, noun: noun)
    }

    private func appendAttachments(_ added: [OutgoingAttachment]) {
        guard !added.isEmpty else { return }
        attachmentNote = nil
        withAnimation(InkMotion.snappy) { draft.attachments.append(contentsOf: added) }
        Haptics.tick()
    }

    private func noteProblems(tooLarge: [(name: String, bytes: Int)], failed: Int, noun: String) {
        var sentences: [String] = []
        if tooLarge.count == 1, let only = tooLarge.first {
            sentences.append("“\(only.name)” is too big to email (\(InkFormat.fileSize(only.bytes))).")
        } else if tooLarge.count > 1 {
            sentences.append("\(tooLarge.count) \(noun)s are too big to email.")
        }
        if failed == 1 {
            sentences.append("Couldn’t attach one \(noun).")
        } else if failed > 1 {
            sentences.append("Couldn’t attach \(failed) \(noun)s.")
        }
        guard !sentences.isEmpty else { return }
        withAnimation(InkMotion.snappy) { attachmentNote = sentences.joined(separator: " ") }
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
    /// signature, the old one goes, along with its "-- " separator. With no old one, the new
    /// account's `block` (separator and signature) goes at the end.
    static func swap(in body: String, from old: String?, to new: String?, block: String) -> String {
        let oldSignature = (old ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let newSignature = (new ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldSignature != newSignature else { return body }
        if oldSignature.isEmpty {
            guard !block.isEmpty else { return body }
            var head = body
            trimTrailingWhitespace(&head)
            return head + block
        }
        guard let range = body.range(of: oldSignature, options: .backwards) else { return body }
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
