import Foundation
import Security

/// Passwords in the user's Keychain, as standard internet-password items keyed by
/// server, port and account. Keychain Access lists them as "rdp://host"; connections to the
/// same computer and user share one item, as browsers do for websites.
public struct CredentialStore: Sendable {
    /// Keychain protocol attribute for RDP (a four-character code, like "htps" for HTTPS).
    static let rdpProtocol = "rdp "

    public init() {}

    public struct Key: Hashable, Sendable {
        public var host: String
        public var port: UInt16
        public var username: String

        public init(host: String, port: UInt16, username: String) {
            self.host = host.trimmingCharacters(in: .whitespaces).lowercased()
            self.port = port
            self.username = username
        }

        public init(_ connection: Connection) {
            self.init(host: connection.host, port: connection.port, username: connection.username)
        }

        /// The gateway's own password; nil when the gateway uses the computer's credentials.
        public init?(gatewayOf connection: Connection) {
            guard let gateway = connection.gateway, !gateway.usesComputerCredentials else { return nil }
            self.init(host: gateway.host, port: gateway.port, username: gateway.username)
        }

        var isUsable: Bool { !host.isEmpty && !username.isEmpty }
    }

    private func query(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: key.host,
            kSecAttrPort as String: Int(key.port),
            kSecAttrAccount as String: key.username,
            kSecAttrProtocol as String: Self.rdpProtocol,
        ]
    }

    public func password(for key: Key) -> String? {
        guard key.isUsable else { return nil }
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func hasPassword(for key: Key) -> Bool {
        guard key.isUsable else { return false }
        var query = query(key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func setPassword(_ password: String, for key: Key, label: String) throws {
        guard key.isUsable else { return }
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(key)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            item[kSecAttrDescription as String] = "Remote desktop password"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    public func removePassword(for key: Key) throws {
        guard key.isUsable else { return }
        let status = SecItemDelete(query(key) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"])
        }
    }
}
