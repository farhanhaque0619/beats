import SwiftUI
import InkCore

/// Links into the project's docs, opened from onboarding and Settings.
enum OnboardingLinks {
    /// docs/ACCOUNTS.md: how to connect each provider.
    static let accountsGuide = URL(string: "https://github.com/farhanhaque0619/beats/blob/HEAD/Ink/docs/ACCOUNTS.md")
    /// The Outlook section of docs/ACCOUNTS.md (app registration for Sign in with Microsoft).
    static let outlookGuide = URL(string: "https://github.com/farhanhaque0619/beats/blob/HEAD/Ink/docs/ACCOUNTS.md#outlookcom-hotmail-live-sign-in-with-microsoft")
    /// docs/RESEARCH.md: the research notes behind Ink.
    static let researchNotes = URL(string: "https://github.com/farhanhaque0619/beats/blob/HEAD/Ink/docs/RESEARCH.md")
}

/// The words Ink shows around each provider while adding an account: glyph, guidance, how to make
/// an app password and what to say when sign-in fails. Server details come from InkProviders'
/// presets; this is the human side.
struct OnboardingProvider {
    let id: ProviderID
    let name: String
    /// Monochrome SF Symbol.
    let glyph: String
    /// One line under the name in the provider list.
    let detail: String
    /// Label and placeholder of the password field.
    let passwordLabel: String
    let passwordPrompt: String
    let emailPrompt: String
    /// App passwords that never contain spaces: strip any the person pasted.
    let stripsSpaces: Bool
    /// Exact length of the provider's app passwords, when it has one (Gmail: 16).
    let passwordLength: Int?
    /// Microsoft only lets mail apps in with OAuth.
    let requiresOAuth: Bool
    /// What must be true on the provider's side first (shown highlighted).
    let requirement: String?
    let guideTitle: String
    /// Steps used when the preset doesn't bring its own.
    let steps: [String]
    let pageURL: URL?
    let pageButtonTitle: String
    /// Gotchas worth knowing, shown quietly under the guide.
    let notes: [String]
    /// Shown under the server's message when the password is refused.
    let authFailureHint: String
    /// Shown when the server can't be reached.
    let connectionHint: String

    /// Rows in the provider list, in order.
    static let pickerOrder: [ProviderID] = [.gmail, .icloud, .outlook, .yahoo, .fastmail, .other]

    static func info(for id: ProviderID) -> OnboardingProvider {
        switch id {
        case .gmail: return gmail
        case .icloud: return icloud
        case .outlook: return outlook
        case .yahoo: return yahoo
        case .aol: return aol
        case .fastmail: return fastmail
        case .zoho: return zoho
        case .other: return other
        case .demo: return demo
        }
    }

    /// The preset's own steps and page when it has them, else the ones written here.
    var auth: OnboardingAuth { OnboardingAuth(provider: self) }

    private static let reachHint = "Check your connection and try again."

    private static let gmail = OnboardingProvider(
        id: .gmail,
        name: "Gmail",
        glyph: "g.circle",
        detail: "Google accounts and Workspace",
        passwordLabel: "App password",
        passwordPrompt: "16 characters",
        emailPrompt: "you@gmail.com",
        stripsSpaces: true,
        passwordLength: 16,
        requiresOAuth: false,
        requirement: "App passwords need 2-Step Verification on your Google Account.",
        guideTitle: "How to get an app password",
        steps: [
            "Turn on 2-Step Verification in your Google Account, if it isn't on yet.",
            "Open myaccount.google.com/apppasswords, type “Ink” as the name and choose Create.",
            "Copy the 16-character password. Spaces don't matter.",
        ],
        pageURL: URL(string: "https://myaccount.google.com/apppasswords"),
        pageButtonTitle: "Open App passwords",
        notes: [
            "IMAP is always on for Gmail, so there's nothing to switch on.",
            "Changing your Google password cancels app passwords. Just make a new one.",
        ],
        authFailureHint: "Gmail only lets mail apps in with an app password, not your Google password. Make one at myaccount.google.com/apppasswords (it needs 2-Step Verification).",
        connectionHint: reachHint
    )

    private static let icloud = OnboardingProvider(
        id: .icloud,
        name: "iCloud Mail",
        glyph: "icloud.circle",
        detail: "@icloud.com, @me.com and @mac.com",
        passwordLabel: "App password",
        passwordPrompt: "xxxx-xxxx-xxxx-xxxx",
        emailPrompt: "you@icloud.com",
        stripsSpaces: true,
        passwordLength: nil,
        requiresOAuth: false,
        requirement: "App-specific passwords need two-factor authentication on your Apple Account.",
        guideTitle: "How to get an app-specific password",
        steps: [
            "Go to account.apple.com and sign in.",
            "Open Sign-In and Security, then App-Specific Passwords.",
            "Choose +, name it “Ink”, and copy the password.",
        ],
        pageURL: URL(string: "https://account.apple.com"),
        pageButtonTitle: "Open Apple Account",
        notes: [
            "Use your iCloud address (…@icloud.com, @me.com or @mac.com).",
            "Changing your Apple Account password cancels app-specific passwords.",
        ],
        authFailureHint: "iCloud needs an app-specific password, not your Apple Account password. Create one at account.apple.com under Sign-In and Security.",
        connectionHint: reachHint
    )

    private static let outlook = OnboardingProvider(
        id: .outlook,
        name: "Outlook",
        glyph: "o.circle",
        detail: "Outlook.com, Hotmail and Live",
        passwordLabel: "Password",
        passwordPrompt: "Password",
        emailPrompt: "you@outlook.com",
        stripsSpaces: false,
        passwordLength: nil,
        requiresOAuth: true,
        requirement: "Microsoft requires Sign in with Microsoft. Passwords and app passwords no longer work for mail apps.",
        guideTitle: "Turn on IMAP first",
        steps: [
            "Open outlook.com, then Settings, Mail, Forwarding and IMAP.",
            "Turn on “Let devices and apps use IMAP” and save.",
            "Come back here and sign in with Microsoft.",
        ],
        pageURL: URL(string: "https://outlook.live.com/mail/"),
        pageButtonTitle: "Open Outlook.com",
        notes: [],
        authFailureHint: "Microsoft didn't let Ink in. Check that IMAP is on in Outlook.com (Settings, Mail, Forwarding and IMAP), then sign in again.",
        connectionHint: reachHint
    )

    private static let yahoo = OnboardingProvider(
        id: .yahoo,
        name: "Yahoo",
        glyph: "y.circle",
        detail: "Yahoo Mail",
        passwordLabel: "App password",
        passwordPrompt: "16 letters",
        emailPrompt: "you@yahoo.com",
        stripsSpaces: true,
        passwordLength: nil,
        requiresOAuth: false,
        requirement: nil,
        guideTitle: "How to get an app password",
        steps: [
            "Open Account Security at login.yahoo.com/account/security.",
            "Choose Generate app password (under App passwords or External connections).",
            "Name it “Ink” and copy the password.",
        ],
        pageURL: URL(string: "https://login.yahoo.com/account/security"),
        pageButtonTitle: "Open Account Security",
        notes: [
            "Yahoo sometimes refuses to make an app password for an account. If that happens, Ink can't connect to it.",
            "Yahoo doesn't push new mail, so Ink checks when you open or refresh.",
        ],
        authFailureHint: "Yahoo needs an app password, not your Yahoo password. Generate one in Account Security.",
        connectionHint: reachHint
    )

    private static let aol = OnboardingProvider(
        id: .aol,
        name: "AOL",
        glyph: "a.circle",
        detail: "AOL Mail",
        passwordLabel: "App password",
        passwordPrompt: "16 letters",
        emailPrompt: "you@aol.com",
        stripsSpaces: true,
        passwordLength: nil,
        requiresOAuth: false,
        requirement: nil,
        guideTitle: "How to get an app password",
        steps: [
            "Open Account Security at login.aol.com/account/security.",
            "Choose Generate app password.",
            "Name it “Ink” and copy the password.",
        ],
        pageURL: URL(string: "https://login.aol.com/account/security"),
        pageButtonTitle: "Open Account Security",
        notes: [],
        authFailureHint: "AOL needs an app password, not your AOL password. Generate one in Account Security.",
        connectionHint: reachHint
    )

    private static let fastmail = OnboardingProvider(
        id: .fastmail,
        name: "Fastmail",
        glyph: "f.circle",
        detail: "Fastmail and your domains there",
        passwordLabel: "App password",
        passwordPrompt: "App password",
        emailPrompt: "you@fastmail.com",
        stripsSpaces: false,
        passwordLength: nil,
        requiresOAuth: false,
        requirement: "Fastmail's Basic plan doesn't include IMAP.",
        guideTitle: "How to get an app password",
        steps: [
            "In Fastmail, open Settings, then Privacy & Security.",
            "Choose Manage app passwords, then New app password.",
            "Give it access to “Mail (IMAP/POP/SMTP)” and copy the password.",
        ],
        pageURL: URL(string: "https://app.fastmail.com/settings/security"),
        pageButtonTitle: "Open Fastmail settings",
        notes: ["Use your full Fastmail address."],
        authFailureHint: "Fastmail needs an app password with Mail (IMAP/POP/SMTP) access. The Basic plan doesn't include IMAP.",
        connectionHint: reachHint
    )

    private static let zoho = OnboardingProvider(
        id: .zoho,
        name: "Zoho Mail",
        glyph: "z.circle",
        detail: "Zoho Mail",
        passwordLabel: "Password",
        passwordPrompt: "Password or app password",
        emailPrompt: "you@zohomail.com",
        stripsSpaces: false,
        passwordLength: nil,
        requiresOAuth: false,
        requirement: nil,
        guideTitle: "Before you connect",
        steps: [
            "In Zoho Mail, open Settings, then IMAP, and make sure IMAP access is on.",
            "With two-factor authentication on, create an app password in Zoho Accounts, under Security.",
        ],
        pageURL: URL(string: "https://accounts.zoho.com"),
        pageButtonTitle: "Open Zoho Accounts",
        notes: [],
        authFailureHint: "Check that IMAP is on in Zoho Mail. With two-factor authentication on, Zoho needs an app password.",
        connectionHint: reachHint
    )

    private static let other = OnboardingProvider(
        id: .other,
        name: "Other",
        glyph: "at.circle",
        detail: "Any IMAP account, custom domains too",
        passwordLabel: "Password",
        passwordPrompt: "Password or app password",
        emailPrompt: "you@example.com",
        stripsSpaces: false,
        passwordLength: nil,
        requiresOAuth: false,
        requirement: nil,
        guideTitle: "",
        steps: [],
        pageURL: nil,
        pageButtonTitle: "",
        notes: [
            "Ink looks up your server settings and shows them under Advanced before your password goes anywhere.",
            "Turn on IMAP in your provider's settings if it's off. Many providers want an app password for mail apps.",
        ],
        authFailureHint: "Check the password, and the username under Advanced. Many providers want an app password for mail apps.",
        connectionHint: "Check the server names and ports under Advanced."
    )

    private static let demo = OnboardingProvider(
        id: .demo,
        name: "Demo",
        glyph: "sparkles",
        detail: "Sample mail that never leaves this device",
        passwordLabel: "Password",
        passwordPrompt: "Password",
        emailPrompt: "",
        stripsSpaces: false,
        passwordLength: nil,
        requiresOAuth: false,
        requirement: nil,
        guideTitle: "",
        steps: [],
        pageURL: nil,
        pageButtonTitle: "",
        notes: [],
        authFailureHint: "",
        connectionHint: ""
    )
}

/// How a provider lets mail apps sign in, merged from its InkProviders preset and Ink's copy.
struct OnboardingAuth {
    /// The OAuth provider the preset offers, if any.
    var oauth: OAuthProviderID?
    /// Whether this build has a client ID for `oauth`.
    var isOAuthAvailable: Bool
    var allowsPassword: Bool
    var steps: [String]
    var pageURL: URL?

    init(provider: OnboardingProvider) {
        var oauth: OAuthProviderID?
        var allowsPassword = provider.id != .demo
        var steps = provider.steps
        var pageURL = provider.pageURL

        if let preset = Providers.preset(for: provider.id) {
            var presetAllowsPassword = false
            for option in preset.authOptions {
                if case .appPassword(let url, let presetSteps) = option {
                    presetAllowsPassword = true
                    if !presetSteps.isEmpty { steps = presetSteps }
                    if let url { pageURL = url }
                }
                if case .password = option {
                    presetAllowsPassword = true
                }
                if case .oauth(let id) = option {
                    oauth = id
                }
            }
            allowsPassword = presetAllowsPassword
        } else {
            switch provider.id {
            case .gmail: oauth = .google
            case .outlook: oauth = .microsoft
            default: break
            }
        }
        if provider.requiresOAuth {
            allowsPassword = false
            if oauth == nil { oauth = .microsoft }
        }

        self.oauth = oauth
        self.isOAuthAvailable = oauth.map { OAuthSettings.isConfigured($0) } ?? false
        self.allowsPassword = allowsPassword
        self.steps = steps
        self.pageURL = pageURL
    }
}

/// An error worth showing while connecting: what went wrong, and what to do about it.
struct OnboardingFailure: Equatable {
    var message: String
    var hint: String?

    init(message: String, hint: String? = nil) {
        self.message = message
        self.hint = hint
    }

    init(error: Error, provider: OnboardingProvider) {
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        guard let mailError = error as? MailError else {
            self.init(message: description, hint: provider.connectionHint.isEmpty ? nil : provider.connectionHint)
            return
        }
        switch mailError {
        case .authenticationFailed(let detail):
            let lowered = detail.lowercased()
            if provider.id == .gmail, lowered.contains("application-specific password") {
                self.init(message: "Gmail wants an app password here.", hint: provider.authFailureHint)
            } else {
                self.init(message: description, hint: provider.authFailureHint.isEmpty ? nil : provider.authFailureHint)
            }
        case .connectionFailed, .tlsFailed, .timeout:
            self.init(message: description, hint: provider.connectionHint.isEmpty ? nil : provider.connectionHint)
        case .oauthNotConfigured:
            self.init(message: description, hint: "The setup guide explains how to add it to your build.")
        case .oauth:
            self.init(message: description, hint: provider.id == .outlook ? provider.authFailureHint : nil)
        default:
            self.init(message: description)
        }
    }

    /// The person backed out (closed the sign-in sheet, said no, or tapped Cancel): nothing to show.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let mailError = error as? MailError, mailError == .cancelled { return true }
        return false
    }
}
