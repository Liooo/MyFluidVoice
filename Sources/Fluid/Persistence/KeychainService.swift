import Foundation
import Security

enum KeychainServiceError: Error, LocalizedError {
    case invalidData
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Failed to convert key data."
        case let .unhandled(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "\(message) (OSStatus: \(status))"
            }
            return "Unhandled Keychain error (OSStatus: \(status))"
        }
    }
}

/// Lightweight helper for storing provider API keys in the system Keychain.
/// Keys retain FluidVoice's service identity so existing installations keep access after upgrade.
final class KeychainService {
    static let shared = KeychainService()

    // Keep the upstream service identity so an in-place fork upgrade retains API keys.
    private let service = "com.fluidvoice.provider-api-keys"
    private let account = "fluidApiKeys"

    private init() {}

    // MARK: - Public API

    func storeKey(_ key: String, for providerID: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var keys = try loadStoredKeys()
        keys[providerID] = trimmed
        try Self.performProviderMutation(
            requiredCleanup: { try self.removeLegacyEntries(providerIDs: [providerID]) },
            primary: { try self.writeStoredKeys(keys) },
            cleanup: { try self.removeLegacyEntries() }
        )
    }

    func fetchKey(for providerID: String) throws -> String? {
        let keys = try loadStoredKeys()
        return keys[providerID]
    }

    func deleteKey(for providerID: String) throws {
        var keys = try loadStoredKeys()
        let shouldCommit = keys.removeValue(forKey: providerID) != nil
        try Self.performProviderMutation(
            requiredCleanup: { try self.removeLegacyEntries(providerIDs: [providerID]) },
            primary: shouldCommit ? { try self.writeStoredKeys(keys) } : nil,
            cleanup: { try self.removeLegacyEntries() }
        )
    }

    func containsKey(for providerID: String) -> Bool {
        guard let keys = try? loadStoredKeys() else { return false }
        return keys[providerID] != nil
    }

    func allProviderIDs() throws -> [String] {
        return try self.loadStoredKeys().keys.sorted()
    }

    func fetchAllKeys() throws -> [String: String] {
        try self.loadStoredKeys()
    }

    func fetchAllKeysWithPresence() throws -> (exists: Bool, values: [String: String]) {
        try self.loadStoredKeysWithPresence()
    }

    func storeAllKeys(_ values: [String: String]) throws {
        try self.saveStoredKeys(values)
    }

    func storeUnreservedKeys(_ values: [String: String]) throws {
        let existing = try self.loadStoredKeys()
        try self.saveStoredKeys(Self.replacingUnreservedKeys(existing: existing, replacements: values))
    }

    nonisolated static func performCommittedMutation(
        primary: () throws -> Void,
        cleanup: () throws -> Void
    ) throws {
        try primary()
        _ = try? cleanup()
    }

    nonisolated static func performProviderMutation(
        requiredCleanup: () throws -> Void,
        primary: (() throws -> Void)?,
        cleanup: () throws -> Void
    ) throws {
        try requiredCleanup()
        guard let primary else { return }
        try Self.performCommittedMutation(primary: primary, cleanup: cleanup)
    }

    nonisolated static func unreservedKeys(
        _ values: [String: String],
        reservedPrefix: String = "asr:"
    ) -> [String: String] {
        values.filter { $0.key.hasPrefix(reservedPrefix) == false }
    }

    nonisolated static func replacingUnreservedKeys(
        existing: [String: String],
        replacements: [String: String],
        reservedPrefix: String = "asr:"
    ) -> [String: String] {
        var result = existing.filter { $0.key.hasPrefix(reservedPrefix) }
        result.merge(replacements.filter { $0.key.hasPrefix(reservedPrefix) == false }) { _, new in new }
        return result
    }

    nonisolated static func authoritativeProviderKeys(
        aggregateExists: Bool,
        aggregate: [String: String],
        legacy: [String: String]
    ) -> [String: String] {
        aggregateExists ? aggregate : legacy
    }

    func legacyProviderEntries() throws -> [String: String] {
        var result: [String: String] = [:]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)

        switch status {
        case errSecSuccess:
            guard let attributesArray = items as? [[String: Any]] else { return [:] }
            for attributes in attributesArray {
                guard let providerID = attributes[kSecAttrAccount as String] as? String,
                      providerID != account
                else {
                    continue
                }

                var dataQuery = self.legacyQuery(for: providerID)
                dataQuery[kSecReturnData as String] = true
                dataQuery[kSecMatchLimit as String] = kSecMatchLimitOne

                var dataItem: CFTypeRef?
                let dataStatus = SecItemCopyMatching(dataQuery as CFDictionary, &dataItem)
                guard dataStatus == errSecSuccess else {
                    if dataStatus == errSecItemNotFound {
                        continue
                    }
                    throw KeychainServiceError.unhandled(dataStatus)
                }
                guard let data = dataItem as? Data,
                      let key = String(data: data, encoding: .utf8)
                else {
                    continue
                }
                result[providerID] = key
            }
            return result
        case errSecItemNotFound:
            return [:]
        default:
            throw KeychainServiceError.unhandled(status)
        }
    }

    func removeLegacyEntries(providerIDs: [String] = []) throws {
        let targets: [String]
        if !providerIDs.isEmpty {
            targets = providerIDs
        } else {
            targets = try Array((self.legacyProviderEntries()).keys)
        }

        for providerID in targets {
            let status = SecItemDelete(legacyQuery(for: providerID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainServiceError.unhandled(status)
            }
        }
    }

    // MARK: - Private helpers

    private func loadStoredKeys() throws -> [String: String] {
        try self.loadStoredKeysWithPresence().values
    }

    private func loadStoredKeysWithPresence() throws -> (exists: Bool, values: [String: String]) {
        var query = self.aggregatedQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainServiceError.invalidData
            }
            if data.isEmpty {
                return (exists: true, values: [:])
            }
            do {
                let values = try JSONDecoder().decode([String: String].self, from: data)
                return (exists: true, values: values)
            } catch {
                throw KeychainServiceError.invalidData
            }
        case errSecItemNotFound:
            return (exists: false, values: [:])
        default:
            throw KeychainServiceError.unhandled(status)
        }
    }

    private func saveStoredKeys(_ keys: [String: String]) throws {
        try Self.performCommittedMutation(
            primary: { try self.writeStoredKeys(keys) },
            cleanup: {
                try self.removeLegacyEntries()
            }
        )
    }

    private func writeStoredKeys(_ keys: [String: String]) throws {
        let data = try JSONEncoder().encode(keys)

        var attributes = self.aggregatedQuery()
        attributes[kSecValueData as String] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
            ]
            let updateStatus = SecItemUpdate(
                self.aggregatedQuery() as CFDictionary,
                updateAttributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainServiceError.unhandled(updateStatus)
            }
        default:
            throw KeychainServiceError.unhandled(status)
        }
    }

    private func aggregatedQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
    }

    private func legacyQuery(for providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: providerID,
        ]
    }
}
