# Ink — UI spec

**Feel:** quiet, fast, confident. Black and white; type and spacing do the work; one accent colour
(the user's pick, default electric blue) for unread dots, the compose button, Send, links and focus.
Semantic colours appear only while swiping (green archive, red trash, amber snooze, yellow star).
Everything moves on springs (`InkMotion`), nothing linear, nothing slow. Rows are light enough
to scroll at 120 Hz. Haptics mark thresholds and commits.

## Shared building blocks (already written — read them)

- `App/Design/Theme.swift`: `Ink.*` colours, `AccentTint`, `AccountPalette`, `SwipeAction.tint(accent:)`,
  `\.inkAccent` environment, `InkFont`, `InkTracking`, `InkSpace`, `InkRadius`, `InkSize`, `InkMotion`,
  `Haptics`, `.inkGlass(in:interactive:)`, `.inkLargeTitle()`.
- `App/AppShell/AppSettings.swift`: user prefs (`@Environment(AppSettings.self)`).
- `App/AppShell/AppModel.swift`: navigation + presentation state and cross-screen actions
  (`@Environment(AppModel.self)`): `phonePath`, `selection`, `composeDraft`, `snoozeTargets`,
  `isSearchPresented`, `isSettingsPresented`, `isMailboxSwitcherPresented`, `isAddAccountPresented`,
  `isCommandPalettePresented`, `compose()`, `reply(to:mode:)`, `open(_:)`, `perform(_:on:)` (routes snooze to the
  picker), `snooze(until:)`, `cancelSnooze()`, `select(scope:)`, `conversation(after:offset:)`,
  `didRemoveFocusedConversation(_:)`, `screenshot`.
- `App/AppShell/RootView.swift`: hosts Compose / Snooze / Add Account / (iOS) Settings sheets and the toast.
- `App/Components/`: `AvatarView`, `UnreadDot`, `AccountDot`, `SectionHeaderView`, `KeyCap`, `Chip`, `IconButton`,
  `EmptyStateView`, `InboxZeroView`, `LoadingDots`, button styles (`.inkPrimary`, `.inkSecondary`, `.inkAccent`,
  `.pressable`), `InkSearchField`, `ConversationRow` + `ConversationRowStyle(settings:scope:accountCount:)`,
  `ToastOverlay`, `InkDate`, `InkFormat`.
- Mail data: `MailStore` (`@Environment(MailStore.self)`, interface in `InkCore/Sources/InkSync/MailStore.swift`),
  models in `InkCore/Sources/InkModel/*`.

## Type names other files rely on (exact)

| Type | Owner | Used by |
|---|---|---|
| `PhoneRootView()` | inbox-ios | RootView |
| `InboxScreen()`, `SwipeRow`, `MailboxSwitcher()` | inbox-ios | PhoneRootView |
| `ThreadScreen(conversationID: String)` | reader | PhoneRootView (push), MacRootView (detail) |
| `EmailWebView` | reader | ThreadScreen |
| `ComposeView(draft: OutgoingMessage)` | compose | RootView sheet |
| `SnoozePicker(conversations: [Conversation])` | compose | RootView sheet, Mac popover |
| `SearchScreen()` | compose | PhoneRootView (full-screen), MacRootView |
| `WelcomeFlow()` | onboarding | RootView (no accounts) |
| `AddAccountFlow()` | onboarding | RootView sheet, Settings, Mac sidebar |
| `SettingsView()` | onboarding | RootView sheet (iOS), Settings scene (Mac) |
| `MacRootView()`, `InkCommands(app: AppModel)` (a `Commands`) | mac | RootView, InkApp |
| `URLSessionMailTransport()`, `KeychainCredentialStore()`, `OAuthSignIn`, `OAuthSettings`, `BackgroundRefresh`, `Notifier` | services | AppModel, InkApp, onboarding |

Services API (exact):
```swift
final class URLSessionMailTransport: MailTransport, @unchecked Sendable { init() }
actor KeychainCredentialStore: CredentialStore { init(service: String = "io.github.farhanhaque0619.ink") }
enum OAuthSettings { static func clientID(for: OAuthProviderID) -> String?; static func configuration(for: OAuthProviderID) -> OAuthConfiguration?; static func isConfigured(_: OAuthProviderID) -> Bool }
struct OAuthSignInResult: Sendable { var token: OAuthToken; var email: String?; var name: String? }
@MainActor enum OAuthSignIn { static func signIn(provider: OAuthProviderID, loginHint: String?, session: WebAuthenticationSession) async throws -> OAuthSignInResult }   // session = @Environment(\.webAuthenticationSession)
@MainActor enum BackgroundRefresh { static let identifier: String; static func register(store: MailStore, settings: AppSettings); static func schedule(); static func handleAppRefresh() async }   // iOS only (#if os(iOS))
@MainActor enum Notifier { static func requestAuthorization() async -> Bool; static func notify(newMessages: [MessageSummary], store: MailStore); static func updateBadge(count: Int) }
```

## iPhone

**Root (`PhoneRootView`)**: `NavigationStack(path: $app.phonePath)` with `InboxScreen` as root and
`.navigationDestination(for: String.self) { ThreadScreen(conversationID: $0) }` with the iOS 18 zoom transition
(`.matchedTransitionSource(id:in:)` on the row, `.navigationTransition(.zoom(sourceID:in:))` on the destination).
Floating compose button (accent circle, `InkSize.fab`, `square.and.pencil`, bottom-trailing, `.inkGlass` ring on iOS 26
is optional; must scale on press and give a haptic) — hidden while a thread is pushed. Presents `MailboxSwitcher`
(sheet, medium+large detents), `SearchScreen` (full-screen cover or push), driven by `AppModel` flags.

**Inbox (`InboxScreen`)**: custom header, not the system large title: `store.title(for: scope)` in `InkFont.largeTitle`
with tight tracking and a small chevron (tapping opens the mailbox switcher), unread count beside it in tertiary;
trailing icons: search, settings. When the scope is an inbox and `store.focusedInboxEnabled`: a two-segment pill
`Focus | Other 12` (Other count = `store.otherUnreadCount` if > 0 else `otherCount`) bound to `store.inboxFilter`,
animated selection capsule (matchedGeometryEffect). When scrolled past the header, a compact inline title fades into
a thin top bar (use `onScrollGeometryChange`, iOS 18). List: `ScrollView` + `LazyVStack(spacing: 0, pinnedViews: [])`
grouped into day sections (`InkDate.sectionTitle`), each row a `SwipeRow` wrapping `ConversationRow` (Equatable,
`.equatable()`), hairline separators inset to the text column. Tap → `app.open(id)`. Long-press → `.contextMenu` with
Archive, Trash, Mark read/unread, Star, Snooze…, Move to… (mailboxes), Spam, plus a preview of the snippet.
`.refreshable { await store.refresh() }`. Infinite scroll: when one of the last 5 rows appears and `store.canLoadMore`,
`await store.loadMore()`; footer shows `LoadingDots`. Empty: `InboxZeroView` for inboxes, `EmptyStateView` otherwise.
First load with no cache: shimmer placeholder rows. Row insert/remove animate with `InkMotion.rowRemoval`
(`.transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))`) — but rows
removed by a swipe have already flown off, so they just collapse. Sync errors: a slim banner under the header with retry.
Screenshot scene `.swipe`: the first row renders mid-swipe (right, past the long threshold) via a debug offset.

**Swipes (`SwipeRow`)**: custom, not `.swipeActions`. iOS 18 `UIGestureRecognizerRepresentable` wrapping a
`UIPanGestureRecognizer` whose `gestureRecognizerShouldBegin` only accepts mostly-horizontal pans (|vx| > |vy| * 1.2),
so vertical scrolling is untouched; recognizes simultaneously with nothing else. Thresholds: short at
max(72pt, 22% width), long at 58% width, per side, using `settings.swipes` (`rightShort`, `rightLong`, `leftShort`,
`leftLong`; skip `.none`). Behind the row: a full-height layer that's `Ink.fill` with a grey icon until the first
threshold, then the action's `tint(accent:)` with a white icon (and the action title appearing past the long threshold);
the icon tracks the finger edge, scales up 1.0→1.15 with a spring "pop" + `Haptics.threshold()` each time a threshold is
crossed (both directions). Past full width: rubber-band (offset grows at 1/3 rate). Velocity fling: a fast flick
(> 900 pt/s) past the short threshold commits the short action. Release: below short → spring back
(`InkMotion.swipeSettle`); otherwise commit: for actions that remove the row (`removesFromList`), the row slides fully
off-screen in the swipe direction (~0.22 s), then calls `app.perform(action, on: [conversation])` and the list collapses;
for toggleRead/flag it springs back and performs; snooze springs back and opens the picker (via `app.perform`).
Tap while open/animating is ignored. Accessibility: expose the configured actions with `.accessibilityAction(named:)`.

**Mailbox switcher (`MailboxSwitcher`)**: sheet. "All Inboxes" (unified) with unread badge; each account's inbox with
`AccountDot` + address; smart mailboxes (`MailboxRole.unifiedRoles` minus inbox) unified; then per-account folders
(collapsible sections, indented by `depth`). Selected scope shows a check in the accent. Footer: Add account
(`app.isAddAccountPresented`), Settings. Selecting calls `app.select(scope:)` and dismisses with a haptic.

**Thread (`ThreadScreen`)** (shared iPhone/Mac): `ScrollView` with the subject (`InkFont.readerSubject` or serif per
settings, tight tracking), a meta line (count, account dot), then message cards oldest→newest. Earlier messages collapsed
to a one-line card (avatar, sender, snippet, date) — tap to expand with a spring; 4+ earlier messages collapse further into
"N more" pill. The latest (and any unread) expanded: header (avatar, sender name semibold, "to me, Ana" secondary,
`InkDate.reader(date)`; tap toggles a details block with From/To/Cc/Date full), then body (`EmailWebView`) — loading
state: `LoadingDots`; error: inline retry. Remote images blocked by default (`!settings.loadRemoteImages`): a quiet
banner "Images hidden to protect your privacy · N trackers blocked" with "Load images" (per message). Attachments:
horizontal chips (icon by type, filename, size) — tap: iOS `QuickLook` preview (`.quickLookPreview` with a temp file URL),
Mac opens with `NSWorkspace` after writing to a temp file; long-press/context: Share / Save. Unsubscribe: if
`listUnsubscribe` exists, a small "Unsubscribe" text button in the latest message header (mailto: opens compose;
https with One-Click post → confirm dialog then POST `List-Unsubscribe=One-Click`; plain https → open in browser).
On appear: `store.markOpened(conversation)` if `settings.markReadOnOpen`. Toolbar/bottom bar (iPhone): floating capsule
(`.inkGlass`) with Archive, Trash, Snooze, and a primary Reply button (accent) with a menu for Reply All / Forward;
star toggle + "More" menu (Mark unread, Move to…, Spam, Move to Inbox when not in inbox) in the nav bar. Archive/Trash/Snooze
call `app.perform`, then `app.didRemoveFocusedConversation(id)`. Mac: same actions as toolbar items. If the conversation
disappears from the store (archived elsewhere) show a calm empty state.
Optional delight: horizontal swipe between conversations is NOT required.

**`EmailWebView`**: `UIViewRepresentable`/`NSViewRepresentable` around `WKWebView`. Config: non-persistent data store,
`defaultWebpagePreferences.allowsContentJavaScript = false`, no link previews on iOS for privacy (`allowsLinkPreview = false`),
`suppressesIncrementalRendering = true`. Remote content blocking: compile once (static cache) a `WKContentRuleList` that
blocks every `^https?://` load and add it unless remote content is allowed for this message. `cid:` images: replace
`cid:` references with `data:` URIs from the body's attachments before loading. Document from
`EmailHTMLDocument.build(html:plainText:options:)` (InkMIME) with `dark` = current colour scheme, accent hex, font by
`settings.readingFont`. Height: inject a `WKUserScript` in `.defaultClient` world at document end that posts
`document.documentElement.scrollHeight` via `webkit.messageHandlers.height` on load and on `ResizeObserver` changes;
also scale-to-fit wide newsletters: if `scrollWidth > innerWidth`, set `document.body.style.zoom = innerWidth/scrollWidth`.
Report height to SwiftUI via a binding; animate height changes (no jumpiness). iOS: `scrollView.isScrollEnabled = false`,
transparent background (`isOpaque = false`, clear background). Mac: subclass `WKWebView` to forward `scrollWheel(with:)`
to `nextResponder` so the outer scroll view scrolls; `setValue(false, forKey: "drawsBackground")`. Links: `decidePolicyFor`
— `.linkActivated` → `mailto:` routes to `app.handleOpenURL`, http(s) opens externally (`UIApplication.shared.open` /
`NSWorkspace.shared.open`), everything else cancelled; initial `about:blank`/loadHTMLString navigation allowed.
Re-render when colour scheme / remote-images toggle changes, not on every SwiftUI update (compare a content key).

**Compose (`ComposeView`)**: sheet (`.presentationDetents([.large])`, `.interactiveDismissDisabled` when non-empty).
Top bar: close (if not empty: confirmation dialog Discard / Keep editing), and Send (`.inkAccent` button, paperplane,
disabled until there's a valid recipient; ⌘↩). Fields with hairline separators: From (menu when > 1 account; shows
`AccountDot`), To with `RecipientField` (tokens as capsules; text field; suggestions list from
`store.contactSuggestions(matching:)` shown inline under the field while typing — avatar, name, address; Return/comma/
space/tab commits a valid address; backspace on empty field selects then deletes the last token), "Cc/Bcc" row that expands
into Cc and Bcc fields, Subject, then the body `TextEditor` (plain text, `InkFont.readerBody`, comfortable insets,
auto-focus To for new mail and body for replies). Replies show the quoted text collapsed as "··· Show quoted text" under
the body. Attachments: paperclip button → iOS `PhotosPicker` + `.fileImporter`; Mac `.fileImporter`; chips with remove.
Send: `store.send(draft)`, dismiss, `Haptics.success()`. Subject empty → confirm "Send without a subject?".

**Snooze (`SnoozePicker`)**: sheet (iOS medium detent) / fits a popover on Mac. Title "Snooze until…", a 2-column grid of
`SnoozePresets.options()` tiles (SF Symbol, title, detail time) that animate on press, and "Pick date & time" revealing a
graphical `DatePicker` + Confirm. Selecting calls `app.snooze(until:)`; cancel calls `app.cancelSnooze()`.

**Search (`SearchScreen`)**: field focused on appear (`InkSearchField`), cancel button; before typing: recent searches
(`store.recentSearches`) and quick filters (Unread, Starred, Attachments as `Chip`s). Typing: instant local results
(`store.searchLocal`) as `ConversationRow`s (debounce 120 ms); after 350 ms idle or on submit, server results
(`store.searchServer`) appear in a "More results" section with `LoadingDots` while loading; `store.recordSearch` on submit.
Tapping a result opens the thread (iPhone: push inside the search's own NavigationStack; Mac: `app.open`).

**Onboarding (`WelcomeFlow`)**: welcome screen: big "Ink" wordmark built from type (the "i" dot is an accent circle that
drops in with a bouncy spring), tagline "Email, quieter.", three tiny feature lines fading up in sequence (Swipe to
triage · Private by default · Fast everywhere), then buttons "Add an account" (`.inkPrimary`) and "Explore the demo
inbox" (`.inkSecondary`; calls `store.addDemoAccount()`). Add account (`AddAccountFlow`, also used from Settings):
provider list (Gmail, iCloud, Outlook, Yahoo, Fastmail, Other) as big rows with monochrome SF Symbol glyphs →
account form: name, email, app password (secure, strips spaces for Gmail), with a "How to get an app password" card listing
the preset's steps + a button opening the provider's page; Gmail: note 2-Step Verification is required; Outlook: OAuth only
— "Sign in with Microsoft" if `OAuthSettings.isConfigured(.microsoft)`, else a short explanation linking to docs/ACCOUNTS.md;
Gmail also offers "Sign in with Google" when configured. "Other": email + password, then `Autodiscovery.discover(email:)`
prefills an Advanced section (IMAP/SMTP host, port, security, username) that's editable. Connect → progress list of
`VerificationStep`s (spinner → check with a spring, one after another) driven by `store.verify(...)`, then
`store.addAccount(...)`; success: big check + "You're in." + haptic, then dismiss into the inbox. Errors: inline, human,
with the `recoverySuggestion`-style hint per provider (e.g. Gmail "Application-specific password required" → explain app
passwords).

**Settings (`SettingsView`)**: iOS: `NavigationStack` + grouped `Form` styled to the theme (scroll background `Ink.background`,
rows on `Ink.surface`). Sections: Accounts (each: dot, name, address → detail with display name, signature, colour,
remove with confirmation; "Add account"), Appearance (Theme System/Light/Dark segmented; Accent: row of swatches with a
check — tapping animates the whole app's accent; Reading font; List density; Avatars; Preview lines 0/1/2), Inbox
(Focus & Other split; Mark as read when opened; After archiving: go to next/back to list), Swipes (four pickers + a live
preview row that animates the configured colours), Sending (Undo Send: Off/5/10/20/30 s), Privacy (Load remote images +
explanation of tracking pixels), Notifications (toggle → `Notifier.requestAuthorization`), About (version, "Your mail goes
straight from your device to your provider. Ink has no servers.", link to the research notes). Mac: same content in a
`TabView` (General, Accounts, Appearance, Swipes, Privacy) at a fixed width ~560.

## Mac

**`MacRootView`**: `NavigationSplitView` (sidebar | list | detail). Sidebar: `List(selection:)` of scopes — "All Inboxes",
unified smart mailboxes, then a section per account with its folders (indented) and unread badges (monospaced, tertiary);
account dots; an "Add Account" button at the bottom; sync status line (last synced / syncing dots / error). List column
(min 320, ideal 380): header with title + Focus/Other segmented control (when inbox), `List(selection: $app.selection)` of
`ConversationRow` with `.swipeActions` (trackpad) mapped from settings (leading: rightShort/rightLong; trailing:
leftShort/leftLong, `allowsFullSwipe` on the long ones), `.contextMenu`, load-more on last rows. Detail:
`ThreadScreen(conversationID:)` for one selection, a "N conversations selected" panel with bulk actions for several, or a
calm empty state with the Ink mark. Toolbar: compose, archive, trash, snooze (popover with `SnoozePicker`), star, reply
menu, search field (`.searchable` in the toolbar → shows `SearchScreen` results in the list column).
Keyboard (when the list or thread has focus, not while typing in a text field): j/k or ↓/↑ next/previous, e archive,
# (shift-3) or ⌫ trash, r reply, a reply all, f forward, c compose, / search, s star, u read/unread, h snooze, ! spam,
Esc clear selection, ⌘K command palette, ⌘N compose, ⌘R refresh, ⌘1…⌘9 mailboxes. Use `.onKeyPress` on the focused list,
NOT menu key equivalents for unmodified letters (they would fire while typing). `InkCommands`: menu items for New Message ⌘N,
Reply ⌘R... (use ⇧⌘R refresh? choose sensible non-conflicting standard Mail-like shortcuts: New ⌘N, Reply ⌘R, Reply All ⇧⌘R,
Forward ⇧⌘F, Archive ⌃⌘A, Move to Trash ⌘⌫, Mark Unread ⇧⌘U, Star ⇧⌘L, Snooze ⌃⌘S, Refresh ⇧⌘N (Get Mail), Command Palette ⌘K,
Search ⌥⌘F). Command palette: overlay sheet with `InkSearchField`, results = commands + mailboxes + matching conversations,
arrow keys + Return, `KeyCap` hints. Window background `Ink.background`; hide the title, unified toolbar.

## Quality bar

- Every file compiles for BOTH iOS 18 and macOS 15 (all App files are in both targets). Wrap a platform-only file entirely in
  `#if os(iOS)` / `#if os(macOS)`; inside shared files guard UIKit/AppKit specifics.
- Availability: iOS 26/macOS 26 APIs only behind `#if compiler(>=6.2)` + `if #available(iOS 26.0, macOS 26.0, *)`.
- Accessibility: labels on icon buttons, actions for swipe, Dynamic Type friendly (no fixed font sizes except glyphs).
- Performance: no `AnyView` in rows, no `GeometryReader` per row, Equatable rows, no work in `body` beyond formatting.
- Copy: short, warm, sentence case, no exclamation marks except "You're in."
