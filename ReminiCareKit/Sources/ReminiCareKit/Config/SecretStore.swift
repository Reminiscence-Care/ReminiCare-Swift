import Foundation
import Security

public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ key: String, value: String) throws
    func delete(_ key: String) throws
}

public struct KeychainError: Error, Sendable {
    public let status: OSStatus
}

/// Generic-password Keychain items, one per setting key.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public init(service: String = "xyz.jessyu.reminicare.settings") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func read(_ key: String) throws -> String? {
        var item: CFTypeRef?
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ key: String, value: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = query(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// In-memory store for tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let values = LockedValue<[String: String]>([:])
    public var failWrites = false
    public init(_ initial: [String: String] = [:]) {
        values.withValue { $0 = initial }
    }
    public func read(_ key: String) throws -> String? { values.current[key] }
    public func write(_ key: String, value: String) throws {
        if failWrites { throw KeychainError(status: errSecIO) }
        values.withValue { $0[key] = value }
    }
    public func delete(_ key: String) throws {
        values.withValue { _ = $0.removeValue(forKey: key) }
    }
}
