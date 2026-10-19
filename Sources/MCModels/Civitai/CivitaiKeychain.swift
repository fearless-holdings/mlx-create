import Foundation
import Security

/// Stores the optional Civitai API key in the login Keychain (HLD D15, AGENTS.md non-negotiable 7). The key value is
/// never logged, and no error carries it.
public struct CivitaiKeychain: Sendable {
    /// The app's own service name. Tests inject another, so they never touch the saved key.
    public static let defaultService = "app.mlx-create.civitai"
    private static let account = "api-key"

    public let service: String

    public init(service: String = CivitaiKeychain.defaultService) {
        self.service = service
    }

    /// The saved key, or nil when none is saved.
    public func read() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CivitaiKeychainError.status(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw CivitaiKeychainError.status(errSecDecode)
        }
        return key
    }

    /// Saves `key`, replacing any key already saved.
    public func write(_ key: String) throws {
        let data = Data(key.utf8)
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw CivitaiKeychainError.status(updateStatus) }

        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CivitaiKeychainError.status(addStatus) }
    }

    /// Removes the saved key. Succeeds when none is saved.
    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CivitaiKeychainError.status(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}

/// A Keychain call failed. The message names the status only, never the key.
public enum CivitaiKeychainError: Error, Sendable, Equatable, LocalizedError {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .status(let status):
            return "Couldn't access the Keychain for your Civitai key (status \(status))."
        }
    }
}
