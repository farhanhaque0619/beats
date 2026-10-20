import SwiftUI
import Accessibility
import InkCore

/// Shows `MailStore.toast` as a floating capsule at the bottom, with Undo when the action allows
/// it. An undoable toast stays for as long as Undo works (the store drops the button when the
/// action or send commits, then the toast lingers briefly); plain messages leave after 2.5 s,
/// errors after 4 s. Swipe it down to dismiss early.
struct ToastOverlay: View {
    @Environment(MailStore.self) private var store
    @Environment(\.inkAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// Extra space below the toast (e.g. to clear the compose button on iPhone).
    var bottomInset: CGFloat = 0
    @State private var drag: CGFloat = 0
    /// The toast that last showed Undo; once the store retires it, it only lingers briefly.
    @State private var undoableID: UUID?

    /// Restarts the dismiss timer when a new toast arrives and again when the store retires a
    /// toast's Undo (same id, `undoable` flips to false).
    private struct Phase: Equatable {
        var id: UUID
        var undoable: Bool
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let toast = store.toast {
                content(toast)
                    .id(toast.id)
                    .transition(transition)
                    .task(id: Phase(id: toast.id, undoable: toast.undoable)) {
                        await expire(toast)
                    }
            }
        }
        .padding(.horizontal, InkSpace.l)
        .padding(.bottom, InkSpace.m + bottomInset)
        .animation(InkMotion.adaptive(InkMotion.toast, reduceMotion: reduceMotion), value: store.toast?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(store.toast != nil)
        .onChange(of: store.toast?.id) { _, id in
            // VoiceOver users hear the toast without hunting for it.
            guard let id, let message = store.toast?.message, ToastAnnouncer.lastID != id else { return }
            // Root and Search both host an overlay; only the first one speaks.
            ToastAnnouncer.lastID = id
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92)),
            removal: .opacity.combined(with: .scale(scale: 0.96))
        )
    }

    /// Waits out the toast, then dismisses it if it is still the one showing.
    private func expire(_ toast: Toast) async {
        let seconds: TimeInterval
        if toast.undoable {
            // The store flips `undoable` off when the window closes, which restarts this task;
            // this is only a backstop in case that never happens.
            undoableID = toast.id
            seconds = max(store.undoWindow, store.undoSendDelay) + 2
        } else if toast.id == undoableID {
            // Undo just expired: let the message settle for a beat, then go.
            seconds = 1.2
        } else if toast.style == .error {
            seconds = 4
        } else {
            seconds = 2.5
        }
        let dwell = voiceOverEnabled ? seconds * 2 : seconds
        try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
        guard !Task.isCancelled, store.toast?.id == toast.id else { return }
        withAnimation(InkMotion.adaptive(InkMotion.toast, reduceMotion: reduceMotion)) { store.dismissToast() }
    }

    private func content(_ toast: Toast) -> some View {
        HStack(spacing: InkSpace.m) {
            if let image = toast.systemImage {
                Image(systemName: image)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor(toast))
                    .symbolEffect(.bounce, value: toast.id)
                    .accessibilityHidden(true)
            }
            Text(toast.message)
                .font(.system(.subheadline, design: .default, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(2)
            if toast.undoable {
                Spacer(minLength: InkSpace.s)
                Button {
                    Haptics.tick()
                    withAnimation(InkMotion.smooth) { store.undo() }
                } label: {
                    Text("Undo")
                        .font(InkFont.button)
                        .foregroundStyle(accent)
                        .padding(.horizontal, InkSpace.m)
                        .padding(.vertical, InkSpace.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .keyboardShortcut("z", modifiers: .command)
                .transition(.opacity)
            }
        }
        .padding(.leading, InkSpace.l)
        .padding(.trailing, toast.undoable ? InkSpace.xs : InkSpace.l)
        // The Undo button is 8 pt taller than a line of text; trimming the padding by as much
        // keeps the capsule the same height when the store retires Undo.
        .padding(.vertical, toast.undoable ? 13 - InkSpace.xs : 13)
        .frame(maxWidth: 460)
        .background(Ink.elevated, in: Capsule())
        .overlay(Capsule().stroke(Ink.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .animation(InkMotion.snappy, value: toast.undoable)
        .offset(y: drag > 0 ? drag : drag / 4)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    let flung = value.predictedEndTranslation.height > 80
                    if value.translation.height > 30 || flung {
                        withAnimation(InkMotion.toast) { store.dismissToast() }
                    }
                    withAnimation(InkMotion.snappy) { drag = 0 }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }

    private func iconColor(_ toast: Toast) -> Color {
        switch toast.style {
        case .info: return Ink.primary
        case .success: return Ink.success
        case .error: return Ink.danger
        }
    }
}

@MainActor
private enum ToastAnnouncer {
    static var lastID: UUID?
}
