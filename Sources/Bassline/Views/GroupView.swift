import AppKit
import SwiftUI

extension Color {
    /// Multi-Output's own colour, between the device colours.
    static let multiOutput = Color(red: 0.12, green: 0.72, blue: 0.70)
}

/// Play the Mac's sound on several headphones and speakers at once.
struct GroupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            GlassGroup(spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    deviceList
                    syncCard
                    tips
                }
            }
            .padding(24)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Multi-Output")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isGroupActive {
                    Button {
                        withAnimation(.smooth(duration: 0.35)) { model.stopGroup() }
                    } label: {
                        Label("Stop Multi-Output", systemImage: "stop.circle")
                    }
                    .help("Play only on the Mac’s sound output again")
                }
            }
        }
        .tint(.multiOutput)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            DeviceBadge(symbol: "hifispeaker.2.fill", tint: .multiOutput, size: 72)
                .shadow(color: Color.multiOutput.opacity(0.4), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text("Multi-Output")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Play your Mac’s sound on several headphones and speakers at once. Each one keeps its own EQ.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(model.isGroupActive ? Color.green : Color.secondary)
                        .symbolEffect(.pulse, options: .repeating, isActive: model.isGroupActive)
                    Text(statusText)
                        .font(.callout.weight(.medium))
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .glassSurface(cornerRadius: 100)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .glassSurface(cornerRadius: 26, tint: .multiOutput)
        .animation(.smooth(duration: 0.3), value: model.isGroupActive)
    }

    private var statusText: String {
        let count = model.activeGroup.count
        if count > 1 { return "Playing on \(count) devices" }
        if model.connectedDevices.count < 2 { return "Connect a second device to start" }
        return "Pick another device below to start"
    }

    // MARK: Devices

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Devices", systemImage: "speaker.wave.2")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ForEach(sortedDevices) { device in
                GroupDeviceRow(device: device)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.35), value: model.extraOutputUIDs)
        .animation(.smooth(duration: 0.35), value: model.connectedDevices.map(\.uid))
    }

    /// The sound output first, then the other group members, then everything else.
    private var sortedDevices: [OutputDevice] {
        let current = model.currentOutput?.uid
        return model.connectedDevices.sorted { a, b in
            func rank(_ d: OutputDevice) -> Int {
                if d.uid == current { return 0 }
                if model.extraOutputUIDs.contains(d.uid) { return 1 }
                return 2
            }
            return (rank(a), a.name) < (rank(b), b.name)
        }
    }

    // MARK: Sync

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Keep Devices in Sync", systemImage: "timer")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.smooth(duration: 0.4)) { model.autoSync() }
                } label: {
                    Label("Auto-Sync", systemImage: "wand.and.stars")
                }
                .disabled(!model.isGroupActive)
            }
            Text("Bluetooth headphones play a little later than wired speakers, so mixing them can sound like an echo. Auto-Sync delays the faster devices to match the slowest. If something still sounds early, raise its delay a few milliseconds at a time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your volume keys control the sound output (the device marked Main). Use the sliders above for the others.", systemImage: "speaker.wave.2")
            Label("Two pairs of AirPods work. If the sound stutters, keep both close to your Mac; Bluetooth bandwidth is shared.", systemImage: "airpods")
            Label("Choosing a device as the sound output in Control Center makes it the Main device here.", systemImage: "switch.2")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

private struct GroupDeviceRow: View {
    @EnvironmentObject private var model: AppModel
    let device: OutputDevice

    @State private var volume: Float = 0
    @State private var hasVolume = false

    var body: some View {
        let profile = model.profile(for: device)
        let tint = profile?.tint ?? DeviceKind.other.tint
        let isMain = device.uid == model.currentOutput?.uid
        let isMember = model.isInGroup(device)
        let route = model.route(for: device)
        let playing = isMember && model.isGroupActive

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    withAnimation(.smooth(duration: 0.35)) { model.toggleGroupMember(device) }
                } label: {
                    Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isMember ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(isMain || !model.canAddToGroup(device))
                .help(isMain ? "The sound output always plays" : (isMember ? "Stop playing here" : "Also play here"))

                DeviceBadge(symbol: profile?.symbolName ?? "speaker.wave.2.fill", tint: tint, size: 36, dimmed: !isMember)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.name).font(.headline).lineLimit(1)
                        if isMain {
                            Text("MAIN")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(tint.opacity(0.18)))
                                .foregroundStyle(tint)
                        }
                    }
                    Text(eqSummary(profile))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if playing, let route {
                    LevelMeter(processor: model.engine.processor, route: route, tint: tint, isActive: true, height: 28)
                        .transition(.opacity)
                }

                if isMember && !isMain {
                    Button("Make Main") { model.playThrough(device) }
                        .controlSize(.small)
                        .help("Make this the Mac’s sound output")
                }
                if let profile {
                    Button {
                        model.selectedProfileID = profile.id
                    } label: {
                        Label("EQ", systemImage: "slider.vertical.3")
                    }
                    .controlSize(.small)
                    .help("Edit this device’s EQ")
                }
            }

            if isMember {
                HStack(spacing: 22) {
                    if hasVolume {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { Double(volume) },
                                set: { volume = Float($0); HAL.setVolume(device.id, Float($0)) }
                            ), in: 0...1)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("Use this device’s own volume controls.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "timer").foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { model.delay(for: device) },
                            set: { model.setDelay($0, for: device) }
                        ), in: 0...500, step: 5)
                        Text(String(format: "%.0f ms", model.delay(for: device)))
                            .font(.callout.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                            .contentTransition(.numericText(value: model.delay(for: device)))
                    }
                    .frame(maxWidth: .infinity)
                    .help("Delay this device so it lines up with the others")
                }
                .padding(.leading, 36)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .glassSurface(cornerRadius: 20, tint: isMember ? tint : nil)
        .tint(tint)
        .onAppear(perform: readVolume)
        .onChange(of: isMember) { _, _ in readVolume() }
    }

    private func readVolume() {
        hasVolume = HAL.canSetVolume(device.id)
        volume = HAL.volume(device.id) ?? 0
    }

    private func eqSummary(_ profile: DeviceProfile?) -> String {
        guard let profile else { return "Flat" }
        if !profile.isEnabled { return "EQ off" }
        if profile.isFlat { return "Flat" }
        return "EQ: \(profile.presetName)"
    }
}
