// GOOP: Polar Loop lane. Compiled ONLY with -DPOLAR_ACCESSLINK (see PolarConfig.xcconfig).
#if POLAR_ACCESSLINK
import Foundation
import Security

/// Keychain wrapper for the AccessLink token — one generic-password item, never UserDefaults or disk.
/// Mirrors OuraTokenStore (delete-then-add, AfterFirstUnlockThisDeviceOnly).
enum PolarTokenStore {
    private static let service = "com.noop.polar"
    private static let account = "accesslink-token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @discardableResult
    static func save(_ tokens: PolarTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> PolarTokens? {
        var q = baseQuery
        q[kSecReturnData as String] = kCFBooleanTrue
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PolarTokens.self, from: data)
    }

    static func clear() { SecItemDelete(baseQuery as CFDictionary) }
    static var isConnected: Bool { load() != nil }
}
#endif // POLAR_ACCESSLINK
