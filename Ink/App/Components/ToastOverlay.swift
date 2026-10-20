import SwiftUI
import InkCore

/// Shows `MailStore.toast` as a floating capsule at the bottom, with Undo when the action allows
/// it. Dismisses itself after the undo window (or 2.5 s for plain messages). Swipe it down to
/// dismiss early.
struct ToastOverlay: View {
    @Environment(MailStore.self) private var store
    @Environment(\.inkAccent) private var accent
    /// Extra space below the toast (e.g. to clear the compose button on iPhone).
    var bottomInset: CGFloat = 0
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            if let toast = store.toast {
                content(toast)
                    .id(toast.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    ))
                    .task(id: toast.id) {
                        let seconds = toast.undoable ? max(store.undoWindow, 2) : (toast.style == .error ? 4 : 2.5)
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        guard !Task.isCancelled, store.toast?.id == toast.id else { return }
                        withAnimation(InkMotion.toast) { store.dismissToast() }
                    }
            }
        }
        .padding(.horizontal, InkSpace.l)
        .padding(.bottom, InkSpace.m + bottomInset)
        .animation(InkMotion.toast, value: store.toast?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(store.toast != nil)
    }

    private func content(_ toast: Toast) -> some View {
        HStack(spacing: InkSpace.m) {
            if let image = toast.systemImage {
                Image(systemName: image)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor(toast))
                    .symbolEffect(.bounce, value: toast.id)
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
                        .padding(.horizontal, InkSpace.s)
                        .padding(.vertical, InkSpace.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("z", modifiers: .command)
            }
        }
        .padding(.leading, InkSpace.l)
        .padding(.trailing, toast.undoable ? InkSpace.s : InkSpace.l)
        .padding(.vertical, 13)
        .frame(maxWidth: 460)
        .background(Ink.elevated, in: Capsule())
        .overlay(Capsule().stroke(Ink.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .offset(y: max(0, drag))
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    if value.translation.height > 30 {
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
