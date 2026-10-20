import SwiftUI
import InkCore

/// "Snooze until…": ready-made times as tiles, or any date and time from a calendar.
/// A sheet on iPhone (medium detent, large while picking a date); sized to fit a popover on Mac.
struct SnoozePicker: View {
    private let conversations: [Conversation]

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.inkAccent) private var accent
    @State private var options: [SnoozeOption]
    @State private var customDate: Date
    @State private var showsCustom = false
    @State private var chosenID: String? = nil
    #if os(iOS)
    @State private var detent: PresentationDetent = .medium
    #endif

    private static let customID = "custom"

    init(conversations: [Conversation]) {
        self.conversations = conversations
        let now = Date()
        _options = State(initialValue: SnoozePresets.options(now: now))
        _customDate = State(initialValue: SnoozePicker.suggestedCustomDate(after: now))
    }

    var body: some View {
        container
            #if os(iOS)
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(InkRadius.sheet)
            .presentationBackground(Ink.surface)
            #else
            .frame(width: 380)
            .background(Ink.surface)
            #endif
    }

    @ViewBuilder private var container: some View {
        #if os(iOS)
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
        #else
        content
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: InkSpace.l) {
            header
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    SnoozeTile(
                        systemImage: option.systemImage,
                        title: option.title,
                        detail: option.detail,
                        fill: chosenID == option.id ? Ink.snooze : nil,
                        onFill: .white
                    ) {
                        choose(option.id, date: option.date)
                    }
                    .keyboardShortcut(shortcut(for: index))
                }
                SnoozeTile(
                    systemImage: "calendar.badge.clock",
                    title: "Pick date & time",
                    detail: showsCustom ? "Choose below" : "Any day, any time",
                    fill: showsCustom ? Ink.inverse : nil,
                    onFill: Ink.onInverse,
                    action: toggleCustom
                )
            }
            if showsCustom {
                customPicker
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                        removal: .opacity
                    ))
            }
        }
        .padding(.horizontal, InkSpace.xl)
        .padding(.top, InkSpace.xl)
        .padding(.bottom, InkSpace.l)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: InkSpace.m) {
            VStack(alignment: .leading, spacing: InkSpace.xxs) {
                Text("Snooze until…")
                    .font(InkFont.title)
                    .tracking(InkTracking.title)
                    .foregroundStyle(Ink.primary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            IconButton("xmark", label: "Cancel", size: 15, action: cancel)
                .keyboardShortcut(.cancelAction)
                .padding(.top, -InkSpace.s)
                .padding(.trailing, -InkSpace.s)
        }
    }

    private var customPicker: some View {
        VStack(spacing: InkSpace.m) {
            DatePicker("Snooze until", selection: $customDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(accent)
            Button {
                choose(Self.customID, date: customDate)
            } label: {
                Text("Snooze until \(InkDate.reader(customDate))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.inkPrimary)
            .disabled(customDate <= Date())
        }
        .padding(InkSpace.m)
        .background(Ink.elevated, in: RoundedRectangle(cornerRadius: InkRadius.large, style: .continuous))
    }

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    private var subtitle: String? {
        switch conversations.count {
        case 0: return nil
        case 1: return conversations[0].subject
        default: return "\(conversations.count) conversations"
        }
    }

    /// Number keys pick the first nine presets (not while the date picker is open).
    private func shortcut(for index: Int) -> KeyboardShortcut? {
        guard !showsCustom, index < 9 else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
    }

    // MARK: Actions

    private func choose(_ id: String, date: Date) {
        guard chosenID == nil else { return }
        withAnimation(InkMotion.bouncy) { chosenID = id }
        Haptics.success()
        Task {
            // Let the tile light up before the sheet goes.
            try? await Task.sleep(for: .milliseconds(220))
            app.snooze(until: date)
            dismiss()
        }
    }

    private func cancel() {
        app.cancelSnooze()
        dismiss()
    }

    private func toggleCustom() {
        Haptics.tick()
        withAnimation(InkMotion.smooth) { showsCustom.toggle() }
        #if os(iOS)
        detent = showsCustom ? .large : .medium
        #endif
    }

    /// Two hours from the top of the current hour: a sensible starting point for the picker.
    private static func suggestedCustomDate(after now: Date) -> Date {
        let calendar = Calendar.current
        let hourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return calendar.date(byAdding: .hour, value: 2, to: hourStart) ?? now.addingTimeInterval(2 * 3600)
    }
}

/// One snooze choice: symbol, title, time. Fills with colour once chosen.
private struct SnoozeTile: View {
    let systemImage: String
    let title: String
    let detail: String
    let fill: Color?
    let onFill: Color
    let action: () -> Void

    init(systemImage: String, title: String, detail: String, fill: Color?, onFill: Color, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.fill = fill
        self.onFill = onFill
        self.action = action
    }

    var body: some View {
        let isFilled = fill != nil
        Button(action: action) {
            VStack(alignment: .leading, spacing: InkSpace.m) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isFilled ? onFill : Ink.primary)
                    .symbolEffect(.bounce, value: isFilled)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(InkFont.headline)
                        .foregroundStyle(isFilled ? onFill : Ink.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(detail)
                        .font(InkFont.meta)
                        .foregroundStyle(isFilled ? onFill.opacity(0.8) : Ink.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(fill ?? Ink.fill, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
        }
        .buttonStyle(SnoozeTileButtonStyle())
        .accessibilityLabel("\(title), \(detail)")
    }
}

/// Tiles sink a little under the finger and spring back.
private struct SnoozeTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(InkMotion.snappy, value: configuration.isPressed)
    }
}
