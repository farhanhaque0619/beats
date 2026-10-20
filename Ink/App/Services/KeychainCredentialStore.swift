import Foundation
import Security
import InkCore

/// Account secrets in the Keychain, readable after the first unlock (so background refresh works
/// while the phone is locked) and never synced or migrated to another device.
///
/// iPhone, and Mac builds signed with a provisioning profile: the data-protection keychain, one
/// generic-password item per account (service + account ID) holding the JSON-encoded `Credential`.
///
/// Unsigned and ad-hoc signed Mac builds lack the entitlement for that (`errSecMissingEntitlement`),
/// so the store falls back to the legacy file keychain. There every account's secret lives in ONE
/// item: each new ad-hoc build asks "Ink wants to use your confidential information…" once per
/// item it reads, so one item means one prompt per update instead of one per account. Items from
/// builds that kept one item per account are moved into it the first time they're read.
///
/// Secrets are read once per launch and then served from memory, which also keeps the Mac prompt
/// from coming back on every connection when someone answers "Allow" rather than "Always Allow".
///
/// `credential(for:)` refreshes an OAuth access token a few minutes before it runs out, saves the
/// new one, and coalesces concurrent refreshes for the same account into one request.
actor KeychainCredentialStore: CredentialStore {
    /// `errSecMissingEntitlement`: the app isn't entitled to the data-protection keychain.
    private static let missingEntitlement: OSStatus = -34018
    /// Refresh this long before an access token expires (RESEARCH §3.7), so a connection opened
    /// just before the deadline still signs in.
    private static let refreshLeeway: TimeInterval = 5 * 60
    /// Token refreshes leave no cookies or cache behind (the shared session would keep the
    /// provider's cookies).
    private static let tokenSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    private let service: String
    private var inFlightRefreshes: [String: Task<OAuthToken, Error>] = [:]
    /// Credentials already read or written this launch, by account ID.
    private var cache: [String: Credential] = [:]
    #if os(macOS)
    /// Nil until the first Keychain call finds out whether this build may use the
    /// data-protection keychain.
    private var usesDataProtectionKeychain: Bool?
    /// The legacy keychain's single item, decoded; nil until read.
    private var vault: [String: Credential]?
    /// `kSecAttrAccount` of that item. Account IDs are UUIDs, so it can't collide with one.
    private static let vaultAccount = "ink.credentials"
    #endif

    init(service: String = "io.github.farhanhaque0619.ink") {
        self.service = service
    }

    // MARK: CredentialStore

    func credential(for account: AccountConfig) async throws -> Credential {
        if account.isDemo { return .password("demo") }
        let stored: Credential
        if let cached = cache[account.id] {
            stored = cached
        } else {
            guard let loaded = try load(accountID: account.id) else {
                throw Self.signInAgain(account)
            }
            cache[account.id] = loaded
            stored = loaded
        }
        guard case .oauth(let token) = stored, token.isExpired(leeway: Self.refreshLeeway) else { return stored }
        let fresh = try await refreshed(token, for: account)
        return .oauth(fresh)
    }

    func save(_ credential: Credential, for accountID: String) async throws {
        try store(credential, accountID: accountID)
    }

    func delete(accountID: String) async throws {
        inFlightRefreshes[accountID]?.cancel()
        inFlightRefreshes[accountID] = nil
        cache[accountID] = nil
        #if os(macOS)
        if !dataProtectionAvailable() {
            try deleteFromVault(accountID: accountID)
            return
        }
        #endif
        let status = deleteItem(accountID: accountID, dataProtection: true)
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
            try await OAuthClient.refresh(token, config: configuration, session: Self.tokenSession)
        }
        inFlightRefreshes[account.id] = refresh
        defer {
            if inFlightRefreshes[account.id] == refresh { inFlightRefreshes[account.id] = nil }
        }

        var fresh = try await refresh.value
        // The account was removed while the request ran: don't write its secret back.
        guard inFlightRefreshes[account.id] == refresh else { throw MailError.cancelled }
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

    // MARK: Load and store

    private func load(accountID: String) throws -> Credential? {
        #if os(macOS)
        if !dataProtectionAvailable() { return try loadFromVault(accountID: accountID) }
        #endif
        return try loadItem(accountID: accountID, dataProtection: true)
    }

    private func store(_ credential: Credential, accountID: String) throws {
        #if os(macOS)
        if !dataProtectionAvailable() {
            var updated = try loadVault()
            updated[accountID] = credential
            try saveVault(updated)
            cache[accountID] = credential
            return
        }
        #endif
        try storeItem(credential, accountID: accountID, dataProtection: true)
        cache[accountID] = credential
    }

    // MARK: One item per account

    private func loadItem(accountID: String, dataProtection: Bool) throws -> Credential? {
        var query = baseQuery(accountID: accountID, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            // Unreadable data is treated like a missing item: the user signs in again.
            guard let data = item as? Data, let credential = try? JSONDecoder().decode(Credential.self, from: data) else { return nil }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw Self.failure(status)
        }
    }

    private func storeItem(_ credential: Credential, accountID: String, dataProtection: Bool) throws {
        let data = try JSONEncoder().encode(credential)
        try write(data, accountID: accountID, dataProtection: dataProtection, label: "Ink mail account")
    }

    /// Updates the item, or adds it when there's none yet.
    private func write(_ data: Data, accountID: String, dataProtection: Bool, label: String) throws {
        let query = baseQuery(accountID: accountID, dataProtection: dataProtection)
        var attributes: [String: Any] = [kSecValueData as String: data]
        if dataProtection {
            // After first unlock: background refresh reads it while the phone is locked.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            item[kSecAttrLabel as String] = label
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.failure(status) }
    }

    @discardableResult
    private func deleteItem(accountID: String, dataProtection: Bool) -> OSStatus {
        SecItemDelete(baseQuery(accountID: accountID, dataProtection: dataProtection) as CFDictionary)
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

    // MARK: Mac without the keychain entitlement

    #if os(macOS)
    /// Whether this build may use the data-protection keychain. Asked once: a lookup there fails
    /// with `errSecMissingEntitlement` in unsigned and ad-hoc signed builds.
    private func dataProtectionAvailable() -> Bool {
        if let usesDataProtectionKeychain { return usesDataProtectionKeychain }
        var probe = baseQuery(accountID: Self.vaultAccount, dataProtection: true)
        probe[kSecReturnAttributes as String] = true
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let available = SecItemCopyMatching(probe as CFDictionary, &result) != Self.missingEntitlement
        usesDataProtectionKeychain = available
        return available
    }

    /// Every account's credential from the single legacy item (read once per launch).
    private func loadVault() throws -> [String: Credential] {
        if let vault { return vault }
        var query = baseQuery(accountID: Self.vaultAccount, dataProtection: false)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let loaded: [String: Credential]
        switch status {
        case errSecSuccess:
            // Unreadable data counts as empty, like an unreadable per-account item.
            loaded = (item as? Data).flatMap { try? JSONDecoder().decode([String: Credential].self, from: $0) } ?? [:]
        case errSecItemNotFound:
            loaded = [:]
        default:
            throw Self.failure(status)
        }
        vault = loaded
        return loaded
    }

    private func saveVault(_ contents: [String: Credential]) throws {
        if contents.isEmpty {
            let status = deleteItem(accountID: Self.vaultAccount, dataProtection: false)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
        } else {
            let data = try JSONEncoder().encode(contents)
            try write(data, accountID: Self.vaultAccount, dataProtection: false, label: "Ink mail accounts")
        }
        vault = contents
    }

    private func loadFromVault(accountID: String) throws -> Credential? {
        var contents = try loadVault()
        if let credential = contents[accountID] { return credential }
        // Builds before the single item kept one item per account: move it over. If saving the
        // single item fails, keep using the old one and try again next launch.
        guard let old = try loadItem(accountID: accountID, dataProtection: false) else { return nil }
        contents[accountID] = old
        do {
            try saveVault(contents)
            deleteItem(accountID: accountID, dataProtection: false)
        } catch {
            // Still readable from the old item.
        }
        return old
    }

    private func deleteFromVault(accountID: String) throws {
        var contents = try loadVault()
        if contents.removeValue(forKey: accountID) != nil { try saveVault(contents) }
        // An item in the old one-per-account format, if this account still had one.
        let status = deleteItem(accountID: accountID, dataProtection: false)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }
    #endif

    // MARK: Errors

    private static func signInAgain(_ account: AccountConfig) -> MailError {
        .authenticationFailed("Sign in again to \(account.emailAddress).")
    }

    private static func failure(_ status: OSStatus) -> MailError {
        if status == errSecInteractionNotAllowed {
            return .serverError("Ink can't read your saved passwords until this device is unlocked.")
        }
        #if os(macOS)
        if status == errSecUserCanceled || status == errSecAuthFailed {
            // The Mac asked whether Ink may use its Keychain item and the answer was Deny.
            return .serverError("Ink wasn't allowed to read your saved passwords. Try again and choose Always Allow when your Mac asks.")
        }
        #endif
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
        return .serverError("Ink couldn't use the Keychain (\(detail)).")
    }
}
