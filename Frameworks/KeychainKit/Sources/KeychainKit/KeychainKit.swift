import Foundation
import Security

/// Errors thrown by `KeychainKit`.
public enum KeychainError: Error, Equatable {
    /// The stored item was not valid UTF-8 string data.
    case unexpectedData
    /// Any `OSStatus` not handled explicitly.
    case unhandled(status: OSStatus)
}

/// Thin wrapper over `SecItem` for generic-password items.
///
/// Zero dependencies beyond the Security framework. Items are scoped by
/// `(service, account)`; callers own the meaning of those keys.
public enum KeychainKit {
    /// Saves a password, overwriting any existing item for the same key.
    ///
    /// Items are accessible after the first unlock and never migrate to a
    /// new device via backup (`AfterFirstUnlockThisDeviceOnly`).
    public static func savePassword(_ password: String, service: String, account: String) throws {
        var attributes = baseQuery(service: service, account: account)
        // Simplest correct upsert: delete-then-add. A delete failure other
        // than "not found" must surface, not be silently added on top of.
        let deleteStatus = SecItemDelete(attributes as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.unhandled(status: deleteStatus)
        }

        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status: status)
        }
    }

    /// Reads a password. Returns `nil` when no item exists for the key.
    public static func readPassword(service: String, account: String) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status: status)
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return password
    }

    /// Deletes the item for the key. Missing items are not an error.
    public static func deletePassword(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status: status)
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
