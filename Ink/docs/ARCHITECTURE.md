# Ink — architecture

Ink is a native SwiftUI email client for iPhone and Mac with no server of its own: the app
talks IMAP and SMTP directly to your mail provider. One codebase, two targets.

```
Ink/
  project.yml, Ink.xcodeproj     XcodeGen spec + generated project (iOS + macOS targets)
  Config/                        xcconfig, Info.plists, entitlements
  InkCore/                       Swift package: everything that isn't UI (builds & tests on Linux)
    Sources/InkModel             shared value types + protocols (the contracts)
    Sources/InkMIME              MIME parse/build, encodings, charsets, addresses, HTML→text, quoting
    Sources/InkIMAP              IMAP client: encoder, parser, connection, client
    Sources/InkSMTP              SMTP submission client, SASL
    Sources/InkProviders         provider presets, autodiscovery, OAuth 2.0 (PKCE)
    Sources/InkSync              IMAPMailService, DemoMailService, cache, threading, MailStore
    Sources/InkCore              umbrella (@_exported imports)
  App/                           SwiftUI app, compiled into both targets
    AppShell/ Design/ Components/ Services/ Features/* Platform/iOS Platform/macOS Resources/
  scripts/                       build-mac, make-dmg, build-ipa, screenshots, make-icon
  docs/                          RESEARCH.md, ARCHITECTURE.md, INSTALL.md, ACCOUNTS.md
```

## Ground rules (all code)

- Swift 5 language mode, Swift 6.2 compiler (Xcode 26.3 on CI, `swift:6.2-noble` on Linux).
- Deployment targets: iOS 18.0, macOS 15.0. APIs newer than that must be wrapped in
  `if #available(iOS 26.0, macOS 26.0, *)` **and** `#if compiler(>=6.2)`.
- **InkCore is Foundation-only.** No UIKit/AppKit/SwiftUI/Network/CryptoKit/Security imports.
  It must compile and pass `swift test` on Linux. Where Apple and Linux Foundation differ
  (e.g. charset conversion via `CFStringConvertIANACharSetNameToEncoding`), use
  `#if canImport(Darwin)` with a Linux fallback, and keep tests platform-neutral.
- Public API of InkModel and the `MailStore` public interface are contracts: don't rename or
  remove anything; additions are fine.
- Doc comments on public types and non-obvious functions; no commented-out code.
- Errors surfaced to the user are `MailError` with human sentences.
- Never log secrets (passwords, tokens, AUTH lines). Redact `LOGIN`/`AUTHENTICATE` lines in any
  protocol log.

## InkModel (written, compiles)

`EmailAddress`, `AccountConfig`/`ServerConfig`/`Credential`/`OAuthToken`/`CredentialStore`,
`MailboxRole`/`MailboxInfo`/`MailScope`/`InboxFilter`, `MessageFlags`/`MessageSummary`/
`MessageBody`/`Attachment`/`Conversation`, `OutgoingMessage`/`OutgoingAttachment`/`ReplyMode`,
`MailAction`/`MailboxSyncState`/`MailboxSyncResult`/`VerificationStep`/`MailService`/`MailError`,
`MailTransport`/`TransportError`/`ScriptedTransport`, `SwipeAction`/`SwipeConfiguration`/
`SnoozeOption`/`SnoozePresets`. Read the sources; they are the spec.

## InkMIME

Public API (exact names matter; InkSync depends on them):

```swift
public struct MIMEHeader: Hashable, Sendable { public var name: String; public var value: String }   // value unfolded, raw (not decoded)
public struct MIMEHeaders: Sendable {
    public var all: [MIMEHeader]
    public subscript(_ name: String) -> String?            // first, case-insensitive, raw
    public func values(_ name: String) -> [String]
    public func decoded(_ name: String) -> String?         // RFC 2047 decoded
}
public struct ContentType: Hashable, Sendable {
    public var type: String; public var subtype: String; public var parameters: [String: String] // lowercased keys, RFC 2231 joined+decoded
    public var mimeType: String { "\(type)/\(subtype)" }  // lowercased
    public static func parse(_ value: String) -> ContentType
}
public struct ContentDisposition: Hashable, Sendable { public var type: String; public var parameters: [String: String]; public var filename: String? }
public final class MIMEPart: Sendable-ish {             // struct is fine too
    public var headers: MIMEHeaders
    public var contentType: ContentType                 // default text/plain; charset=us-ascii
    public var disposition: ContentDisposition?
    public var transferEncoding: String                 // lowercased, default "7bit"
    public var partID: String                           // IMAP-style section: "1", "1.2", ... ("" for a non-multipart root's body is "1")
    public var body: Data                               // decoded per Content-Transfer-Encoding (empty for multiparts)
    public var children: [MIMEPart]
    public var contentID: String?                       // without <>
    public var filename: String?                        // disposition filename, else type "name" param, decoded
    public func text() -> String?                       // body decoded with charset (text/* only)
}
public struct ParsedMessage: Sendable {
    public var headers: MIMEHeaders
    public var root: MIMEPart
    public var subject: String; public var from: [EmailAddress]; public var replyTo: [EmailAddress]
    public var to: [EmailAddress]; public var cc: [EmailAddress]; public var bcc: [EmailAddress]
    public var date: Date?; public var messageID: String?; public var inReplyTo: [String]; public var references: [String]
    public var plainText: String?                       // best text/plain (joined if multiple inline text parts)
    public var html: String?                            // best text/html
    public var attachments: [Attachment]                // InkModel.Attachment with data; inline images get isInline=true + contentID
    public func body(messageID: String) -> MessageBody
}
public enum MIMEParser { public static func parse(_ data: Data) -> ParsedMessage }   // never throws; tolerant of garbage

public enum EncodedWord { public static func decode(_ s: String) -> String; public static func encode(_ s: String) -> String }  // RFC 2047
public enum QuotedPrintable { public static func decode(_ data: Data) -> Data; public static func decode(_ s: String) -> Data; public static func encode(_ data: Data, lineLength: Int = 76) -> String }
public enum Base64Lenient { public static func decode(_ s: String) -> Data; public static func decode(_ data: Data) -> Data }   // ignores whitespace/garbage, tolerates missing padding and truncation (decodes whole quanta only)
public enum Charset { public static func decode(_ data: Data, charset: String?) -> String }   // utf-8, us-ascii, iso-8859-1..16, windows-125x, koi8-r/u, gb2312/gbk/gb18030, big5, shift_jis, euc-jp, iso-2022-jp, euc-kr, utf-16/le/be; fallback: utf-8 lossy, then latin1
public enum AddressParser { public static func parseList(_ s: String) -> [EmailAddress]; public static func parse(_ s: String) -> EmailAddress? }  // RFC 5322 incl. quoted names, comments, groups ("undisclosed-recipients:;"), encoded-word names, bare addresses, sloppy real-world input
public enum MessageIDParser { public static func parseList(_ s: String) -> [String] }  // "<a@b> <c@d>" -> ["a@b","c@d"], tolerant
public enum RFC5322Date { public static func parse(_ s: String) -> Date?; public static func format(_ d: Date) -> String } // obsolete zones, missing seconds, day names, "(UTC)" comments
public enum HTMLText {
    public static func toPlainText(_ html: String) -> String        // drops head/style/script/comments/hidden preheaders? (keep preheader text), block tags→newlines, decodes entities, collapses whitespace
    public static func decodeEntities(_ s: String) -> String          // named (common set) + numeric
    public static func escape(_ s: String) -> String
}
public enum Snippet { public static func make(plain: String?, html: String?, maxLength: Int = 200) -> String }  // strips quoted replies, signatures, URLs-only lines; single line, whitespace collapsed
public enum QuoteSplitter {
    // Splits a plain-text body into what the sender wrote and the quoted tail ("On … wrote:" in en/de/fr/es/it/nl/pt/sv + "-----Original Message-----", "From: … Sent: …" Outlook blocks, ">" runs at the end, "-- " signature).
    public static func split(_ text: String) -> (body: String, quoted: String?)
    // HTML: finds div.gmail_quote, blockquote[type=cite], #divRplyFwdMsg / #appendonsend (Outlook), div.yahoo_quoted, .protonmail_quote; returns (htmlWithoutQuote, hasQuote)
    public static func stripQuotedHTML(_ html: String) -> (html: String, hadQuote: Bool)
}
public enum EmailHTMLDocument {
    /// Wraps an email's HTML (or plain text) in a full document for WKWebView:
    /// viewport meta, a strict CSP (`default-src 'none'; img-src cid: data: <https: http: only if allowRemote>; style-src 'unsafe-inline'; font-src data:`),
    /// base CSS (system font, readable line height, max-width images, word-break for long URLs, tables don't overflow),
    /// and dark-mode handling: if the HTML is "simple" (no explicit background colours/images and no bgcolor) it is
    /// recoloured for dark mode with CSS; "designed" newsletters keep their own colours on a light card.
    /// Plain text becomes escaped HTML with linkified URLs and `>` quotes as blockquotes.
    public static func build(html: String?, plainText: String?, options: Options) -> String
    public struct Options: Sendable { public var dark: Bool; public var allowRemoteContent: Bool; public var accentHex: String; public var fontFamily: String /* "-apple-system" or "ui-serif" */; public var fontSizePx: Int; public var collapseQuotes: Bool; public init(...) }
    public static func isDesigned(_ html: String) -> Bool
    public static func countRemoteImages(_ html: String) -> Int        // <img src="http(s)…">
    public static func countTrackingPixels(_ html: String) -> Int      // 1x1 / display:none images and known tracker hosts
}
public enum MessageBuilder {
    /// RFC 5322 message: Date, From, To, Cc (never Bcc), Subject (encoded-word if non-ASCII), Message-ID
    /// (<uuid@from-domain>), In-Reply-To/References, MIME-Version, User-Agent: Ink.
    /// Body: multipart/alternative (text/plain quoted-printable utf-8 + text/html generated from the plain text,
    /// with quotedHTML appended as a blockquote when present); wrapped in multipart/mixed when there are
    /// attachments (base64, 76-char lines, RFC 2231 filename*= for non-ASCII). CRLF line endings throughout.
    public static func build(_ message: OutgoingMessage, date: Date = Date(), messageID: String? = nil) -> (data: Data, messageID: String)
}
public enum ReplyBuilder {
    /// Recipients for reply / reply-all (Reply-To over From; reply-all adds To+Cc minus `myAddresses`, dedup;
    /// replying to your own sent message replies to its original To), "Re: " / "Fwd: " subject (no stacking),
    /// In-Reply-To + References (parent references + parent Message-ID, capped to the last 20),
    /// quoted text "On <date>, <name> wrote:" + "> " lines (or a forward header block for forwards), quotedHTML.
    public static func draft(replyingTo message: MessageSummary, body: MessageBody?, mode: ReplyMode, from account: AccountConfig, myAddresses: Set<String>, now: Date = Date()) -> OutgoingMessage
}
```

## InkIMAP

```swift
public actor IMAPClient {
    public init(host: String, port: Int, security: ConnectionSecurity, transport: MailTransport, timeout: TimeInterval = 30, logger: (@Sendable (String) -> Void)? = nil)
    public private(set) var capabilities: Set<String>        // uppercased
    public var isGmail: Bool                                  // X-GM-EXT-1
    public func connect() async throws                        // greeting (+ STARTTLS + re-CAPABILITY), handles PREAUTH/BYE
    public func login(username: String, password: String) async throws          // AUTHENTICATE PLAIN if advertised (SASL-IR when possible), else LOGIN with quoted/literal strings; refreshes capabilities after auth
    public func authenticateXOAUTH2(username: String, accessToken: String) async throws   // handles the error-challenge round trip (send empty line)
    public func enable(_ caps: [String]) async throws         // ENABLE (e.g. QRESYNC, UTF8=ACCEPT) only if supported
    public func id(_ fields: [String: String]) async throws   // RFC 2971, only if supported
    public func listMailboxes() async throws -> [IMAPMailbox]  // LIST "" "*" (RETURN (SPECIAL-USE) when supported); decodes modified UTF-7
    public func select(_ rawPath: String, readOnly: Bool = false, condstore: Bool = false) async throws -> IMAPSelectInfo
    public func status(_ rawPath: String) async throws -> IMAPStatus   // MESSAGES UIDNEXT UIDVALIDITY UNSEEN (+HIGHESTMODSEQ)
    public func fetch(_ set: IMAPSequenceSet, byUID: Bool, items: [IMAPFetchItem], changedSince: UInt64? = nil) async throws -> [IMAPFetchResponse]
    public func uidSearch(_ criteria: IMAPSearchCriteria) async throws -> [UInt32]
    public func uidStore(_ uids: IMAPSequenceSet, flags: [String], mode: IMAPStoreMode /* add, remove, replace */, silent: Bool = true) async throws
    public func gmailStoreLabels(_ uids: IMAPSequenceSet, labels: [String], mode: IMAPStoreMode) async throws     // X-GM-LABELS
    public func uidCopy(_ uids: IMAPSequenceSet, to rawPath: String) async throws -> [UInt32: UInt32]   // COPYUID mapping when UIDPLUS
    public func uidMove(_ uids: IMAPSequenceSet, to rawPath: String) async throws -> [UInt32: UInt32]   // MOVE, else COPY + STORE \Deleted + UID EXPUNGE (EXPUNGE only if no UIDPLUS... careful: plain EXPUNGE removes other \Deleted mail; prefer UID EXPUNGE, and if UIDPLUS is missing only expunge when the caller allows)
    public func uidExpunge(_ uids: IMAPSequenceSet) async throws
    public func append(to rawPath: String, message: Data, flags: [String] = [], date: Date? = nil) async throws -> UInt32?   // APPENDUID when available; uses literal (LITERAL+ if supported)
    public func create(_ rawPath: String) async throws
    public func noop() async throws -> [IMAPUntagged]
    public func idle(timeout: TimeInterval = 25 * 60, onEvent: @Sendable (IMAPUntagged) -> Bool /* return false to stop */) async throws   // sends IDLE, waits for '+', delivers untagged events, sends DONE on stop/timeout/cancellation
    public func logout() async
}
```

Supporting types (public): `IMAPMailbox` (rawName, name (decoded), delimiter, attributes, specialUse role → `MailboxRole?`), `IMAPSelectInfo` (exists, recent, uidValidity, uidNext, highestModSeq, flags, permanentFlags, readOnly), `IMAPStatus`, `IMAPSequenceSet` (from `[UInt32]` compressing runs `1:5,9,12:*`; `.all`, ranges; `description` is the wire form), `IMAPFetchItem` (uid, flags, internalDate, rfc822Size, envelope, bodyStructure, bodyPeek(section: String, partial: (Int, Int)?), headerFields([String]), gmailThreadID, gmailMessageID, gmailLabels, modSeq), `IMAPFetchResponse` (seq, uid, flags, internalDate, size, envelope: `IMAPEnvelope`, bodyStructure: `BodyStructure`, sections: [String: Data] keyed by the section spec as requested e.g. "1.2", "HEADER.FIELDS (REFERENCES)", "" for the whole message; gmail ids/labels; modSeq), `IMAPEnvelope` (date string, subject (decoded via encoded-word? NO — InkIMAP doesn't depend on InkMIME; return raw strings and raw address parts; InkSync decodes), from/sender/replyTo/to/cc/bcc as `[IMAPAddress]` (name, adl, mailbox, host raw), inReplyTo, messageID raw), `BodyStructure` (indirect enum single/multipart with section paths, type/subtype lowercased, params, id, description, encoding, size, lines, md5, disposition + params, language, location; helpers: `preferredTextPart() -> (section, part)?` (text/plain over text/html, skipping attachments), `htmlPart`, `attachmentParts`, `hasAttachments`), `IMAPSearchCriteria` (all, uid range, since date, unseen, flagged, header(name, value), from/to/subject/body/text(String), gmailRaw(String), or/and/not; encodes strings as quoted or literal with CHARSET UTF-8 when non-ASCII), `IMAPUntagged` (exists(n), expunge(seq), recent(n), fetch(IMAPFetchResponse), vanished, flags, capability, bye(String), other(String)), `IMAPError` mapped to `MailError` (NO on LOGIN/AUTHENTICATE → `.authenticationFailed(text)`; `[ALERT]` text surfaced).

Implementation notes:
- Layers: `IMAPEncoder` (commands, tags `A001`…, quoting, literals `{n}`/`{n+}`), `IMAPResponseParser` (incremental byte parser: atoms, quoted strings with escapes, literals spanning reads, NIL, nested lists, response codes `[UIDVALIDITY 1]`, `[COPYUID ...]`, `[CAPABILITY ...]`), `IMAPConnection` (buffering, reads full responses incl. literals, tagged completion, continuation `+`).
- Modified UTF-7 (RFC 3501 §5.1.3) encode/decode.
- Commands are serialized (one in flight) inside the actor; untagged responses that arrive during a command are collected and returned or applied (EXISTS/EXPUNGE update selected-mailbox state).
- Timeouts → `MailError.timeout`; transport closed → `MailError.connectionFailed`.
- Tests use `ScriptedTransport` with real server transcripts (Gmail, iCloud, Dovecot, Outlook flavours) covering literals in FETCH, BODYSTRUCTURE edge cases (nested multipart/alternative inside mixed, message/rfc822, missing fields, extension data, NIL params, uppercase types, Gmail's quirks), ENVELOPE with NIL and encoded words, LIST with special-use and `\Noselect`, COPYUID/APPENDUID, IDLE flow, auth failures with `[AUTHENTICATIONFAILED]`, `[ALERT]`.

## InkSMTP

```swift
public actor SMTPClient {
    public init(host: String, port: Int, security: ConnectionSecurity, transport: MailTransport, localHostname: String = "localhost", timeout: TimeInterval = 30, logger: (@Sendable (String) -> Void)? = nil)
    public private(set) var extensions: [String: String]      // EHLO keywords → params, uppercased keys
    public func connect() async throws                         // greeting 220, EHLO (fallback HELO), STARTTLS + EHLO again
    public func login(username: String, password: String) async throws        // AUTH PLAIN (initial response) else AUTH LOGIN
    public func authenticateXOAUTH2(username: String, accessToken: String) async throws   // handles 334 error challenge
    public func send(from: String, recipients: [String], message: Data) async throws        // MAIL FROM (SIZE=, SMTPUTF8/8BITMIME when needed), RCPT TO each (fail if all rejected; collect per-recipient errors), DATA with dot-stuffing and CRLF normalisation, final 250
    public func quit() async
}
public enum SASL { public static func plain(username: String, password: String) -> String; public static func xoauth2(username: String, accessToken: String) -> String }  // base64
```
Multi-line replies (`250-…`/`250 …`), enhanced status codes; 535 → `.authenticationFailed`; 5xx on RCPT → `.sendFailed("<addr>: <reason>")`.

## InkProviders

```swift
public struct ProviderPreset: Identifiable, Sendable {
    public var id: ProviderID; public var name: String; public var domains: [String]; public var mxSuffixes: [String]
    public var imap: (host: String, port: Int, security: ConnectionSecurity); public var smtp: (host: String, port: Int, security: ConnectionSecurity)
    public var authOptions: [ProviderAuthOption]   // .appPassword(url: URL?, steps: [String]), .password, .oauth(OAuthProviderID)
    public var savesSentAutomatically: Bool; public var archiveRole: MailboxRole (gmail: .all, others: .archive)
    public var notes: [String]                      // gotchas shown in setup
    public func accountConfig(email: String, displayName: String, authMethod: AuthMethod) -> AccountConfig
}
public enum Providers {
    public static let all: [ProviderPreset]         // gmail, icloud, outlook, yahoo, aol, fastmail, zoho
    public static func preset(for id: ProviderID) -> ProviderPreset?
    public static func preset(forEmail: String) -> ProviderPreset?     // by domain
}
public enum Autodiscovery {
    // Mozilla ISPDB (https://autoconfig.thunderbird.net/v1.1/<domain>), https://autoconfig.<domain>/mail/config-v1.1.xml?emailaddress=,
    // https://<domain>/.well-known/autoconfig/mail/config-v1.1.xml; MX lookup via DNS-over-HTTPS (https://dns.google/resolve?name=<domain>&type=MX)
    // to map custom domains hosted by Google/Microsoft/Fastmail/Zoho/iCloud to a preset; finally guesses imap.<domain>/smtp.<domain>.
    public static func discover(email: String, session: URLSession = .shared) async -> DiscoveryResult?
    public static func parseClientConfig(_ xml: Data, email: String) -> DiscoveryResult?    // XMLParser-based (FoundationXML on Linux)
}
public struct DiscoveryResult: Sendable { public var imap: ServerConfig; public var smtp: ServerConfig; public var preset: ProviderID?; public var source: String }
public struct OAuthConfiguration: Sendable {
    public var provider: OAuthProviderID; public var clientID: String; public var redirectURI: String
    public var authorizationEndpoint: URL; public var tokenEndpoint: URL; public var scopes: [String]
    public static func google(clientID: String) -> OAuthConfiguration    // redirect com.googleusercontent.apps.<id>:/oauth2redirect, scope https://mail.google.com/
    public static func microsoft(clientID: String, bundleID: String) -> OAuthConfiguration  // consumers+orgs "common" tenant; IMAP.AccessAsUser.All, SMTP.Send, offline_access
    public var callbackScheme: String
}
public struct PKCE: Sendable { public var verifier: String; public var challenge: String; public static func generate() -> PKCE }   // S256, pure-Swift SHA-256 (tested with NIST vectors)
public enum OAuthClient {
    public static func authorizationURL(config: OAuthConfiguration, pkce: PKCE, state: String, loginHint: String?) -> URL
    public static func exchange(code: String, config: OAuthConfiguration, pkce: PKCE, session: URLSession = .shared) async throws -> OAuthToken
    public static func refresh(_ token: OAuthToken, config: OAuthConfiguration, session: URLSession = .shared) async throws -> OAuthToken
    public static func parseTokenResponse(_ data: Data, previous: OAuthToken?, now: Date) throws -> OAuthToken
}
```

## InkSync

- `IMAPMailService: MailService` (actor). One IMAP connection for commands (lazily connected,
  reconnect once on connection errors), a separate one per `watch`. SMTP connects per send.
  - `mailboxes()`: LIST, map roles by SPECIAL-USE (`\Sent \Drafts \Trash \Junk \Archive \All \Flagged`),
    else well-known names (Sent Messages, Sent Items, Deleted Messages, Deleted Items, Junk E-mail, Bulk Mail,
    Archive, [Gmail]/…). INBOX case-insensitive. Sort: inbox, flagged, drafts, sent, archive/all, junk, trash, then custom A–Z.
  - `sync`: SELECT (CONDSTORE when available). Reset when UIDVALIDITY changed / no state. New: sequence range
    `max(1, exists-limit+1):exists` on reset, else `UID <uidNext>:*`. Flags for the known window via
    `UID FETCH <min known>:* (UID FLAGS)` (with `CHANGEDSINCE` when CONDSTORE); known UIDs that didn't come back → removed.
    Summary items: UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE
    `BODY.PEEK[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-ID PRECEDENCE AUTO-SUBMITTED)]`
    (+ X-GM-THRID X-GM-MSGID X-GM-LABELS on Gmail). Snippets: preferred text part from BODYSTRUCTURE, grouped by section,
    `UID FETCH … (BODY.PEEK[<section>]<0.2048>)`, decoded (transfer encoding + charset, HTML→text) → `Snippet.make`.
    `isBulk` = List-Unsubscribe or List-Id present, Precedence bulk/list/junk, Auto-Submitted ≠ no, or `looksAutomated` sender.
  - `body(for:)`: SELECT the message's mailbox if needed, `UID FETCH uid BODY.PEEK[]`, `MIMEParser.parse` → `MessageBody`.
    Throws `.messageNotFound` when gone.
  - `perform`: group by mailbox. archive → Gmail: `UID MOVE` to the `\All` mailbox (drops the Inbox label); others: MOVE to
    the `.archive` mailbox, creating "Archive" if missing. trash/markSpam → MOVE to trash/junk. read/flag → UID STORE.
    moveToInbox → find each message by `X-GM-MSGID` (Gmail, search `X-GM-MSGID <id>` in All Mail then COPY to INBOX, or MOVE from
    Trash/Spam) or `HEADER Message-ID <id>` in archive/trash/junk mailboxes, then MOVE to INBOX. move(path). deletePermanently → STORE \Deleted + UID EXPUNGE.
  - `send`: `MessageBuilder.build`, SMTP (login/XOAUTH2 from the credential), then APPEND to the `.sent` mailbox with `\Seen`
    unless `account.savesSentAutomatically`.
  - `search`: Gmail `X-GM-RAW` in All Mail; others `OR OR FROM q SUBJECT q BODY q` (TEXT on servers where BODY is slow) in the given
    mailbox, newest `limit` summaries.
  - `watch`: dedicated connection, SELECT, IDLE; yields `.changed` on EXISTS/EXPUNGE/FETCH; re-IDLE every 25 min; reconnect with
    backoff; `.connectionLost` after repeated failures; stops on task cancellation.
  - `verify`: connect+auth IMAP, LIST, connect+auth SMTP, QUIT, LOGOUT — reporting `VerificationStep`s.
- `DemoMailService: MailService` (actor): realistic, deterministic sample mail relative to "now" (~40 conversations in
  Inbox incl. threads with replies from "me", newsletters/notifications (bulk), receipts, travel, a calendar invite,
  attachments, a long HTML newsletter with images (data: URIs or none — no network), plain-text personal mail, a few starred,
  some unread; Sent, Archive, Trash, Spam with a few each). All actions mutate in-memory state. `send` adds to Sent.
  Fictional people and companies only.
- `MailCache`: JSON files under `storageDirectory/cache/<accountID>/`: `mailboxes.json`, `mailbox-<sha>.json`
  (`MailboxSyncState` + `[MessageSummary]`), `bodies/<sha>.json` (`MessageBody`, attachments > 5 MB stored without data).
  Writes are atomic and coalesced (debounced) off the main thread. Corrupt files are ignored.
- `Threader`: groups summaries into conversations per account: Gmail `X-GM-THRID`; otherwise union-find over
  Message-ID / In-Reply-To / References, plus a fallback that joins messages with the same normalized subject and an overlapping
  participant within 30 days when neither has references. De-duplicates copies of the same message (`dedupeKey`), preferring the
  inbox copy. Assigns `threadKey`.
- `ContactIndex`: frequency/recency-ranked addresses from From/To/Cc of cached mail, sent mail weighted higher; prefix match on
  name words and address.
- `MailStore` (`@MainActor @Observable`): implements the interface in `MailStore.swift` exactly. Optimistic triage with a
  delayed commit queue (`undoWindow`), undo-send queue (`undoSendDelay`), snoozes persisted in `snoozes.json`
  (`[conversationID: SnoozeRecord(until, messages)]`, server-archived while snoozed, `moveToInbox` + mark unread on wake; wake
  check on refresh and a 60 s timer), Focus/Other split (`isBulk`), unified scopes merge accounts, `preview()` builds a demo store
  synchronously (no disk, no network), toasts ("Archived", "Moved to Trash", "Snoozed until Tue 8:00", "Sending…", "Sent",
  errors). Accounts persisted to `accounts.json` (no secrets).
  - `load()` must be idempotent: a cold background launch (BGAppRefreshTask) calls it before the UI does, and the UI
    calls it again; the second call must not duplicate state or start a second refresh loop.
  - `refreshAllInboxes()` returns messages that arrived after a persisted per-account high-water mark (highest
    UID / received date seen by the previous `refreshAllInboxes` call), so foreground refreshes in between don't
    swallow the "new mail" set used for notifications. Only unread, non-bulk inbox messages.
  - `conversation(id:)` finds a conversation anywhere in the cache (any scope, search results, snoozed), not just in
    the current `conversations` list: the reader opens threads from search and from other scopes.
  - Triage calls (`perform`, `archive`, …) update `conversations` synchronously so the UI's `withAnimation` around them
    animates the list closing up.
  - `syncStatus` is `.syncing` while a refresh runs and `lastSyncedAt` is set after a successful one (the first-load
    shimmer depends on both).
  - `addAccount` removes the demo account when it's the only account; `updateAccount` persists name/signature/colour;
    `removeAccount` deletes the credential and the cache.

## App (SwiftUI)

See `App/` — Design tokens in `App/Design/Theme.swift`, settings in `App/AppShell/AppSettings.swift`.
The app owns platform services: `URLSessionMailTransport` (URLSessionStreamTask; `startSecureConnection()` for both
implicit TLS and STARTTLS), `KeychainCredentialStore` (data-protection keychain; on macOS falls back to the file keychain when
unsigned/ad-hoc signed builds get `errSecMissingEntitlement`), `OAuthSignIn` (ASWebAuthenticationSession), background refresh
(BGAppRefreshTask + local notifications).
