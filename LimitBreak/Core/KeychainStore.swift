import Foundation
import Security

/// Keychain-backed storage for the credentials LimitBreak holds.
///
/// Two secrets live here: the Anthropic API key, and the bearer token for a
/// self-hosted Odysseus server. Both are long-lived credentials, so neither
/// touches `UserDefaults` (plain-text plist, included in unencrypted backups).
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps them readable by
/// background refreshes after the first unlock, while `ThisDeviceOnly` keeps
/// them out of iCloud Keychain and encrypted backups.
///
/// They're stored under separate services so removing one never disturbs the
/// other — the lifter can keep a Claude key on file while switching the app
/// over to their own server, and switch back without re-pasting.
enum KeychainStore {

    private enum Service {
        static let anthropic = "com.limitbreak.anthropic"
        static let odysseus = "com.limitbreak.odysseus"
    }

    private static let account = "api-key"

    // MARK: - Anthropic

    /// The stored Anthropic key, or nil when none has been saved.
    static var apiKey: String? { read(service: Service.anthropic) }

    static var hasKey: Bool { apiKey != nil }

    /// Saves (or replaces) the key. Passing nil or an empty string deletes it.
    @discardableResult
    static func setAPIKey(_ key: String?) -> Bool {
        write(key, service: Service.anthropic)
    }

    @discardableResult
    static func deleteAPIKey() -> Bool {
        delete(service: Service.anthropic)
    }

    // MARK: - Odysseus

    /// The bearer token for the self-hosted server (an `ody_...` string).
    static var odysseusToken: String? { read(service: Service.odysseus) }

    static var hasOdysseusToken: Bool { odysseusToken != nil }

    @discardableResult
    static func setOdysseusToken(_ token: String?) -> Bool {
        write(token, service: Service.odysseus)
    }

    @discardableResult
    static func deleteOdysseusToken() -> Bool {
        delete(service: Service.odysseus)
    }

    // MARK: - Keychain plumbing

    private static func read(service: String) -> String? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    private static func write(_ value: String?, service: String) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return delete(service: service) }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Update in place when an entry already exists; SecItemAdd would fail
        // with errSecDuplicateItem.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery(service: service) as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = baseQuery(service: service)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    private static func delete(service: String) -> Bool {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

// MARK: - Display helpers

extension String {
    /// Masked form of a credential for display: keeps the recognizable prefix
    /// and the last four characters so the lifter can tell which key is stored,
    /// without rendering the secret. Works for both `sk-ant-...` keys and
    /// `ody_...` tokens.
    var maskedAPIKey: String {
        guard count > 12 else { return String(repeating: "•", count: max(count, 8)) }
        let prefix = self.prefix(7)
        let suffix = self.suffix(4)
        return "\(prefix)••••••••••••\(suffix)"
    }
}
