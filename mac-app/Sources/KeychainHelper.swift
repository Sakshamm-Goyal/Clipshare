import Foundation

/// Simple storage helper using UserDefaults (for development)
/// In production, use Keychain with proper code signing
class KeychainHelper {
    private static let defaults = UserDefaults.standard
    private static let prefix = "com.clipshare."

    // MARK: - Device Token

    static func saveDeviceToken(_ token: String) {
        defaults.set(token, forKey: prefix + "deviceToken")
    }

    static func getDeviceToken() -> String? {
        return defaults.string(forKey: prefix + "deviceToken")
    }

    // MARK: - Device Keys

    static func saveDevicePrivateKey(_ keyData: Data) {
        defaults.set(keyData, forKey: prefix + "devicePrivateKey")
    }

    static func getDevicePrivateKey() -> Data? {
        return defaults.data(forKey: prefix + "devicePrivateKey")
    }

    static func saveDevicePublicKey(_ keyData: Data) {
        defaults.set(keyData, forKey: prefix + "devicePublicKey")
    }

    static func getDevicePublicKey() -> Data? {
        return defaults.data(forKey: prefix + "devicePublicKey")
    }

    // MARK: - Peer Keys

    static func savePeerPublicKey(_ keyData: Data) {
        defaults.set(keyData, forKey: prefix + "peerPublicKey")
    }

    static func getPeerPublicKey() -> Data? {
        return defaults.data(forKey: prefix + "peerPublicKey")
    }

    static func deletePeerPublicKey() {
        defaults.removeObject(forKey: prefix + "peerPublicKey")
    }

    static func deleteDeviceToken() {
        defaults.removeObject(forKey: prefix + "deviceToken")
    }

    // MARK: - Delete All

    static func deleteAll() {
        let keys = ["deviceToken", "devicePrivateKey", "devicePublicKey", "peerPublicKey"]
        for key in keys {
            defaults.removeObject(forKey: prefix + key)
        }
    }
}
