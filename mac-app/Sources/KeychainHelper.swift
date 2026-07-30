import Foundation
import Security

/// Stores all long-lived device secrets in the macOS Keychain. Clipboard
/// routes are encrypted independently and are never stored here.
enum KeychainHelper {
    private static let service = "com.clipshare.desktop"
    private static let legacyPrefix = "com.clipshare."

    static func saveDeviceToken(_ token: String) {
        save(Data(token.utf8), account: "deviceToken")
    }

    static func getDeviceToken() -> String? {
        get(account: "deviceToken").flatMap { String(data: $0, encoding: .utf8) }
    }

    static func saveDevicePrivateKey(_ keyData: Data) { save(keyData, account: "devicePrivateKey") }
    static func getDevicePrivateKey() -> Data? { get(account: "devicePrivateKey") }
    static func saveDevicePublicKey(_ keyData: Data) { save(keyData, account: "devicePublicKey") }
    static func getDevicePublicKey() -> Data? { get(account: "devicePublicKey") }
    static func savePeerPublicKey(_ keyData: Data) { save(keyData, account: "peerPublicKey") }
    static func getPeerPublicKey() -> Data? { get(account: "peerPublicKey") }
    static func deletePeerPublicKey() { delete(account: "peerPublicKey") }
    static func deleteDeviceToken() { delete(account: "deviceToken") }

    static func deleteAll() {
        ["deviceToken", "devicePrivateKey", "devicePublicKey", "peerPublicKey"].forEach { delete(account: $0) }
    }

    private static func save(_ data: Data, account: String) {
        delete(account: account)
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess { NSLog("Keychain save failed for %@: %d", account, status) }
    }

    private static func get(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess { return result as? Data }

        // Migrate development builds that previously wrote secrets to
        // UserDefaults, then delete that insecure copy immediately.
        let legacyKey = legacyPrefix + account
        let legacyData = UserDefaults.standard.data(forKey: legacyKey)
            ?? UserDefaults.standard.string(forKey: legacyKey).flatMap { $0.data(using: .utf8) }
        guard let legacyData else { return nil }
        save(legacyData, account: account)
        UserDefaults.standard.removeObject(forKey: legacyKey)
        return legacyData
    }

    private static func delete(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("Keychain delete failed for %@: %d", account, status)
        }
    }
}
