import Foundation
import Security

/// Local keychain storage. No App Intent reads or returns these values.
enum SecretStore {
    // Preserve the existing app's storage namespace, independent of bundle ID.
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.dotprototype.PhoneAgent",
         kSecAttrAccount as String: account]
    }
    static func load(_ account: String) throws -> String? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw AppError.unavailable(String(localized: "Could not read the keychain"))
        }
        return value
    }
    static func contains(_ account: String) throws -> Bool {
        var attributes = query(account)
        attributes[kSecReturnData as String] = false
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(attributes as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw AppError.unavailable(String(localized: "Could not check the keychain")) }
        return true
    }
    static func save(_ value: String, account: String) throws {
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(account).merging(update) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError.unavailable(String(localized: "Could not save to the keychain")) }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.unavailable(String(localized: "Could not delete the keychain item"))
        }
    }
}
