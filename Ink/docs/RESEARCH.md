# Ink — research notes

*Compiled 2026-10-20 from six research dossiers (Gmail, other providers, protocols, rendering, UX, distribution). Each dossier's critical claims were then checked by an independent verifier. Where a verifier corrected a claim, this document uses the corrected version. Remaining uncertainty is marked inline.*

**How to read this.** The owner should read §1, §2 (the provider table and step-by-step guides), §6 and §7. Engineers should read everything. **(critical)** marks a fact that changes how we build or what the owner has to do.

**Method caveat.** The research sandbox often could not load support.google.com, developers.google.com, support.microsoft.com, learn.microsoft.com, support.apple.com or rfc-editor.org directly. Claims about those pages rest on three kinds of evidence:

- search-index extracts of the pages;
- the official doc-source repos on GitHub (MicrosoftDocs, Apple DocC JSON);
- the source code of shipping clients (Thunderbird, FairEmail, Proton, Mailspring, MailKit).

Several items below are marked "test on device" for that reason.

---

## 1. TL;DR

- **What we're building.** Ink is a native SwiftUI mail app for iPhone (iOS 18+) and Mac (macOS 15+). The Mac version is a **native macOS target, not Mac Catalyst**. Each device talks IMAP and SMTP directly to the mail providers, and there is no Ink server. The research supports the planned design: our own Swift IMAP/SMTP engine over `URLSessionStreamTask`, using implicit TLS on ports 993/465 and **STARTTLS on 587**. STARTTLS is mandatory because iCloud and Outlook only offer it for sending.
- **Most accounts connect with an app password.** An app password is a one-off password you generate in your provider's security settings. It works for Gmail, iCloud, Fastmail (paid plans), Zoho, GMX/web.de and AOL. **Yahoo is uncertain:** as of mid-2026 there are credible reports that Yahoo no longer accepts app passwords.
- **Outlook.com, Hotmail and Live require "Sign in with Microsoft" (OAuth).** Microsoft switched off passwords for these accounts on 16 Sep 2024. Ink has no company behind it, so you would register Ink with Microsoft yourself. That now requires an **Azure account**, which is free but needs a real credit or debit card for verification. It is a one-time job of about 20–30 minutes.
- **Gmail OAuth is optional.** The app password needs no setup. If you want "Sign in with Google", you create a free Google Cloud project and **publish it unverified**. You click through an "unverified app" warning once. If you leave the project in "Testing", you have to sign in again every 7 days.
- **What won't work:**
  - Gmail accounts enrolled in Google's **Advanced Protection Program**. Google blocks both app passwords and OAuth for apps like Ink.
  - **Proton Mail on iPhone.** Proton works on Mac only, through Proton Mail Bridge, which needs a paid Proton plan.
  - "Sign in with" buttons for Yahoo, AOL, Fastmail and iCloud. None of these providers lets individual developers register.
- **iPhone install with a free Apple ID.** Xcode on your Mac builds Ink and installs it on the phone. **The install expires every 7 days**, so you re-run one script each week. There are no push notifications and no iCloud sync. Accounts don't sync between iPhone and Mac, so you add each account on both.
- **iPhone install with the paid Apple Developer Program ($99/yr).** GitHub Actions uploads every build to **TestFlight**, and each build lasts 90 days. The paid program also unlocks notarized Mac builds.
- **Mac install.** Download the DMG and drag Ink to Applications. On first launch, approve it in **System Settings › Privacy & Security › Open Anyway**. Expect a keychain "allow access" prompt after updates, because ad-hoc signing changes the app's identity with each build.
- **New-mail alerts are best effort.** True push needs a server that holds your credentials, plus a paid Apple account. We have neither, by design.
  - While Ink is open, mail arrives instantly over IMAP IDLE.
  - When Ink is in the background on iPhone, iOS wakes it for about 30 s whenever iOS chooses, and sometimes not at all.
  - Snooze, send-later and "remind me" only fire while Ink is running on one of your devices.
- **Privacy defaults.** HTML mail renders in a locked-down web view with JavaScript off. All remote images are blocked until you tap "Load images". Loading them reveals your IP address and the time you opened the message to the sender, because we have no image proxy. Known trackers stay blocked even after you load images. One-click unsubscribe only happens after you confirm.
- **How it feels.**
  - Multi-stage swipes: a short swipe archives and a long swipe deletes, for example.
  - Keyboard-first on the Mac, with j/k to move and e to archive.
  - Black and white, with one accent colour that shows up mostly during gestures.
  - 120 Hz on ProMotion iPhones. This needs one Info.plist key: `CADisableMinimumFrameDurationOnPhone`.
  - On iOS/macOS 26+, system bars pick up Liquid Glass automatically.
- **Toolchain deadline.** CI on GitHub's `macos-15` runner with Xcode 26.3 is fine today. **From April 2027, TestFlight and App Store uploads must be built with the iOS 27 SDK**, which means Xcode 27 on a macOS Tahoe 26.6+ runner. DMG installs and Xcode-direct installs are not affected.

---

## 2. How email accounts connect

### 2.1 App passwords vs OAuth, in plain English

- **App password.** You go to your provider's security page and click "create app password". The provider gives you a random code, such as 16 letters for Google. You paste that code into Ink instead of your real password.
  - It only works for email access, not for signing into your account on the web.
  - You can revoke it on its own.
  - It usually requires two-factor authentication on the account.
  - It needs no setup from us, which makes it the zero-setup path.
  - Downsides: providers increasingly discourage app passwords. Google calls them "not recommended" but has **not** deprecated them. Changing your main password silently revokes them for Google and Apple, though not for Yahoo.
- **OAuth ("Sign in with Google/Microsoft").** Ink opens the provider's real sign-in page in a secure browser sheet. You approve access, and the provider hands Ink a token. Ink never sees your password.
  - To do this, the provider has to know about the app. Ink has no company or verified developer behind it, so **you register Ink with Google or Microsoft yourself** and paste the resulting "client ID" into Ink.
  - Google: free, about 10–15 minutes, with one warning screen.
  - Microsoft: free, but you need an Azure account, which requires card verification.
- **Recommendation.**
  - Use app passwords everywhere they work.
  - Outlook.com users must use OAuth, because there is no alternative.
  - Gmail OAuth is a nice-to-have.

### 2.2 Provider table

All IMAP and SMTP connections use TLS. "TLS" means implicit TLS from the first byte. "STARTTLS" means the connection starts in plaintext and upgrades to TLS before anything sensitive is sent. Usernames are the full email address unless the table says otherwise.

| Provider | How you sign in | IMAP | SMTP | Setup steps / links | Gotchas |
|---|---|---|---|---|---|
| **Gmail** (personal @gmail.com) | App password (default) or OAuth (optional, your own Google Cloud client) | `imap.gmail.com:993` TLS | `smtp.gmail.com:465` TLS (fallback `:587` STARTTLS) | Turn on 2-Step Verification, then create a password at https://myaccount.google.com/apppasswords. IMAP has been always on since Jan 2025, with no toggle | At most 15 IMAP connections per account across *all* your devices and clients. 2,500 MB/day download and 500 MB/day upload; exceeding either locks IMAP for about 1–24 h. Advanced Protection blocks Ink completely. Changing your Google password revokes app passwords. Gmail saves sent mail itself (Ink must not upload a copy). About 500 recipients/day and 25 MB per message (third-party figures) |
| **Google Workspace** (custom domain on Gmail) | App password if the admin allows it, or OAuth. If you administer the domain, an "Internal" consent screen avoids every OAuth limit below | same | same | Admin console › Gmail › End User Access controls IMAP | The admin can turn IMAP off or restrict it to allow-listed OAuth clients. Enforcing security-key-only 2SV disables app passwords |
| **iCloud Mail** (@icloud.com, @me.com, @mac.com, iCloud+ custom domains) | App-specific password (needs two-factor). **No OAuth exists** | `imap.mail.me.com:993` TLS; username = the *name part* of your iCloud Mail address (try the full address if that fails) | `smtp.mail.me.com:587` **STARTTLS**; username = full iCloud Mail address | account.apple.com › Sign-In and Security › App-Specific Passwords (see §2.4) | Always log in with your **primary iCloud Mail address**, even if you send from an alias or custom domain. At most 25 active app passwords; changing your Apple Account password revokes them all. No MOVE command; folder names "Sent Messages", "Deleted Messages", "Junk", "Drafts", "Archive". Port 465 seems to work but is undocumented, so we don't rely on it. Unclear whether iCloud saves sent mail (Ink checks) |
| **Outlook.com / Hotmail / Live / MSN** | **OAuth only**, through your own Microsoft app registration (§2.6) | `outlook.office365.com:993` TLS | `smtp-mail.outlook.com:587` **STARTTLS** (`smtp.office365.com:587` also works) | 1) Turn IMAP on at outlook.live.com › Settings › Mail › Forwarding and IMAP › "Let devices and apps use IMAP". 2) Register an app in Entra (§2.6) | Passwords and app passwords have been rejected since 16 Sep 2024; the server's pre-login capabilities show `LOGINDISABLED`. "User is authenticated but not connected" means IMAP is off. On new accounts the IMAP toggle can revert in the first 10–24 h, and you may need to confirm "This was me" at account.live.com/activity. Some consumer accounts get SMTP `535 5.7.3` even with OAuth (open issue). About 20 MB attachment limit |
| **Microsoft 365** (work/school) | OAuth (the tenant may need admin consent) | `outlook.office365.com:993` TLS | `smtp.office365.com:587` STARTTLS | Ask the tenant admin | A tenant can disable SMTP AUTH (`535 5.7.139`). Basic SMTP AUTH is off by default for existing tenants from end of Dec 2026 (MC786329) |
| **Yahoo** (yahoo.\*, ymail, rocketmail; AT&T via Yahoo) | App password, **best effort**. OAuth is not available to us | `imap.mail.yahoo.com:993` TLS (`export.imap.mail.yahoo.com:993` for huge mailboxes) | `smtp.mail.yahoo.com:465` TLS | login.yahoo.com › Account Security › "Generate app password". Use a browser you've signed in with on several consecutive days, and not Incognito | FairEmail (June 2026) says Yahoo no longer accepts app passwords, and others report the option greyed out. A Thunderbird contributor said in Dec 2025 that Yahoo is *not* discontinuing them. **Test with your account.** Repeated failed logins reportedly trigger a ~1 h lockout. Searches are silently capped at 1,000 results. Inboxes over 10,000 messages have trouble fetching new mail |
| **AOL** (aol.\*, aim.com, verizon.net) | App password | `imap.aol.com:993` TLS | `smtp.aol.com:465` TLS | login.aol.com › Account Security › "Generate app password" (same browser trust check as Yahoo) | Probably shares Yahoo's IMAP quirks (untested) |
| **Fastmail** | App password (**mandatory**; your normal password won't work) | `imap.fastmail.com:993` TLS | `smtp.fastmail.com:465` TLS (or 587 STARTTLS) | Settings › Privacy & Security › App passwords | The **Basic plan has no IMAP/SMTP at all**. Fastmail doesn't save sent mail by default (Ink uploads the copy). JMAP is a possible v2 |
| **Proton Mail** | Bridge-generated password, **paid plan, Mac only** | `127.0.0.1:1143` STARTTLS by default, via Proton Mail Bridge on the Mac | `127.0.0.1:1025` STARTTLS by default | Install Bridge, sign in, copy the Bridge password, and read the ports and mode Bridge shows (they can differ) | Connect to `127.0.0.1`, never `localhost`. Bridge uses its own self-signed certificate, which Ink pins. **Nothing works on iPhone** except send-only SMTP submission (`smtp.protonmail.ch:587`, per-address SMTP token, custom-domain addresses on paid plans) |
| **Zoho** (personal) | Password, or an app password when 2FA, SAML or Google/Facebook sign-in is on | `imap.zoho.com:993` TLS (`.eu`, `.in`, `.com.au` by data centre) | `smtp.zoho.com:465` TLS (or 587) | Enable IMAP in Zoho Mail › Settings › Mail Accounts › IMAP Access. App passwords: accounts.zoho.com › Security › App Passwords | **New free-plan sign-ups have no IMAP.** Organisation accounts use `imappro.zoho.com` / `smtppro.zoho.com` |
| **GMX / web.de** | Password, or an app-specific password with 2FA | `imap.gmx.com:993` (US), `imap.gmx.net:993` (DE), `imap.web.de:993` | `mail.gmx.com:465`/`587`, `mail.gmx.net:465`/`587`, `smtp.web.de:465`/`587` | Enable "POP3 & IMAP" in webmail settings | IMAP is off by default and can switch itself off again after long disuse. TLS 1.2+ only. web.de uses the **name part** as the username. One unconfirmed Oct 2026 report says GMX now requires an app password even without 2FA |
| **Any other domain** | Usually a password or app password | auto-discovered (§3.10) | auto-discovered | Ink shows the discovered servers before sending your password | — |

**Hard blocker to check first (critical).** If your Google account is in the **Advanced Protection Program** (check at myaccount.google.com › Security, or g.co/advancedprotection), Ink cannot read that Gmail account by either path:

- Enrolling revokes existing app passwords and blocks new ones.
- OAuth from an app that is not on Google's APP-approved list fails with `Error 400: policy_enforced`. "Verified" does not help here: OAuth-verified apps such as eM Client and Thunderbird for Android are still blocked.
- Your options are to leave Advanced Protection or to use Apple Mail for that account. Apple Mail is on Google's approved list.
- This is a different thing from Android's device-level "Advanced Protection" mode.

### 2.3 Gmail app password, step by step

1. **Turn on 2-Step Verification.** Go to myaccount.google.com › Security › 2-Step Verification. App passwords don't exist without it. A passkey on its own does not count as 2SV.
2. **Open https://myaccount.google.com/apppasswords directly.** Since 2023 the page is often missing from the Security menu, so either use the link or search "App passwords" in your Google Account.
3. **Name it "Ink"** and click Create.
4. **Copy the 16-letter code.** Google shows it once, as four groups of four letters. Ink removes the spaces for you.
5. **In Ink, enter your full Gmail address and paste the code.** Ink connects to `imap.gmail.com:993` and `smtp.gmail.com:465`.

**If the option is missing,** the cause is one of these:
- 2SV is off.
- 2SV is set up only with security keys. Some people also report this with passkey-only 2SV (unverified).
- It's a work or school account.
- The account has Advanced Protection.

**When it stops working.** Changing your Google password revokes all app passwords. Gmail then returns a generic "invalid credentials" error. When any Gmail login fails, Ink will say: *"Your app password may have been revoked (for example after a Google password change). Create a new one at myaccount.google.com/apppasswords."*

**Error strings Ink maps to messages:**
- IMAP: `[ALERT] Application-specific password required`, which means you used your normal password.
- IMAP: `[AUTHENTICATIONFAILED] Invalid credentials`.
- SMTP: `534-5.7.9 Application-specific password required`.
- SMTP: `535-5.7.8 Username and Password not accepted`.

Status: app passwords still work for personal Gmail in Oct 2026, and Google has published no deprecation. "2026 phase-out" articles from Mailbird, warmysender and others cite no Google source.

### 2.4 iCloud app-specific password, step by step

1. Make sure two-factor authentication is on for your Apple Account. It is on by default for modern accounts.
2. Go to **https://account.apple.com** and sign in.
3. Open **Sign-In and Security › App-Specific Passwords**, then press **+** (or "Generate").
4. Enter the label "Ink" and click Create. You may be asked for your Apple Account password.
5. Copy the password, which looks like `xxxx-xxxx-xxxx-xxxx`.
6. In Ink, enter your **iCloud Mail address**: the primary @icloud.com, @me.com or @mac.com address. This applies even if your Apple Account email is different, and even if you send from an alias or an iCloud+ custom domain. Ink logs in with that address and lets you choose a different "From" address.

You can have up to 25 active app passwords. Changing or resetting your Apple Account password revokes every one of them, and Ink will ask for a new one.

### 2.5 Enabling Google OAuth (optional): steps and honest costs

**One-time setup, about 10–15 minutes:**
1. Go to https://console.cloud.google.com and create a project named "Ink".
2. *(Optional but harmless.)* Under APIs & Services, enable the Gmail API. This makes the scope easy to pick in step 5. IMAP probably doesn't need it (unverified).
3. Go to **Google Auth Platform › Branding** and fill in:
   - app name and support email;
   - **Application home page URL** and **privacy policy URL**;
   - that site's domain under **Authorized domains**.

   **New since about Sep 2026:** "Publish app" stays greyed out, with no explanation, until these three are filled in, even for a one-person app. A free GitHub Pages site (`<you>.github.io`) works for both URLs.
4. Go to **Audience**: choose External, add yourself as a test user, then click **Publish app** so the status reads **"In production"**. Do **not** submit for verification.
5. Go to **Data Access** and add `https://mail.google.com/`, `openid` and `email`.
6. Go to **Clients › Create client › iOS**. Enter Ink's bundle ID and leave App Store ID and Team ID blank. **Do not enable App Check**: it needs a paid Team ID, and once it's enforced Google rejects Ink's requests. Copy the client ID. **One iOS-type client serves both the iPhone and the Mac app.** Google's docs say iOS and macOS apps must use the iOS type.
7. In Ink, paste the client ID and sign in. On the "Google hasn't verified this app" screen, click **Advanced › Go to Ink (unsafe)**. You do this once.

**Honest costs and limits:**
- **"Testing" status (critical).** A test user's consent, and the refresh token with it, **expires 7 days after consent**. Mail access always triggers this; adding openid/email doesn't help. Testing also caps you at 100 listed test users.
- **"In production", unverified.** No 7-day expiry. You see the warning screen once. There is a lifetime cap of 100 users, which doesn't matter for one owner. **Tokens issued while in Testing don't become long-lived when you publish**, so sign in again after publishing.
  - One forum anecdote reports the 7-day expiry even after publishing. Check that your token still works more than 7 days later.
- **Verification is not needed.** Google's "personal use" exemption covers apps that aren't shared or have fewer than 100 known users.
- **If you ever share Ink publicly:**
  - `https://mail.google.com/` is a *restricted* scope and needs full verification.
  - Apps that move restricted data through a server also need an annual CASA security assessment. Ink has no server, but Google doesn't explicitly confirm that exempts it.
- **Things that still kill a token** (Ink shows "Reconnect Gmail" when this happens):
  - you change your Google password (for tokens with Gmail scopes);
  - 6 months without use;
  - you revoke access;
  - more than 100 refresh tokens for one account and one client (the oldest is dropped silently);
  - Workspace admin policy.
- **Housekeeping.** Since 2025, Google deletes OAuth clients that go unused for 6 months (restorable for 30 days).

**Engineering details (critical):**
- Endpoints, verified live: authorize `https://accounts.google.com/o/oauth2/v2/auth`, token `https://oauth2.googleapis.com/token`, revoke `https://oauth2.googleapis.com/revoke`. PKCE `S256` is supported.
- Redirect URI: `com.googleusercontent.apps.<ID>:/oauth2redirect`. That is the reversed client ID, lowercased, with **one** slash. iOS-type clients have no redirect list to register.
- Do not use a "Desktop" client type.
  - Desktop clients need a client secret, which Google shows only once since 2025.
  - They require a loopback `http://127.0.0.1` redirect. Loopback redirects are blocked for iOS-type clients.
  - AppAuth's README still tells macOS apps to use Desktop; that advice is outdated.
- The token request carries `client_id`, `code`, `code_verifier`, `redirect_uri` and `grant_type`, with no secret. Refresh sends `grant_type=refresh_token`, `refresh_token` and `client_id`. Access tokens last about 3600 s.
- Use `ASWebAuthenticationSession(url:callback:.customScheme("com.googleusercontent.apps.<ID>"))`. This initializer is iOS 17.4+ / macOS 14.4+. On macOS, supply a `presentationContextProvider`.
- If the client ID is pasted in at runtime, the scheme can't be in `CFBundleURLTypes`. An Apple forum answer says `ASWebAuthenticationSession` doesn't need the scheme registered (medium confidence, test on device). The fallback is to bake the client ID into the build settings.
- Check that the returned `scope` contains `https://mail.google.com/`. Google is rolling out granular consent checkboxes, so a user can untick it.

### 2.6 Enabling Microsoft OAuth: required for Outlook.com, with honest costs

**Why there's friction (critical).** Since June 2024, every new Microsoft app registration has to live inside an Entra directory (a "tenant"). A personal Microsoft account on its own can no longer register an app. You can get a tenant in two ways:

- **Already have one?** An old Azure sign-up's "Default Directory", or a work tenant that lets you register apps, works. Use it.
- **Otherwise, sign up for Azure's free account** (aka.ms/signUpForAzure) with your personal Microsoft account.
  - You need a **real credit or debit card**. Microsoft places a small verification hold that clears in 3–5 days. Prepaid and virtual cards are refused, and VoIP numbers are refused for phone verification.
  - The free trial is only for people new to Azure.
  - After 30 days the subscription is disabled unless you upgrade, but **the tenant stays**. Entra ID Free has no charge, so the app registration should keep working. The docs imply this but don't state it outright.

Routes that do **not** work:
- The **Microsoft 365 Developer Program sandbox.** It's limited to Visual Studio subscribers and certain partners, needs a billing account since Sep 2026, and lasts 90 days.
- An **Entra External ID tenant.** Its apps must be single-tenant and can't request the Outlook IMAP/SMTP scopes.

**Steps:**
1. Sign in at https://portal.azure.com (or entra.microsoft.com) and go to **Microsoft Entra ID › App registrations › New registration**.
2. Name it "Ink". For supported account types, pick **"Personal accounts only"** (Ink will use `/consumers`) or **"Any Entra ID Tenant + Personal Microsoft accounts"** (Ink will use `/common`).
3. Go to **Authentication › Add a platform › Mobile and desktop applications**, or the iOS/macOS platform with the bundle ID. Add the redirect `msauth.<bundle-id>://auth`. **Do not** register it as a "Single-page application", because SPA refresh tokens die after 24 h. Create no client secret.
4. *(Optional.)* Set "Allow public client flows" to **Yes** if Ink offers the device-code fallback.
5. Copy the **Application (client) ID** into Ink, along with the tenant setting from step 2.
6. In Outlook on the web, turn on **"Let devices and apps use IMAP"** (see the table above).
7. The consent screen will say the publisher is "unverified". That's fine for your own personal account.

**Engineering details:**
- Endpoints, verified live: `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize`, `/token` and `/devicecode`. `<tenant>` is `common`, `consumers`, `organizations` or a tenant ID.
- **Store the tenant per account. Don't hard-code it.**
  - A single-tenant app gets `AADSTS50194` on `/common`.
  - An Entra-only app gets `AADSTS9002332` on `/consumers`.
  - A personal-only app needs `/consumers`.
- Scopes: `https://outlook.office.com/IMAP.AccessAsUser.All`, `https://outlook.office.com/SMTP.Send` and `offline_access`, plus optionally `openid email`. All are on one resource, so a single token covers IMAP and SMTP.
- **Use PKCE S256.** Microsoft recommends it for all app types. (Thunderbird doesn't use PKCE with Microsoft; don't copy that.) Never send a client secret.
- Refresh tokens last about 90 days and rotate. **Replace the stored token on every refresh.** Consumer access tokens are opaque, so never parse them.
- **Never reuse Thunderbird's or FairEmail's client IDs**, which are visible in their source. That is impersonation, and their redirects won't match anyway.
- Open issue: some consumer accounts fail SMTP XOAUTH2 with `535 5.7.3`. FairEmail works around this by sending through Microsoft Graph `Mail.Send`. Test on the owner's account.

### 2.7 Providers where OAuth isn't an option for us

- **Yahoo/AOL.** The `mail-w` scope isn't self-service. Yahoo isn't accepting new client registrations with mail access, and the only route is a commercial access request. Its self-serve developer console reportedly offers only OpenID Connect permissions as of July 2026.
- **Fastmail.** OAuth clients are registered by hand, by Fastmail staff.
- **iCloud.** There is no third-party OAuth.
- **Proton.** There is none.

---

## 3. Protocol & architecture decisions

### 3.1 Verdict on the planned approach

| Plan item | Verdict |
|---|---|
| IMAP + SMTP implemented in pure Swift (our own client) | **Keep.** Libraries are immature (swift-nio-imap) or a poor fit for Swift 6 (MailCore2). Use them as references and test-fixture sources |
| TLS through `URLSessionStreamTask` with `startSecureConnection()` | **Keep.** It's not deprecated. TN3151 says to prefer Network.framework "unless you have a specific reason", and STARTTLS is that reason. Two usage rules apply (§3.2) |
| App passwords as the zero-setup path | **Keep** for Gmail, iCloud, Fastmail, Zoho, GMX/web.de and AOL. **Not** for Outlook.com. **Fragile** for Yahoo |
| Optional OAuth with user-supplied client IDs | **Keep for Google and Microsoft.** Microsoft is effectively *mandatory* for Outlook users and needs an Azure tenant. Google must be published to avoid 7-day expiry. Drop Yahoo, AOL and Fastmail OAuth |
| Implied: push notifications | **Impossible** without a server and a paid account. Use background refresh plus IDLE |
| Implied: credentials shared between iPhone and Mac | **Impossible** on free or ad-hoc signing. Accounts are set up per device |

### 3.2 Transport and TLS

**Decision.** Use `URLSessionStreamTask` for both implicit TLS and STARTTLS. Hide it behind a `Transport` protocol (connect, read, write, startTLS, close), so the IMAP and SMTP engines are pure byte-in/byte-out state machines.

**Facts (verified against Apple's DocC, Oct 2026):**
- Not deprecated: the class, `URLSession.streamTask(withHostName:port:)`, `startSecureConnection()`, `readData(ofMinLength:maxLength:timeout:)` and `write(_:timeout:)`. Async variants exist: `readData(...) async throws -> (Data?, Bool)` and `write(_:timeout:) async throws`.
- Deprecated: `stopSecureConnection()`, the class's `init()`/`new()`, and `streamTask(with: NetService)` (marked deprecated at 27.2). We use none of them.
- `startSecureConnection()` has **no completion handler**. The handshake is queued behind any pending reads and writes. TLS and certificate errors only surface on the *next* read or write. Server-trust challenges arrive at `urlSession(_:task:didReceive:completionHandler:)`, which is where we pin Proton Bridge's certificate.
- **Network.framework can't upgrade an existing connection to TLS natively.** STARTTLS on `NWConnection` needs a custom `NWProtocolFramer`, using `prependApplicationProtocol(options:)`, then `passThroughInput()`, `passThroughOutput()` and `markReady()` (iOS 13+). That's roughly 50–150 lines; Apple DTS says Apple Mail does it this way. Keep it as the plan B transport.
- The new Swift `NetworkConnection` API is iOS/macOS 26+ only and has no STARTTLS path. `prependApplicationProtocolIgnoringReady` is iOS/macOS 27 only. Neither helps with an iOS 18 target.
- **Avoid** CFStream/NSStream (deprecation path, no TLS 1.3) and Secure Transport (deprecated).
- **Linux.** swift-corelibs-foundation marks the stream-task factory and all of its I/O methods `@available(*, unavailable)`. Tested on Swift 6.2.4 Linux: they don't compile. Put the transport behind `#if canImport(Darwin)` and test the engines on Linux with an in-memory transport.

**Rules (critical):**
1. **Implicit TLS (993/465).** Call `startSecureConnection()` before `resume()` and before queueing any read or write, as Apple's TCPTransports sample does. Apple doesn't spell this pattern out, but it follows from the documented semantics and real apps use it. **Write an integration test against 993/465 early.**
2. **STARTTLS (587, and 143 if ever needed):**
   1. Read the server's full reply to `STARTTLS`, **with no further read queued**.
   2. If any bytes are left over in our buffer, **abort**. Leftover bytes indicate a response-injection attack (USENIX'21 "NO STARTTLS").
   3. Call `startSecureConnection()`.
   4. Write `CAPABILITY` (IMAP) or `EHLO` again (SMTP, as RFC 3207 requires).
   5. Throw away every capability learned before TLS.

   Apple documents that the handshake waits for pending I/O. Whether a pending read actually deadlocks is unproven: one XMPP client reports it works. Design around it anyway.
3. **Prove TLS works before sending credentials.** Complete one read over TLS (the greeting on 993/465, or the CAPABILITY/EHLO reply after STARTTLS) before AUTH.
4. **Never fall back to plaintext.** Fail if STARTTLS isn't advertised.
5. Set `tlsMinimumSupportedProtocolVersion = .TLSv12`; GMX requires it.
6. Read timeouts: about 60 s for commands, and 0 (none) for IDLE with our own watchdog. Use `NWPathMonitor` to reconnect when the network changes, and set `allowsConstrainedNetworkAccess` appropriately for Low Data Mode.
7. **Port choice:**
   - Prefer implicit TLS where it's offered (RFC 8314): Gmail, Yahoo, AOL, Fastmail, Zoho and GMX all offer 465.
   - Use 587 STARTTLS for iCloud and Outlook.
   - Use STARTTLS for Proton Bridge unless the user switched Bridge to SSL mode.

```swift
let cfg = URLSessionConfiguration.ephemeral
cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
let session = URLSession(configuration: cfg, delegate: trustDelegate, delegateQueue: nil)
let task = session.streamTask(withHostName: host, port: port)
if implicitTLS { task.startSecureConnection() }   // before resume() and before any I/O
task.resume()
// Implicit TLS: the first read (server greeting) is where TLS/trust errors appear.
// STARTTLS: read greeting -> write "a1 STARTTLS" -> read until tagged OK (no other read queued)
//   -> abort if bytes remain buffered -> task.startSecureConnection()
//   -> write "a2 CAPABILITY" -> read it (fails here on a bad certificate) -> only then authenticate.
let (data, eof) = try await task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: 60)
```

### 3.3 Our own IMAP/SMTP vs a library

| Library | State (Oct 2026) | Use |
|---|---|---|
| apple/swift-nio-imap | Active (commits to 2026-10-16, 0.4.0 on 2026-07-21). README says "not yet ready for use in production". 0.4.0 has an 8 KiB line limit, so large BODYSTRUCTUREs fail. Its new `IMAPCommands` client is implicit-TLS only | Possible drop-in **parser** (`NIOIMAPCore` needs only NIO's ByteBuffer, not BoringSSL). Keep our parser behind a protocol so we can swap it in |
| Cocoanetics/SwiftMail | Very active (1.16.0, 2026-10-09). BSD-2. Built on swift-nio-imap, NIOPosix and NIOSSL | Mine for fixtures, its provider capability matrix, and its IDLE and Mail.app analyses (credit them) |
| MailCore2 | Its SPM target is a 2020 binary xcframework from a fork | Avoid |
| Postal | Dormant (Swift 5.0 era) | Avoid |

**What we give up by writing our own:** years of server-quirk handling. MailKit detects 19 server "personalities". Known examples:
- Gmail returns a broken BODYSTRUCTURE for nested multiparts that share a boundary.
- Gmail sometimes swaps name and mailbox in ENVELOPE addresses.
- Exchange doesn't quote folder names that contain control characters.
- iCloud answers `ENABLE QRESYNC CONDSTORE` with OK but no untagged `ENABLED`.
- Yandex sends BYE without a tagged reply.

So the parser must be *tolerant*:
- literals can appear anywhere a string can;
- NIL can appear in any nstring position;
- quoted strings can hold raw 8-bit UTF-8 (fall back to Latin-1);
- mailbox names use modified UTF-7 unless `UTF8=ACCEPT` is enabled;
- `{n}` synchronising literals must wait for `+`; `{n+}` needs LITERAL+; LITERAL- allows at most 4096 bytes.

**Implementation order:**
1. CAPABILITY.
2. `ID ("name" "Ink" "version" "x")`. NetEase 126/163 reject SELECT without it.
3. LOGIN, AUTHENTICATE PLAIN and XOAUTH2, with SASL-IR.
4. LIST with SPECIAL-USE.
5. SELECT/EXAMINE and STATUS.
6. UID FETCH, STORE and SEARCH, with ESEARCH.
7. MOVE, falling back to `UID COPY` + `UID STORE +FLAGS.SILENT (\Deleted)` + `UID EXPUNGE` (UIDPLUS).
8. APPEND.
9. IDLE.
10. ENABLE CONDSTORE/QRESYNC.

Defer COMPRESS=DEFLATE. Apple's Compression framework has no sync-flush, so it would need zlib.

### 3.4 Capabilities: decide at runtime, never from a table

**Re-issue CAPABILITY after TLS and again after authentication (critical).** iCloud only shows IDLE after login. Exchange's auth reply carries no capability code, and its pre-login list differs from its post-login list. iCloud's advertised list changed between 2025 and 2026. The table below comes from dated wire captures and is for orientation only.

| | Gmail | iCloud (captured 2026-10-08) | Exchange / Outlook.com (2026-10-16) | Yahoo (2026 capture) |
|---|---|---|---|---|
| IDLE | yes | yes, but only advertised after login | yes | listed in a 2026 capture; older captures lacked it, so check. IDLE doesn't report deletions |
| MOVE | yes | **no** (use the COPY+STORE+EXPUNGE fallback) | yes (returns COPYUID) | yes |
| CONDSTORE / QRESYNC | yes / **no** (MODSEQ is account-wide) | yes / yes (has had bugs, so validate VANISHED) | **no / no** (no HIGHESTMODSEQ) | **not advertised**. `CHANGEDSINCE` returns `NO [CANNOT]` |
| ENABLE | yes | yes, but **silent** (treat the tagged OK as success) | no | yes |
| SPECIAL-USE advertised | yes (attributes on every LIST) | no, yet LIST marks `\Sent` "Sent Messages" and `\Trash` "Deleted Messages" | no, yet LIST marks `\Sent` `\Drafts` `\Trash` `\Junk`; "Archive" is bare | yes |
| Other | X-GM-EXT-1, ESEARCH, LIST-STATUS, UTF8=ACCEPT, LITERAL-, COMPRESS, APPENDLIMIT=35651584 | ESEARCH, SORT, LIST-STATUS, SASL-IR, no LITERAL+ (use synchronising literals) | pre-login `AUTH=XOAUTH2 LOGINDISABLED`. PERMANENTFLAGS has no `\*`, so no custom keywords | **MESSAGELIMIT=1000**, UIDONLY, PARTIAL, OBJECTID, XYMHIGHESTMODSEQ |

**Yahoo paging (critical; from one project's live testing).** A `UID SEARCH SINCE <date>` that matches more than 1,000 messages returns only 1,000, with a plain OK. The cut happens *before* other criteria, so splitting the search into UID ranges doesn't help. Instead:
- page with `UID FETCH <lo>:* (UID FLAGS INTERNALDATE) (PARTIAL 1:<limit>)` when PARTIAL is advertised, or use UID spans no wider than the limit;
- filter dates on the device;
- treat any result whose size equals MESSAGELIMIT as possibly truncated.

**Folder roles.** Resolve them by attribute (`\All \Archive \Drafts \Junk \Sent \Trash`), then by name:
- iCloud: "Sent Messages", "Deleted Messages", "Junk", "Drafts", "Archive".
- Exchange: "Sent Items", "Deleted Items", "Junk Email", "Drafts", "Archive".

The Gmail prefix can be `[Gmail]` or `[Google Mail]` (legacy UK/DE accounts), so **never match Gmail folders by name**. If the user unticked "Show in IMAP" for All Mail, `\All` can be missing.

### 3.5 Sync strategy

1. **Connect:** CAPABILITY → ID → AUTH → CAPABILITY. Then ENABLE QRESYNC (or CONDSTORE) and UTF8=ACCEPT where they're advertised.
2. **Folders:** `LIST "" "*" RETURN (SPECIAL-USE STATUS (MESSAGES UIDNEXT UNSEEN HIGHESTMODSEQ))` when LIST-STATUS is available. Otherwise use LIST followed by STATUS.
3. **Window:** SELECT INBOX, take the newest N UIDs (for example 200, in batches no larger than MESSAGELIMIT), then one batched fetch:
   `UID FETCH … (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-POST LIST-ID)])`.
   On Gmail, add `X-GM-MSGID X-GM-THRID X-GM-LABELS`.
4. **Snippets:** use `FETCH n (PREVIEW (LAZY))` if PREVIEW is advertised (RFC 8970, Dovecot ≥ 2.3.15). Otherwise fetch `BODY.PEEK[<text part>]<0.2048>`, or 16–32 KB for HTML. Fetch full bodies only when a message is opened, and cache them as files. Always use `.PEEK` so the fetch doesn't set `\Seen`.
5. **Flags:**
   - With CONDSTORE: `UID FETCH lo:* (FLAGS) (CHANGEDSINCE <modseq>)`.
   - Without it (Exchange, Yahoo): re-fetch FLAGS for the whole window.
6. **Deletions:**
   - With QRESYNC: use `VANISHED (EARLIER)`.
   - Otherwise (Gmail, Exchange, Yahoo): `UID SEARCH RETURN (ALL) UID lo:*` and diff against the local set.
   - If **UIDVALIDITY** changes, wipe the cached mailbox.
7. **Cache:** SQLite, keyed by (account, mailbox, UIDVALIDITY, UID) plus Message-ID. Gmail messages are keyed by `X-GM-MSGID`, which is stable across folders. Per mailbox, store UIDVALIDITY, UIDNEXT and HIGHESTMODSEQ. Persist only UIDs, never sequence numbers.
8. **Connections:** per device, one command connection plus one IDLE connection on INBOX, plus at most one body/attachment fetch. iPhone and Mac together stay at 6 or fewer, well under Gmail's limit of 15 across all clients.
   - Gmail IMAP sessions last about 24 h, or about 1 h with OAuth (the access-token lifetime). Plan for reconnect and re-auth.
9. **IDLE:**
   - Re-issue it every **5–10 minutes**. RFC 2177 says at most 29, but NAT boxes and Gmail drop idle connections sooner. MailKit's Gmail example uses 9 minutes; macOS Mail uses about 5.
   - Reconnect on `* BYE` or a socket error.
   - Close both connections when the iPhone app is backgrounded, and resync when it returns to the foreground.
10. **Bandwidth:** sync headers first in a recent window, fetch bodies on demand, and use STATUS/LIST-STATUS for counts. This keeps us far under Gmail's 2,500 MB/day.

**Gmail actions: be explicit (critical).** What `\Deleted` + EXPUNGE does depends on the user's Gmail settings (`autoExpunge`, and `expungeBehavior` = archive by default, trash, or deleteForever), so don't rely on it.

| Action | Gmail | Other servers |
|---|---|---|
| Archive | `UID MOVE <uid> <\All folder>` or `UID STORE <uid> -X-GM-LABELS (\Inbox)` | MOVE to the `\Archive` / "Archive" folder |
| Trash | `UID MOVE <uid> <\Trash folder>` (Gmail purges it after 30 days) | MOVE to `\Trash` / "Deleted Messages" / "Deleted Items" |
| Delete forever | in Trash: `STORE +FLAGS (\Deleted)`, then `UID EXPUNGE` | same |
| Spam | MOVE to `\Junk` | MOVE to `\Junk` / "Junk" / "Junk Email" |
| Star / read | `\Flagged` / `\Seen` | same |

Without MOVE (iCloud), use `UID COPY` + `UID STORE +FLAGS.SILENT (\Deleted)` + `UID EXPUNGE`. Without UIDPLUS, a plain EXPUNGE also removes other `\Deleted` messages, so avoid it.

### 3.6 Threading

- **Gmail:** use `X-GM-THRID`, fetched from the `\All` folder so your own replies are included.
- **Servers with OBJECTID:** use `THREADID`.
- **Everyone else:** client-side **JWZ threading** over Message-ID, References and In-Reply-To. Avoid merging threads on subject alone.

### 3.7 Authentication state machine

XOAUTH2 initial response (RFC 4648 standard base64, no line breaks):
```
base64("user=" + email + "\x01" + "auth=Bearer " + accessToken + "\x01\x01")
```
- **IMAP:** `a1 AUTHENTICATE XOAUTH2 <b64>` on one line when SASL-IR is advertised. Otherwise send `AUTHENTICATE XOAUTH2`, wait for `+`, then send `<b64>`.
- **SMTP (critical):** default to the **two-step form**: `AUTH XOAUTH2` → `334` → `<b64>`. RFC 4954 forbids an initial response that pushes the line past the 512-octet limit, and OAuth tokens do. Gmail accepts the one-line form; Microsoft's samples use two steps.
- **Failure handling must not assume one shape (critical):**
  - Gmail sends a challenge: `+ <b64 JSON>` (IMAP) or `334 <b64 JSON>` (SMTP), for example `{"status":"401","schemes":"bearer","scope":"https://mail.google.com/"}`. Ink must reply with an **empty line**, then read `NO` / `535`.
  - Microsoft fails immediately: `NO AUTHENTICATE failed.` / `535 5.7.3 Authentication unsuccessful`.
  - So accept any of OK/235, NO/535, or a continuation followed by an empty line and then NO/535. Never block waiting for a challenge.
- On an auth failure with OAuth: refresh the token and retry **once**. If it fails again, or the token endpoint returns `invalid_grant`, mark the account "needs sign-in".
- Refresh about 5 minutes before `expires_in` runs out. Reuse one refresh token per account.
- OAUTHBEARER (RFC 7628) is optional. Its failure acknowledgement is a single `0x01` byte, not an empty line, so don't mix the two mechanisms.
- **Yahoo:** stop on the first auth failure and show the message. Don't retry in a loop, because of the reported ~1 h lockout.

### 3.8 Sending and Sent-folder copies

**SMTP flow:**
1. Greeting 220 → `EHLO` → (`STARTTLS` → `EHLO` again) → `AUTH`. Use PLAIN, LOGIN as a fallback, or XOAUTH2.
2. `MAIL FROM:<a> SIZE=n` → one `RCPT TO` per recipient. Bcc recipients exist **only** here; strip the Bcc header from the message.
3. `DATA`, dot-stuffing any line that starts with `.`, ending with `CRLF.CRLF`, then `QUIT`.
4. Respect EHLO `SIZE`. Use CRLF everywhere, lines ≤ 998 octets, and QP/base64 for non-ASCII content. Use SMTPUTF8 only if it's advertised *and* needed.

**Sent copies (critical; corrected).** Providers differ. These observations come from client code and test harnesses (Mailspring-Sync, imapsync), not from provider docs:
- Gmail, Yahoo/AOL, Zoho and Exchange/Outlook.com file a Sent copy themselves.
- Exchange is late: the copy usually appears 0.5–3.5 s after the SMTP 250, sometimes 6–8 s, once about 3 minutes.
- iCloud is unverified (it likely does not save a copy). Fastmail does not by default.
- A blind APPEND on Gmail doesn't create a visible duplicate (Gmail discards it), but it wastes upload bandwidth and returns a phantom UID. On Exchange, Yahoo and Zoho it does create duplicates.

**Algorithm:**
1. Always generate our own `Message-ID: <UUID@sender-domain>`.
2. **Gmail:** never APPEND. Find the server's copy in `\Sent` or `\All` by Message-ID.
3. **Other providers:**
   - After the 250 reply, poll `\Sent` with `UID SEARCH HEADER Message-ID <id>`, backing off about 4 s on a fresh account (delays 0,1,1,2) or about 12 s once we know the server saves copies (0,1,1,2,2,3,3).
   - If no copy appears, `APPEND` our own with `\Seen`.
   - Learn and store `serverSavesSent` per account.
4. **Late-copy cleanup:** if a server copy with the same Message-ID appears within 30 minutes of an APPEND, delete the server's copy and keep ours.
5. Each separate SMTP submission produces its own server copy (for example, per-recipient sends).

### 3.9 Credentials storage

**iOS:**
- Use the data-protection keychain with `kSecAttrAccessibleAfterFirstUnlock`. Background refresh has to read credentials while the phone is locked, and the default `WhenUnlocked` fails there.
- Items survive reinstalls as long as the **Team ID stays the same**. Re-signing with a different Apple ID, for example through SideStore with another account, loses them.

**macOS, ad-hoc-signed DMG (critical):**
- The data-protection keychain needs entitlements authorised by a provisioning profile. Without one, SecItem returns `errSecMissingEntitlement` (−34018). So **do not set `kSecUseDataProtectionKeychain`** in ad-hoc builds; use the file-based login keychain.
- File-keychain access lists follow the app's designated requirement. For ad-hoc code that requirement is the specific build's cdhash, so **every update can trigger "Ink wants to use your confidential information…"**. Mitigations:
  - Store **all** account secrets in **one** keychain item, so there's at most one prompt per update.
  - Sign every build with one stable identity. That could be a self-signed certificate or the free personal-team "Apple Development" certificate exported to CI. Whether this stops the prompts is **unverified; test it**.
  - Put data-protection keychain use behind a build flag, and turn it on for properly provisioned builds (Apple Development, Developer ID, TestFlight).
- Mac Catalyst supports *only* the data-protection keychain. That's another reason to use a native macOS target.
- Avoid App Groups on the ad-hoc Mac build. On macOS 15+, group-container access without a profile triggers a consent prompt on every launch.

**No cross-device sync.** iCloud Keychain sync (`kSecAttrSynchronizable`) needs the data-protection keychain and a shared, Team-ID-prefixed access group. A free-provisioned iPhone app and an ad-hoc Mac app can't share one, so **accounts are set up on each device**. A manual export/import of account settings, *without* secrets unless they're encrypted with a passphrase, can make this easier.

### 3.10 Background refresh, and why true push needs a server

**iPhone:**
- iOS suspends apps shortly after they go to the background. There's no supported way to keep an IMAP socket open, run at a guaranteed interval, or wake on network activity.
- **`BGAppRefreshTask`:**
  - Setup: `UIBackgroundModes` = `fetch`, plus `BGTaskSchedulerPermittedIdentifiers` in Info.plist. Register handlers before launch finishes and resubmit the request inside the handler. In SwiftUI, use `.backgroundTask(.appRefresh("id"))`.
  - Timing: about 30 s per run, at times iOS chooses. Low Power Mode, Background App Refresh being off, or the user force-quitting Ink can stop it completely.
  - The handler connects, runs `STATUS INBOX (UIDNEXT UNSEEN)`, fetches envelopes for new UIDs, posts a **local notification**, and logs out.
  - Free teams can't use Time Sensitive or Communication notifications.
- `BGContinuedProcessingTask` (iOS 26+) is only for user-started work with a Live Activity. It isn't a polling mechanism.
- `BGTaskRequest.earliestBeginDate` only guarantees "not before" that time. So **snooze, send-later and remind-if-no-reply fire only when Ink runs** on either device.
- **Undo send** is a local delay before the SMTP submission, wrapped in `beginBackgroundTask` in case the app is backgrounded mid-send.

**Mac:**
- There's no `BGAppRefreshTask` on native macOS. Keep IDLE running while the app runs.
- Use `ProcessInfo.beginActivity` to avoid App Nap timer coalescing, and optionally `NSBackgroundActivityScheduler` and a login item.

**Why real push needs a server.** True push requires a server that watches each mailbox and sends APNs pushes:
- for Gmail, `users.watch` → Cloud Pub/Sub, re-called at least every 7 days;
- for Microsoft, Graph subscriptions;
- for everything else, the server holds your credentials and runs IMAP IDLE itself.

That means a server storing your credentials or tokens (Spark works this way and is criticised for it), and APNs is **not available to free Apple developer accounts**. Apple Mail's own push for iCloud uses a private mechanism (`XAPPLEPUSHSERVICE`) that we can't use.

### 3.11 Server auto-discovery for custom domains

Thunderbird runs its lookups in parallel and ranks them by priority, rather than trying them one after another. Ink's pipeline:

1. **Built-in provider table**, covering every row in §2.2 plus MX hints.
2. **Provider autoconfig over HTTPS:** `https://autoconfig.<domain>/mail/config-v1.1.xml?emailaddress=<email>`, then `https://<domain>/.well-known/autoconfig/mail/config-v1.1.xml`.
3. **Thunderbird ISPDB:** `https://autoconfig.thunderbird.net/v1.1/<domain>` (desktop Thunderbird uses `https://live.thunderbird.net/autoconfig/v1.1/<domain>`).
4. **MX lookup** with `DNSServiceQueryRecord` (type 15). Take the most-preferred MX, sorted numerically. Try the MX host minus its first label, then its eTLD+1, against our table, autoconfig and ISPDB. This is what tells Outlook.com (`*.olc.protection.outlook.com`) apart from M365 (`*.mail.protection.outlook.com`). Other mappings:
   - `aspmx.l.google.com`, `smtp.google.com` and `smtp.goog` → Gmail;
   - `mx0x.mail.icloud.com` → iCloud;
   - `*.messagingengine.com` → Fastmail;
   - `*.am0.yahoodns.net` → Yahoo, `mail.gm0.yahoodns.net` → AOL;
   - `mx.zoho.*` → Zoho.
5. **Optional RFC 6186/8314 SRV records:** `_imaps._tcp`, `_submissions._tcp`, `_submission._tcp`. Thunderbird doesn't use them, so coverage is patchy.
6. **Guessing:** `imap.<d>` / `mail.<d>` / `<d>` on 993 then 143, and `smtp.<d>` / `mail.<d>` on 465 then 587. Probe with CAPABILITY or EHLO, require a valid certificate, and rank implicit TLS above STARTTLS.

- **Skip Microsoft Autodiscover.** Its v2 can't return IMAP/SMTP settings, and the older form needs credentials.
- **Trade-off (critical):** HTTPS-only fetching is right for iOS (ATS, spoofing), but Thunderbird's own comments say most hosting companies serve autoconfig over plain HTTP. We will miss those configs. The built-in table, MX matching and guessing make up for it.
- **Always show the discovered hostnames before sending a password.**
- Upcoming IETF work, not deployed yet: draft-ietf-mailmaint-autoconfig-06, PACC-04 (`/.well-known/user-agent-configuration.json`) and oauth-public-06.

---

## 4. Rendering & privacy

### 4.1 HTML in a locked-down WKWebView

SwiftUI's `WebView`/`WebPage` is **iOS 26 / macOS 26 only**, so Ink wraps `WKWebView` in `UIViewRepresentable` / `NSViewRepresentable`. `WKProcessPool` is deprecated (marked in the 26 SDK, retroactive to iOS 15) and does nothing, so don't design around it.

**Configuration:**
- **`defaultWebpagePreferences.allowsContentJavaScript = false`.** Also re-set it in `webView(_:decidePolicyFor:preferences:decisionHandler:)`. This stops inline `<script>`, external scripts, `javascript:` URLs and `on*` handlers. Our own `evaluateJavaScript`, `callAsyncJavaScript` and `WKUserScript` still run.
  - Put our scripts in a separate `WKContentWorld` (for example `.defaultClient`), and register the message handler **in that same world** with `add(_:contentWorld:name:)`. Otherwise `window.webkit.messageHandlers.<name>` is undefined there.
  - **Don't** use the deprecated `WKPreferences.javaScriptEnabled = false`. It doesn't stop user scripts, but it breaks event listeners and timers, including ours.
  - Side effect: with page JS off, `<noscript>` content renders, so the sanitiser removes it.
- **Sanitise in Swift before loading (critical).** The JS-off flag strips script only at parse time. HTML that our own script inserts later with `innerHTML` can still run handlers, so never sanitise in JS. Use SwiftSoup or our own pass to remove:
  - `script iframe frame object embed form input base link noscript` and `meta http-equiv=refresh`;
  - the email's own viewport meta;
  - all `on*` attributes, `javascript:` URLs and `ping` attributes;
  - `srcdoc`.

  Rewrite `cid:` to `ink-cid://<messageKey>/<percent-encoded content-id>`. Inject a viewport meta, `<meta name="referrer" content="no-referrer">`, and base CSS: `img{max-width:100%;height:auto} pre{white-space:pre-wrap}`, `overflow-wrap:break-word`, `-webkit-text-size-adjust:100%`.
- **`websiteDataStore = .nonPersistent()`**, shared across message views.
- **Content blocking with `WKContentRuleList`.** Compile once per launch with a **versioned identifier** (for example `ink.block.v3`) and **fail closed**: if compilation fails, don't render the HTML.
- **CSP.** Two routes are both viable:
  - **Route A** is what the *current* Proton iOS app, Delta Chat and nc-mac-mail do: sanitise, then `loadHTMLString(html, baseURL: nil)`, with a scheme handler only for `ink-cid:` images. Ink adds a `<meta http-equiv="Content-Security-Policy">` as the first element of `<head>`. Multiple policies intersect, so an email can't loosen ours.
  - **Route B** is legacy Proton: serve the document from an `ink-msg:` scheme handler, returning an **`HTTPURLResponse`** (a plain `URLResponse` carries no headers) with a real `Content-Security-Policy` header and `charset=utf-8`. WebKit's source applies that header, but Apple doesn't document it, so **test it** with a page that tries a remote load.
  - Note: a document loaded with `loadHTMLString` is *never* blocked by content rules; only its subresources are.

Suggested CSP while remote content is blocked:
```
default-src 'none'; img-src ink-cid: data:; media-src ink-cid: data:; style-src 'unsafe-inline'; font-src data:; script-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'
```
When the user loads images, add `https:` (and `http:`) to `img-src`, `style-src`, `font-src` and `media-src`.

**Content-rule-list facts (verified in WebKit source and tests, critical):**
- No `|` disjunction, no `\b`, no named backreferences, no `\d`/`\w`/`\s`, no lookarounds, and no `{n,m}` except `{0,1}`.
- `^` must be the first term and `$` the last.
- A numeric backreference `(a)\1` compiles silently as octal `\x01` and matches the wrong thing.
- **One invalid regex fails the whole list.** Write `^https?:` and `^wss?:` as two rules.
- `data:` URLs are never checked. **Custom schemes are checked**, so a `.*` block also blocks `ink-cid:` unless a *later* `ignore-previous-rules` rule **in the same list** exempts it.
- `ignore-following-rules` exists only in Safari 26-era WebKit, so use `ignore-previous-rules`.

Default (blocked) list:
```json
[
 {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
 {"trigger":{"url-filter":"^ink-msg:"},"action":{"type":"ignore-previous-rules"}},
 {"trigger":{"url-filter":"^ink-cid:"},"action":{"type":"ignore-previous-rules"}}
]
```
"Load images" list: tracker rules come back *after* the allow rule, so trackers stay blocked.
```json
[
 {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
 {"trigger":{"url-filter":"^https?://","resource-type":["image","style-sheet","font","media"]},"action":{"type":"ignore-previous-rules"}},
 {"trigger":{"url-filter":"^ink-msg:"},"action":{"type":"ignore-previous-rules"}},
 {"trigger":{"url-filter":"^ink-cid:"},"action":{"type":"ignore-previous-rules"}},
 {"trigger":{"url-filter":".*"},"action":{"type":"block-cookies"}},
 {"trigger":{"url-filter":"list-manage\\.com/track/open\\.php"},"action":{"type":"block"}}
]
```
To switch modes: `removeAllContentRuleLists()`, add the other list, reload. Offer "Load once" and "Always for this sender".

**Links and navigation:**
- In `decidePolicyFor`, allow only the initial document load.
- On `.linkActivated` in the main frame: send `mailto:` to Ink's composer, `http(s)` to Safari (`UIApplication.open` / `NSWorkspace.open`), and return `.cancel`.
- Cancel everything else, and never load `file:`.
- `target="_blank"` links arrive at `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)`. Open them externally and return `nil`.
- Optionally use `dataDetectorTypes` (iOS) to link phone numbers and addresses.

**Height, scrolling, fit-to-width:**
- A `.atDocumentEnd` user script runs a `ResizeObserver` on `documentElement` and listens for image `load` events in the capture phase. It posts `Math.ceil(max(body.getBoundingClientRect().height, documentElement.scrollHeight))` and `scrollWidth`.
- Debounce and clamp the value, apply it with `.frame(height:)`, and cache it by (message, width bucket, theme, remote-content state). Reading `scrollHeight` once at `didFinish` is unreliable.
- **iOS:** `scrollView.isScrollEnabled = false` and `bounces = false`.
- **macOS:** subclass `WKWebView` and forward mostly-vertical `scrollWheel(with:)` events to `nextResponder`.
- **Wide newsletters:** if `scrollWidth > innerWidth`, set `pageZoom = innerWidth/scrollWidth` (floor about 0.4) and measure again. Pinch-zoom lives in a full-screen reader.

**Memory and process crashes (critical):**
- Each `WKWebView` gets its own WebContent process. WebKit caps this at 400 per app and kills the least-recently-used process beyond that.
- An app **cannot raise** a WebContent process's memory limit.
- When the process is killed, the view goes blank. Implement `webViewWebContentProcessDidTerminate(_:)` and **reload the cached HTML and height**: immediately if the view is on screen, otherwise when it next appears. WebKit's own auto-reload doesn't restore `loadHTMLString` content.

**Thread view:**
- Collapsed messages are native rows showing the snippet.
- Only expanded messages get a web view, taken from a reused pool of 3–4. Pre-warm one at launch.
- Never render a whole thread as one huge page.
- Avoid CSS `filter` on the default path.
- Test very tall web views at 120 Hz on the owner's lowest-RAM device.

### 4.2 Dark mode

Classify each HTML email when sanitising it:
1. **It declares dark support** (`<meta name="color-scheme" content="light dark">`, CSS `color-scheme`, or a `prefers-color-scheme` query). Let WebKit follow the app appearance.
2. **"Simple" email** (no background colours or images, only black or grey text; typical human replies). Inject `:root{color-scheme:light dark}` with Ink's black background and white text, and rewrite near-black inline colours.
   - iOS: make the view transparent (`isOpaque = false`).
   - macOS: paint the body with the exact app background.
3. **Designed or branded email.** Render it as designed on a light "paper" card with rounded corners. Offer an opt-in **"Darken"** toggle: `filter: invert(100%) hue-rotate(180deg)` with images re-inverted, as FairEmail does.

Confidence is medium; the evidence for how other clients behave comes from secondary sources such as Litmus and Fastmail's blog.

### 4.3 Quoted text and signatures

**HTML quotes.** Use Proton's selector list and collapse the **last** match behind a "•••" control:
- `.protonmail_quote`;
- `.gmail_quote:not(.gmail_quote_container)` (Gmail's container also holds the user's own note);
- `div.gmail_extra`, `div.yahoo_quoted`, `blockquote.iosymail`, `.tutanota_quote`, `.zmail_extra`;
- `#divRplyFwdMsg`, `div[id="mail-editor-reference-message-container"]`, `hr[id=replySplit]`;
- `.moz-cite-prefix`, `blockquote[type="cite"]`, `[name="quote"]`, plus a few others.

For Outlook markers, collapse from the marker (and the `<hr>` before it) to the end of the parent element.

**Plain text:**
- **format=flowed (RFC 3676):**
  - a trailing space marks a soft break;
  - `DelSp=yes` means delete that space when joining lines;
  - the number of leading `>` gives the quote depth;
  - remove one stuffed space *after* the quote check;
  - `-- ` is never flowed.
- **Quote detection:** `>` nesting plus crisp-oss email-reply-parser's multilingual attribution regexes. Examples: `On … wrote:`, `Le … a écrit :`, `Am … schrieb …:`, `-----Original Message-----`, and Outlook `From:/Von:/De:` blocks. Attribution lines often wrap over two lines.
- **Signatures:** `^-- $` and mobile footers ("Sent from my iPhone", "Get Outlook for …", "Von meinem … gesendet").

**Display plain-text bodies in `UITextView` / `NSTextView`, not SwiftUI `Text` (critical).** With the iOS 26 SDK (Xcode 26.3), `Text.textSelection(.enabled)` only offers a whole-text menu on iPhone, *even on iOS 27 devices*. Range selection depends on building with the iOS 27 SDK.

**Never use `NSAttributedString` HTML import.** Apple says the synchronous initialisers must not run on a background thread, can time out, and now explicitly "discourages" them. The async `loadFromHTML` alternative loads network resources by default, which would fetch tracking pixels.

### 4.4 Remote images, trackers, links

- **Block remote content by default.** Show "N trackers blocked (Mailchimp…)" using MailTrackerBlocker's ~280 vendor patterns (BSD-3, already in content-blocker-compatible regex) plus a heuristic for 0/1-pixel images that exempts spacer images.
- **Be honest in the UI.** Apple Mail Privacy Protection relays images through two proxies, and HEY proxies them too. Ink has no server, so **"Load images" reveals your IP address and when you opened the message**.
- **Links:**
  - Long-press shows the real URL with the host emphasised.
  - Warn when link text looks like a domain that differs from the link's real domain.
  - Optionally strip click IDs such as `gclid`, `fbclid` and `msclkid`.
- **Avatars:** never fetch remote avatars (Gravatar, BIMI). That would leak data.

### 4.5 Unsubscribe (RFC 8058 / RFC 2369)

- Show an Unsubscribe button only when `List-Unsubscribe` is present.
- **One-click** requires all of the following:
  - an `https:` URI;
  - `List-Unsubscribe-Post: List-Unsubscribe=One-Click`;
  - a DKIM signature whose `h=` covers both headers;
  - **dkim=pass** for that `d=` in the topmost `Authentication-Results` added by the user's own provider. A client can't verify DKIM without DNS.
- **Always get explicit consent.** Then POST `List-Unsubscribe=One-Click` (preferably `multipart/form-data`; `application/x-www-form-urlencoded` is allowed) using an **ephemeral `URLSession` with no cookies and no redirect-following**.
- Fallbacks, in order: the left-most supported URI, then `mailto:` (pre-filled and sent from the subscribed address after confirmation), then opening the https link in the browser. Never `file:`.
- Open question: which `authserv-id` values to trust per provider (`mx.google.com`, `*.outlook.com`, iCloud).

### 4.6 Snippets

- Use IMAP PREVIEW when available. Otherwise:
  1. prefer the text/plain part;
  2. strip `head`, `style`, `script`, `title`, `noscript`, comments and MSO conditionals;
  3. **keep** the hidden preheader near the top;
  4. delete filler characters U+034F, U+200B–U+200D, U+2060, U+FEFF and U+00AD, and map U+00A0, U+2007 and U+202F to spaces;
  5. remove quotes and signatures;
  6. collapse whitespace and cut at about 200 characters on a grapheme boundary (RFC 8970: SHOULD ≤ 200, MUST ≤ 256).

### 4.7 MIME parsing and composing (engineers)

**Parse leniently and compose strictly:**

- **Header folding.** Unfold CRLF followed by whitespace. Accept bare LF and lines longer than 998.
- **RFC 2047 encoded-words:**
  - The ≤ 75-character limit binds senders; don't reject longer words.
  - Ignore whitespace *only between adjacent encoded-words*.
  - For runs of adjacent words that share a charset and an encoding, decode each word to bytes, **concatenate the bytes**, then convert to text. Decode each B word separately.
  - In Q encoding, `_` = 0x20.
  - Strip RFC 2231 `*lang` suffixes.
  - Decode even inside quotes and parameters; real senders break the rules.
- **RFC 2231 parameters.** Reassemble `name*0`, `name*1`, … **by index**. Prefer `filename*`. Also decode RFC 2047 inside quoted `filename=` (old Outlook). Sanitise filenames against path traversal and U+202E.
- **QP and base64.** For QP, treat a trailing `=` as a soft break and keep malformed `=` literally. For base64, use `.ignoreUnknownCharacters`.
- **Content types:**
  - An unknown Content-Transfer-Encoding becomes an attachment.
  - Unknown multipart subtypes are treated as mixed.
  - A missing close boundary means the part runs to EOF.
- **multipart/alternative.** Pick the **last supported** part, preferring HTML. **Treat `text/x-amp-html` and `text/watch-html` as unsupported.**
- **multipart/related.** The root is the first part or the one named by `start`. Resolve `cid:` and Content-Location, and hide referenced images from the attachment list.
- **Body vs attachments.** Port JMAP's `parseStructure` algorithm from RFC 8621 as-is.
- **Nested messages and special types.** Render `message/rfc822` as a nested card. Show the first part of `multipart/signed`, and a placeholder for encrypted parts. List TNEF (`winmail.dat`) as an attachment for now.
- **Charsets:**
  1. Normalise the label.
  2. Apply WHATWG supersets: ascii/latin1 → windows-1252; gb2312/gbk → GB18030 (`kCFStringEncodingGB_18030_2000`); shift_jis → CP932; ks_c_5601-1987 → CP949; iso-8859-9 → windows-1254.
  3. Call `CFStringConvertIANACharSetNameToEncoding`.
  4. Fall back to strict UTF-8, then windows-1252, then ISO-8859-1.
  5. On Linux, use glibc `iconv` behind a `CharsetDecoder` protocol.

  Don't rely on `String.Encoding(ianaName:)`: it's FoundationPreview 6.3 and knows only 19 encodings.
- **Composing:**
  - Date: `en_US_POSIX` with `"EEE, dd MMM yyyy HH:mm:ss Z"`.
  - Message-ID: `<UUID@sender-domain>`.
  - Replies: In-Reply-To = the parent's Message-ID; References = the parent's References + the parent's Message-ID.
  - Subject: exactly one `Re: ` or `Fwd: ` prefix.
  - Structure: `multipart/mixed[ multipart/alternative(text/plain, text/html), attachments(base64) ]`, with a boundary containing `=_`.
  - Non-ASCII subjects and names use encoded-words, never inside quotes or addresses.
  - Attachment names: `filename*=UTF-8''…` plus a `name="=?UTF-8?B?…?="` fallback.
- **Reply-all:**
  1. If I sent the original, reuse its To and Cc.
  2. Otherwise To = Reply-To, or From if there is no Reply-To.
  3. Cc = original To ∪ Cc, minus all my identities and anything already in To, deduplicated case-insensitively.
  4. Never include the original Bcc.
  5. Offer "Reply to list" when `List-Post` is present.

---

## 5. UX principles we're adopting

### 5.1 Principles

- **Archive ("Done") is the primary action.** It gets the easiest gesture and the `e` key.
- **Every committing action can be undone.** Show a ~5 s Undo toast, with ⌘Z / `z` on the Mac.
- **Speed is a feature.** Interactions should finish in under 100 ms, as in Superhuman's rule. Never parse MIME or HTML in a view body.
- **Monochrome and typographic.** Colour appears mainly *during* a gesture, plus one accent for unread, Send and links.
- **Calm.** No avatars by default, a muted Inbox Zero state, and celebration only when the real inbox is empty, never an empty filter.
- **On-device and private.** That's a real advantage over Spark (server-side credentials) and HEY (no IMAP).

### 5.2 Swipe map and thresholds

"Trailing" means the finger moves right to left; "leading" means left to right.

| Gesture | Default action | Colour shown during the swipe | Threshold |
|---|---|---|---|
| Trailing, short | **Archive** | accent | ≥ max(72 pt, 22% of row width) |
| Trailing, long | **Trash** | `#FF3B30` | ≥ 60% of width |
| Leading, short | **Read / Unread** | fg3 (neutral) | ≥ max(72 pt, 22%) |
| Leading, long | **Snooze** (opens the preset sheet; the row springs back) | `#FFB800` | ≥ 60% |
| Fling | commits the short action | — | velocity > 900 pt/s and \|translation\| > 40 pt |

All four actions are configurable. Physics:
- The row follows the finger directly with no animation.
- Past the end it rubber-bands, using `(1 − 1/((x·0.55/d)+1))·d`.
- On release: `withAnimation(.spring(duration: 0.35, bounce: 0.12))`. SwiftUI carries the gesture velocity into the spring.
- Haptics: `prepare()` when the gesture begins, a light impact at the short threshold, a medium impact at the long threshold, and a selection tick when crossing back. Or use `.sensoryFeedback(.impact(weight: .light), trigger:)`.
- The icon scales and fades in with the offset, with `.symbolEffect(.bounce, value: tier)` each time a threshold is crossed.
- On commit, the row slides off screen, is removed inside `withAnimation(.snappy)`, and an Undo toast appears.

**Implementation (critical):**
- **iPhone:** build a custom swipe row from a `UIPanGestureRecognizer` wrapped in `UIGestureRecognizerRepresentable` (iOS 18+).
  - Its delegate's `gestureRecognizerShouldBegin` returns `true` only when `|vx| > 1.2·|vy|`. Returning `false` fails the recognizer, so vertical List scrolling keeps working.
  - Native `.swipeActions` can't do this: only the *first* action per edge fires on a full swipe, there's a single threshold, and the visuals are fixed (UIKit has the same limits).
  - **Don't use a SwiftUI `DragGesture`.** Since iOS 18, a `DragGesture` on rows inside a scroll view blocks vertical scrolling (FB14205678, still open). The iOS 26 SDK also changed `simultaneousGesture` and priority semantics.
- **iOS 26's full-width "swipe back"** (`UINavigationController.interactiveContentPopGestureRecognizer`) pops a *pushed* screen on any leading-to-trailing pan. Native swipe actions block it automatically; custom gestures don't.
  - On iPhone, make the **Inbox the root of a `NavigationStack`**, with account and mailbox switching through a menu or sheet. A `NavigationSplitView` collapses on iPhone so that the sidebar is the root and the Inbox is *pushed*.
  - Belt and braces: behind `if #available(iOS 26, *)`, have the row pan's delegate return `true` from `gestureRecognizer(_:shouldBeRequiredToFailBy:)` for that recognizer. SwiftUI gestures can also be named with `.gesture(_:name:isEnabled:)` to set up failure relationships.
- **Mac:**
  - Use native `List` `.swipeActions` (macOS 12+), which respond to trackpad and Magic Mouse swipes.
  - Users with a plain mouse can't swipe, so **every action also has a context menu, hover buttons (`onHover`; `.hoverEffect` doesn't exist on macOS) and a keyboard shortcut**.
  - `NSGestureRecognizerRepresentable` is macOS 26+ only, and `NSPanGestureRecognizer` tracks mouse drags, not two-finger swipes. So custom multi-threshold Mac swipes would need `scrollWheel(with:)` handling. Defer that.
- **Later, needs Xcode 27:** iOS 27's `swipeActionsContainer()` brings native swipes to non-List containers. It isn't usable with Xcode 26.3.

### 5.3 Triage features

- **Snooze presets:**
  - Later Today (+3 h), This Evening (18:00), Tomorrow (08:00), This Weekend (Sat 09:00), Next Week (Mon 08:00), Someday, Pick Date;
  - plus a typed natural-language field;
  - presets that have already passed for the day are hidden.
- **Remind me** defaults to "if no reply", as Superhuman does: the thread returns at the set time unless someone has replied. The other option is "regardless".
- **Undo send** is a local delay before SMTP submission. Default 10 s; options Off, 5, 10, 20, 30.
- **Honest limitation:** snooze, send-later and reminders fire only while Ink is running on a device (§3.10). Cross-device sync of this state without a server is an open question (§7).
- **Compose:**
  - Recipient tokens autocomplete from a local index of addresses seen in headers.
  - Dismissing compose saves a draft rather than blocking.
  - `writingToolsBehavior` (iOS 18 / macOS 15) gives free Apple Intelligence proofreading on supported devices.
- **Not in v1, open question:** an "Important vs Other" split, built from header heuristics or Gmail's `category:primary` via X-GM-RAW (unverified).

### 5.4 Keyboard shortcuts (Mac)

| Action | Single key (focused list) | Menu / ⌘ shortcut |
|---|---|---|
| Next / previous | `j` / `k`, ↓ / ↑ | — |
| Open / back | Return / Esc (`onExitCommand`) | — |
| Archive | `e` | ⌃⌘A (Apple Mail's shortcut is unconfirmed; check the Mail menu) |
| Delete | `#` | ⌘⌫ |
| Reply / reply all / forward | `r` / `a` / `f` | ⌘R / ⇧⌘R / ⇧⌘F |
| Compose / search | `c` / `/` | ⌘N / ⌥⌘F |
| Star / toggle read | `s` / `u` | ⇧⌘U |
| Snooze / undo | `h` / `z` | ⌘Z |
| Command palette | — | ⌘K |
| Send | — | ⌘Return and ⇧⌘D |

Implementation notes:
- `.onKeyPress(characters:)` fires only on the **focused** view, so pair it with `.focusable()`, `@FocusState` and `.defaultFocus`.
- macOS swallows Shift+Tab before SwiftUI sees it.
- Use `onExitCommand`, `onDeleteCommand` and `onMoveCommand` (macOS-only).
- Mirror every action in a `CommandMenu("Message")` that acts on the selection exposed through `focusedSceneValue`.
- Use `searchFocused(_:)` so `/` focuses search, and `contextMenu(forSelectionType:menu:primaryAction:)` so double-click opens a message.
- Don't repurpose standard system shortcuts (HIG).

### 5.5 Layout, design tokens and typography

**Layout:**
- **Mac:** `NavigationSplitView` with a sidebar of about 200 pt, a message list with `min: 300, ideal: 360`, and the reader. Add a `Settings` scene.
- **iPhone:** a `NavigationStack` rooted at the Inbox (§5.2).

| Token | Light | Dark | Use |
|---|---|---|---|
| bg | `#FFFFFF` | `#000000` (true black for OLED, same as the dark system background) | list and reader |
| surface | `#F5F5F5` | `#141414` (sheets use the system elevated `#1C1C1E`) | compose card, toasts |
| fg / fg2 / fg3 | `#000` at 100 / 60 / 32% | `#FFF` at 100 / 60 / 32% | sender / preview / metadata |
| hairline | fg at 12%, 1/displayScale | fg at 14% | separators (or hidden) |
| fill-press | fg at 6% | fg at 10% | pressed, hovered, selected rows |
| accent | `#1F4FFF` (about 5.8:1 on white) | `#5C84FF` (about 6.2:1 on black) | unread dot, Send, links, focus ring, archive swipe |
| swipe colours | archive = accent, trash `#FF3B30`, snooze `#FFB800`, read = fg3 | same | only visible during a gesture |

- **Accent colour:** keep it as a **named asset colour**, not `Color.accentColor`, because on macOS the user's system accent overrides the app accent.
- **Contrast:** at least 4.5:1, aiming for 7:1 for small custom-coloured text.
- **Appearance:** follow the system light/dark setting; the HIG says not to add an app-only appearance switch.
- **Spacing:** a 4 pt grid (4, 8, 12, 16, 20, 24, 32, 48). Row padding is 12/16 pt on iPhone and 10/14 pt on Mac.
- **Radii:** 10 for cards; capsule buttons.
- **Typography:**
  - SF Pro text styles for the interface. Don't add manual tracking; the system font adjusts tracking automatically.
  - iOS: Body 17/22, Headline 17/22 semibold, Subheadline 15/20, Footnote 13/18; minimum 11 pt.
  - macOS: Body 13/16, Headline 13/16 bold; minimum 10 pt; no Dynamic Type.
  - Avoid Ultralight, Thin and Light weights.
  - **New York** (`.fontDesign(.serif)`) for plain-text bodies and the reader's subject: 17 pt on iPhone, 15–16 pt on Mac, with about 1.5× line height (`.lineSpacing(4)`) and a measure of 60–75 characters (about 680 pt max width on Mac).
- **Row:**
  - Sender: `.body`, semibold when unread.
  - Time: `.footnote.monospacedDigit()` in fg2.
  - Subject: `.subheadline` in fg.
  - Preview: `.subheadline` in fg2, `lineLimit(2)`.
  - Unread: an 8 pt accent dot plus the weight change.
- **Icons:** SF Symbols at the weight of the neighbouring text, with `.hierarchical` rendering: `archivebox`, `trash`, `clock`, `envelope.badge`, `arrowshape.turn.up.left`, `square.and.pencil`, `paperplane.fill`, `magnifyingglass`.

### 5.6 Motion

| Use | Spec |
|---|---|
| Press | `.snappy(duration: 0.2)` |
| Swipe release | `.spring(duration: 0.35, bounce: 0.12)` |
| Row removal | `.snappy(duration: 0.3)` |
| Toast | `.smooth(duration: 0.35)` |
| Read/unread icon | `.contentTransition(.symbolEffect(.replace))` |
| Counts | `.contentTransition(.numericText())` |
| Inbox Zero | `checkmark.circle` with `.drawOn` on 26+ (`.bounce` on 17+), plus a success haptic |

- Apple's guidance: start with bounce 0 and stay below about 0.4. For reference, `Animation.default` is a spring with response 0.55 and damping 1.0.
- When `accessibilityReduceMotion` is on, cross-fade instead.
- Don't animate high-frequency interactions, and keep every animation interruptible.
- **Zoom transition:**
  - `.matchedTransitionSource(id:in:)` plus `.navigationTransition(.zoom(sourceID:in:))`, iOS 18+.
  - Use it only for Compose button → compose sheet and attachment previews; opening a message is a normal push.
  - Zoom **doesn't exist on macOS**, so guard *only* the `.navigationTransition(.zoom…)` call with `#if os(iOS)`. Note that `os(iOS)` is also true for Catalyst.
  - A toolbar-item source (`ToolbarContent.matchedTransitionSource`) is iOS 26+ and **marked unavailable on macOS**, so it needs both `#if os(iOS)` and `if #available(iOS 26, *)`. On iOS 18, use a floating in-content Compose button.

### 5.7 120 Hz and performance (critical)

Add this to the **iOS** Info.plist:
```xml
<key>CADisableMinimumFrameDurationOnPhone</key><true/>
```
- Apple's ProMotion doc says that **without it, Core Animation won't use refresh rates above 60 Hz on iPhone**.
  - It's documented for `CADisplayLink` and `CAAnimation` hints. Whether SwiftUI's own animations get past 60 Hz without it is undocumented, but developer measurements suggest the key is needed.
  - iPad Pro and Macs don't need it.
- **Devices:** iPhone 13 Pro/Pro Max and later Pro models, iPhone 17 and later, and iPhone Air (10–120 Hz). On the Mac, the 14″ and 16″ MacBook Pro. A MacBook Air runs at 60 Hz.
- **Verifying:** the Simulator always renders at 60 Hz. Verify on a real device with Instruments, with Low Power Mode off and Settings › Accessibility › Motion › Limit Frame Rate off.
- `CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)` is only for high-impact animations. Pause animations that never stop.
- **Frame budget at 120 Hz: 8.33 ms.**

**List performance rules:**
- Use `List` with `.listStyle(.plain)`, `.listRowInsets(EdgeInsets())`, `.listRowSeparator(.hidden)` and `.listRowBackground`. List is UICollectionView-backed with cell reuse; one 2025 test measured 4.6 hangs vs 78 for `LazyVStack`. On the Mac it also gives selection, keyboard navigation and swipes for free.
- Stable, cheap IDs: account + mailbox + UID.
- Each element must produce a **constant number of views**. No `AnyView`, and no conditionals that change the view count.
- Precompute a `Sendable`, `Equatable` row view-model (display name, subject, trimmed snippet, time string) off the main thread, and use `.equatable()` where it helps.
- Use per-item `@Observable` models (held in an `@ObservationIgnored` dictionary), so marking one message read re-renders only its row.
- No `GeometryReader`, `shadow`, `blur` or materials inside rows. Don't create formatters in `body`. Update relative times from one minute-tick clock. Never put fast-changing values in the environment.
- Profile with the SwiftUI instrument: Long View Body Updates, Long Representable Updates, and the Cause & Effect graph.
- The iOS/macOS 26 runtimes give List improvements for free.

### 5.8 Liquid Glass

- Built with Xcode 26.3, standard bars, toolbars, sheets, sidebars and controls **become Liquid Glass automatically on iOS/macOS 26+**. On iOS 18 and macOS 15 the app keeps the old look.
- **Remove custom bar and sheet backgrounds** (`presentationBackground`) so the system glass shows through.
- Use explicit glass sparingly, and **never in the content layer**: one floating Compose button with `.glassProminent`, tinted with the accent, and plain icon buttons with `.sharedBackgroundVisibility(.hidden)` grouped by `ToolbarSpacer(.fixed)`.
- Every glass API is iOS/macOS 26 only: `glassEffect`, `GlassEffectContainer`, `.glass`/`.glassProminent`, `ToolbarSpacer`, `sharedBackgroundVisibility`, `scrollEdgeEffectStyle`. Guard them with `if #available(iOS 26, macOS 26, *)` and a material fallback:
```swift
@ViewBuilder func inkGlass(in s: some Shape) -> some View {
  if #available(iOS 26, macOS 26, *) { glassEffect(.regular, in: s) }
  else { background(.ultraThinMaterial, in: s) }
}
```
- Test with Clear and Tinted glass (iOS 26.1) and with Reduce Transparency.
- **Opt-out:** `UIDesignRequiresCompatibility = YES` is honoured as long as we link against the 26 SDK, even on iOS 27 devices. It is ignored once we build with the 27 SDK.

### 5.9 Things to avoid

- SwiftUI `DragGesture` swipe rows.
- Liquid Glass in the content layer, or several tinted controls.
- An app-only light/dark setting.
- Remote avatars.
- `NSAttributedString` HTML import.
- SwiftUI `Text` for selectable bodies.
- Mac Catalyst.
- Per-row timers or formatters.
- Celebrating an empty filter as Inbox Zero.
- Blocking dialogs on compose dismissal.
- Inventing shortcuts that clash with system ones.

---

## 6. Getting it on your devices

### 6.1 Which Xcode on your Mac

| Your Mac runs | Use | Notes |
|---|---|---|
| macOS 27, or Tahoe 26.6+ | **Xcode 27.1** (recommended) | Required if your Mac is on macOS 27, because Xcode 26.x is only supported up to Tahoe 26.x. Adds Wi-Fi pairing for iOS 27 phones (Device Hub › + › "Pair Nearby Device…") |
| Tahoe 26.2 – 26.x | Xcode 26.5 / 26.6 | Deploys fine to iOS 27 phones |
| Sequoia 15.6+ | Xcode 26.3 | Deploys to iOS 27 phones; only Address Sanitizer is known to fail there |

Background:
- iOS 27 and macOS 27 shipped on 14 Sep 2026; Xcode 27.1 shipped on 15 Oct; Xcode 27.2 RC came out on 19 Oct.
- Xcode 27 replaced Simulator.app and the Devices window with **Device Hub** (`open -a DeviceHub`). `simctl` and `devicectl` still work.

### 6.2 Free Apple ID: install from Xcode (the default path)

**One-time setup:**
1. Install Xcode (see above). Go to Xcode › Settings › Apple Accounts and add your Apple ID; it shows as "(Personal Team)".
2. In the Ink target's **Signing & Capabilities**, turn on "Automatically manage signing" and pick your Personal Team. Use a **globally unique bundle ID**, for example `com.<yourname>.ink`.
3. Pair the iPhone: either a cable plus "Trust This Computer", or on iOS 27 with Xcode 27, wirelessly through Device Hub.
4. On the iPhone, go to **Settings › Privacy & Security › Developer Mode**. The switch only appears once pairing has started. Turn it on, tap **Restart**, then **Turn On** and enter your passcode.
5. Run Ink from Xcode. The first launch shows "Untrusted Developer". Go to **Settings › General › VPN & Device Management › Developer App › Apple Development: <your Apple ID> › Trust**.

**Every week**, before the 7 days are up, run one command on your Mac. Reinstalling over the existing app keeps its data and keychain items.
```bash
xcodebuild -scheme Ink-iOS -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM=<personalTeamID> build
xcrun devicectl device install app --device <udid-or-name> build/Build/Products/Release-iphoneos/Ink.app
xcrun devicectl device process launch --device <udid-or-name> com.<yourname>.ink
```

**Free-team limits** (Apple's membership page, verified Oct 2026):
- up to **10 App IDs per rolling 7 days**;
- **3 devices**, which expire after 7 days;
- **3 apps per device**;
- provisioning profiles **expire 7 days** after they're issued.

App extensions each use an App ID, so **Ink ships with no extensions** on this path.

**Capabilities available on the free team:**
- iOS: App Groups, Background Modes, Data Protection, Keychain Sharing, Maps, HealthKit, HomeKit, and a few others.
- macOS: App Groups, App Sandbox, Hardened Runtime, Keychain Sharing, Maps.
- **Not available:**
  - Push Notifications;
  - all iCloud (CloudKit, Documents, key-value);
  - **Associated Domains**, which is why OAuth uses custom-scheme redirects;
  - Sign in with Apple;
  - Time Sensitive and Communication notifications;
  - Network Extensions;
  - AutoFill credential provider;
  - App Attest;
  - In-App Purchase;
  - WeatherKit.

**CI can't do this step.** Free accounts get no App Store Connect API key, so only Xcode signed in on *your* Mac can sign for your phone.

### 6.3 Paid account ($99/yr): TestFlight with automated CI upload

**What you get:**
- **Internal testing:** up to 100 App Store Connect users, no review, builds last **90 days**, so no weekly reinstall.
- **External testing:** up to 10,000 testers; the first build goes through Beta App Review.
- Notarized Mac DMGs, and optionally Mac TestFlight.
- Shared keychain groups, which are what would make cross-device credential sync possible.

**One-time steps (owner):**
1. Join the Apple Developer Program.
2. In App Store Connect, **create the app record by hand** (Apps › + › New App). The API can't create it: `POST /v1/apps` returns 403. One record and bundle ID can cover both iOS and macOS.
3. Go to Users and Access › Integrations › App Store Connect API › **Team Keys** and create a key with the **Admin** role.
   - Individual keys can't use provisioning endpoints or notarytool.
   - Cloud-managed distribution certificates need Admin or Account Holder.
   - Only the Account Holder can request API access in the first place.
4. Add the GitHub secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` and `TEAM_ID`.

**Workflow (no fastlane).** Run on `macos-15` and select Xcode 26.3 explicitly, because the runner defaults to 16.4:
```bash
export DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer
mkdir -p ~/.appstoreconnect/private_keys
printf '%s' "$ASC_KEY_P8" > ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
xcodebuild archive -project Ink.xcodeproj -scheme Ink-iOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$RUNNER_TEMP/Ink.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" "${AUTH[@]}"
xcodebuild -exportArchive -archivePath "$RUNNER_TEMP/Ink.xcarchive" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$RUNNER_TEMP/out" "${AUTH[@]}"
```
`ExportOptions.plist`:
```xml
<dict>
  <key>method</key><string>app-store-connect</string>   <!-- replaces deprecated "app-store" -->
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>YOURTEAMID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <!-- optional: <key>testFlightInternalTestingOnly</key><true/> (build can never go external/App Store) -->
</dict>
```
- Every upload needs a unique, increasing `CFBundleVersion`; the workflow uses `GITHUB_RUN_NUMBER`.
- The API-key flags date from Xcode 13, and `-exportArchive` uploads date from Xcode 15. No changes through Xcode 27.
- **Pitfall: certificate churn on fresh runners.** Automatic signing can mint a new Apple Development certificate on every run and then fail ("private key is not installed", or the certificate limit). Two fixes:
  - (a) Archive with `CODE_SIGNING_ALLOWED=NO` and let `-exportArchive` cloud-sign. This needs one real run to confirm.
  - (b) Import a persistent `.p12` and profile into a temporary keychain, following GitHub's recipe: `security create-keychain`, `security import … -A -t cert -f pkcs12`, `security set-key-partition-list -S apple-tool:,apple:`, `security list-keychains`. Profiles go in `~/Library/Developer/Xcode/UserData/Provisioning Profiles`.
- Alternatives: upload separately with `xcrun altool --upload-package Ink.ipa --type ios --apiKey … --apiIssuer …`. A Bitrise note says Xcode 26's altool may not return failing exit codes, so check. Or use fastlane's `app_store_connect_api_key` → `build_app` → `upload_to_testflight`, with `match` for certificates.

**Info.plist and project hygiene for uploads:**
- `ITSAppUsesNonExemptEncryption` = `NO`. We only use OS TLS. Re-evaluate if we ever add PGP or S/MIME.
- `PrivacyInfo.xcprivacy` (enforced since 1 May 2024): `NSPrivacyTracking = false`, no collected data types, and required-reason codes as they apply:
  - UserDefaults: `CA92.1` (`1C8F.1` with an App Group);
  - file timestamps: `C617.1` / `DDA9.1`;
  - boot time: `35F9.1`;
  - disk space: `E174.1`.
- Icons: iOS takes a single 1024×1024 image. macOS needs every size (16–512 at @1x and @2x) or an Icon Composer `.icon`. Also set `CFBundleIconName` and a `UILaunchScreen` dictionary.
- **Mac TestFlight:**
  - The app must be **sandboxed** (`com.apple.security.app-sandbox`), plus `com.apple.security.network.client` and `com.apple.security.files.user-selected.read-write` for attachments.
  - It must **embed a provisioning profile**; otherwise upload fails with ITMS-90889.
  - It must not carry the `com.apple.quarantine` attribute (rule since 18 Feb 2025): run `xattr -dr com.apple.quarantine Ink.app`.
  - Make the Mac target sandbox-ready now, even for DMG builds. Sandboxing is allowed on ad-hoc builds.

**Deadline (critical).** Uploads have required Xcode 26+ and the 26 SDKs since 28 Apr 2026. **From April 2027**, announced 9 Sep 2026 (exact day TBA), iOS uploads must be built with the **iOS 27 SDK** and target iOS 15+.
- Xcode 27 needs macOS Tahoe 26.6+, so it can't run on `macos-15`.
- Move the TestFlight job to the `xcode-27` runner label (preview) or a future macOS 27 image before then.
- Building with the 27 SDK also forces Liquid Glass, because the opt-out is ignored.

### 6.4 Sideloading the IPA (free Apple ID, no Xcode)

CI can produce an **unsigned** IPA:
```bash
xcodebuild archive -scheme Ink-iOS -destination 'generic/platform=iOS' -archivePath Ink.xcarchive CODE_SIGNING_ALLOWED=NO
mkdir Payload && cp -R Ink.xcarchive/Products/Applications/Ink.app Payload/ && zip -qry Ink.ipa Payload
```
It can't be installed until it's re-signed. Tools that re-sign with your Apple ID:
- **SideStore 0.7.0-alpha** (Sep 2026; don't use 0.6.4). Needs a one-time iloader pairing plus LocalDevVPN. iOS 27 isn't mentioned in its release notes.
- **AltStore Classic 2.3** (30 Sep 2026; iOS 17.4+; adds "Remote AltServer").
- **Sideloadly.** Status unclear; reportedly an Intel-only Mac build (low confidence).

All the free-ID limits still apply (7 days, 3 apps, 10 App IDs per week), and the store app itself uses an app slot. Developer Mode is still required. **Re-signing under a different Apple ID changes the Team ID and loses keychain items.** EU alternative marketplaces need a paid developer account, so they don't help.

**If you have a Mac, plain Xcode or the §6.2 script is simpler and more reliable.**

### 6.5 Mac: DMG and Gatekeeper

**Build (CI):**
```bash
# ad-hoc sign (CODE_SIGN_IDENTITY=- in the build, or after the fact):
codesign --force --deep -s - Ink.app
mkdir -p dmg && cp -R Ink.app dmg/ && ln -s /Applications dmg/Applications
hdiutil create -volname Ink -srcfolder dmg -ov -format UDZO Ink.dmg   # ULFO/ULMO are smaller
```
Apple-silicon code must be signed. An ad-hoc signature is enough to run the app, but not enough to pass Gatekeeper.

**Install, as the owner:**
1. Open the DMG and drag **Ink** to **Applications**.
2. Open Ink. macOS will refuse; click **Done**. Since macOS Sequoia, Control-click › Open **no longer** overrides this.
3. Go to **System Settings › Privacy & Security** and scroll to Security. Click **Open Anyway**; it's available for about an hour after the blocked launch. Enter your login password and click **Open**. macOS remembers the exception.
   - Shortcut: `xattr -dr com.apple.quarantine /Applications/Ink.app`.
   - Downloading with `curl -L -o Ink.dmg <url>` doesn't set the quarantine attribute at all.
4. After updates, expect one "Ink wants to use your confidential information" keychain prompt. Click **Always Allow** (see §3.9).

**With a paid account,** notarize instead. You need a Developer ID Application certificate, hardened runtime, a secure timestamp and no `get-task-allow`:
```bash
xcrun notarytool submit Ink.dmg --key AuthKey.p8 --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple Ink.dmg
```

**Use a native macOS target, not Catalyst.** You get proper menus, the Settings scene, keyboard handling and `swipeActions`. Catalyst also forces the data-protection keychain and has Xcode 27.1-era regressions.

### 6.6 CI notes

- **Runners (Oct 2026):**
  - `macos-15` (arm64, macOS 15.7.9): Xcode 26.3 / 26.2 / 26.1.1 / 26.0.1 and 16.x, **default 16.4**. iOS 18.5, 18.6 and 26.x simulator runtimes; iPhone 17 Pro only on 26.x. It's the only image with iOS 18 runtimes preinstalled.
  - `macos-26` = `macos-latest` (macOS 26.6.2): default Xcode 26.6.
  - `xcode-27` (preview, macOS 27.0.1): Xcode 27.0 / 27.1 RC / 27.2 beta, only the iOS 27.0 runtime, and **no "iPhone 17 Pro"** device. There's an open keychain-unlock issue (#14837).
  - `macos-14` loses support on 2 Nov 2026. No deprecation date has been announced for `macos-15`.
- **Swift version.** Apple's tables say Xcode 26.3 bundles Swift 6.2.3; swift.org's release metadata says 6.2.4. Run `swift --version` on the runner. Either way the language mode is the same.
- **Screenshots:**
  - Pick simulator devices dynamically from `xcrun simctl list devices available -j`.
  - Use `simctl status_bar … override --time 9:41`, `simctl ui <dev> appearance dark`, and `simctl io <dev> screenshot`.
  - On macOS, the runner image pre-grants screen capture to `/bin/bash`, so `screencapture -x -o -l<windowID>` works. Get the window ID from `CGWindowListCopyWindowInfo`.
  - Don't build simulator apps with `CODE_SIGNING_ALLOWED=NO` if they use the keychain.
- **Project generation:** pin XcodeGen 2.46.0 (released format `xcode16_0`, objectVersion 77) with `supportedDestinations: [iOS, macOS]`. It runs on Linux. The `xcode26_3` / `xcode27_0` formats and an Xcode 27.2 conversion fix exist only on master.
- **Private repos:** macOS runner minutes are billed. Check your plan.

---

## 7. Risks, limitations, open questions

### 7.1 Limitations we're accepting by design

- **No real push.** Background alerts are best effort on iPhone and live only while Ink runs. Snooze, send-later and reminders fire only while Ink runs.
- **Free path:** a weekly iPhone reinstall, no iCloud, no shared keychain. Accounts are added on each device, and snooze/reminder state doesn't sync.
- **Ad-hoc Mac:** a Gatekeeper approval on first launch, and likely keychain prompts after updates.
- **No image proxy.** Loading images reveals your IP address and open time.
- **Providers we can't fully support:**
  - Proton on iPhone;
  - Yahoo if app passwords really are gone;
  - any Gmail account under Advanced Protection;
  - Outlook.com without an Azure tenant;
  - Fastmail Basic plans;
  - new Zoho free plans.

### 7.2 Risks

- **Providers keep tightening access.**
  - Google officially discourages app passwords.
  - Microsoft ended Basic auth for Outlook.com and is phasing it out for M365 SMTP by end of 2026.
  - Yahoo's position changed in 2026.
  - Watch FairEmail's FAQ and Thunderbird's ISPDB as early-warning signals.
- **Google OAuth churn.** The "Publish" rules changed in Sep 2026, unused clients are auto-deleted after 6 months, and token revocation follows password changes.
- **Gmail limits:** 15 connections and 2.5 GB/day. A bug in a sync loop could lock IMAP for up to 24 h.
- **Our own parser** will meet server quirks that MailKit already handles. Mitigations: tolerant parsing, real-world fixtures, and keeping NIOIMAPCore swappable.
- **STARTTLS** is security-sensitive (injection, downgrade). Follow §3.2 exactly.
- **Toolchain:** Xcode 26.3 on `macos-15` is a dead end. TestFlight needs Xcode 27 by April 2027, and `macos-15` will eventually be deprecated.
- **Gestures on iOS 26/27:** content backswipe, the iOS 26 SDK's changed gesture semantics, and the unfixed DragGesture/ScrollView bug. These can only be validated on hardware.

### 7.3 Test early, on real devices and accounts

1. Implicit TLS with `startSecureConnection()` before `resume()` against `imap.gmail.com:993` and `smtp.gmail.com:465`. STARTTLS against `smtp.mail.me.com:587` and `smtp-mail.outlook.com:587`. Whether a read left pending across STARTTLS hangs. TLS 1.3 negotiation.
2. `ASWebAuthenticationSession` with a custom scheme that is **not** in `CFBundleURLTypes` (needed for a runtime-pasted client ID), on iOS 18–27 and macOS 15–27.
3. That a Gmail OAuth token from an "In production" unverified app survives more than 7 days.
4. Outlook.com: `/consumers` vs `/common`; SMTP XOAUTH2 `535 5.7.3` on the owner's account; the IMAP toggle reverting on new accounts.
5. Yahoo: can you generate an app password, and does it authenticate IMAP? Does post-login CAPABILITY include IDLE?
6. iCloud: LIST attributes, whether a sent copy appears in "Sent Messages", and whether port 465 works (undocumented).
7. Whether a CSP header on a `WKURLSchemeHandler` `HTTPURLResponse` is enforced (Route B). WebKit behaviour for very tall non-scrolling web views at 120 Hz. Whether WebKit DNS-prefetches link hosts while loads are blocked.
8. The swipe recognizer against List's own pan, iOS 26's content-pop recognizer, and the iOS 26 SDK gesture changes. `swipeActions` with a long trackpad swipe and with a plain mouse on the owner's MacBook.
9. Whether Mac keychain prompts stop when every build is signed with one stable identity (self-signed vs exported personal-team certificate).
10. Proton Bridge certificate pinning through the stream task's trust challenge (connect to `127.0.0.1`).
11. `CODE_SIGNING_ALLOWED=NO` archive plus cloud-signed export on Xcode 26.3 (paid path only).
12. Whether SideStore 0.7.0-alpha works on iOS 27.

### 7.4 Questions for the owner

- **Which iPhone and Mac, and which OS versions?** This decides the Xcode version (§6.1) and whether 120 Hz is possible: a ProMotion iPhone and a MacBook Pro, not a MacBook Air.
- **Which mail accounts?**
  - Personal Gmail or Workspace? If it's a Workspace domain you administer, an "Internal" consent screen removes every Google OAuth limit.
  - **Is the Google account in Advanced Protection?**
  - Any Outlook/Hotmail, Yahoo or Proton accounts?
- **Are you willing to add a card to an Azure account** (for Outlook OAuth), and to **pay $99/yr** (TestFlight, notarization, shared keychain)?
- **Snooze/reminder sync across devices without a server:** an IMAP "Ink/Snoozed" folder plus a hidden metadata message? IMAP keywords? Exchange has no custom keywords, and Gmail's keyword support is reportedly limited (unverified). Or iCloud key-value storage, which needs the paid account?
- **Designed HTML in dark mode:** always a white "paper" card, or try inversion by default?
- **Is the GitHub repo private?** Runner minutes. **Are you in the EU?** That only matters for alternative marketplaces.

---

## 8. Sources

**Google / Gmail**
- https://support.google.com/mail/answer/7126229 — Gmail IMAP/SMTP settings; IMAP always on since Jan 2025
- https://developers.google.com/workspace/gmail/imap/imap-smtp
- https://developers.google.com/workspace/gmail/imap/xoauth2-protocol
- https://developers.google.com/workspace/gmail/imap/imap-extensions
- https://github.com/google/gmail-oauth2-tools/blob/master/python/oauth2.py
- https://support.google.com/accounts/answer/185833 — app passwords
- https://support.google.com/accounts/answer/7539956 — Advanced Protection FAQ
- https://support.google.com/accounts/answer/6010255 — less secure apps (personal accounts)
- https://support.google.com/a/answer/14114704 and https://knowledge.workspace.google.com/admin/sync/transition-from-less-secure-apps-to-oauth
- https://workspaceupdates.googleblog.com/2023/09/winding-down-google-sync-and-less-secure-apps-support.html
- https://accounts.google.com/.well-known/openid-configuration
- https://developers.google.com/identity/protocols/oauth2/native-app
- https://developers.google.com/identity/sign-in/ios/start-integrating — iOS client type for iOS and macOS
- https://developers.google.com/identity/protocols/oauth2#expiration
- https://developers.google.com/identity/protocols/oauth2/policies
- https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration
- https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification
- https://support.google.com/cloud/answer/15549945 — Manage App Audience (Testing, 7 days)
- https://support.google.com/cloud/answer/13464323 — verification exceptions (personal use)
- https://support.google.com/cloud/answer/7454865 — unverified apps
- https://developers.googleblog.com/usability-and-safety-updates-to-google-auth-platform/
- https://github.com/rclone/rclone/blob/master/docs/content/drive.md and https://github.com/rclone/rclone/issues/9854 — publish-without-verification; Branding URLs requirement (Sep 2026)
- https://developers.google.com/workspace/gmail/api/guides/push
- https://developers.google.com/workspace/gmail/api/reference/quota
- https://knowledge.workspace.google.com/admin/gmail/gmail-bandwidth-limits
- https://gmail.googleapis.com/$discovery/rest?version=v1 — ImapSettings, scopes
- https://github.com/jstedfast/MailKit/blob/master/Documentation/Examples/ImapIdleExample.cs

**Apple accounts / iCloud Mail**
- https://support.apple.com/en-us/102525 — iCloud Mail server settings
- https://support.apple.com/en-us/102654 — app-specific passwords
- https://support.apple.com/en-gb/102374 — iCloud+ custom-domain MX

**Microsoft**
- https://support.microsoft.com/en-us/office/pop-imap-and-smtp-settings-for-outlook-com-d088b986-291d-42b8-9564-9c414e2aa040
- https://techcommunity.microsoft.com/t5/outlook-blog/keeping-our-outlook-personal-email-users-safe-reinforcing-our/ba-p/4164184
- https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth
- https://login.microsoftonline.com/consumers/v2.0/.well-known/openid-configuration
- https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow
- https://learn.microsoft.com/en-us/entra/identity-platform/reference-breaking-changes — registrations must be in a directory (June 2024)
- https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app
- https://learn.microsoft.com/en-us/entra/fundamentals/create-new-tenant
- https://learn.microsoft.com/en-us/azure/cost-management-billing/troubleshoot-subscription/troubleshoot-azure-sign-up
- https://learn.microsoft.com/entra/msal/objc/redirect-uris-ios
- https://learn.microsoft.com/en-ca/entra/identity-platform/refresh-tokens
- https://techcommunity.microsoft.com/blog/exchange/updated-exchange-online-smtp-auth-basic-authentication-deprecation-timeline/4489835 and https://mc.merill.net/message/MC786329

**Other providers**
- https://help.yahoo.com/kb/sln15241.html — Yahoo app passwords
- https://github.com/M66B/FairEmail/blob/master/FAQ.md (FAQ 14, 88, 148) and https://github.com/M66B/FairEmail/commit/4f2f0f6b652422bb021f1a49570d1ef383166832
- https://raw.githubusercontent.com/M66B/FairEmail/master/app/src/main/res/xml/providers.xml
- https://github.com/thunderbird/knowledgebase-issues/issues/117
- https://raw.githubusercontent.com/simonrob/email-oauth2-proxy/main/README.md — Yahoo/AOL mail scope not registrable
- https://senders.yahooinc.com/developer/developer-access/
- https://github.com/allodia-eu/email-calendar-sync-engine/pull/263 — Yahoo MESSAGELIMIT behaviour
- https://www.fastmail.help/hc/en-us/articles/1500000278342 and https://www.fastmail.com/dev/
- https://proton.me/support/imap-smtp-and-pop3-setup, https://proton.me/support/smtp-submission, https://github.com/ProtonMail/proton-bridge
- https://www.zoho.com/mail/help/imap-access.html
- https://support.gmx.com/pop-imap/toggle.html

**Autodiscovery**
- https://github.com/thunderbird/autoconfig (ISPDB: `ispdb/me.com.xml`, `hotmail.com.xml`, `yahoo.com.xml`, …)
- https://raw.githubusercontent.com/mozilla/releases-comm-central/master/mail/components/accountcreation/modules/FindConfig.sys.mjs (and `FetchConfig`, `GuessConfig`, `mailnews.js`)
- https://raw.githubusercontent.com/mozilla/releases-comm-central/master/mailnews/base/src/OAuth2Providers.sys.mjs
- https://www.ietf.org/archive/id/draft-ietf-mailmaint-autoconfig-06.html and https://datatracker.ietf.org/doc/draft-ietf-mailmaint-pacc/

**Protocols (IETF)**
- https://www.rfc-editor.org/rfc/rfc3501, https://www.rfc-editor.org/rfc/rfc9051 — IMAP4rev1 / rev2
- https://www.rfc-editor.org/rfc/rfc2177 — IDLE
- https://www.rfc-editor.org/rfc/rfc7162 — CONDSTORE/QRESYNC
- https://www.rfc-editor.org/rfc/rfc6851 — MOVE; https://www.rfc-editor.org/rfc/rfc6154 — SPECIAL-USE; https://www.rfc-editor.org/rfc/rfc4315 — UIDPLUS
- https://www.rfc-editor.org/rfc/rfc9738 — MESSAGELIMIT; https://www.rfc-editor.org/rfc/rfc8970 — PREVIEW
- https://www.rfc-editor.org/rfc/rfc8314 — implicit TLS; https://www.rfc-editor.org/rfc/rfc3207 — SMTP STARTTLS; https://www.rfc-editor.org/rfc/rfc4954 — SMTP AUTH; https://datatracker.ietf.org/doc/html/rfc7628 — OAUTHBEARER
- https://datatracker.ietf.org/doc/rfc6186/ — SRV discovery
- https://www.rfc-editor.org/rfc/rfc5322, https://www.rfc-editor.org/rfc/rfc2045, https://www.rfc-editor.org/rfc/rfc2046, https://www.rfc-editor.org/rfc/rfc2047, https://www.rfc-editor.org/rfc/rfc2231, https://www.rfc-editor.org/rfc/rfc2387, https://www.rfc-editor.org/rfc/rfc2392, https://www.rfc-editor.org/rfc/rfc3676, https://www.rfc-editor.org/rfc/rfc8621
- https://www.rfc-editor.org/rfc/rfc8058 and https://www.rfc-editor.org/rfc/rfc2369 — unsubscribe
- https://nostarttls.secvuln.info/ — STARTTLS injection study

**Apple: networking, background, keychain**
- https://developer.apple.com/documentation/foundation/urlsessionstreamtask and https://developer.apple.com/documentation/foundation/urlsessionstreamtask/startsecureconnection()
- https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api
- https://developer.apple.com/forums/thread/755795 — STARTTLS via NWProtocolFramer
- https://developer.apple.com/documentation/technotes/tn3191-imap-extensions-supported-by-mail
- https://developer.apple.com/forums/thread/685525 — background execution reality
- https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app
- https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate
- https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
- https://developer.apple.com/forums/thread/114456 and https://developer.apple.com/forums/thread/98484
- https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlock
- https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession

**Apple: WebKit and rendering**
- https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript
- https://developer.apple.com/documentation/safariservices/creating-a-content-blocker
- https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/URLFilterParser.cpp and https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/ContentExtensionsBackend.cpp
- https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/seturlschemehandler(_:forurlscheme:)
- https://developer.apple.com/documentation/webkit/wknavigationdelegate/webviewwebcontentprocessdidterminate(_:)
- https://developer.apple.com/documentation/webkit/wkprocesspool and https://developer.apple.com/documentation/webkit/webview-swift.struct
- https://developer.apple.com/documentation/swiftui/view/textselection(_:)
- https://developer.apple.com/documentation/foundation/nsattributedstring/init(data:options:documentattributes:)

**Reference implementations**
- https://github.com/apple/swift-nio-imap, https://github.com/Cocoanetics/SwiftMail
- https://github.com/jstedfast/MailKit, https://github.com/jstedfast/MimeKit
- https://github.com/Foundry376/Mailspring-Sync — sent-copy handling
- https://github.com/igorkulman/Postie/blob/main/Postie/Views/HTMLMessageBody.swift
- https://github.com/ProtonMail/ios-mail (branches `main` and `v4`), https://github.com/deltachat/deltachat-ios
- https://github.com/ProtonMail/WebClients/blob/main/applications/mail/src/app/helpers/message/messageBlockquote.ts
- https://github.com/crisp-oss/email-reply-parser/blob/master/lib/regex.ts
- https://github.com/apparition47/MailTrackerBlocker/blob/master/Source/MTBBlockedMessage.m
- https://github.com/jmapio/jmap/blob/master/spec/mail/message.mdown
- https://www.jwz.org/doc/threading.html

**Apple: SwiftUI, UX, HIG**
- https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays
- https://developer.apple.com/documentation/bundleresources/information-property-list/cadisableminimumframedurationonphone
- https://developer.apple.com/documentation/uikit/uinavigationcontroller/interactivecontentpopgesturerecognizer and https://developer.apple.com/videos/play/wwdc2025/284/
- https://developer.apple.com/documentation/swiftui/view/swipeactions(edge:allowsfullswipe:content:)
- https://developer.apple.com/documentation/swiftui/uigesturerecognizerrepresentable and https://developer.apple.com/documentation/swiftui/nsgesturerecognizerrepresentable
- https://developer.apple.com/forums/thread/760035 — DragGesture blocks ScrollView (iOS 18)
- https://developer.apple.com/documentation/swiftui/navigationtransition/zoom(sourceid:in:) and https://developer.apple.com/videos/play/wwdc2024/10145/
- https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:) and https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- https://developer.apple.com/documentation/bundleresources/information-property-list/uidesignrequirescompatibility and https://developer.apple.com/forums/thread/832543
- https://developer.apple.com/videos/play/wwdc2023/10160/, https://developer.apple.com/videos/play/wwdc2025/306/, https://developer.apple.com/videos/play/wwdc2025/256/
- https://developer.apple.com/design/human-interface-guidelines/typography, …/color, …/dark-mode, …/materials, …/motion, …/keyboards
- https://support.google.com/mail/answer/6594 — Gmail shortcuts; https://help.superhuman.com/hc/en-us/articles/38458431506067-Customizing-Swipes-and-Triage-Bar
- https://github.com/alikaragoz/MCSwipeTableViewCell — Mailbox-style thresholds

**Distribution**
- https://developer.apple.com/xcode/system-requirements/ and https://developer.apple.com/support/xcode/
- https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
- https://developer.apple.com/news/upcoming-requirements/, https://developer.apple.com/news/?id=k1mtkt1k (April 2027 iOS 27 SDK requirement), https://developer.apple.com/app-store/submitting/
- https://developer.apple.com/support/compare-memberships/ — free-team limits
- https://developer.apple.com/help/account/reference/supported-capabilities-ios and https://developer.apple.com/help/account/reference/supported-capabilities-macos
- https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line
- https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview
- https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api
- https://developer.apple.com/documentation/xcode-release-notes/xcode-13-release-notes and https://developer.apple.com/documentation/xcode-release-notes/xcode-15-release-notes
- https://developer.apple.com/forums/thread/773749 — ExportOptions methods; https://developer.apple.com/forums/thread/759126 — app record via API (403); https://developer.apple.com/forums/thread/733942 — Mac TestFlight profile and sandbox
- https://developer.apple.com/documentation/security/app-sandbox
- https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations
- https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- https://developer.apple.com/documentation/xcode/configuring-your-app-icon
- https://developer.apple.com/news/?id=saqachfa — Sequoia Gatekeeper change; https://support.apple.com/guide/mac-help/mh40617
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- https://github.com/actions/runner-images (READMEs for `macos-15-arm64`, `macos-26-arm64`, `xcode-27-arm64`; issue #14404)
- https://github.com/github/docs/blob/main/content/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications.md
- https://github.com/SideStore/SideStore/releases and https://github.com/altstoreio/AltStore/releases
- https://github.com/yonaskolb/XcodeGen/releases
- https://www.swift.org/api/v1/install/releases.json — Swift version per Xcode
