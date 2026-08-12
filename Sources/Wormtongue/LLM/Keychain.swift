import Foundation
import Security
import WormtongueCore

/// API keys live in the Keychain, never in the JSON config (§7 of the brief).
///
/// Keyed providers each get their own Keychain item, keyed by the provider kind.
/// `ANTHROPIC_API_KEY` is honoured as a read-only fallback for the Anthropic
/// provider so `swift run` works before the Keychain item exists. Subscription
/// providers store nothing here at all.
enum Keychain {
    private static let service = "com.wormtongue.wormtongue"

    /// The stored (or, for Anthropic, env-fallback) key for a keyed provider.
    static func apiKey(for kind: ProviderKind) -> String? {
        guard kind.isKeyed else { return nil }
        if let stored = read(kind: kind), !stored.isEmpty { return stored }
        if kind == .anthropicKeyed,
            let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
            !env.isEmpty
        {
            return env
        }
        return nil
    }

    static func hasStoredKey(kind: ProviderKind) -> Bool {
        guard kind.isKeyed else { return false }
        return read(kind: kind) != nil
    }

    static func read(kind: ProviderKind) -> String? {
        guard kind.isKeyed else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: kind),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String, kind: ProviderKind) -> Bool {
        guard kind.isKeyed else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: kind),
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(kind: ProviderKind) -> Bool {
        guard kind.isKeyed else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: kind),
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func account(for kind: ProviderKind) -> String {
        switch kind {
        case .anthropicKeyed: return "anthropic-api-key"
        case .openAICompatible: return "openai-api-key"
        case .claudeSubscription, .codexSubscription: return "unused-subscription"
        }
    }

    // MARK: - Anthropic convenience (the pre-provider keyed path)

    static func apiKey() -> String? { apiKey(for: .anthropicKeyed) }

    static var hasStoredKey: Bool { hasStoredKey(kind: .anthropicKeyed) }

    @discardableResult
    static func save(_ key: String) -> Bool { save(key, kind: .anthropicKeyed) }

    @discardableResult
    static func delete() -> Bool { delete(kind: .anthropicKeyed) }
}
