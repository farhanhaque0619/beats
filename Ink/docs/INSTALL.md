# Installing Ink

Ink builds on GitHub Actions on every push. Each build is published as the
[`ink-latest` pre-release](https://github.com/farhanhaque0619/beats/releases/tag/ink-latest)
with the Mac app, an unsigned iPhone build and fresh screenshots.

## Mac (2 minutes)

1. Download **Ink.dmg** from [`ink-latest`](https://github.com/farhanhaque0619/beats/releases/tag/ink-latest).
2. Open it and drag **Ink** into **Applications**.
3. Open Ink. macOS blocks the first launch because the app isn't notarized (that needs a paid
   developer account). Go to **System Settings › Privacy & Security**, scroll down and click
   **Open Anyway**. Or run this once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Ink.app
   ```

4. After an update, macOS may ask whether Ink can use its saved password in your keychain. Click
   **Always Allow**. This happens because each build is signed separately.

Update from Terminal:

```bash
osascript -e 'quit app "Ink"' 2>/dev/null
curl -L -o /tmp/Ink.dmg https://github.com/farhanhaque0619/beats/releases/download/ink-latest/Ink.dmg
hdiutil attach /tmp/Ink.dmg -nobrowse -quiet -mountpoint /tmp/InkDMG
rm -rf /Applications/Ink.app && ditto /tmp/InkDMG/Ink.app /Applications/Ink.app
hdiutil detach /tmp/InkDMG -quiet
xattr -dr com.apple.quarantine /Applications/Ink.app
open /Applications/Ink.app
```

## iPhone

Apple only lets you install apps that are signed for your device. There are three ways to get
that signature. Start with option A: it's free and takes about 15 minutes, most of it the Xcode
download.

### A. Xcode with your free Apple ID (recommended to start)

You need: your MacBook, a USB-C cable, and an iPhone on iOS 18 or later.

1. Install **Xcode** from the Mac App Store (it's large, so give it time). Open it once and let it
   install its components. Which version depends on your Mac:

   | Your Mac runs | Use |
   |---|---|
   | macOS 27, or Tahoe 26.6 and later | Xcode 27.1 (required on macOS 27) |
   | macOS Tahoe 26.2–26.5 | Xcode 26.5 or 26.6 |
   | macOS Sequoia 15.6 and later | Xcode 26.3 |

   All of them can install onto an iPhone on iOS 27.
2. Get the code:
   ```bash
   git clone https://github.com/farhanhaque0619/beats.git
   cd beats && git checkout claude/email-app-research-poc-5ulcvp
   open Ink/Ink.xcodeproj
   ```
3. In Xcode, pick the **Ink-iOS** scheme at the top. Click the **Ink** project in the sidebar,
   select the **Ink-iOS** target, then **Signing & Capabilities**. Under **Team**, choose **Add an
   Account…**, sign in with your Apple ID, and pick **(Your Name) (Personal Team)**.
   - If Xcode says the bundle identifier isn't available, copy `Ink/Config/Local.xcconfig.example`
     to `Ink/Config/Local.xcconfig` and set `INK_BUNDLE_ID = com.yourname.ink`.
4. Plug in your iPhone and tap **Trust** on the phone. On the iPhone, turn on
   **Settings › Privacy & Security › Developer Mode** (it restarts the phone).
5. Choose your iPhone as the run destination at the top of Xcode and press **⌘R**.
6. The first time, iOS says the developer isn't trusted. Open **Settings › General › VPN & Device
   Management**, tap your Apple ID, then **Trust**. Open Ink.

**Every week:** the free route's install stops opening after **7 days**. Renew it with one command
(it builds, signs with your team and installs; your accounts and settings stay):

```bash
cd beats/Ink
cp Config/Local.xcconfig.example Config/Local.xcconfig   # once; set DEVELOPMENT_TEAM
./scripts/install-iphone.sh
```

Or plug in the phone and press ⌘R in Xcode. Free teams are limited to 3 sideloaded apps per device,
3 devices and 10 app IDs per week, and can't use push notifications or iCloud, which is why Ink
checks for mail in the background instead and why accounts are set up separately on each device.

### B. TestFlight (needs the $99/year Apple Developer Program)

TestFlight installs like a normal app, updates itself, and builds last 90 days. CI can upload every
build for you.

One-time setup:
1. Join the [Apple Developer Program](https://developer.apple.com/programs/enroll/).
2. In [App Store Connect](https://appstoreconnect.apple.com) › **Apps › +** › **New App**: platform
   iOS, name "Ink" (or anything that's free), bundle ID `io.github.farhanhaque0619.ink` (register it
   under Certificates, Identifiers & Profiles › Identifiers first if it isn't listed).
3. **Users and Access › Integrations › App Store Connect API › Team Keys › +**, role **Admin**
   (cloud-managed signing needs Admin; only the Account Holder can turn on API access).
   Download the `.p8` key (you only get one chance) and note the **Key ID** and **Issuer ID**.
4. In GitHub: **repo Settings › Secrets and variables › Actions › New repository secret**:
   - `ASC_KEY_ID`: the Key ID
   - `ASC_ISSUER_ID`: the Issuer ID
   - `ASC_KEY_P8`: the whole contents of the `.p8` file
   - `APPLE_TEAM_ID`: your Team ID (developer.apple.com › Membership)
   - `INK_BUNDLE_ID` (optional): only if you used a different bundle ID
5. In App Store Connect › your app › **TestFlight**, create an **internal testing** group and add
   yourself.

Each time you want a build on your phone: **Actions › Ink › Run workflow**, tick **Upload to
TestFlight**, then **Run**. Or put `[testflight]` in a commit message. Builds show up in the
TestFlight app after Apple finishes processing them (usually 5–30 minutes). Internal testing needs no
App Review.

Two caveats. The first CI run may need a retry if automatic signing creates a new certificate on the
fresh runner (see docs/RESEARCH.md §6.3 for the fallback). And from **April 2027** Apple only accepts
uploads built with the iOS 27 SDK (Xcode 27), so the TestFlight job will need a newer runner by then.

### C. Sideload the unsigned build

`Ink-unsigned.ipa` on the release page can be installed with [Sideloadly](https://sideloadly.io) or
[AltStore](https://altstore.io), which sign it with your Apple ID. With a free Apple ID it also
expires after 7 days, so option A is usually simpler if you have a Mac.

## Connecting accounts

See [ACCOUNTS.md](ACCOUNTS.md). Short version: Gmail, iCloud, Yahoo and Fastmail work with an
**app password** you create on the provider's website. Outlook/Hotmail needs "Sign in with
Microsoft", which needs a one-time app registration.

## Building from source on a Mac

```bash
cd Ink
./scripts/build-mac.sh     # build/Ink.app (universal, ad-hoc signed)
./scripts/make-dmg.sh      # build/Ink.dmg
./scripts/build-ipa.sh     # build/Ink-unsigned.ipa
./scripts/screenshots.sh   # build/screenshots/*.png from the iOS Simulator
```

`InkCore` (all the mail logic) also builds and tests on Linux: `swift test --package-path Ink/InkCore`.
