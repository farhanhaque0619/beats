# Overdrive

A control center for your Mac: sound, display, performance and power-user tools in one quiet, native app. Overdrive started life as **Bassline**, a per-device equalizer. Everything Bassline did lives in the Sound section.

<img src="Resources/AppIcon.png" width="128" alt="Overdrive icon">

## Sections

### Overview
The state of your Mac at a glance: what's playing and where, CPU, memory, GPU and temperature gauges, Extra Brightness, Keep Awake and the microphone. Each tile jumps to its page.

### Sound
- **An EQ for every output**: built-in speakers, displays, USB, AirPlay and Bluetooth. Beats Studio Pro, AirPods Pro 2 and Marshall Acton III get tuned bass-forward starting points. The right EQ switches on as soon as your Mac plays through a device.
- **10-band EQ** with a draggable response curve, a live spectrum, Bass Boost, Hold to Compare, saved presets and distortion protection.
- **Multi-Output**: play on up to four devices at once, each with its own EQ, volume and sync delay. **Auto-Sync** lines devices up. **Speaker roles** split the music: Vocals, Music & Bass, Bass Only or Full Sound, with **Smart Split** for MacBook speakers plus a bigger speaker.
- **App Sound**: a volume for each app, and a switch to let calls skip the EQ.
- **Battery levels** for AirPods, Beats and other Bluetooth headphones.

### Display
- **Extra Brightness** for XDR displays (14- and 16-inch MacBook Pro, Pro Display XDR): goes past the normal brightness limit using the panel's HDR headroom. This is the same technique BrightIntosh and Vivid use, and it has guard rails:
  - Capped at +60%, the level those apps treat as the safe maximum.
  - Pauses automatically when macOS reports the Mac is running hot, and when the battery drops below a level you choose.
  - The change lives in the display's colour table, which macOS restores the moment Overdrive quits, even after a crash. The panel's firmware keeps enforcing its own power and heat limits.
- **Brightness** and **Dim** (below the normal minimum) for every display.
- **Resolution**: every scaled resolution and refresh rate your display supports.

### Performance
CPU (per core), GPU, memory and memory pressure, CPU/GPU/battery temperatures, fan speeds, system power draw, battery health and cycle count, network and disk throughput, free space, and the busiest apps. It only samples while you're looking, so it costs nothing in the background. Settings can also put CPU and temperature in the menu bar.

### Tools
- **Keep Awake** for 15 minutes up to indefinitely, with or without letting the display sleep.
- **Microphone mute** for every app at once.
- **Finder and Dock**: show hidden files, show all file extensions, hide desktop icons, hide the Dock automatically.
- **Quick actions**: sleep displays, eject all disks, restart the Dock, Finder or the menu bar, open Activity Monitor.

### Keyboard shortcuts
⌘1 Overview · ⌘2 current sound device · ⌘3 Displays · ⌘4 Performance · ⌘5 Tools · ⇧⌘M Multi-Output · ⇧⌘A App Sound · ⇧⌘E EQ on/off · ⌥⌘↑/↓ Bass Boost · ⌥⌘B Extra Brightness · ⌥⌘K Keep Awake · ⌥⌘M mute microphone.

## Install

1. Download **Overdrive.dmg** from the [latest release](https://github.com/farhanhaque0619/beats/releases/latest).
2. Open it and drag **Overdrive** into **Applications**.
3. The app isn't notarized, so the first launch is blocked. Open **System Settings › Privacy & Security** and click **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Overdrive.app`.
4. Allow system audio access when asked; the equalizer needs it. Audio is never recorded or saved.

**Coming from Bassline?** Use **Settings › Updates › Install and Relaunch** in Bassline. It installs Overdrive, which renames itself from Bassline.app to Overdrive.app and keeps all your settings.

Requires macOS Sonoma 14.2 or later.

## Updating from Terminal

```bash
osascript -e 'quit app "Overdrive"' -e 'quit app "Bassline"' 2>/dev/null
curl -L -o /tmp/Overdrive.dmg https://github.com/farhanhaque0619/beats/releases/latest/download/Overdrive.dmg
hdiutil attach /tmp/Overdrive.dmg -nobrowse -quiet -mountpoint /tmp/OverdriveDMG
rm -rf /Applications/Overdrive.app /Applications/Bassline.app
ditto /tmp/OverdriveDMG/Overdrive.app /Applications/Overdrive.app
hdiutil detach /tmp/OverdriveDMG -quiet
xattr -dr com.apple.quarantine /Applications/Overdrive.app
open /Applications/Overdrive.app
```

## How it works

- **Sound** uses Core Audio process taps (macOS 14.2+). The Mac's output is tapped and muted, run through per-device biquad filter chains, and played to the real devices through a private aggregate device. Nothing is installed in the system.
- **Extra Brightness** keeps a 2-pixel EDR (HDR) surface on screen, hidden under the display's rounded corner, so the panel enters HDR mode. It then scales the display's gamma table into the extra headroom.
- **Temperatures and fans** are read from the System Management Controller, falling back to the HID temperature sensors on newer chips. **GPU load** comes from the GPU driver's performance statistics, and **memory** from the kernel's VM statistics, using Activity Monitor's definition of "Memory Used".

## Build from source

```bash
./scripts/build-app.sh   # build/Overdrive.app (universal)
./scripts/make-dmg.sh    # build/Overdrive.dmg
```

Every push builds on GitHub Actions and updates the release.
