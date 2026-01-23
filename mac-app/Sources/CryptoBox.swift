import Foundation
import Crypto

// Plaintext message structure
struct PlainItem: Codable {
    let id: String
    let seq: Int
    let tsMs: Int64
    let kind: String
    let payload: Payload
    let meta: Meta?

    struct Payload: Codable {
        let type: String
        let size: Int
        let text: String
    }

    struct Meta: Codable {
        let app: String?
        let network: String?
        let lang: String?
    }

    var preview: String {
        let text = payload.text
        if text.count > 50 {
            return String(text.prefix(47)) + "..."
        }
        return text
    }

    var sourceName: String? {
        return meta?.app
    }
}

// Encrypted envelope
struct Envelope: Codable {
    let v: Int
    let from: String
    let to: String
    let nonce: String
    let ciphertext: String
    let ad: String?
}

class CryptoBox {
    // Use KeyAgreement keys for ECDH (not Signing keys)
    private var devicePrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var peerPublicKey: Curve25519.KeyAgreement.PublicKey?
    private var sessionKey: SymmetricKey?
    private var seq: Int = 0

    // Key derivation info for HKDF
    private let hkdfInfo = "ClipShare-E2E-v1".data(using: .utf8)!
    private let hkdfSalt = "ClipShare-Salt-2024".data(using: .utf8)!

    init() {
        loadKeys()
    }

    // MARK: - Key Management

    func loadKeys() {
        // Load device private key from Keychain
        if let keyData = KeychainHelper.getDevicePrivateKey() {
            do {
                devicePrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
                print("✓ Loaded existing device key")
            } catch {
                print("✗ Failed to load device key: \(error)")
                generateNewDeviceKey()
            }
        } else {
            generateNewDeviceKey()
        }

        // Load peer public key and derive session key if available
        if let peerKeyData = KeychainHelper.getPeerPublicKey() {
            do {
                peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKeyData)
                try deriveSessionKey()
                print("✓ Loaded peer key and derived session key")
            } catch {
                print("✗ Failed to load peer key: \(error)")
            }
        }
    }

    func generateNewDeviceKey() {
        // Generate Curve25519 KeyAgreement key (for ECDH)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        devicePrivateKey = privateKey

        // Save private key to Keychain
        KeychainHelper.saveDevicePrivateKey(privateKey.rawRepresentation)

        // Save public key for sharing during pairing
        let publicKey = privateKey.publicKey
        KeychainHelper.saveDevicePublicKey(publicKey.rawRepresentation)

        print("✓ Generated new Curve25519 KeyAgreement keypair")
    }

    func setPeerPublicKey(_ keyData: Data) throws {
        // Parse and validate peer's public key
        peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)

        // Save to Keychain for persistence
        KeychainHelper.savePeerPublicKey(keyData)

        // Derive session key using ECDH
        try deriveSessionKey()

        print("✓ Peer public key set and session key derived")
    }

    func setPeerPublicKeyBase64(_ base64Key: String) throws {
        guard let keyData = Data(base64Encoded: base64Key) else {
            throw CryptoError.invalidPublicKey
        }
        try setPeerPublicKey(keyData)
    }

    func deriveSessionKey() throws {
        guard let privateKey = devicePrivateKey else {
            throw CryptoError.noDeviceKey
        }
        guard let peerKey = peerPublicKey else {
            throw CryptoError.noPeerKey
        }

        // Perform ECDH key agreement
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)

        // Derive session key using HKDF-SHA256
        // This produces a cryptographically secure key from the shared secret
        sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSalt,
            sharedInfo: hkdfInfo,
            outputByteCount: 32  // 256-bit key for ChaChaPoly
        )

        print("✓ Session key derived via ECDH + HKDF-SHA256")
    }

    func getPublicKeyBase64() -> String? {
        guard let devicePrivateKey = devicePrivateKey else { return nil }
        return devicePrivateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    func getPublicKeyData() -> Data? {
        guard let devicePrivateKey = devicePrivateKey else { return nil }
        return devicePrivateKey.publicKey.rawRepresentation
    }

    func hasSessionKey() -> Bool {
        return sessionKey != nil
    }

    func hasPeerKey() -> Bool {
        return peerPublicKey != nil
    }

    // Clear all keys (for unpairing)
    func clearKeys() {
        peerPublicKey = nil
        sessionKey = nil
        KeychainHelper.deletePeerPublicKey()
        print("✓ Cleared peer key and session key")
    }

    // MARK: - Encryption / Decryption

    func encrypt(_ item: PlainItem) throws -> Envelope {
        guard let sessionKey = sessionKey else {
            throw CryptoError.noSessionKey
        }

        // Encode plaintext to JSON
        let jsonData = try JSONEncoder().encode(item)

        // Generate random nonce (12 bytes for ChaChaPoly)
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        let result = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        guard result == errSecSuccess else {
            throw CryptoError.encryptionFailed
        }
        let nonce = try ChaChaPoly.Nonce(data: Data(nonceBytes))

        // Encrypt with ChaChaPoly (includes authentication tag)
        let sealedBox = try ChaChaPoly.seal(jsonData, using: sessionKey, nonce: nonce)

        let deviceID = UserDefaults.standard.string(forKey: "deviceID") ?? "unknown"
        let peerDeviceID = UserDefaults.standard.string(forKey: "peerDeviceID") ?? "unknown"

        // Combine ciphertext and tag for transport
        var combined = Data(sealedBox.ciphertext)
        combined.append(contentsOf: sealedBox.tag)

        return Envelope(
            v: 1,
            from: deviceID,
            to: peerDeviceID,
            nonce: Data(nonceBytes).base64EncodedString(),
            ciphertext: combined.base64EncodedString(),
            ad: nil
        )
    }

    func encryptToJSON(_ item: PlainItem) throws -> String {
        let envelope = try encrypt(item)
        let jsonData = try JSONEncoder().encode(envelope)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw CryptoError.encryptionFailed
        }
        return jsonString
    }

    func decrypt(_ envelopeData: String) throws -> PlainItem {
        guard let sessionKey = sessionKey else {
            throw CryptoError.noSessionKey
        }

        // Decode envelope JSON
        guard let jsonData = envelopeData.data(using: .utf8) else {
            throw CryptoError.invalidCiphertext
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: jsonData)

        // Decode nonce
        guard let nonceData = Data(base64Encoded: envelope.nonce),
              nonceData.count == 12 else {
            throw CryptoError.invalidNonce
        }
        let nonce = try ChaChaPoly.Nonce(data: nonceData)

        // Decode combined ciphertext + tag
        guard let combinedData = Data(base64Encoded: envelope.ciphertext),
              combinedData.count > 16 else {
            throw CryptoError.invalidCiphertext
        }

        // Split ciphertext and tag (tag is last 16 bytes)
        let ciphertext = combinedData.prefix(combinedData.count - 16)
        let tag = combinedData.suffix(16)

        // Create sealed box and decrypt
        let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plainData = try ChaChaPoly.open(sealedBox, using: sessionKey)

        // Decode plain item
        let plainItem = try JSONDecoder().decode(PlainItem.self, from: plainData)

        return plainItem
    }

    func decryptEnvelope(_ envelope: Envelope) throws -> PlainItem {
        let jsonData = try JSONEncoder().encode(envelope)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw CryptoError.decryptionFailed
        }
        return try decrypt(jsonString)
    }

    // MARK: - Helper Methods

    func createPlainItem(text: String) -> PlainItem {
        seq += 1
        return PlainItem(
            id: UUID().uuidString,
            seq: seq,
            tsMs: Int64(Date().timeIntervalSince1970 * 1000),
            kind: "clipboard_item",
            payload: PlainItem.Payload(
                type: "text/plain",
                size: text.utf8.count,
                text: text
            ),
            meta: PlainItem.Meta(
                app: "ClipShare-Mac@1.0.0",
                network: getNetworkType(),
                lang: Locale.current.language.languageCode?.identifier
            )
        )
    }

    private func getNetworkType() -> String {
        // Simple network type detection
        return "wifi" // Could be enhanced with actual network detection
    }
}

enum CryptoError: Error, LocalizedError {
    case noSessionKey
    case noDeviceKey
    case noPeerKey
    case invalidNonce
    case invalidCiphertext
    case invalidPublicKey
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .noSessionKey: return "No session key available. Please pair devices first."
        case .noDeviceKey: return "Device key not found. Please restart the app."
        case .noPeerKey: return "Peer public key not set. Please pair devices first."
        case .invalidNonce: return "Invalid nonce in encrypted message."
        case .invalidCiphertext: return "Invalid ciphertext format."
        case .invalidPublicKey: return "Invalid public key format."
        case .encryptionFailed: return "Encryption failed."
        case .decryptionFailed: return "Decryption failed. Message may be corrupted."
        }
    }
}
