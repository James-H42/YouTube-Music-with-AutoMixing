import Foundation
import Security

/// Secrets (scrobbling sessions, tokens, pairing keys) live in the Keychain as generic
/// passwords, readable only on this device while it is unlocked. They are never written to
/// the app's data folder, so backups and copies of that folder don't contain them.
enum Keychain {
    /// Tests use another service name so they never touch real items.
    nonisolated(unsafe) static var service = "Metrolist"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves, replaces or (with nil) deletes an item.
    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
