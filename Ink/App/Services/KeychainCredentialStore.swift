import Foundation
import Security
import InkCore

/// Account secrets in the Keychain: one generic-password item per account (service + account ID),
/// holding the JSON-encoded `Credential`, readable after the first unlock and never synced or
/// migrated to another device.
///
/// On the Mac it uses the data-protection keychain. Unsigned and ad-hoc signed builds lack the
/// entitlement for that (`errSecMissingEntitlement`), so the store falls back to the legacy file
/// keychain and remembers that choice.
///
/// `credential(for:)` refreshes an expired OAuth access token, saves the new one, and coalesces
/// concurrent refreshes for the same account into one request.
actor KeychainCredentialStore: CredentialStore {
    /// `errSecMissingEntitlement`: the app isn't entitled to the data-protection keychain.
    private static let missingEntitlement: OSStatus = -34018

    private let service: String
    private var inFlightRefreshes: [String: Task<OAuthToken, Error>] = [:]
    #if os(macOS)
    private var prefersDataProtectionKeychain = true
    #endif

    init(service: String = "io.github.farhanhaque0619.ink") {
        self.service = service
    }

    // MARK: CredentialStore

    func credential(for account: AccountConfig) async throws -> Credential {
        if account.isDemo { return .password("demo") }
        guard let stored = try load(accountID: account.id) else {
            throw Self.signInAgain(account)
        }
        guard case .oauth(let token) = stored, token.isExpired() else { return stored }
        let fresh = try await refreshed(token, for: account)
        return .oauth(fresh)
    }

    func save(_ credential: Credential, for accountID: String) async throws {
        try store(credential, accountID: accountID)
    }

    func delete(accountID: String) async throws {
        inFlightRefreshes[accountID]?.cancel()
        inFlightRefreshes[accountID] = nil
        let status = withKeychain { dataProtection in
            SecItemDelete(baseQuery(accountID: accountID, dataProtection: dataProtection) as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }

    // MARK: OAuth refresh

    private func refreshed(_ token: OAuthToken, for account: AccountConfig) async throws -> OAuthToken {
        if let running = inFlightRefreshes[account.id] {
            return try await running.value
        }
        guard let provider = Self.oauthProvider(for: account) else { throw Self.signInAgain(account) }
        guard let configuration = OAuthSettings.configuration(for: provider) else {
            throw MailError.oauthNotConfigured(provider)
        }
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw Self.signInAgain(account)
        }

        let refresh = Task<OAuthToken, Error> {
            try await OAuthClient.refresh(token, config: configuration)
        }
        inFlightRefreshes[account.id] = refresh
        defer { inFlightRefreshes[account.id] = nil }

        var fresh = try await refresh.value
        // Google doesn't send a new refresh token on refresh; keep the one we have.
        if fresh.refreshToken?.isEmpty ?? true { fresh.refreshToken = refreshToken }
        try store(.oauth(fresh), accountID: account.id)
        return fresh
    }

    private static func oauthProvider(for account: AccountConfig) -> OAuthProviderID? {
        if let provider = account.oauthProvider { return provider }
        switch account.provider {
        case .gmail: return .google
        case .outlook: return .microsoft
        default: return nil
        }
    }

    // MARK: Keychain

    private func load(accountID: String) throws -> Credential? {
        var found: Data?
        let status = withKeychain { dataProtection in
            var query = baseQuery(accountID: accountID, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let result = SecItemCopyMatching(query as CFDictionary, &item)
            found = item as? Data
            return result
        }
        switch status {
        case errSecSuccess:
            // Unreadable data is treated like a missing item: the user signs in again.
            guard let found, let credential = try? JSONDecoder().decode(Credential.self, from: found) else { return nil }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw Self.failure(status)
        }
    }

    private func store(_ credential: Credential, accountID: String) throws {
        let data = try JSONEncoder().encode(credential)
        let status = withKeychain { dataProtection in
            let query = baseQuery(accountID: accountID, dataProtection: dataProtection)
            var attributes: [String: Any] = [kSecValueData as String: data]
            #if os(macOS)
            if dataProtection {
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            #else
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updated == errSecItemNotFound else { return updated }
            var item = query
            item.merge(attributes) { _, new in new }
            item[kSecAttrLabel as String] = "Ink mail account"
            return SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.failure(status) }
    }

    private func baseQuery(accountID: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
        #if os(macOS)
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    /// Runs a SecItem call against the data-protection keychain, or — on a Mac build without the
    /// keychain entitlement — against the legacy keychain, remembering which one works.
    private func withKeychain(_ operation: (_ dataProtection: Bool) -> OSStatus) -> OSStatus {
        #if os(macOS)
        if prefersDataProtectionKeychain {
            let status = operation(true)
            guard status == Self.missingEntitlement else { return status }
            prefersDataProtectionKeychain = false
        }
        return operation(false)
        #else
        return operation(true)
        #endif
    }

    // MARK: Errors

    private static func signInAgain(_ account: AccountConfig) -> MailError {
        .authenticationFailed("Sign in again to \(account.emailAddress).")
    }

    private static func failure(_ status: OSStatus) -> MailError {
        if status == errSecInteractionNotAllowed {
            return .serverError("Ink can't read your saved passwords until this device is unlocked.")
        }
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
        return .serverError("Ink couldn't use the Keychain (\(detail)).")
    }
}
