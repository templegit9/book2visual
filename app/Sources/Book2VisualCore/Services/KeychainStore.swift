import Foundation
import Security

/// Abstraction over the Keychain so tests can use an in-memory store.
public protocol SecretStore: Sendable {
    func set(_ value: String, for account: String) throws
    func get(_ account: String) throws -> String?
    func delete(_ account: String) throws
    func setData(_ value: Data, for account: String) throws
    func getData(_ account: String) throws -> Data?
}

/// Stores the Thunder API token and the SSH private key via the Security framework.
/// Service id: `book2visual.thunder`.
public struct KeychainStore: SecretStore {
    public static let service = "book2visual.thunder"

    // Well-known account names.
    public static let thunderTokenAccount = "thunder.api.token"
    public static let sshPrivateKeyAccount = "ssh.private.key"
    public static let sshKeyPassphraseAccount = "ssh.key.passphrase"
    public static let instanceIdAccount = "thunder.instance.id"

    private let service: String

    public init(service: String = KeychainStore.service) {
        self.service = service
    }

    public func set(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }
        try setData(data, for: account)
    }

    public func get(_ account: String) throws -> String? {
        guard let data = try getData(account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setData(_ value: Data, for account: String) throws {
        var query = baseQuery(account)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: value]
            let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        } else if status == errSecItemNotFound {
            query[kSecValueData as String] = value
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func getData(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Thread-safe in-memory SecretStore for tests/offline.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func set(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }
        try setData(data, for: account)
    }

    public func get(_ account: String) throws -> String? {
        guard let data = try getData(account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setData(_ value: Data, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = value
    }

    public func getData(_ account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    public func delete(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = nil
    }
}
