import Foundation
import Security

/// Storage for the pairing secret and the last hub URL.
///
/// Primary store is the device Keychain with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (the app must be able to read
/// it while the wrist is down, and the secret must never leave this watch).
/// On unsigned development builds the Keychain can be unavailable, so the store
/// degrades to an Internal-free `UserDefaults` fallback and says so in `source`.
enum SecretStore {
    enum Source: String {
        case keychain
        case bundled
        case defaults
        case missing
    }

    private static let service = "me.kluser.watchpilot"
    private static let account = "totp-secret"
    private static let defaultsKey = "WPTotpSecret"

    static var source: Source {
        if keychainRead() != nil { return .keychain }
        if bundledSecret() != nil { return .bundled }
        if UserDefaults.standard.string(forKey: defaultsKey) != nil { return .defaults }
        return .missing
    }

    /// The base32 secret used to generate codes, from the most trusted source available.
    static var secret: String? {
        keychainRead() ?? bundledSecret() ?? UserDefaults.standard.string(forKey: defaultsKey)
    }

    @discardableResult
    static func save(secret: String) -> Bool {
        let clean = secret.uppercased().replacingOccurrences(of: " ", with: "")
        UserDefaults.standard.set(clean, forKey: defaultsKey)
        return keychainWrite(clean)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keychain

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainRead() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    @discardableResult
    private static func keychainWrite(_ value: String) -> Bool {
        let data = Data(value.utf8)
        SecItemDelete(keychainQuery() as CFDictionary)
        var attributes = keychainQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Demo/provisioning path: `Pairing.plist` shipped inside the app bundle by
    /// `scripts/install-app.sh` (it is git-ignored and removed after first launch).
    private static func bundledSecret() -> String? {
        guard let url = Bundle.main.url(forResource: "Pairing", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["totp_secret"] as? String
    }
}
