import AppKit
import Combine
import SwiftUI

extension Color {
    /// App Sound's own colour.
    static var appSound: Color { Theme.accent }
}

/// Volume and EQ for each app.
struct AppsView: View {
    @EnvironmentObject private var model: SoundModel

    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            GlassGroup(spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if model.audioApps.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "speaker.slash")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text("No apps are using sound yet")
                                .font(.headline)
                            Text("Play something in Spotify, Music, a browser or any other app and it appears here.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(32)
                        .glassSurface(cornerRadius: 22)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(model.audioApps) { app in
                                AppRow(app: app)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .animation(.smooth(duration: 0.35), value: model.audioApps.map(\.id))
                    }

                    if !model.savedRulesForClosedApps.isEmpty {
                        savedRules
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Turn EQ off for FaceTime, Zoom or Teams so voices on calls sound natural.", systemImage: "phone")
                        Label("Apps set to skip the EQ still play on every Multi-Output device, unchanged.", systemImage: "hifispeaker.2")
                        Label("Changing an app for the first time briefly restarts Overdrive’s audio.", systemImage: "info.circle")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                }
            }
            .padding(24)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("App Sound")
        .tint(.appSound)
        .onAppear { model.refreshApps() }
        .onReceive(poll) { _ in model.refreshApps() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            DeviceBadge(symbol: "square.stack.3d.up.fill", tint: .appSound, size: 72)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text("App Sound")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Set a volume for each app, or let an app skip the EQ entirely.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .glassSurface(cornerRadius: 26, tint: .appSound)
    }

    private var savedRules: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Saved for Apps Not Running", systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .foregroundStyle(.secondary)
            ForEach(model.savedRulesForClosedApps, id: \.key) { item in
                HStack {
                    Text(item.rule.name)
                    Spacer()
                    Text(summary(item.rule))
                        .foregroundStyle(.secondary)
                    Button("Reset") {
                        withAnimation(.smooth) { model.resetRule(for: item.key) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .glassCard()
    }

    private func summary(_ rule: AppRule) -> String {
        var parts = ["\(Int((rule.volume * 100).rounded()))%"]
        if !rule.useEQ { parts.append("EQ skipped") }
        return parts.joined(separator: " · ")
    }
}

private struct AppRow: View {
    @EnvironmentObject private var model: SoundModel
    let app: AudioApp

    var body: some View {
        let rule = model.rule(for: app)
        HStack(spacing: 14) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 36, height: 36)
                .opacity(app.isPlaying ? 1 : 0.6)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(app.isPlaying ? Color.green : Color.secondary.opacity(0.5))
                    Text(app.isPlaying ? "Playing" : "Not playing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 170, alignment: .leading)

            HStack(spacing: 8) {
                Image(systemName: rule.volume < 0.01 ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Slider(value: Binding(
                    get: { model.rule(for: app).volume },
                    set: { model.setVolume($0, for: app) }
                ), in: 0...1)
                Text("\(Int((rule.volume * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
                    .contentTransition(.numericText(value: rule.volume))
            }
            .frame(maxWidth: .infinity)

            Toggle(isOn: Binding(
                get: { model.rule(for: app).useEQ },
                set: { newValue in withAnimation(.smooth) { model.setUsesEQ(newValue, for: app) } }
            )) {
                Text("EQ")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(rule.useEQ ? "This app plays through your EQ" : "This app plays unchanged")

            Button {
                withAnimation(.smooth) { model.resetRule(for: app.id) }
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .opacity(rule.isDefault ? 0 : 1)
            .disabled(rule.isDefault)
            .help("Reset to full volume with EQ")
        }
        .padding(14)
        .glassSurface(cornerRadius: 18, tint: rule.isDefault ? nil : .appSound)
        .animation(.smooth(duration: 0.3), value: rule.isDefault)
    }
}
