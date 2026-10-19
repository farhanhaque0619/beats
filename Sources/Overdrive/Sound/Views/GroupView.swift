import AppKit
import SwiftUI

extension Color {
    /// Multi-Output's own colour, between the device colours.
    static var multiOutput: Color { Theme.accent }
}

/// Play the Mac's sound on several headphones and speakers at once.
struct GroupView: View {
    @EnvironmentObject private var model: SoundModel

    var body: some View {
        PageScroll {
            PageHeader(symbol: "hifispeaker.2.fill", title: "Multi-Output", subtitle: statusText) {
                InfoButton("""
                Tick devices to play on all of them at once. Each keeps its own EQ.

                Your volume keys control the device marked Main. Use the volume in each row for the others.

                Two pairs of AirPods work. If one stutters, move closer to your Mac, since they share its Bluetooth.
                """)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(sortedDevices) { device in
                    GroupDeviceRow(device: device)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.smooth(duration: 0.35), value: model.extraOutputUIDs)
            .animation(.smooth(duration: 0.35), value: model.connectedDevices.map(\.uid))

            if model.isGroupActive {
                arrangeBar
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.3), value: model.isGroupActive)
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

    private var statusText: String {
        let count = model.activeGroup.count
        if count > 1 { return "Playing on \(count) devices at once." }
        if model.connectedDevices.count < 2 { return "Connect a second speaker or pair of headphones to start." }
        return "Tick another device below to play on both."
    }

    /// The two one-click helpers, with their explanations tucked into ⓘ buttons.
    private var arrangeBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.smooth(duration: 0.35)) { model.smartSplit() }
            } label: {
                Label("Smart Split", systemImage: "sparkles")
            }
            .disabled(model.builtInGroupMembers.isEmpty)
            InfoButton("Gives your Mac’s built-in speakers the vocals and every other device the music and bass, so together they sound wider and clearer. Needs the built-in speakers in the group.")

            Divider().frame(height: 18)

            Button {
                withAnimation(.smooth(duration: 0.35)) { model.autoSync() }
            } label: {
                Label("Auto-Sync", systemImage: "timer")
            }
            InfoButton("Bluetooth plays a little later than wired speakers, which can sound like an echo. Auto-Sync delays the faster devices to match. Fine-tune any device with the delay in its row.")

            Spacer()

            Button("Reset Roles") {
                withAnimation(.smooth(duration: 0.35)) { model.resetRoles() }
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassSurface(cornerRadius: 18)
    }

    /// The sound output first, then the other group members, then everything else.
    private var sortedDevices: [OutputDevice] {
        let current = model.currentOutput?.uid
        let extras = Set(model.extraOutputUIDs)
        let rank: (OutputDevice) -> Int = { device in
            if device.uid == current { return 0 }
            return extras.contains(device.uid) ? 1 : 2
        }
        return model.connectedDevices.sorted { a, b in
            (rank(a), a.name) < (rank(b), b.name)
        }
    }
}

/// One device: a compact line by default, with volume and delay a click away.
private struct GroupDeviceRow: View {
    @EnvironmentObject private var model: SoundModel
    @EnvironmentObject private var battery: BatteryMonitor
    let device: OutputDevice

    @State private var isExpanded = false
    @State private var volume: Float = 0
    @State private var hasVolume = false

    var body: some View {
        let profile = model.profile(for: device)
        let isMain = device.uid == model.currentOutput?.uid
        let isMember = model.isInGroup(device)
        let playing = isMember && model.isGroupActive

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.smooth(duration: 0.35)) { model.toggleGroupMember(device) }
                } label: {
                    Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isMember ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(isMain || !model.canAddToGroup(device))
                .help(isMain ? "The sound output always plays" : (isMember ? "Stop playing here" : "Also play here"))

                DeviceBadge(symbol: profile?.symbolName ?? "speaker.wave.2.fill", size: 32, dimmed: !isMember)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.name).font(.headline).lineLimit(1)
                        if isMain { Tag(text: "MAIN") }
                    }
                    Text(subtitle(profile))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if playing, let route = model.route(for: device) {
                    LevelMeter(processor: model.engine.processor, route: route, tint: Theme.accent, isActive: true, height: 24)
                }

                if playing {
                    Menu {
                        Picker("Plays", selection: Binding(
                            get: { model.role(for: device) },
                            set: { role in withAnimation(.smooth) { model.setRole(role, for: device) } }
                        )) {
                            ForEach(SpeakerRole.allCases) { role in
                                Label(role.title, systemImage: role.symbolName).tag(role)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(model.role(for: device).title, systemImage: model.role(for: device).symbolName)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(model.role(for: device).detail)
                }

                if isMember {
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide options" : "Volume, delay and more")
                }
            }

            if isMember && isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    if hasVolume {
                        OptionRow(title: "Volume", symbol: "speaker.wave.2") {
                            Slider(value: Binding(
                                get: { Double(volume) },
                                set: { volume = Float($0); HAL.setVolume(device.id, Float($0)) }
                            ), in: 0...1)
                            Text(Format.percent(Double(volume)))
                                .font(.callout.monospacedDigit())
                                .frame(width: 48, alignment: .trailing)
                        }
                    } else {
                        OptionRow(title: "Volume", symbol: "speaker.wave.2") {
                            Text("Use this device’s own volume buttons.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    OptionRow(title: "Delay", symbol: "timer") {
                        Slider(value: Binding(
                            get: { model.delay(for: device) },
                            set: { model.setDelay($0, for: device) }
                        ), in: 0...500, step: 5)
                        Text(String(format: "%.0f ms", model.delay(for: device)))
                            .font(.callout.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }
                    HStack(spacing: 10) {
                        if !isMain {
                            Button("Make Main") { model.playThrough(device) }
                        }
                        if let profile {
                            Button("Edit EQ") { model.selectedProfileID = profile.id }
                        }
                        Spacer()
                        if playing {
                            Text(model.role(for: device).detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: 360, alignment: .trailing)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 44)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .glassSurface(cornerRadius: 18, tint: isMember ? Theme.accent : nil)
        .onAppear(perform: readVolume)
        .onChange(of: isMember) { _, member in
            readVolume()
            if !member { isExpanded = false }
        }
    }

    private func readVolume() {
        hasVolume = HAL.canSetVolume(device.id)
        volume = HAL.volume(device.id) ?? 0
    }

    private func subtitle(_ profile: DeviceProfile?) -> String {
        var parts: [String] = []
        if let profile {
            if !profile.isEnabled || profile.isFlat { parts.append("No EQ") } else { parts.append(profile.presetName) }
        }
        if model.isInGroup(device), model.isGroupActive, model.delay(for: device) > 0 {
            parts.append("\(Int(model.delay(for: device))) ms delay")
        }
        if let level = battery.battery(for: device.name)?.headline {
            parts.append("\(level)% battery")
        }
        return parts.joined(separator: " · ")
    }
}

private struct OptionRow<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            content
        }
    }
}
