import Foundation
import InkModel
import InkIMAP

// Folder list, role detection, and finding or creating the folders actions need.
extension IMAPMailService {
    /// Every folder (LIST), with roles from SPECIAL-USE attributes or well-known names, sorted:
    /// Inbox, Starred, Drafts, Sent, Archive / All Mail, Spam, Trash, then other folders A–Z.
    /// Always asks the server; the result also refreshes the folder cache actions use.
    public func mailboxes() async throws -> [MailboxInfo] {
        try await exclusive {
            try await self.withClient { client in try await self.loadMailboxes(client) }
        }
    }

    /// LIST, mapped and cached.
    @discardableResult
    func loadMailboxes(_ client: IMAPClient) async throws -> [MailboxInfo] {
        let listed = try await client.listMailboxes()
        let isGmail = await client.isGmail
        let infos = IMAPMailServiceRoles.mailboxInfos(from: listed, accountID: account.id, isGmail: isGmail)
        mailboxCache = infos
        return infos
    }

    /// The folder list of this session (LIST the first time).
    func cachedMailboxes(_ client: IMAPClient) async throws -> [MailboxInfo] {
        if let mailboxCache { return mailboxCache }
        return try await loadMailboxes(client)
    }

    /// The selectable folder with `role`, if the account has one.
    func mailbox(role: MailboxRole, client: IMAPClient) async throws -> MailboxInfo? {
        try await cachedMailboxes(client).first { $0.role == role && $0.isSelectable }
    }

    /// The folder with the decoded `path`. Lists again once when the cache doesn't know it
    /// (it may have been created elsewhere); nil when the server doesn't have it either.
    func mailbox(path: String, client: IMAPClient) async throws -> MailboxInfo? {
        if let found = Self.find(path: path, in: try await cachedMailboxes(client)) { return found }
        return Self.find(path: path, in: try await loadMailboxes(client))
    }

    /// The wire name for a decoded path: from the folder list when known, otherwise encoded.
    func rawPath(for path: String, client: IMAPClient) async throws -> String {
        if let found = try await mailbox(path: path, client: client) { return found.rawPath }
        if path.caseInsensitiveCompare("INBOX") == .orderedSame { return "INBOX" }
        return ModifiedUTF7.encode(path)
    }

    /// The role of the folder at `path` (`.custom` when unknown).
    func role(ofPath path: String, client: IMAPClient) async throws -> MailboxRole {
        if path.caseInsensitiveCompare("INBOX") == .orderedSame { return .inbox }
        return Self.find(path: path, in: try await cachedMailboxes(client))?.role ?? .custom
    }

    static func find(path: String, in mailboxes: [MailboxInfo]) -> MailboxInfo? {
        if let exact = mailboxes.first(where: { $0.path == path }) { return exact }
        if path.caseInsensitiveCompare("INBOX") == .orderedSame {
            return mailboxes.first { $0.role == .inbox }
        }
        return nil
    }

    /// The folder with `role`, creating it (as `name`, next to the other system folders) when
    /// the account has none. Used for Archive, Trash, Junk and Sent on servers that only have an
    /// INBOX until a client makes the rest.
    func mailbox(role: MailboxRole, creatingAs name: String, client: IMAPClient) async throws -> MailboxInfo {
        if let existing = try await mailbox(role: role, client: client) { return existing }
        let current = try await cachedMailboxes(client)
        // A folder with that name may exist without the role being detected (e.g. nested); use it.
        let rawName = IMAPMailServiceRoles.newFolderRawName(name, existing: current)
        if let same = current.first(where: { $0.rawPath == rawName && $0.isSelectable }) { return same }
        log("Creating the \(role.title) folder “\(rawName)”.")
        try await client.create(rawName)
        do {
            try await client.subscribe(rawName)
        } catch let error as MailError where !Self.isConnectionLoss(error) {
            // Subscribing is a courtesy for other clients.
        }
        let refreshed = try await loadMailboxes(client)
        if let made = refreshed.first(where: { $0.rawPath == rawName }) {
            if made.role == role { return made }
            var adjusted = made
            adjusted.role = role
            mailboxCache = IMAPMailServiceRoles.sorted(refreshed.map { $0.rawPath == rawName ? adjusted : $0 })
            return adjusted
        }
        let delimiter = current.compactMap(\.delimiter).first ?? "/"
        let made = MailboxInfo(accountID: account.id, path: ModifiedUTF7.decode(rawName), rawPath: rawName, delimiter: delimiter, role: role)
        mailboxCache = IMAPMailServiceRoles.sorted(refreshed + [made])
        return made
    }
}

/// Maps LIST results to `MailboxInfo`s: roles from SPECIAL-USE (RFC 6154) or Gmail's XLIST
/// attributes first, then well-known folder names in several languages, one folder per role.
///
/// Gmail is the exception: its system folders live under `[Gmail]` or, on older UK and German
/// accounts, `[Google Mail]`, with localized names, and every other folder is a user label that
/// may be called "Archive" or "Sent". So on Gmail only the attributes count (RESEARCH §3.4), and
/// a role whose folder is hidden from IMAP (All Mail, when "Show in IMAP" is off) stays missing.
enum IMAPMailServiceRoles {
    /// Well-known names per role, lowercased, best first. Matched against the last path component
    /// of top-level folders and of folders directly under INBOX (Courier/cPanel style
    /// `INBOX.Sent`) or `[Gmail]` / `[Google Mail]`.
    static let wellKnownNames: [(MailboxRole, [String])] = [
        (.sent, ["sent", "sent messages", "sent items", "sent mail", "sent-mail", "sent e-mails", "outbox sent",
                 "gesendet", "gesendete elemente", "gesendete objekte", "gesendete nachrichten",
                 "envoyés", "envoyes", "éléments envoyés", "elements envoyes", "messages envoyés",
                 "enviados", "elementos enviados", "mensajes enviados", "itens enviados",
                 "posta inviata", "inviati", "elementi inviati",
                 "verzonden", "verzonden items", "verzonden berichten",
                 "skickat", "skickade objekt", "skickade meddelanden", "sendt", "sendte elementer", "sendt post",
                 "lähetetyt", "wysłane", "odeslané", "отправленные", "已发送", "已傳送", "送信済み", "보낸편지함"]),
        (.drafts, ["drafts", "draft", "entwürfe", "entwurf", "brouillons", "borradores", "rascunhos", "bozze",
                   "concepten", "utkast", "kladder", "luonnokset", "kopie robocze", "koncepty", "черновики", "草稿", "下書き", "임시보관함"]),
        (.trash, ["trash", "deleted messages", "deleted items", "deleted", "bin", "rubbish", "wastebasket",
                  "papierkorb", "gelöschte elemente", "gelöschte objekte", "corbeille", "éléments supprimés", "elements supprimes",
                  "papelera", "elementos eliminados", "lixeira", "itens excluídos", "cestino", "posta eliminata", "elementi eliminati",
                  "prullenbak", "verwijderde items", "papperskorgen", "borttagna objekt", "borttaget", "papirkurv", "slettede elementer",
                  "roskakori", "kosz", "koš", "корзина", "удаленные", "已删除", "垃圾桶", "ゴミ箱", "휴지통"]),
        (.junk, ["junk", "junk e-mail", "junk email", "junk mail", "spam", "bulk mail", "bulk", "junk-e-mail",
                 "spamverdacht", "unerwünscht", "courrier indésirable", "courrier indesirable", "indésirables", "pourriel",
                 "correo no deseado", "no deseado", "lixo eletrônico", "posta indesiderata", "ongewenste e-mail", "ongewenst",
                 "skräppost", "uønsket e-post", "roskaposti", "спам", "垃圾邮件", "迷惑メール", "스팸편지함"]),
        (.archive, ["archive", "archives", "archived", "archiv", "archivo", "archivio", "archief", "arkiv", "arkisto",
                    "archiwum", "arquivo", "archivé", "архив", "归档", "アーカイブ", "보관함"]),
        (.all, ["all mail", "alle nachrichten", "tous les messages", "todos", "tutti i messaggi", "alle berichten"]),
        (.flagged, ["starred", "flagged", "markiert"]),
    ]

    /// Parents under which system folders commonly live.
    static let systemParents: Set<String> = ["inbox", "[gmail]", "[google mail]"]

    /// Sidebar order of roles; custom folders come last.
    static func sortRank(_ role: MailboxRole) -> Int {
        switch role {
        case .inbox: return 0
        case .flagged: return 1
        case .snoozed: return 2
        case .drafts: return 3
        case .sent: return 4
        case .archive, .all: return 5
        case .junk: return 6
        case .trash: return 7
        case .custom: return 100
        }
    }

    /// LIST results → sorted `MailboxInfo`s with one folder per system role. `isGmail` turns off
    /// matching by name.
    static func mailboxInfos(from mailboxes: [IMAPMailbox], accountID: String, isGmail: Bool = false) -> [MailboxInfo] {
        var infos: [MailboxInfo] = []
        var claimed = Set<MailboxRole>()
        var inboxSeen = false
        for mailbox in mailboxes {
            let isInbox = mailbox.rawName.caseInsensitiveCompare("INBOX") == .orderedSame || mailbox.specialUse == .inbox
            var role: MailboxRole = .custom
            if isInbox, !inboxSeen {
                role = .inbox
                inboxSeen = true
            } else if mailbox.isSelectable, let special = mailbox.specialUse, special != .inbox, !claimed.contains(special) {
                role = special
            }
            if role != .custom { claimed.insert(role) }
            let path = role == .inbox ? "INBOX" : mailbox.name
            infos.append(MailboxInfo(accountID: accountID, path: path, rawPath: mailbox.rawName, delimiter: mailbox.delimiter,
                                     role: role, attributes: mailbox.attributes))
        }
        if !inboxSeen {
            // RFC 3501: INBOX always exists, even when a server forgets to list it.
            let delimiter = mailboxes.compactMap(\.delimiter).first ?? "/"
            infos.insert(MailboxInfo(accountID: accountID, path: "INBOX", rawPath: "INBOX", delimiter: delimiter, role: .inbox), at: 0)
        }

        // Well-known names for roles no attribute claimed: best name, then shallowest, wins.
        // Never on Gmail, where such names are user labels.
        guard !isGmail else { return sorted(infos) }
        var best: [MailboxRole: (index: Int, score: Int)] = [:]
        for (index, info) in infos.enumerated() where info.role == .custom && info.isSelectable {
            guard let (role, score) = wellKnownRole(for: info), !claimed.contains(role) else { continue }
            if let current = best[role], current.score <= score { continue }
            best[role] = (index, score)
        }
        for (role, choice) in best { infos[choice.index].role = role }
        return sorted(infos)
    }

    /// The role a folder's name suggests, with a score (lower is better), or nil.
    static func wellKnownRole(for info: MailboxInfo) -> (MailboxRole, Int)? {
        let components = pathComponents(info.path, delimiter: info.delimiter)
        guard let last = components.last else { return nil }
        let depth = components.count - 1
        if depth > 1 { return nil }
        if depth == 1, !systemParents.contains(components[0].lowercased()) { return nil }
        let name = last.trimmingCharacters(in: .whitespaces).lowercased()
        for (role, names) in wellKnownNames {
            if let position = names.firstIndex(of: name) {
                return (role, depth * 1000 + position)
            }
        }
        return nil
    }

    static func pathComponents(_ path: String, delimiter: String?) -> [String] {
        guard let delimiter, !delimiter.isEmpty else { return [path] }
        return path.components(separatedBy: delimiter)
    }

    /// Role order, then custom folders A–Z by path component (children right after parents).
    static func sorted(_ infos: [MailboxInfo]) -> [MailboxInfo] {
        infos.enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            let rankL = sortRank(left.role), rankR = sortRank(right.role)
            if rankL != rankR { return rankL < rankR }
            if left.role != .custom || right.role != .custom {
                if left.role != right.role { return left.role.rawValue < right.role.rawValue }
                return lhs.offset < rhs.offset
            }
            let a = pathComponents(left.path, delimiter: left.delimiter)
            let b = pathComponents(right.path, delimiter: right.delimiter)
            for (x, y) in zip(a, b) {
                let order = x.compare(y, options: [.caseInsensitive, .numeric, .diacriticInsensitive])
                if order != .orderedSame { return order == .orderedAscending }
                if x != y { return x < y }
            }
            if a.count != b.count { return a.count < b.count }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The wire name for a new system folder: inside INBOX when the server keeps every folder
    /// there (Courier, many cPanel hosts), otherwise top level.
    static func newFolderRawName(_ name: String, existing: [MailboxInfo]) -> String {
        let encoded = ModifiedUTF7.encode(name)
        let others = existing.filter { $0.role != .inbox }
        guard let delimiter = existing.compactMap(\.delimiter).first(where: { !$0.isEmpty }), !others.isEmpty else { return encoded }
        let prefix = "INBOX" + delimiter
        let nested = others.allSatisfy { $0.rawPath.uppercased().hasPrefix(prefix.uppercased()) }
        guard nested, let sample = others.first?.rawPath else { return encoded }
        // Keep the server's spelling of INBOX ("INBOX." vs "Inbox.").
        return String(sample.prefix(prefix.count)) + encoded
    }
}
