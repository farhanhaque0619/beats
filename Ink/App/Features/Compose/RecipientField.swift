import SwiftUI
import InkCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Recipients as capsule tokens followed by a text field, with contact suggestions shown
/// inline under the field while typing.
///
/// Return, comma, semicolon, tab or a space after a complete address turns the text into a
/// token, and so does leaving the field. Backspace in an empty field selects the last token;
/// a second backspace removes it.
struct RecipientField: View {
    private let label: String
    @Binding private var recipients: [EmailAddress]
    /// Text typed but not yet turned into a token. Compose reads it so Send can pick it up.
    @Binding private var pending: String
    private let field: ComposeField
    private let focus: FocusState<ComposeField?>.Binding
    /// Whether `field` has focus. Passed in (rather than read from `focus`) so this view
    /// updates whenever focus moves.
    private let isFocused: Bool
    /// Return in an empty field moves on to the next field.
    private let onAdvance: () -> Void

    @Environment(MailStore.self) private var store
    @State private var raw = ComposeAddressParsing.sentinel
    @State private var selected: EmailAddress? = nil
    @State private var suggestions: [EmailAddress] = []
    @State private var highlighted: Int? = nil

    private static let sentinel = ComposeAddressParsing.sentinel
    private static let separators = CharacterSet(charactersIn: ",;\n\t")

    init(
        _ label: String,
        recipients: Binding<[EmailAddress]>,
        pending: Binding<String>,
        field: ComposeField,
        focus: FocusState<ComposeField?>.Binding,
        isFocused: Bool,
        onAdvance: @escaping () -> Void = {}
    ) {
        self.label = label
        self._recipients = recipients
        self._pending = pending
        self.field = field
        self.focus = focus
        self.isFocused = isFocused
        self.onAdvance = onAdvance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: InkSpace.s) {
                ComposeFieldLabel(label)
                    .contentShape(Rectangle())
                    .onTapGesture { focus.wrappedValue = field }
                RecipientFlowLayout(spacing: 6, lineSpacing: 4, minInputWidth: 96) {
                    ForEach(recipients, id: \.normalized) { address in
                        token(address)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    input
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, InkSpace.gutter)
            .padding(.vertical, ComposeMetrics.rowPadding)

            if showsSuggestions {
                suggestionList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(InkMotion.snappy, value: recipients)
        .animation(InkMotion.snappy, value: showsSuggestions)
        .onChange(of: raw) { _, value in
            handleEdit(value)
        }
        .onChange(of: pending) { _, value in
            if value != typedText { raw = Self.sentinel + value }
        }
        .onChange(of: isFocused) { _, focused in
            guard !focused else { return }
            commitTyped()
            selected = nil
            suggestions = []
        }
    }

    // MARK: Pieces

    private var input: some View {
        TextField("", text: $raw)
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(Ink.primary)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            #endif
            .submitLabel(.next)
            .focused(focus, equals: field)
            .onSubmit(submit)
            .onKeyPress(.downArrow) { moveHighlight(by: 1) }
            .onKeyPress(.upArrow) { moveHighlight(by: -1) }
            .frame(minHeight: ComposeMetrics.line)
            .accessibilityLabel(label)
            .accessibilityValue(pending)
    }

    @ViewBuilder
    private func token(_ address: EmailAddress) -> some View {
        let isSelected = selected == address
        let isValid = address.isValid
        Text(isSelected ? address.address : address.displayName)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(isSelected ? Ink.onInverse : (isValid ? Ink.primary : Ink.danger))
            .padding(.horizontal, 10)
            .frame(minHeight: ComposeMetrics.token)
            .background(tokenBackground(isSelected: isSelected, isValid: isValid), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { toggleSelection(address) }
            .contextMenu {
                Button {
                    copy(address)
                } label: {
                    Label("Copy address", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                    remove(address)
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isValid ? "\(address.displayName), \(address.address)" : "\(address.address), not a valid address")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "Remove") { remove(address) }
    }

    private func tokenBackground(isSelected: Bool, isValid: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Ink.inverse) }
        return AnyShapeStyle(isValid ? Ink.fill : Ink.danger.opacity(0.12))
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.normalized) { index, address in
                Button {
                    pick(address)
                } label: {
                    HStack(spacing: InkSpace.m) {
                        AvatarView(address: address, size: InkSize.avatarSmall)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(address.displayName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)
                            Text(address.address)
                                .font(.footnote)
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, InkSpace.gutter)
                    .padding(.vertical, 7)
                    .background(index == highlighted ? Ink.selection : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(address.displayName), \(address.address)")
                .accessibilityHint("Adds this recipient")
            }
        }
        .padding(.bottom, InkSpace.xs)
    }

    // MARK: State

    private var typedText: String {
        raw.replacingOccurrences(of: Self.sentinel, with: "")
    }

    private var showsSuggestions: Bool {
        isFocused && !suggestions.isEmpty && !pending.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Editing

    private func handleEdit(_ value: String) {
        guard value.hasPrefix(Self.sentinel) else {
            // The sentinel is gone: either backspace in an empty field, or the whole text
            // was replaced (select-all and type, or a paste).
            let rest = value.replacingOccurrences(of: Self.sentinel, with: "")
            if rest.isEmpty && pending.isEmpty { deleteBackward() }
            raw = Self.sentinel + rest
            return
        }
        let typed = String(value.dropFirst()).replacingOccurrences(of: Self.sentinel, with: "")
        // A separator inside quotes or angle brackets ("Doe, Jane" <jane@x.com>) is part of
        // the address being typed, not the end of it.
        if typed.rangeOfCharacter(from: Self.separators) != nil,
           let separator = ComposeAddressParsing.lastSeparator(in: typed) {
            commitSeparated(typed, at: separator)
            return
        }
        if typed.hasSuffix(" ") {
            let candidate = typed.trimmingCharacters(in: .whitespaces)
            if candidate.isEmpty {
                setTyped("")
                return
            }
            let address = EmailAddress(address: candidate)
            if address.isValid {
                add([address])
                setTyped("")
                return
            }
        }
        if !typed.isEmpty { selected = nil }
        if pending != typed { pending = typed }
        refreshSuggestions(for: typed)
    }

    /// Text containing a separator: everything before the last separator becomes tokens,
    /// what follows stays in the field. A name with no address yet ("Ana,") takes the
    /// highlighted or best suggestion.
    private func commitSeparated(_ typed: String, at separator: Range<String.Index>) {
        let head = String(typed[..<separator.lowerBound])
        let tail = String(typed[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        let parsed = ComposeAddressParsing.split(head)
        var found = parsed.addresses
        var leftovers = parsed.leftovers
        if found.isEmpty, leftovers.count == 1, let suggestion = currentSuggestion {
            found = [suggestion]
            leftovers = []
        }
        if found.isEmpty {
            // Nothing to turn into a token: drop the separator and keep the text.
            setTyped(head + tail)
            return
        }
        add(found)
        // Pieces that aren't addresses stay in the field to be fixed, not thrown away. Joined
        // with spaces: a separator here would be read as another one just typed.
        setTyped((leftovers + [tail]).filter { !$0.isEmpty }.joined(separator: " "))
    }

    private func submit() {
        let typed = pending.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else {
            onAdvance()
            return
        }
        if let highlighted, suggestions.indices.contains(highlighted) {
            add([suggestions[highlighted]])
            setTyped("")
        } else {
            let parsed = ComposeAddressParsing.split(typed)
            if !parsed.addresses.isEmpty {
                add(parsed.addresses)
                setTyped(parsed.leftovers.joined(separator: " "))
            } else if let first = suggestions.first {
                add([first])
                setTyped("")
            } else {
                Haptics.warning()
            }
        }
        // Keep the keyboard up for the next recipient.
        focus.wrappedValue = field
    }

    /// Leaving the field turns complete addresses into tokens; anything else stays as typed.
    private func commitTyped() {
        let parsed = ComposeAddressParsing.split(pending)
        guard !parsed.addresses.isEmpty else { return }
        add(parsed.addresses)
        setTyped(parsed.leftovers.joined(separator: " "))
    }

    /// The suggestion Return or a comma would pick: the highlighted one, else the best match.
    private var currentSuggestion: EmailAddress? {
        if let highlighted, suggestions.indices.contains(highlighted) { return suggestions[highlighted] }
        return suggestions.first
    }

    private func pick(_ address: EmailAddress) {
        add([address])
        setTyped("")
        focus.wrappedValue = field
    }

    private func setTyped(_ text: String) {
        pending = text
        raw = Self.sentinel + text
        refreshSuggestions(for: text)
    }

    private func add(_ addresses: [EmailAddress]) {
        let fresh = addresses.uniqued().filter { !recipients.contains($0) }
        selected = nil
        highlighted = nil
        guard !fresh.isEmpty else { return }
        recipients.append(contentsOf: fresh)
        Haptics.tick()
    }

    private func remove(_ address: EmailAddress) {
        recipients.removeAll { $0 == address }
        if selected == address { selected = nil }
        Haptics.tick()
    }

    private func deleteBackward() {
        if let selected {
            remove(selected)
        } else if let last = recipients.last {
            withAnimation(InkMotion.snappy) { selected = last }
            Haptics.tick()
        }
    }

    private func toggleSelection(_ address: EmailAddress) {
        withAnimation(InkMotion.snappy) { selected = selected == address ? nil : address }
        focus.wrappedValue = field
        Haptics.tick()
    }

    private func refreshSuggestions(for text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        highlighted = nil
        guard !query.isEmpty else {
            suggestions = []
            return
        }
        suggestions = store.contactSuggestions(matching: query, limit: 5).filter { !recipients.contains($0) }
    }

    private func moveHighlight(by step: Int) -> KeyPress.Result {
        guard showsSuggestions else { return .ignored }
        let current = highlighted ?? (step > 0 ? -1 : suggestions.count)
        highlighted = min(max(current + step, 0), suggestions.count - 1)
        return .handled
    }

    private func copy(_ address: EmailAddress) {
        #if os(iOS)
        UIPasteboard.general.string = address.address
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address.address, forType: .string)
        #endif
    }
}

/// Turns typed or pasted text into addresses ("ana@x.com", "Ana <ana@x.com>, bob@y.com",
/// "\"Doe, Jane\" <jane@x.com>").
enum ComposeAddressParsing {
    /// A zero-width space kept at the start of a recipient text field. SwiftUI reports no key
    /// event for backspace in an empty field, but deleting this character is an ordinary edit.
    static let sentinel = "\u{200B}"

    private static let wrappers = CharacterSet(charactersIn: "<>\"'()")

    /// Valid addresses in `text`, de-duplicated, in order.
    static func addresses(in text: String) -> [EmailAddress] {
        split(text).addresses
    }

    /// The addresses in `text`, plus the pieces that aren't addresses (so they can stay in the
    /// field instead of silently disappearing).
    static func split(_ text: String) -> (addresses: [EmailAddress], leftovers: [String]) {
        let cleaned = text.replacingOccurrences(of: sentinel, with: "")
        var addresses: [EmailAddress] = []
        var leftovers: [String] = []
        for segment in segments(of: cleaned) {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let words = trimmed
                .split(whereSeparator: \.isWhitespace)
                .map { EmailAddress(address: $0.trimmingCharacters(in: wrappers)) }
                .filter(\.isValid)
            // "ana@x.com bob@y.com" is two people; the header parser would read the first as
            // the second's name.
            if words.count > 1, !trimmed.contains("<") {
                addresses += words
                continue
            }
            let parsed = AddressParser.parseList(trimmed).filter(\.isValid)
            if !parsed.isEmpty {
                addresses += parsed
                continue
            }
            // An address wrapped in brackets or quotes. Words around an address are taken to
            // be its name.
            if words.isEmpty {
                leftovers.append(trimmed)
            } else {
                addresses += words
            }
        }
        return (addresses.uniqued(), leftovers)
    }

    /// `text` cut at every `,` `;` newline or tab that isn't inside quotes or angle brackets.
    static func segments(of text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        for separator in separators(in: text) {
            result.append(text[start..<separator.lowerBound])
            start = separator.upperBound
        }
        result.append(text[start...])
        return result
    }

    /// The last separator outside quotes and angle brackets: where finished recipients end and
    /// the one still being typed begins.
    static func lastSeparator(in text: String) -> Range<String.Index>? {
        separators(in: text).last
    }

    private static func separators(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var inQuotes = false
        var escaped = false
        var angleDepth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if escaped {
                escaped = false
            } else if inQuotes {
                if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inQuotes = false
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case "<":
                    angleDepth += 1
                case ">":
                    angleDepth = max(angleDepth - 1, 0)
                case ",", ";", "\n", "\r", "\r\n", "\t":
                    if angleDepth == 0 { found.append(index..<next) }
                default:
                    break
                }
            }
            index = next
        }
        return found
    }
}

/// Lays tokens out left to right, wrapping as needed. The last subview (the text field) takes
/// the rest of the final line, or a line of its own when too little room is left.
private struct RecipientFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var minInputWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = max(proposed, 0)
        } else {
            width = naturalWidth(of: subviews)
        }
        let frames = arrange(width: width, subviews: subviews)
        let height = frames.reduce(CGFloat(0)) { max($0, $1.maxY) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews)
        for index in subviews.indices where index < frames.count {
            let frame = frames[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    /// Everything on one line, with the text field at its minimum width.
    private func naturalWidth(of subviews: Subviews) -> CGFloat {
        guard !subviews.isEmpty else { return 0 }
        let lastIndex = subviews.count - 1
        var total: CGFloat = 0
        for index in subviews.indices {
            let ideal = subviews[index].sizeThatFits(.unspecified).width
            total += index == lastIndex ? max(ideal, minInputWidth) : ideal
        }
        return total + spacing * CGFloat(subviews.count - 1)
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var lineStart = 0

        // Centres the items of the finished line vertically within it.
        func endLine(at end: Int) {
            guard lineStart < end else { return }
            for index in lineStart..<end {
                frames[index].origin.y = y + (lineHeight - frames[index].height) / 2
            }
        }

        func wrap(at index: Int) {
            endLine(at: index)
            y += lineHeight + lineSpacing
            x = 0
            lineHeight = 0
            lineStart = index
        }

        let lastIndex = subviews.count - 1
        for index in subviews.indices {
            let subview = subviews[index]
            var size: CGSize
            if index == lastIndex {
                if x > 0 && maxWidth - x < minInputWidth { wrap(at: index) }
                let available = max(maxWidth - x, 0)
                size = subview.sizeThatFits(ProposedViewSize(width: available, height: nil))
                size.width = available
            } else {
                size = subview.sizeThatFits(.unspecified)
                size.width = min(size.width, maxWidth)
                if x > 0 && x + size.width > maxWidth { wrap(at: index) }
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        endLine(at: frames.count)
        return frames
    }
}
