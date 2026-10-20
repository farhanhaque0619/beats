import Foundation
import InkCore

/// OAuth client IDs baked into this build. They come from `INK_GOOGLE_CLIENT_ID` /
/// `INK_MICROSOFT_CLIENT_ID` (Config/Ink.xcconfig, Local.xcconfig or CI variables) through the
/// Info.plist keys `InkGoogleClientID` / `InkMicrosoftClientID`. Empty, or an unexpanded
/// `$(...)`, means the provider isn't set up and the app offers app passwords instead.
enum OAuthSettings {
    static func clientID(for provider: OAuthProviderID) -> String? {
        let key: String
        switch provider {
        case .google: key = "InkGoogleClientID"
        case .microsoft: key = "InkMicrosoftClientID"
        }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    static func configuration(for provider: OAuthProviderID) -> OAuthConfiguration? {
        guard let clientID = clientID(for: provider) else { return nil }
        switch provider {
        case .google:
            return .google(clientID: clientID)
        case .microsoft:
            return .microsoft(clientID: clientID, bundleID: Bundle.main.bundleIdentifier ?? "")
        }
    }

    static func isConfigured(_ provider: OAuthProviderID) -> Bool {
        clientID(for: provider) != nil
    }
}
