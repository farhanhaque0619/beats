import Foundation
import InkModel

/// Turns the big providers' sign-in refusals into sentences that say what to do.
///
/// Servers explain failures in their own words ("Invalid credentials", "AUTHENTICATE failed.",
/// "User is authenticated but not connected."), which rarely tell people what to fix. The
/// mappings follow RESEARCH §2.2 (provider table), §2.3 (Gmail's error strings) and §2.6
/// (Outlook.com needs OAuth):
///
/// - Gmail `[ALERT] Application-specific password required` (IMAP) and
///   `534-5.7.9 Application-specific password required` (SMTP): the normal Google password was used.
/// - Any other Gmail refusal, e.g. `[AUTHENTICATIONFAILED] Invalid credentials` or
///   `535-5.7.8 Username and Password not accepted`: the app password may have been revoked.
/// - Outlook hosts refusing a password (`AUTHENTICATE failed.`, `LOGIN failed.`, `LOGINDISABLED`):
///   Outlook.com only takes Sign in with Microsoft.
/// - `User is authenticated but not connected`: IMAP is switched off in Outlook's settings.
/// - Microsoft 365 `535 5.7.139 … SmtpClientAuthentication is disabled`: the tenant turned SMTP AUTH off.
///
/// Advice keeps the error's case (so callers that branch on `.authenticationFailed` still work)
/// and replaces its detail; applying it twice changes nothing.
public enum ProviderErrorAdvice {
    /// Which server refused.
    public enum Server: Sendable, Equatable {
        case imap, smtp
    }

    // MARK: Sentences

    /// Gmail was given the account password instead of an app password.
    public static let gmailAppPasswordRequired = "Gmail needs an app password (an application-specific password) here, not your Google account password. Create one at myaccount.google.com/apppasswords; it needs 2-Step Verification."
    /// Gmail refused an app password (RESEARCH §2.3, word for word).
    public static let gmailAppPasswordRejected = "Your app password may have been revoked (for example after a Google password change). Create a new one at myaccount.google.com/apppasswords."
    /// Gmail refused an OAuth token.
    public static let googleSignInRejected = "Google didn't accept Ink's sign-in. Sign in with Google again."
    /// An Outlook host refused a password.
    public static let outlookNeedsOAuth = "Outlook.com and Microsoft 365 don't let mail apps sign in with a password any more. Use Sign in with Microsoft instead."
    /// Outlook's IMAP server refused an OAuth token.
    public static let outlookSignInRejected = "Microsoft didn't accept Ink's sign-in. Check that IMAP is on (Outlook on the web › Settings › Mail › Forwarding and IMAP), then sign in with Microsoft again."
    /// Outlook signed the account in but IMAP access is switched off.
    public static let outlookIMAPDisabled = "Microsoft signed you in, but IMAP is turned off for this account. In Outlook on the web, open Settings › Mail › Forwarding and IMAP, turn on “Let devices and apps use IMAP”, then try again. On a new account the switch can take up to a day to stick."
    /// A Microsoft 365 tenant turned off SMTP AUTH.
    public static let outlookSMTPAuthDisabled = "Your organisation has turned off SMTP sign-in for this mailbox, so Ink can't send. Ask your administrator to allow authenticated SMTP (SMTP AUTH) for it."
    /// Outlook's SMTP server refused an OAuth token (some consumer accounts get 535 5.7.3).
    public static let outlookSendRejected = "Microsoft signed you in but wouldn't let Ink send. Some Outlook.com accounts have this problem: sign in with Microsoft again, and if it keeps happening, send from Outlook on the web for now."
    /// iCloud refused a password.
    public static let icloudAppPasswordRejected = "iCloud Mail needs an app-specific password from account.apple.com (Sign-In and Security › App-Specific Passwords), not your Apple Account password. Changing your Apple Account password revokes them all."
    /// Yahoo refused a password.
    public static let yahooAppPasswordRejected = "Yahoo didn't accept that app password. Check it before trying again: repeated failed sign-ins can lock mail apps out for about an hour."
    /// AOL refused a password.
    public static let aolAppPasswordRejected = "AOL didn't accept that app password. Check it before trying again: repeated failed sign-ins can lock mail apps out for about an hour."
    /// Fastmail refused a password.
    public static let fastmailAppPasswordRejected = "Fastmail needs an app password with access to Mail (IMAP/POP/SMTP); your normal password won't work. The Basic plan has no IMAP at all."
    /// Zoho refused a password.
    public static let zohoPasswordRejected = "Check that IMAP Access is on in Zoho Mail (Settings › Mail Accounts › IMAP). With two-factor authentication on, Zoho needs an app-specific password."

    static let allSentences: Set<String> = [
        gmailAppPasswordRequired, gmailAppPasswordRejected, googleSignInRejected,
        outlookNeedsOAuth, outlookSignInRejected, outlookIMAPDisabled, outlookSMTPAuthDisabled, outlookSendRejected,
        icloudAppPasswordRejected, yahooAppPasswordRejected, aolAppPasswordRejected,
        fastmailAppPasswordRejected, zohoPasswordRejected,
    ]

    // MARK: Advice

    /// `error` with its detail replaced by advice when it's a refusal this type recognises;
    /// otherwise `error` unchanged.
    ///
    /// - Parameters:
    ///   - provider: The account's provider. For `.other`, the provider is recognised from `host`.
    ///   - host: The host name of the server that refused.
    ///   - authMethod: How the account signs in.
    ///   - server: IMAP or SMTP.
    public static func advise(_ error: MailError, provider: ProviderID, host: String, authMethod: AuthMethod, server: Server) -> MailError {
        if isAdvice(error) { return error }
        let text = detail(of: error)?.lowercased() ?? ""

        // Phrases that only one provider uses, whatever the account says it is.
        if contains(text, "user is authenticated but not connected") {
            return .serverError(outlookIMAPDisabled)
        }
        if case .authenticationFailed = error, contains(text, "application-specific password required") {
            return .authenticationFailed(gmailAppPasswordRequired)
        }

        let effective = Providers.preset(for: provider)?.id ?? Providers.preset(forServerHost: host)?.id
        switch effective {
        case .gmail?:
            guard case .authenticationFailed = error else { return error }
            return .authenticationFailed(authMethod == .oauth2 ? googleSignInRejected : gmailAppPasswordRejected)
        case .outlook?:
            if server == .smtp, contains(text, "smtpclientauthentication is disabled") || contains(text, "smtp_auth_disabled") {
                return .authenticationFailed(outlookSMTPAuthDisabled)
            }
            switch error {
            case .authenticationFailed:
                if authMethod == .password { return .authenticationFailed(outlookNeedsOAuth) }
                return .authenticationFailed(server == .smtp ? outlookSendRejected : outlookSignInRejected)
            case .notSupported(let what) where authMethod == .password && contains(what.lowercased(), "password"):
                // LOGINDISABLED: the server won't even take a password.
                return .authenticationFailed(outlookNeedsOAuth)
            default:
                return error
            }
        case .icloud?:
            return passwordRefusal(error, authMethod: authMethod, advice: icloudAppPasswordRejected)
        case .yahoo?:
            return passwordRefusal(error, authMethod: authMethod, advice: yahooAppPasswordRejected)
        case .aol?:
            return passwordRefusal(error, authMethod: authMethod, advice: aolAppPasswordRejected)
        case .fastmail?:
            return passwordRefusal(error, authMethod: authMethod, advice: fastmailAppPasswordRejected)
        case .zoho?:
            return passwordRefusal(error, authMethod: authMethod, advice: zohoPasswordRejected)
        default:
            return error
        }
    }

    /// True when `error` already carries advice from this type. Such errors need the person to do
    /// something (make an app password, switch IMAP on), so retrying on a timer won't help.
    public static func isAdvice(_ error: MailError) -> Bool {
        guard let detail = detail(of: error) else { return false }
        return allSentences.contains(detail)
    }

    // MARK: Helpers

    private static func passwordRefusal(_ error: MailError, authMethod: AuthMethod, advice: String) -> MailError {
        guard authMethod == .password, case .authenticationFailed = error else { return error }
        return .authenticationFailed(advice)
    }

    private static func detail(of error: MailError) -> String? {
        switch error {
        case .authenticationFailed(let text), .connectionFailed(let text), .tlsFailed(let text), .protocolError(let text),
             .serverError(let text), .notSupported(let text), .sendFailed(let text), .oauth(let text):
            return text
        default:
            return nil
        }
    }

    /// Substring test through Foundation on every platform (the stdlib's `contains(_:)` works on
    /// Characters on Apple platforms, so the two can disagree around CRLF).
    private static func contains(_ text: String, _ phrase: String) -> Bool {
        text.range(of: phrase) != nil
    }
}
