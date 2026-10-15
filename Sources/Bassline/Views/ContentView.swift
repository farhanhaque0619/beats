import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            if let id = model.selectedProfileID, model.profile(id: id) != nil {
                ProfileDetailView(profileID: id)
                    .id(id)
            } else {
                ContentUnavailableView(
                    "Choose a Device",
                    systemImage: "headphones",
                    description: Text("Pick headphones or a speaker to shape how it sounds.")
                )
            }
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    private var visibleOthers: [DeviceProfile] {
        model.otherProfiles.filter { model.isConnected($0) || $0.isEnabled || model.isCurrentOutput($0) }
    }

    var body: some View {
        List(selection: $model.selectedProfileID) {
            Section("My Devices") {
                ForEach(model.knownProfiles) { profile in
                    DeviceRow(profile: profile).tag(profile.id)
                }
            }
            if !visibleOthers.isEmpty {
                Section("Other Outputs") {
                    ForEach(visibleOthers) { profile in
                        DeviceRow(profile: profile).tag(profile.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            EngineFooter()
        }
    }
}

private struct DeviceRow: View {
    @EnvironmentObject private var model: AppModel
    let profile: DeviceProfile

    var body: some View {
        let status = model.status(of: profile)
        HStack(spacing: 10) {
            Image(systemName: profile.kind.symbolName)
                .font(.system(size: 17))
                .frame(width: 26)
                .foregroundStyle(status == .disconnected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                    .lineLimit(1)
                Text(status.shortTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if status == .equalizing {
                Image(systemName: "waveform")
                    .foregroundStyle(.green)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .help("Equalizing now")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct EngineFooter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var dotColor: Color {
        switch model.engineStatus {
        case .running: .green
        case .idle: .gray
        case .failed, .unsupported: .orange
        }
    }

    private var title: String {
        switch model.engineStatus {
        case .running: "Equalizer on"
        case .idle: "Equalizer off"
        case .failed: "Equalizer stopped"
        case .unsupported: "Unavailable"
        }
    }

    private var subtitle: String {
        let output = model.currentOutput?.name ?? "No output"
        return "Output: \(output)"
    }
}
