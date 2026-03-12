import Foundation
import Security

struct KeychainCredentialStore: CredentialStore {
    private let service = "com.gongxun.QuotaBar.codex-auth"

    func save(authData: Data, for accountID: UUID) async throws {
        let query = baseQuery(for: accountID)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData] = authData
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func loadAuthData(for accountID: UUID) async throws -> Data {
        var query = lookupQuery(for: accountID)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        return data
    }

    func deleteAuthData(for accountID: UUID) async throws {
        let status = SecItemDelete(baseQuery(for: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for accountID: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: accountID.uuidString as CFString,
        ]
    }

    private func lookupQuery(for accountID: UUID) -> [CFString: Any] {
        baseQuery(for: accountID)
    }
}

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain error (\(status))"
        }
    }
}
