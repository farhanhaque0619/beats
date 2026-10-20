import Foundation

/// SASL payloads for SMTP (and IMAP) authentication. Every function returns base64 text ready to
/// put on the wire; none of them log or keep the secret.
public enum SASL {
    /// RFC 4616 PLAIN: `base64("\0" + username + "\0" + password)` with an empty authorization identity.
    public static func plain(username: String, password: String) -> String {
        var bytes: [UInt8] = [0]
        bytes.append(contentsOf: username.utf8)
        bytes.append(0)
        bytes.append(contentsOf: password.utf8)
        return Data(bytes).base64EncodedString()
    }

    /// Google / Microsoft XOAUTH2: `base64("user=" + username + "\x01auth=Bearer " + token + "\x01\x01")`.
    public static func xoauth2(username: String, accessToken: String) -> String {
        let payload = "user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        return Data(payload.utf8).base64EncodedString()
    }

    /// RFC 7628 OAUTHBEARER initial client response (GS2 header, host, port, bearer token).
    public static func oauthBearer(username: String, accessToken: String, host: String? = nil, port: Int? = nil) -> String {
        var payload = "n,a=\(escapeGS2(username)),\u{01}"
        if let host, !host.isEmpty { payload += "host=\(host)\u{01}" }
        if let port { payload += "port=\(port)\u{01}" }
        payload += "auth=Bearer \(accessToken)\u{01}\u{01}"
        return Data(payload.utf8).base64EncodedString()
    }

    /// The legacy LOGIN mechanism sends the username and password as separate base64 lines.
    public static func login(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    /// The JSON a server sends in a failed XOAUTH2 / OAUTHBEARER `334` challenge,
    /// e.g. Gmail's `{"status":"400","schemes":"Bearer","scope":"https://mail.google.com/"}`.
    public struct OAuthErrorChallenge: Sendable, Equatable {
        public var status: String?
        public var schemes: String?
        public var scope: String?

        /// A sentence explaining the failure, for when the server's final reply says little.
        public var explanation: String {
            switch status {
            case "401": return "The sign-in token was rejected (it may have expired). Sign in again."
            case "400": return "The sign-in token was rejected. Sign in again."
            case "403": return "The sign-in token doesn't allow sending mail. Sign in again and allow mail access."
            default: return "The sign-in token was rejected. Sign in again."
            }
        }
    }

    /// Decodes a base64 OAuth error challenge. Returns nil when it isn't base64 JSON.
    public static func decodeOAuthErrorChallenge(_ base64: String) -> OAuthErrorChallenge? {
        let trimmed = base64.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = decodeBase64(trimmed),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            if let value = json[key] as? String { return value }
            if let value = json[key] as? NSNumber { return value.stringValue }
            return nil
        }
        return OAuthErrorChallenge(status: string("status"), schemes: string("schemes"), scope: string("scope"))
    }

    /// Base64 decode that tolerates missing padding.
    static func decodeBase64(_ text: String) -> Data? {
        var padded = text
        let remainder = padded.utf8.count % 4
        if remainder == 2 { padded += "==" } else if remainder == 3 { padded += "=" }
        return Data(base64Encoded: padded)
    }

    /// GS2 escaping for the authzid in OAUTHBEARER (`,` → `=2C`, `=` → `=3D`).
    private static func escapeGS2(_ value: String) -> String {
        value.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
    }
}
