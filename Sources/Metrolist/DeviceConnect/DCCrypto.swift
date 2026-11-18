import CryptoKit
import Foundation

/// The cryptography of Metrolist's Device Connect protocol (version 2), written to match
/// `DeviceConnectPairing.kt` and `DeviceCrypto.kt` byte for byte: P-256 ECDH with the public key as
/// X.509 DER, HKDF-SHA256, AES-256-GCM with a 12-byte random IV in front of the ciphertext,
/// HMAC-SHA256 proofs, SHA-256 transcripts over length-prefixed parts.
enum DCRole: String {
    case initiator, responder
    var peer: DCRole { self == .initiator ? .responder : .initiator }
}

enum DCCrypto {
    static let protocolVersion = 2
    static let label = "metrolist-device-connect-v2"
    static let commitmentLabel = label + "/hello-commit"
    static let nonceBytes = 16
    static let commitmentBytes = 32
    static let maxPublicKeyBytes = 256

    // MARK: Encoding

    static func base64(_ data: Data) -> String { data.base64EncodedString() }

    /// Canonical standard Base64 only: padding where needed, nothing re-encoded differently.
    static func fromBase64(_ text: String) -> Data? {
        guard let data = Data(base64Encoded: text), data.base64EncodedString() == text else { return nil }
        return data
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "no secure random bytes")
        return Data(bytes)
    }

    static func int32(_ value: Int) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    /// Each part preceded by its length as four big-endian bytes.
    static func lengthPrefixed(_ parts: [Data]) -> Data {
        var output = Data()
        for part in parts { output += int32(part.count) + part }
        return output
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func hmac(key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Metrolist's HKDF: extract with the salt (zeros if none), expand one block.
    static func hkdf(ikm: Data, salt: Data?, info: Data) -> Data {
        let prk = hmac(key: salt ?? Data(count: 32), ikm)
        return hmac(key: prk, info + Data([1]))
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    // MARK: Hello

    struct Hello {
        var role: DCRole
        var deviceId: String
        var nonce: Data
        var publicKey: Data
    }

    static func commitment(_ hello: Hello) -> Data {
        sha256(lengthPrefixed([
            Data(commitmentLabel.utf8), int32(protocolVersion), Data(hello.role.rawValue.utf8), Data(hello.deviceId.utf8), hello.nonce, hello.publicKey,
        ]))
    }

    static func transcript(local: Hello, peer: Hello) -> Data {
        let initiator = local.role == .initiator ? local : peer
        let responder = local.role == .responder ? local : peer
        return sha256(lengthPrefixed([
            Data(label.utf8), int32(protocolVersion), commitment(initiator), commitment(responder),
            Data(initiator.role.rawValue.utf8), Data(initiator.deviceId.utf8), initiator.nonce, initiator.publicKey,
            Data(responder.role.rawValue.utf8), Data(responder.deviceId.utf8), responder.nonce, responder.publicKey,
        ]))
    }

    struct IdentityFlags {
        var fingerprint: String
        var anonymous: Bool
        var resolved: Bool
        var hasPair: Bool
        var supportsCodePairing: Bool
    }

    /// The transcript after both identities are known, used when both sides support code pairing.
    static func codePairingTranscript(hello: Data, localRole: DCRole, local: IdentityFlags, peer: IdentityFlags) -> Data {
        let initiator = localRole == .initiator ? local : peer
        let responder = localRole == .responder ? local : peer
        func metadata(_ identity: IdentityFlags) -> Data {
            lengthPrefixed([
                Data(identity.fingerprint.utf8),
                Data([identity.anonymous ? 1 : 0, identity.resolved ? 1 : 0, identity.hasPair ? 1 : 0, identity.supportsCodePairing ? 1 : 0]),
            ])
        }
        return sha256(lengthPrefixed([Data((label + "/mutual-code-pairing").utf8), hello, metadata(initiator), metadata(responder)]))
    }

    static func trafficKey(shared: Data, transcript: Data, sender: DCRole) -> Data {
        hkdf(ikm: shared, salt: transcript, info: Data("\(label)/\(sender.rawValue)".utf8))
    }

    static func pairSecret(shared: Data, transcript: Data) -> Data {
        hkdf(ikm: shared, salt: transcript, info: Data("\(label)/pair-secret".utf8))
    }

    /// The six digits both people compare.
    static func sas(pairSecret: Data) -> String {
        let bytes = hmac(key: pairSecret, Data("\(label)/sas".utf8))
        let value = (UInt64(bytes[0]) << 24) | (UInt64(bytes[1]) << 16) | (UInt64(bytes[2]) << 8) | UInt64(bytes[3])
        return String(format: "%06d", Int(value % 1_000_000))
    }

    static func proof(secret: Data, phase: String, sender: DCRole, senderId: String, receiverId: String, transcript: Data) -> String {
        base64(hmac(key: secret, lengthPrefixed([
            Data(label.utf8), Data(phase.utf8), Data(sender.rawValue.utf8), Data(senderId.utf8), Data(receiverId.utf8), transcript,
        ])))
    }

    static func proofMatches(secret: Data, proof claimed: String, phase: String, sender: DCRole, senderId: String, receiverId: String, transcript: Data) -> Bool {
        guard let actual = fromBase64(claimed) else { return false }
        let expected = fromBase64(proof(secret: secret, phase: phase, sender: sender, senderId: senderId, receiverId: receiverId, transcript: transcript))!
        return constantTimeEquals(expected, actual)
    }

    static func accountFingerprint(_ scope: String) -> String {
        base64(sha256(Data("\(label)/account-scope/\(scope)".utf8)))
    }

    // MARK: Frames

    static func aad(type: String, seq: Int64) -> Data { Data("\(label):\(type):\(seq)".utf8) }

    /// IV (12) ‖ ciphertext ‖ tag.
    static func seal(key: Data, plaintext: Data, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(), authenticating: aad)
        guard let combined = box.combined else { throw DCError.crypto }
        return combined
    }

    static func open(key: Data, data: Data, aad: Data) throws -> Data {
        guard data.count > 12 else { throw DCError.crypto }
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    // MARK: Keys

    static func newKeyPair() -> P256.KeyAgreement.PrivateKey { P256.KeyAgreement.PrivateKey() }

    static func publicKeyDER(_ key: P256.KeyAgreement.PrivateKey) -> Data { key.publicKey.derRepresentation }

    static func sharedSecret(private key: P256.KeyAgreement.PrivateKey, peerPublicDER: Data) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(derRepresentation: peerPublicDER)
        return try key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
    }
}

enum DCError: Error { case crypto, protocolViolation(String) }

/// Device ids are letters, digits, "-" and "_", up to 128 characters.
func dcIsValidDeviceId(_ value: String) -> Bool {
    (1 ... 128).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
}

/// Names are shown to people and sent over the network: printable text only, and short.
func dcSanitizeDeviceName(_ value: String) -> String {
    String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init).prefix(64)).trimmingCharacters(in: .whitespaces)
}
