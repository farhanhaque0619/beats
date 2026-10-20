import SwiftUI
import AuthenticationServices
import InkCore

/// Step two of adding an account: who you are and how you sign in, then Connect. Shows the
/// connection checklist and the success screen in place.
struct OnboardingAccountForm: View {
    let choice: ProviderID
    /// True while connecting or celebrating, so the sheet can't be swiped away mid-way.
    @Binding var isBusy: Bool
    var onBack: () -> Void
    var onSwitchProvider: (ProviderID) -> Void
    var onFinish: () -> Void

    @Environment(MailStore.self) private var store
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var connector = OnboardingConnector()
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var revealsPassword = false
    @State private var imap = OnboardingServerFields(port: 993)
    @State private var smtp = OnboardingServerFields(port: 465)
    @State private var discovery: DiscoveryResult?
    @State private var discoveryStatus: OnboardingDiscoveryStatus = .idle
    @State private var showsServerSettings = false
    @State private var isAuthorizing = false
    /// Chose "Use an app password instead" on a provider that offers sign-in.
    @State private var prefersAppPassword = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case name, email, password
    }

    var body: some View {
        ZStack {
            switch connector.phase {
            case .editing:
                editor
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .connecting:
                OnboardingConnectionView(connector: connector, providerName: provider.name, email: connectingEmail)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            case .succeeded:
                OnboardingSuccessView(email: connectingEmail, onDone: onFinish)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: connector.phase) { _, phase in
            isBusy = phase != .editing
        }
        .task(id: discoveryKey) { await discover() }
        .task { await focusFirstField() }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: InkSpace.xl) {
                    header
                    if let failure = connector.failure {
                        OnboardingFailureCard(failure: failure, attempt: connector.failureCount)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if let suggestion = suggestedProvider {
                        switchSuggestion(suggestion)
                            .transition(.opacity)
                    }
                    authContent
                    if !notes.isEmpty {
                        OnboardingNotes(notes: notes)
                    }
                }
                .padding(.horizontal, InkSpace.xl)
                .padding(.top, InkSpace.s)
                .padding(.bottom, InkSpace.xxl)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .animation(InkMotion.smooth, value: guideID)
                .animation(InkMotion.snappy, value: suggestedProvider)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: InkSpace.xs) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                    Text("Providers")
                        .font(.body)
                }
                .foregroundStyle(Ink.primary)
                .frame(minHeight: InkSize.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Back to providers")
            #if os(macOS)
            .keyboardShortcut(.cancelAction)
            #endif
            Spacer()
        }
        .padding(.horizontal, InkSpace.l)
        .padding(.top, InkSpace.xs)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: InkSpace.s) {
            Image(systemName: provider.glyph)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Ink.primary)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(title)
                .font(InkFont.largeTitle)
                .tracking(InkTracking.largeTitle)
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, InkSpace.s)
    }

    @ViewBuilder private var authContent: some View {
        let auth = self.auth
        if signsInFirst {
            signInFirstContent
        } else if auth.allowsPassword {
            if auth.isOAuthAvailable, let oauth = auth.oauth {
                OnboardingOAuthButton(provider: oauth, prominent: false, isWorking: isAuthorizing) {
                    signIn(with: oauth)
                }
                OnboardingDividerLabel(text: "or use an app password")
            }
            identityFields(includesPassword: true)
            if !auth.steps.isEmpty {
                OnboardingGuideCard(
                    title: provider.guideTitle,
                    requirement: provider.requirement,
                    steps: auth.steps,
                    pageURL: auth.pageURL,
                    pageButtonTitle: provider.pageButtonTitle
                )
            }
            if usesServerSettings {
                OnboardingServerSettingsCard(imap: $imap, smtp: $smtp, status: discoveryStatus, isExpanded: $showsServerSettings)
            }
        } else {
            if !auth.steps.isEmpty {
                OnboardingGuideCard(
                    title: provider.guideTitle,
                    requirement: provider.requirement,
                    steps: auth.steps,
                    pageURL: auth.pageURL,
                    pageButtonTitle: provider.pageButtonTitle
                )
            }
            if auth.isOAuthAvailable {
                identityFields(includesPassword: false)
            } else if let oauth = auth.oauth {
                OnboardingOAuthUnavailableCard(provider: oauth)
            }
        }
    }

    /// Gmail with Sign in with Google in this build: no form at all. The provider's page asks who
    /// you are, and its answer fills in the address and name.
    private var signInFirstContent: some View {
        VStack(alignment: .leading, spacing: InkSpace.m) {
            Label {
                Text("Your password goes to \(signInCompany) only. Ink gets a key to your mail that you can revoke any time.")
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Ink.secondary)
            }
            Button("Use an app password instead") {
                Haptics.tick()
                connector.clearFailure()
                withAnimation(InkMotion.smooth) { prefersAppPassword = true }
                // The fields only exist once the switch has rendered.
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if connector.phase == .editing { focus = .name }
                }
            }
            .buttonStyle(.inkAccent)
        }
        .padding(InkSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.fill, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
    }

    private func identityFields(includesPassword: Bool) -> some View {
        OnboardingFieldGroup {
            OnboardingFieldRow(label: "Name") {
                TextField("Your name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = .email }
                    #if os(iOS)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    #endif
            }
            OnboardingFieldRow(label: "Email", showsDivider: includesPassword) {
                TextField(provider.emailPrompt, text: $email)
                    .textFieldStyle(.plain)
                    .onboardingEmailInput()
                    .focused($focus, equals: .email)
                    .submitLabel(includesPassword ? .next : .done)
                    .onSubmit { focus = includesPassword ? .password : nil }
            }
            if includesPassword {
                OnboardingFieldRow(label: provider.passwordLabel, showsDivider: false) {
                    passwordField
                }
            }
        }
    }

    private var passwordField: some View {
        HStack(spacing: InkSpace.s) {
            Group {
                if revealsPassword {
                    TextField(provider.passwordPrompt, text: $password)
                        .font(InkFont.mono)
                } else {
                    SecureField(provider.passwordPrompt, text: $password)
                }
            }
            .textFieldStyle(.plain)
            .onboardingLiteralInput()
            .focused($focus, equals: .password)
            .submitLabel(.go)
            .onSubmit(connectWithPassword)

            if let length = provider.passwordLength, !cleanedPassword.isEmpty {
                Text("\(cleanedPassword.count)/\(length)")
                    .font(InkFont.meta)
                    .foregroundStyle(cleanedPassword.count == length ? Ink.success : Ink.tertiary)
                    .contentTransition(.numericText())
                    .accessibilityLabel("\(cleanedPassword.count) of \(length) characters")
            }

            Button {
                revealsPassword.toggle()
                focus = .password
            } label: {
                Image(systemName: revealsPassword ? "eye.slash" : "eye")
                    .font(.subheadline)
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealsPassword ? "Hide password" : "Show password")
        }
        .animation(InkMotion.snappy, value: cleanedPassword.count)
    }

    private func switchSuggestion(_ id: ProviderID) -> some View {
        let info = OnboardingProvider.info(for: id)
        return HStack(spacing: InkSpace.m) {
            Image(systemName: info.glyph)
                .font(.title3.weight(.light))
                .foregroundStyle(Ink.primary)
                .accessibilityHidden(true)
            Text("That address belongs to \(info.name).")
                .font(.subheadline)
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: InkSpace.s)
            Button("Switch") {
                Haptics.tick()
                onSwitchProvider(id)
            }
            .buttonStyle(.inkAccent)
        }
        .padding(InkSpace.m)
        .background(Ink.fill, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
    }

    @ViewBuilder private var bottomBar: some View {
        let auth = self.auth
        if signsInFirst, let oauth = auth.oauth {
            OnboardingOAuthButton(provider: oauth, prominent: true, isWorking: isAuthorizing) {
                signIn(with: oauth)
            }
            .keyboardShortcut(.defaultAction)
            .modifier(OnboardingBottomBar())
        } else if auth.allowsPassword {
            Button(action: connectWithPassword) {
                Text("Connect")
            }
            .buttonStyle(.inkPrimary)
            .disabled(!canConnect)
            .keyboardShortcut(.defaultAction)
            .modifier(OnboardingBottomBar())
        } else if auth.isOAuthAvailable, let oauth = auth.oauth {
            OnboardingOAuthButton(provider: oauth, prominent: true, isWorking: isAuthorizing) {
                signIn(with: oauth)
            }
            .modifier(OnboardingBottomBar())
        }
    }

    // MARK: Derived state

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var address: EmailAddress { EmailAddress(address: trimmedEmail) }

    /// The provider a known domain belongs to (gmail.com → Gmail).
    private var emailPresetID: ProviderID? {
        guard address.isValid else { return nil }
        return Providers.preset(forEmail: trimmedEmail)?.id
    }

    /// "Other" with an unknown domain: the server settings are looked up and editable.
    private var usesServerSettings: Bool { choice == .other && emailPresetID == nil }

    /// Whose rules apply: the provider picked, or for Other, the one the address points to.
    private var guideID: ProviderID {
        if choice != .other { return choice }
        if let known = emailPresetID { return known }
        if let hosted = discovery?.preset, hosted != .other, hosted != .demo { return hosted }
        return .other
    }

    private var provider: OnboardingProvider { OnboardingProvider.info(for: guideID) }
    private var auth: OnboardingAuth { provider.auth }

    private var signInCompany: String { auth.oauth == .microsoft ? "Microsoft" : "Google" }

    /// The provider takes both an app password and sign-in, and sign-in is set up in this build:
    /// lead with sign-in. Not for Other, where the address being typed picks the provider and the
    /// field can't vanish under the cursor.
    private var signsInFirst: Bool {
        choice != .other && auth.allowsPassword && auth.isOAuthAvailable && auth.oauth != nil && !prefersAppPassword
    }

    private var suggestedProvider: ProviderID? {
        guard choice != .other, let detected = emailPresetID, detected != choice else { return nil }
        return detected
    }

    private var title: String {
        choice == .other ? "Add an account" : "Add \(OnboardingProvider.info(for: choice).name)"
    }

    private var subtitle: String {
        if signsInFirst {
            return "Sign in on \(signInCompany)'s own page, and Ink takes it from there."
        }
        if choice == .other, guideID != .other {
            return emailPresetID != nil
                ? "Looks like \(provider.name). Ink knows its settings."
                : "Your domain's mail is with \(provider.name)."
        }
        if !auth.allowsPassword {
            return "Microsoft only lets mail apps in with Sign in with Microsoft."
        }
        if guideID == .other, Self.protonDomains.contains(address.domain) {
            return "Proton Mail has no IMAP of its own, so Ink can't connect to it directly."
        }
        if guideID == .other {
            return "Ink finds your server settings from your address."
        }
        return "Ink signs in with an app password: a separate password just for Ink that you can revoke any time."
    }

    /// Proton's own domains: no IMAP without Proton Mail Bridge (RESEARCH §2.2).
    private static let protonDomains: Set<String> = ["proton.me", "protonmail.com", "protonmail.ch", "pm.me"]

    private var notes: [String] {
        if !provider.notes.isEmpty { return provider.notes }
        return Providers.preset(for: guideID)?.notes ?? []
    }

    /// What the person typed, minus the spaces providers print app passwords with.
    private var cleanedPassword: String {
        provider.stripsSpaces ? password.filter { !$0.isWhitespace } : password.trimmingCharacters(in: .newlines)
    }

    private var canConnect: Bool {
        guard auth.allowsPassword, address.isValid, !cleanedPassword.isEmpty, !isAuthorizing else { return false }
        guard usesServerSettings else { return true }
        switch discoveryStatus {
        case .found, .notFound: return imap.isComplete && smtp.isComplete
        case .idle, .looking: return false
        }
    }

    private var connectingEmail: String { connector.account?.emailAddress ?? trimmedEmail }

    private var discoveryKey: String { usesServerSettings && address.isValid ? address.normalized : "" }

    /// The first unused colour, so each account keeps its own hint of colour.
    private var nextColorIndex: Int {
        let used = Set(store.accounts.filter { !$0.isDemo }.map(\.colorIndex))
        return (0..<AccountPalette.colors.count).first { !used.contains($0) } ?? store.accounts.count
    }

    // MARK: Actions

    private func connectWithPassword() {
        guard canConnect, connector.phase == .editing else { return }
        focus = nil
        let address = trimmedEmail
        guard let account = makeAccount(email: address, name: resolvedName(fallback: nil, email: address), authMethod: .password, oauth: nil) else {
            connector.show(missingSettingsFailure)
            return
        }
        connector.connect(account, credential: .password(cleanedPassword), store: store, provider: provider)
    }

    private func signIn(with oauthProvider: OAuthProviderID) {
        guard !isAuthorizing, connector.phase == .editing else { return }
        focus = nil
        connector.clearFailure()
        isAuthorizing = true
        let hint = address.isValid ? trimmedEmail : nil
        let session = webAuthenticationSession
        Task {
            do {
                let result = try await OAuthSignIn.signIn(provider: oauthProvider, loginHint: hint, session: session)
                isAuthorizing = false
                let signedIn = (result.email ?? trimmedEmail).trimmingCharacters(in: .whitespacesAndNewlines)
                guard EmailAddress(address: signedIn).isValid else {
                    connector.show(OnboardingFailure(
                        message: "Signed in, but your address didn't come back.",
                        hint: "Type your email address above and sign in again."
                    ))
                    return
                }
                if signedIn.lowercased() != trimmedEmail.lowercased() { email = signedIn }
                let displayName = resolvedName(fallback: result.name, email: signedIn)
                guard let account = makeAccount(email: signedIn, name: displayName, authMethod: .oauth2, oauth: oauthProvider) else {
                    connector.show(missingSettingsFailure)
                    return
                }
                connector.connect(account, credential: .oauth(result.token), store: store, provider: provider)
            } catch {
                isAuthorizing = false
                guard !OnboardingFailure.isCancellation(error) else { return }
                connector.show(OnboardingFailure(error: error, provider: provider))
            }
        }
    }

    private var missingSettingsFailure: OnboardingFailure {
        OnboardingFailure(
            message: "Ink doesn't have \(provider.name)'s server settings.",
            hint: "Go back, choose Other and enter them under Advanced."
        )
    }

    private func resolvedName(fallback: String?, email: String) -> String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        if let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty { return fallback }
        return EmailAddress(address: email).localPart
    }

    private func makeAccount(email: String, name: String, authMethod: AuthMethod, oauth: OAuthProviderID?) -> AccountConfig? {
        var account: AccountConfig
        if usesServerSettings {
            guard let incoming = imap.serverConfig(fallbackUsername: email),
                  let outgoing = smtp.serverConfig(fallbackUsername: email) else { return nil }
            let hostedID = discovery?.preset
            let hosted = hostedID.flatMap { Providers.preset(for: $0) }
            account = AccountConfig(
                provider: hosted?.id ?? .other,
                displayName: name,
                emailAddress: email,
                imap: incoming,
                smtp: outgoing,
                authMethod: authMethod,
                oauthProvider: oauth,
                savesSentAutomatically: hosted?.savesSentAutomatically ?? false
            )
        } else if let preset = Providers.preset(for: guideID) {
            account = preset.accountConfig(email: email, displayName: name, authMethod: authMethod)
            if let oauth { account.oauthProvider = oauth }
        } else {
            return nil
        }
        account.colorIndex = nextColorIndex
        return account
    }

    // MARK: Discovery and focus

    /// Looks up server settings for an unknown domain, a moment after typing stops.
    private func discover() async {
        let target = trimmedEmail
        guard usesServerSettings, EmailAddress(address: target).isValid else {
            if discoveryStatus != .idle {
                withAnimation(InkMotion.snappy) {
                    discoveryStatus = .idle
                    discovery = nil
                }
            }
            return
        }
        try? await Task.sleep(nanoseconds: 550_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(InkMotion.snappy) { discoveryStatus = .looking }
        let result = await Autodiscovery.discover(email: target)
        guard !Task.isCancelled else { return }
        let domain = EmailAddress(address: target).domain
        withAnimation(InkMotion.smooth) {
            discovery = result
            if let result {
                imap = OnboardingServerFields(result.imap)
                smtp = OnboardingServerFields(result.smtp)
                discoveryStatus = .found(source: result.source)
                // A guess (imap.<domain>) is worth checking before connecting.
                showsServerSettings = result.isGuess
            } else {
                imap = OnboardingServerFields(host: "imap.\(domain)", port: 993, security: .tls, username: target)
                smtp = OnboardingServerFields(host: "smtp.\(domain)", port: 465, security: .tls, username: target)
                discoveryStatus = .notFound
                showsServerSettings = true
            }
        }
    }

    /// Puts the cursor in the first field once the slide-in has settled.
    private func focusFirstField() async {
        guard auth.allowsPassword, !signsInFirst else { return }
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !Task.isCancelled, focus == nil, connector.phase == .editing else { return }
        focus = .name
    }
}

/// The pinned area under the form that holds Connect.
private struct OnboardingBottomBar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, InkSpace.xl)
            .padding(.vertical, InkSpace.m)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background(
                Ink.background
                    .opacity(0.96)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Ink.hairline).frame(height: 0.5)
                    }
                    .ignoresSafeArea()
            )
    }
}
