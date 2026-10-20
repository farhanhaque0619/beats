# Connecting your email to Ink

Ink talks to your provider directly over IMAP (reading) and SMTP (sending), with TLS. There's no
Ink server, so your mail and password never pass through anyone else. Passwords live in the
Keychain on each device.

Most providers no longer accept your normal password from third-party apps. You either create an
**app password** (a separate password just for Ink, which you can revoke any time) or use
**Sign in with …** (OAuth). App passwords need no setup on Ink's side, so they're the default.

| Provider | How you sign in | Notes |
|---|---|---|
| Gmail / Google | App password (OAuth optional) | Needs 2-Step Verification. Not possible on Advanced Protection accounts. |
| iCloud Mail | App-specific password | Needs two-factor authentication (on for nearly everyone). |
| Outlook.com / Hotmail / Live | Sign in with Microsoft only | Needs a one-time app registration (below). Turn on IMAP in Outlook settings. |
| Yahoo / AOL | App password | Yahoo sometimes refuses to make app passwords for an account. |
| Fastmail | App password | Basic plan has no IMAP. |
| Zoho, GMX, web.de, custom domains | App password or account password | Turn on IMAP in the provider's settings if it's off. Ink finds the servers for you. |
| Proton Mail | Not on iPhone | Proton has no IMAP; Proton Bridge only runs on desktop computers. |

## Gmail (app password, ~2 minutes)

1. Make sure **2-Step Verification** is on: <https://myaccount.google.com/signinoptions/twosv>.
2. Open <https://myaccount.google.com/apppasswords>, type "Ink" as the name, and click **Create**.
3. Copy the 16-character password (spaces don't matter).
4. In Ink: **Add account › Gmail**, enter your name, address and that password.

IMAP is always on for Gmail (Google removed the switch in January 2025). Changing your Google
password revokes app passwords; just create a new one.

## iCloud Mail (app-specific password)

1. Go to <https://account.apple.com>, sign in, open **Sign-In and Security › App-Specific Passwords**.
2. Click **+**, name it "Ink", and copy the password (format `abcd-efgh-ijkl-mnop`).
3. In Ink: **Add account › iCloud**, use your iCloud address (…@icloud.com, @me.com or @mac.com).

Changing your Apple Account password revokes app-specific passwords.

## Yahoo and AOL

Yahoo: <https://login.yahoo.com/account/security> › **Generate app password** (under "App
passwords" or "External connections"). AOL: <https://login.aol.com/account/security>. Yahoo's IMAP
has no push (IDLE), so Ink checks for new Yahoo mail when you open or refresh the app.

## Fastmail

**Settings › Privacy & Security › Manage app passwords › New app password**, access "Mail (IMAP/
POP/SMTP)". Use your full Fastmail address as the username.

## Outlook.com, Hotmail, Live (Sign in with Microsoft)

Microsoft switched off passwords and app passwords for IMAP/SMTP on personal accounts in
September 2024, so Outlook needs OAuth. OAuth needs an *app registration*, which identifies the
app to Microsoft. Since mid-2024 Microsoft only allows registrations inside a directory (tenant).
A plain personal Microsoft account can't make one, but a free Azure account comes with a tenant.

1. Turn on IMAP in Outlook: <https://outlook.live.com> › **Settings › Mail › Forwarding and IMAP ›
   Let devices and apps use IMAP**.
2. Create a free Azure account at <https://azure.microsoft.com/free> (it asks for a card to verify
   you; you aren't charged for this). This gives you a Microsoft Entra tenant.
3. Open <https://entra.microsoft.com> › **Applications › App registrations › New registration**:
   - Name: `Ink`
   - Supported account types: **Accounts in any organizational directory and personal Microsoft
     accounts**
   - Redirect URI: platform **Public client/native (mobile & desktop)**, value
     `msauth.io.github.farhanhaque0619.ink://auth` (use your own bundle ID if you changed it)
4. Copy the **Application (client) ID**.
5. Put it in the app (pick one):
   - Local Xcode builds: in `Ink/Config/Local.xcconfig`, `INK_MICROSOFT_CLIENT_ID = <the ID>`
   - CI builds (DMG, TestFlight): GitHub repo **Settings › Secrets and variables › Actions ›
     Variables › New variable**, `INK_MICROSOFT_CLIENT_ID`.
6. In Ink: **Add account › Outlook › Sign in with Microsoft**.

Ink asks for `IMAP.AccessAsUser.All`, `SMTP.Send` and `offline_access`, and uses PKCE with no
client secret.

## Gmail with "Sign in with Google" (optional)

App passwords are simpler. If you'd rather use OAuth:

1. <https://console.cloud.google.com> › create a project › **Google Auth Platform**.
2. **Branding**: app name "Ink", your email. **Audience**: External, then add yourself as a
   **test user**.
3. **Data access › Add scopes**: `https://mail.google.com/` (plus `openid` and `email`).
4. **Clients › Create client** › type **iOS**, bundle ID `io.github.farhanhaque0619.ink`. Copy the
   client ID. Ink uses this one client on both iPhone and Mac.
5. **Audience › Publish app**. While an app is in *Testing*, Google expires its sign-ins every 7
   days. Published but unverified apps are fine for personal use: you click through one "Google
   hasn't verified this app" warning, and there's a 100-user cap that doesn't matter here. Google may
   ask for a home page and privacy policy URL before it lets you publish.
6. Set `INK_GOOGLE_CLIENT_ID` the same way as the Microsoft ID above.

## Other providers and custom domains

Choose **Other** and enter your address. Ink looks up your server settings: first its built-in
list, then your domain's autoconfig file, then Thunderbird's provider database, then your domain's
MX records (so a custom domain hosted by Google, Microsoft, Fastmail, Zoho or iCloud is recognized).
It shows what it found under **Advanced** before it sends your password anywhere, and you can edit
it.
