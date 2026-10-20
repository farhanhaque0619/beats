import SwiftUI
import InkCore

/// Drives "Connect": verifies the account step by step, saves it, and reports progress at a pace
/// people can read (servers often answer faster than the checks can be seen).
@MainActor
@Observable
final class OnboardingConnector {
    enum Phase: Equatable {
        case editing, connecting, succeeded
    }

    enum RowState: Equatable {
        case pending, active, done
    }

    private(set) var phase: Phase = .editing
    private(set) var failure: OnboardingFailure?
    /// Goes up on every failure so the error card can shake again.
    private(set) var failureCount = 0
    /// The account being connected (and, after success, the one that was added).
    private(set) var account: AccountConfig?

    /// The verification steps, then saving the account and opening its inbox.
    let rowTitles: [String] = OnboardingConnector.verificationSteps.map(\.title) + ["Opening your inbox"]
    /// Rows showing a check.
    private(set) var completed = 0
    /// How far the connection really got; `completed` catches up with it.
    private(set) var reached = 0

    @ObservationIgnored private var work: Task<Void, Never>?
    /// Invalidates scheduled row updates from an earlier attempt.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextReveal = Date.distantPast

    private static let verificationSteps = VerificationStep.allCases.filter { $0 != .done }
    private static let revealInterval: TimeInterval = 0.32

    private var verificationRowCount: Int { Self.verificationSteps.count }

    /// Cancel is offered until the account is being saved.
    var canCancel: Bool { phase == .connecting && reached < verificationRowCount }

    func state(at index: Int) -> RowState {
        if index < completed { return .done }
        if index == completed, phase == .connecting { return .active }
        return .pending
    }

    /// Verifies, then adds the account. Progress, success and failure land in the published state.
    func connect(_ account: AccountConfig, credential: Credential, store: MailStore, provider: OnboardingProvider) {
        guard phase == .editing else { return }
        generation += 1
        failure = nil
        completed = 0
        reached = 0
        nextReveal = Date()
        self.account = account
        withAnimation(InkMotion.smooth) { phase = .connecting }

        work = Task {
            do {
                try await store.verify(account, credential: credential) { step in
                    Task { @MainActor in self.reach(step) }
                }
                try Task.checkCancellation()
                self.reach(index: self.verificationRowCount)
                try await store.addAccount(account, credential: credential)
                self.reach(index: self.rowTitles.count)
                await self.waitForRows()
                guard !Task.isCancelled, self.phase == .connecting else { return }
                withAnimation(InkMotion.bouncy) { self.phase = .succeeded }
                Haptics.success()
            } catch {
                guard !Task.isCancelled, !OnboardingFailure.isCancellation(error) else { return }
                self.fail(OnboardingFailure(error: error, provider: provider))
            }
        }
    }

    /// Stops a connection attempt that hasn't started saving yet.
    func cancel() {
        guard canCancel else { return }
        generation += 1
        work?.cancel()
        work = nil
        Haptics.tick()
        withAnimation(InkMotion.smooth) { phase = .editing }
    }

    /// Shows a problem found before connecting (e.g. sign-in with the provider failed).
    func show(_ failure: OnboardingFailure) {
        failureCount += 1
        withAnimation(InkMotion.smooth) { self.failure = failure }
        Haptics.warning()
    }

    func clearFailure() {
        guard failure != nil else { return }
        withAnimation(InkMotion.snappy) { failure = nil }
    }

    // MARK: Progress

    private func reach(_ step: VerificationStep) {
        reach(index: Self.verificationSteps.firstIndex(of: step) ?? verificationRowCount)
    }

    /// Marks every row before `index` as done, one after another.
    private func reach(index: Int) {
        let target = min(index, rowTitles.count)
        guard phase == .connecting, target > reached else { return }
        let attempt = generation
        for row in (reached + 1)...target {
            let now = Date()
            let revealAt = max(now, nextReveal.addingTimeInterval(Self.revealInterval))
            nextReveal = revealAt
            let delay = revealAt.timeIntervalSince(now)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard self.generation == attempt, self.phase == .connecting else { return }
                withAnimation(InkMotion.bouncy) { self.completed = max(self.completed, row) }
            }
        }
        reached = target
    }

    /// Waits until the last check has been shown.
    private func waitForRows() async {
        let remaining = nextReveal.timeIntervalSinceNow
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64((remaining + 0.12) * 1_000_000_000))
        }
    }

    private func fail(_ failure: OnboardingFailure) {
        generation += 1
        work = nil
        failureCount += 1
        self.failure = failure
        withAnimation(InkMotion.smooth) { phase = .editing }
        Haptics.warning()
    }
}
