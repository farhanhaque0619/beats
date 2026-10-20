import SwiftUI
import InkCore

/// Adding an account: pick a provider, fill in the form, watch it connect, "You're in."
/// Presented as a sheet from the welcome screen, Settings and the Mac sidebar.
struct AddAccountFlow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var choice: ProviderID?
    /// Connecting or celebrating: no going back and no swiping the sheet away.
    @State private var isBusy = false
    @GestureState(resetTransaction: Transaction(animation: InkMotion.swipeSettle)) private var edgeDrag: CGFloat = 0

    var body: some View {
        ZStack {
            if let choice {
                OnboardingAccountForm(
                    choice: choice,
                    isBusy: $isBusy,
                    onBack: goBack,
                    onSwitchProvider: pick,
                    onFinish: close
                )
                .offset(x: edgeDrag)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(1)
            } else {
                OnboardingProviderPicker(onPick: pick, onClose: close)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background.ignoresSafeArea())
        .clipped()
        #if os(iOS)
        .overlay(alignment: .leading) { backSwipeEdge }
        .presentationDragIndicator(.hidden)
        #endif
        .interactiveDismissDisabled(isBusy)
        #if os(macOS)
        .frame(width: 480, height: 640)
        #endif
    }

    /// Swipe from the left edge to go back to the providers, like a navigation stack.
    @ViewBuilder private var backSwipeEdge: some View {
        if choice != nil, !isBusy {
            Color.clear
                .frame(width: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .updating($edgeDrag) { value, state, _ in
                            state = max(0, value.translation.width)
                        }
                        .onEnded { value in
                            if value.translation.width > 110 || value.predictedEndTranslation.width > 260 {
                                goBack()
                            }
                        }
                )
                .accessibilityHidden(true)
        }
    }

    private func pick(_ id: ProviderID) {
        withAnimation(InkMotion.smooth) { choice = id }
    }

    private func goBack() {
        guard !isBusy else { return }
        Haptics.tick()
        withAnimation(InkMotion.smooth) { choice = nil }
    }

    private func close() {
        app.isAddAccountPresented = false
        dismiss()
    }
}
