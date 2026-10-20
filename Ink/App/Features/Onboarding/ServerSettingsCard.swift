import SwiftUI
import InkCore

/// Incoming or outgoing server, for defaults that depend on which.
enum OnboardingServerKind {
    case incoming, outgoing

    func defaultPort(for security: ConnectionSecurity) -> Int {
        switch (self, security) {
        case (.incoming, .startTLS): return 143
        case (.incoming, _): return 993
        case (.outgoing, .startTLS): return 587
        case (.outgoing, _): return 465
        }
    }
}

/// Editable IMAP or SMTP details for "Other", kept as text while typing.
struct OnboardingServerFields: Equatable {
    var host: String
    var port: String
    var security: ConnectionSecurity
    var username: String

    /// A plain-text server becomes STARTTLS: Ink never sends a password unencrypted.
    init(host: String = "", port: Int, security: ConnectionSecurity = .tls, username: String = "") {
        self.host = host
        self.port = String(port)
        self.security = security == ConnectionSecurity.none ? .startTLS : security
        self.username = username
    }

    init(_ server: ServerConfig) {
        self.init(host: server.host, port: server.port, security: server.security, username: server.username)
    }

    /// The finished config, or nil while something is missing. An empty username means the address.
    func serverConfig(fallbackUsername: String) -> ServerConfig? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedHost.contains(" "),
              let number = Int(port), (1...65_535).contains(number) else { return nil }
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return ServerConfig(
            host: trimmedHost,
            port: number,
            security: security == ConnectionSecurity.none ? .startTLS : security,
            username: trimmedUser.isEmpty ? fallbackUsername : trimmedUser
        )
    }

    var isComplete: Bool { serverConfig(fallbackUsername: "-") != nil }

    /// "imap.example.com · 993 · SSL/TLS".
    var summary: String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return [trimmedHost.isEmpty ? "No server yet" : trimmedHost, port, security.onboardingTitle].joined(separator: " · ")
    }

    /// After switching between SSL/TLS and STARTTLS, a standard port moves along with it.
    mutating func securityChanged(from oldValue: ConnectionSecurity, kind: OnboardingServerKind) {
        guard oldValue != security else { return }
        if port.isEmpty || Int(port) == kind.defaultPort(for: oldValue) {
            port = String(kind.defaultPort(for: security))
        }
    }
}

extension ConnectionSecurity {
    /// Name shown in server settings.
    var onboardingTitle: String {
        switch self {
        case .tls: return "SSL/TLS"
        case .startTLS: return "STARTTLS"
        case .none: return "None"
        }
    }
}

/// Where the server settings for "Other" stand.
enum OnboardingDiscoveryStatus: Equatable {
    case idle
    case looking
    case found(source: String)
    case notFound
}

/// "Advanced" for Other: the server settings autodiscovery found, editable before anything is sent.
struct OnboardingServerSettingsCard: View {
    @Binding var imap: OnboardingServerFields
    @Binding var smtp: OnboardingServerFields
    let status: OnboardingDiscoveryStatus
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpace.l) {
            Button {
                Haptics.tick()
                withAnimation(InkMotion.snappy) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: InkSpace.s) {
                    Image(systemName: "server.rack")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ink.primary)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: InkSpace.xxs) {
                        Text("Advanced")
                            .font(InkFont.headline)
                            .foregroundStyle(Ink.primary)
                        statusLine
                    }
                    Spacer(minLength: InkSpace.s)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Ink.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: InkSpace.l) {
                    OnboardingServerSection(title: "Incoming mail (IMAP)", fields: $imap, kind: .incoming)
                    OnboardingServerSection(title: "Outgoing mail (SMTP)", fields: $smtp, kind: .outgoing)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(InkSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous)
                .stroke(Ink.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
        .animation(InkMotion.snappy, value: status)
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .idle:
            Text("Your mail server settings. Ink looks them up from your address.")
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
        case .looking:
            HStack(spacing: InkSpace.s) {
                LoadingDots()
                Text("Looking up your servers")
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
            }
        case .found(let source):
            VStack(alignment: .leading, spacing: InkSpace.xxs) {
                Text(Self.describe(source))
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
                if !isExpanded {
                    // Both servers, visible before the password goes anywhere.
                    VStack(alignment: .leading, spacing: InkSpace.xxs) {
                        Text("In  " + imap.summary)
                        Text("Out " + smtp.summary)
                    }
                    .font(InkFont.mono)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Incoming \(imap.summary). Outgoing \(smtp.summary).")
                }
            }
        case .notFound:
            Text("Couldn't find them automatically. Check these with your provider.")
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Autodiscovery's source in plain words.
    private static func describe(_ source: String) -> String {
        let lowered = source.lowercased()
        if lowered.contains("ispdb") || lowered.contains("thunderbird") { return "Found in Thunderbird's provider list." }
        if lowered.contains("autoconfig") || lowered.contains("well-known") { return "Found in your domain's mail settings file." }
        if lowered.contains("mx") { return "Matched from your domain's mail servers." }
        if lowered.contains("guess") { return "A best guess. Check it with your provider." }
        if lowered.contains("preset") || lowered.contains("built") { return "From Ink's list of providers." }
        return "Found automatically. Check before connecting."
    }
}

private struct OnboardingServerSection: View {
    let title: String
    @Binding var fields: OnboardingServerFields
    let kind: OnboardingServerKind

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpace.s) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .default, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Ink.tertiary)
                .accessibilityAddTraits(.isHeader)

            OnboardingFieldGroup {
                OnboardingFieldRow(label: "Server") {
                    TextField(kind == .incoming ? "imap.example.com" : "smtp.example.com", text: $fields.host)
                        .textFieldStyle(.plain)
                        .onboardingHostInput()
                }
                OnboardingFieldRow(label: "Port") {
                    TextField(String(kind.defaultPort(for: fields.security)), text: $fields.port)
                        .textFieldStyle(.plain)
                        .monospacedDigit()
                        .onboardingNumberInput()
                        .onChange(of: fields.port) { _, newValue in
                            let digits = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(5))
                            if digits != newValue { fields.port = digits }
                        }
                }
                OnboardingFieldRow(label: "Security") {
                    Picker("Security", selection: $fields.security) {
                        Text(ConnectionSecurity.tls.onboardingTitle).tag(ConnectionSecurity.tls)
                        Text(ConnectionSecurity.startTLS.onboardingTitle).tag(ConnectionSecurity.startTLS)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: fields.security) { oldValue, _ in
                        fields.securityChanged(from: oldValue, kind: kind)
                    }
                }
                OnboardingFieldRow(label: "Username", showsDivider: false) {
                    TextField("Same as your address", text: $fields.username)
                        .textFieldStyle(.plain)
                        .onboardingLiteralInput()
                }
            }
        }
    }
}
