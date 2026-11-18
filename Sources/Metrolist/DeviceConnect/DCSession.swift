import CryptoKit
import Foundation

// MARK: - Wire format

struct DCWire: Codable {
    var type: String
    var payload: String
    var version = 0
    var encrypted = false
    var seq: Int64 = 0

    init(type: String, payload: String, version: Int, encrypted: Bool, seq: Int64) {
        self.type = type; self.payload = payload; self.version = version; self.encrypted = encrypted; self.seq = seq
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        payload = try c.decode(String.self, forKey: .payload)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        encrypted = try c.decodeIfPresent(Bool.self, forKey: .encrypted) ?? false
        seq = try c.decodeIfPresent(Int64.self, forKey: .seq) ?? 0
    }
}

enum DCType {
    static let helloCommit = "hello_commit", hello = "hello", identity = "identity", pairProof = "pair_proof", pairRequest = "pair_request"
    static let pairApprove = "pair_approve", pairCommit = "pair_commit", authResult = "auth_result", deviceInfo = "device_info"
    static let playback = "playback", ping = "ping", pong = "pong", bye = "bye"
    static let encrypted: Set<String> = [identity, pairProof, pairRequest, pairApprove, pairCommit, authResult, deviceInfo, playback, ping, pong, bye]
}

struct DCHelloCommit: Codable { var version: Int; var role: String; var deviceId: String; var commitment: String }
struct DCHello: Codable { var version: Int; var role: String; var deviceId: String; var nonce: String; var publicKey: String }
struct DCIdentity: Codable {
    var fingerprint: String; var accountProof: String; var anonymous: Bool; var resolved: Bool; var hasPair: Bool; var supportsCodePairing: Bool
    init(fingerprint: String, accountProof: String, anonymous: Bool, resolved: Bool, hasPair: Bool, supportsCodePairing: Bool) {
        self.fingerprint = fingerprint; self.accountProof = accountProof; self.anonymous = anonymous; self.resolved = resolved; self.hasPair = hasPair; self.supportsCodePairing = supportsCodePairing
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        accountProof = try c.decodeIfPresent(String.self, forKey: .accountProof) ?? ""
        anonymous = try c.decode(Bool.self, forKey: .anonymous)
        resolved = try c.decode(Bool.self, forKey: .resolved)
        hasPair = try c.decode(Bool.self, forKey: .hasPair)
        supportsCodePairing = try c.decodeIfPresent(Bool.self, forKey: .supportsCodePairing) ?? false
    }
}
struct DCProofPayload: Codable { var deviceId: String; var proof: String }
struct DCAuthResult: Codable {
    var accepted: Bool; var reason: String
    init(accepted: Bool, reason: String) { self.accepted = accepted; self.reason = reason }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try c.decode(Bool.self, forKey: .accepted)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}
struct DCDeviceInfo: Codable {
    var deviceId: String; var deviceName: String; var model: String; var playbackVersion: Int
    var supportsPlaybackClock: Bool; var supportsPlaybackPitch: Bool; var deviceType: String
    init(deviceId: String, deviceName: String, model: String, playbackVersion: Int, supportsPlaybackClock: Bool, supportsPlaybackPitch: Bool, deviceType: String) {
        self.deviceId = deviceId; self.deviceName = deviceName; self.model = model; self.playbackVersion = playbackVersion
        self.supportsPlaybackClock = supportsPlaybackClock; self.supportsPlaybackPitch = supportsPlaybackPitch; self.deviceType = deviceType
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        model = try c.decode(String.self, forKey: .model)
        playbackVersion = try c.decodeIfPresent(Int.self, forKey: .playbackVersion) ?? 0
        supportsPlaybackClock = try c.decodeIfPresent(Bool.self, forKey: .supportsPlaybackClock) ?? false
        supportsPlaybackPitch = try c.decodeIfPresent(Bool.self, forKey: .supportsPlaybackPitch) ?? false
        deviceType = try c.decodeIfPresent(String.self, forKey: .deviceType) ?? "unknown"
    }
}
struct DCPing: Codable { var t: Int64 }
struct DCBye: Codable {
    var reason = ""
    init() {}
    init(from decoder: Decoder) throws { reason = (try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .reason)) ?? "" }
}
struct DCChunk: Codable { var messageId: String; var index: Int; var count: Int; var totalBytes: Int; var data: String }

// MARK: - Playback chunks

enum DCPlaybackLimits {
    static let version = 4
    static let chunkBytes = 24 * 1024
    static let maxBytes = 8 * 1024 * 1024
    static let timeout: TimeInterval = 10
    static let maxFrameBytes = 64 * 1024
}

func dcChunks(_ bytes: Data) -> [DCChunk] {
    precondition(!bytes.isEmpty && bytes.count <= DCPlaybackLimits.maxBytes)
    let id = DCCrypto.base64(DCCrypto.randomBytes(16))
    let count = (bytes.count + DCPlaybackLimits.chunkBytes - 1) / DCPlaybackLimits.chunkBytes
    return (0 ..< count).map { index in
        let start = index * DCPlaybackLimits.chunkBytes
        return DCChunk(messageId: id, index: index, count: count, totalBytes: bytes.count, data: DCCrypto.base64(bytes[start ..< min(start + DCPlaybackLimits.chunkBytes, bytes.count)]))
    }
}

/// Puts chunks back together, applying every check Metrolist's assembler does.
struct DCAssembler {
    private var header: DCChunk?
    private var buffer = Data()
    private var next = 0
    private var deadline = Date.distantPast
    var pending: Bool { header != nil }

    mutating func clear() { header = nil; buffer = Data(); next = 0 }

    mutating func accept(_ chunk: DCChunk, now: Date = Date()) throws -> Data? {
        do {
            if pending, now >= deadline { throw DCError.protocolViolation("playback assembly timed out") }
            guard (1 ... DCPlaybackLimits.maxBytes).contains(chunk.totalBytes),
                  chunk.count == (chunk.totalBytes + DCPlaybackLimits.chunkBytes - 1) / DCPlaybackLimits.chunkBytes,
                  (0 ..< chunk.count).contains(chunk.index), chunk.messageId.count == 24,
                  let id = DCCrypto.fromBase64(chunk.messageId), id.count == 16
            else { throw DCError.protocolViolation("bad chunk") }
            let expected = min(DCPlaybackLimits.chunkBytes, chunk.totalBytes - chunk.index * DCPlaybackLimits.chunkBytes)
            guard chunk.data.count == (expected + 2) / 3 * 4, let decoded = DCCrypto.fromBase64(chunk.data), decoded.count == expected else { throw DCError.protocolViolation("bad chunk data") }
            if !pending {
                guard chunk.index == 0 else { throw DCError.protocolViolation("chunk out of order") }
                header = chunk
                buffer = Data(count: chunk.totalBytes)
                deadline = now.addingTimeInterval(DCPlaybackLimits.timeout)
            }
            guard let first = header, chunk.messageId == first.messageId, chunk.count == first.count, chunk.totalBytes == first.totalBytes, chunk.index == next else {
                throw DCError.protocolViolation("chunk out of order")
            }
            buffer.replaceSubrange(chunk.index * DCPlaybackLimits.chunkBytes ..< chunk.index * DCPlaybackLimits.chunkBytes + expected, with: decoded)
            next += 1
            if next == chunk.count { defer { clear() }; return buffer }
            return nil
        } catch {
            clear()
            throw error
        }
    }
}

// MARK: - Session

struct DCLocal {
    var deviceId: String
    var name: String
    var model: String
    var deviceType: String
    var fingerprint: String
    var anonymous: Bool
    var resolved: Bool
    var supportsCodePairing = true
}

struct DCPair: Codable {
    var peerId: String
    var peerName: String
    var peerModel: String
    var fingerprint: String
    var anonymous: Bool
    var secret: Data
}

protocol DCPairStore: AnyObject {
    func find(peerId: String, fingerprint: String, anonymous: Bool) -> DCPair?
    func save(_ pair: DCPair) -> Bool
}

struct DCPairingRequest: Equatable {
    var requestId: String
    var peerId: String
    var peerName: String
    var sas: String
    var expires: Date
}

/// One connection, in either role. The Mac only ever answers (responder); the initiator half
/// is here so tests can play the phone. Everything is driven from the main actor.
@MainActor
final class DCSession {
    enum Phase { case handshaking, pairing, connected, closed }

    let role: DCRole
    private var local: DCLocal
    /// Shared-queue guests only, and only if the host allows it: this side waits for the phone's
    /// identity and presents the same account in reply, so a phone signed in to its own YouTube
    /// account can pair (Metrolist pairs only devices that present the same account). Nothing
    /// about any account is exchanged either way: with code pairing the account is just a label
    /// both sides must agree on; the six digits approved on both screens are what authorise.
    var mirrorPeerAccount = false
    private(set) var mirroredAccount = false
    private let store: DCPairStore
    private let send: (String) -> Void
    private let closeTransport: () -> Void
    let connectionId = UUID().uuidString
    private(set) var phase = Phase.handshaking
    private(set) var peerId: String?
    private(set) var peerName = ""
    private(set) var peerModel = ""
    private(set) var peerType = "unknown"
    private(set) var peerPlaybackVersion = 0

    /// Callbacks into the app.
    var allowNewPairing: () -> Bool = { false }
    var onPairingRequest: (DCPairingRequest) -> Void = { _ in }
    var onPairingCleared: () -> Void = {}
    var onConnected: () -> Void = {}
    var onPlayback: (Data) -> Void = { _ in }
    var onClosed: (_ reason: String) -> Void = { _ in }
    var onPairingFailed: () -> Void = {}
    var log: (String) -> Void = { _ in }

    private let key = DCCrypto.newKeyPair()
    private let nonce = DCCrypto.randomBytes(DCCrypto.nonceBytes)
    private lazy var localHello = DCCrypto.Hello(role: role, deviceId: local.deviceId, nonce: nonce, publicKey: DCCrypto.publicKeyDER(key))
    private var peerCommit: DCHelloCommit?
    private var peerHello: DCCrypto.Hello?
    private var commitSent = false, helloSent = false
    private var transcript: Data?
    private var outKey: Data?, inKey: Data?, secret: Data?
    private var outSeq: Int64 = 0, lastInSeq: Int64 = 0
    private var localIdentity: DCIdentity?, peerIdentity: DCIdentity?
    private var localHasPair = false, peerHasPair = false
    private var savedPair: DCPair?
    private var pairRequestSent = false, pairRequestReceived = false
    private var localApproved = false, peerApproved = false, localCommitted = false, peerCommitted = false
    private var ourProofSent = false, peerProofVerified = false
    private var assembler = DCAssembler()
    private var timers: [Task<Void, Never>] = []
    private var lastReceived = Date()
    private var codePairing = false
    private var closing = false
    static let handshakeTimeout: TimeInterval = 10
    static let pairingTimeout: TimeInterval = 300
    static let heartbeatTimeout: TimeInterval = 20

    init(role: DCRole, local: DCLocal, store: DCPairStore, send: @escaping (String) -> Void, closeTransport: @escaping () -> Void) {
        self.role = role; self.local = local; self.store = store; self.send = send; self.closeTransport = closeTransport
    }

    // MARK: Life cycle

    func start() {
        timers.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.handshakeTimeout))
            guard let self, self.phase == .handshaking else { return }
            self.log("handshake timed out")
            self.close(reason: "handshake timeout")
        })
        sendHelloCommit()
    }

    func close(reason: String = "closed", sendBye: Bool = false) {
        guard !closing else { return }
        closing = true
        if sendBye, phase == .connected { try? sendEncrypted(DCType.bye, DCBye()) }
        let was = phase
        phase = .closed
        timers.forEach { $0.cancel() }
        timers = []
        if was == .pairing || pairRequestSent || pairRequestReceived { onPairingCleared() }
        closeTransport()
        onClosed(reason)
    }

    private func violation(_ reason: String) {
        log("protocol violation: \(reason)")
        close(reason: reason)
    }

    // MARK: Sending

    private func sendWire(_ wire: DCWire) {
        guard let data = try? JSONEncoder().encode(wire), data.count <= DCPlaybackLimits.maxFrameBytes, let text = String(data: data, encoding: .utf8) else { return violation("oversized outbound frame") }
        send(text)
    }

    private func sendHelloCommit() {
        let payload = DCHelloCommit(version: DCCrypto.protocolVersion, role: role.rawValue, deviceId: local.deviceId, commitment: DCCrypto.base64(DCCrypto.commitment(localHello)))
        sendWire(DCWire(type: DCType.helloCommit, payload: String(decoding: try! JSONEncoder().encode(payload), as: UTF8.self), version: DCCrypto.protocolVersion, encrypted: false, seq: 0))
        commitSent = true
    }

    private func sendHello() {
        let payload = DCHello(version: DCCrypto.protocolVersion, role: role.rawValue, deviceId: local.deviceId, nonce: DCCrypto.base64(nonce), publicKey: DCCrypto.base64(localHello.publicKey))
        sendWire(DCWire(type: DCType.hello, payload: String(decoding: try! JSONEncoder().encode(payload), as: UTF8.self), version: DCCrypto.protocolVersion, encrypted: false, seq: 0))
        helloSent = true
    }

    func sendEncrypted<T: Encodable>(_ type: String, _ payload: T) throws {
        guard helloSent, let key = outKey else { throw DCError.protocolViolation("encrypted before hello") }
        outSeq += 1
        let json = try JSONEncoder().encode(payload)
        let sealed = try DCCrypto.seal(key: key, plaintext: json, aad: DCCrypto.aad(type: type, seq: outSeq))
        sendWire(DCWire(type: type, payload: DCCrypto.base64(sealed), version: DCCrypto.protocolVersion, encrypted: true, seq: outSeq))
    }

    /// Sends a playback message, chunked, as one uninterrupted run of frames.
    func sendPlayback(_ bytes: Data) -> Bool {
        guard phase == .connected, !bytes.isEmpty, bytes.count <= DCPlaybackLimits.maxBytes else { return false }
        for chunk in dcChunks(bytes) {
            do { try sendEncrypted(DCType.playback, chunk) } catch { close(reason: "send failed"); return false }
        }
        return true
    }

    // MARK: Receiving

    func receive(_ text: String) {
        guard !closing else { return }
        guard text.utf8.count <= DCPlaybackLimits.maxFrameBytes else { return violation("oversized frame") }
        guard let wire = try? JSONDecoder().decode(DCWire.self, from: Data(text.utf8)) else { return violation("malformed frame") }
        guard wire.version == DCCrypto.protocolVersion else { return violation("unsupported protocol version") }
        if wire.type == DCType.helloCommit || wire.type == DCType.hello {
            guard !wire.encrypted, wire.seq == 0 else { return violation("invalid envelope") }
            if wire.type == DCType.helloCommit { onHelloCommit(wire) } else { onHello(wire) }
            return
        }
        guard wire.encrypted, wire.seq > 0, DCType.encrypted.contains(wire.type) else { return violation("cleartext or unsequenced frame") }
        guard wire.seq > lastInSeq else { log("dropped replayed frame"); return }
        guard let key = inKey, let sealed = DCCrypto.fromBase64(wire.payload),
              let plain = try? DCCrypto.open(key: key, data: sealed, aad: DCCrypto.aad(type: wire.type, seq: wire.seq))
        else { return violation("unauthenticated frame") }
        lastInSeq = wire.seq
        lastReceived = Date()
        let isPairing = [DCType.identity, DCType.pairProof, DCType.pairRequest, DCType.pairApprove, DCType.pairCommit, DCType.authResult].contains(wire.type)
        if phase == .connected, isPairing { return violation("\(wire.type) after pairing") }
        if phase != .connected, !isPairing, wire.type != DCType.bye { return violation("\(wire.type) before pairing completed") }
        if [DCType.pairProof, DCType.pairRequest, DCType.pairApprove, DCType.pairCommit].contains(wire.type), peerIdentity == nil { return violation("\(wire.type) before identity") }
        let decoder = JSONDecoder()
        do {
            switch wire.type {
            case DCType.identity: try onIdentity(decoder.decode(DCIdentity.self, from: plain))
            case DCType.pairProof: try onPairProof(decoder.decode(DCProofPayload.self, from: plain))
            case DCType.pairRequest: try onPairRequest(decoder.decode(DCProofPayload.self, from: plain))
            case DCType.pairApprove: try onPairApprove(decoder.decode(DCProofPayload.self, from: plain))
            case DCType.pairCommit: try onPairCommit(decoder.decode(DCProofPayload.self, from: plain))
            case DCType.authResult: try onAuthResult(decoder.decode(DCAuthResult.self, from: plain))
            case DCType.deviceInfo: try onDeviceInfo(decoder.decode(DCDeviceInfo.self, from: plain))
            case DCType.playback: try onChunk(decoder.decode(DCChunk.self, from: plain))
            case DCType.ping: let ping = try decoder.decode(DCPing.self, from: plain); if phase == .connected { try? sendEncrypted(DCType.pong, ping) }
            case DCType.pong: break
            case DCType.bye: close(reason: "peer said bye")
            default: violation("unknown message")
            }
        } catch {
            violation("invalid \(wire.type) payload")
        }
    }

    // MARK: Hello

    private func onHelloCommit(_ wire: DCWire) {
        guard peerCommit == nil, peerHello == nil,
              let commit = try? JSONDecoder().decode(DCHelloCommit.self, from: Data(wire.payload.utf8)),
              commit.version == DCCrypto.protocolVersion, commit.role == role.peer.rawValue,
              dcIsValidDeviceId(commit.deviceId), commit.deviceId != local.deviceId,
              let bytes = DCCrypto.fromBase64(commit.commitment), bytes.count == DCCrypto.commitmentBytes
        else { return violation("invalid hello commitment") }
        peerCommit = commit
        sendHello()
    }

    private func onHello(_ wire: DCWire) {
        guard peerHello == nil, let commit = peerCommit else { return violation("hello before commitment") }
        guard let hello = try? JSONDecoder().decode(DCHello.self, from: Data(wire.payload.utf8)),
              hello.version == commit.version, hello.role == commit.role, hello.deviceId == commit.deviceId,
              let nonceBytes = DCCrypto.fromBase64(hello.nonce), nonceBytes.count == DCCrypto.nonceBytes,
              let keyBytes = DCCrypto.fromBase64(hello.publicKey), (1 ... DCCrypto.maxPublicKeyBytes).contains(keyBytes.count)
        else { return violation("invalid hello") }
        let material = DCCrypto.Hello(role: role.peer, deviceId: hello.deviceId, nonce: nonceBytes, publicKey: keyBytes)
        guard let expected = DCCrypto.fromBase64(commit.commitment), DCCrypto.constantTimeEquals(DCCrypto.commitment(material), expected) else { return violation("hello commitment mismatch") }
        guard let shared = try? DCCrypto.sharedSecret(private: key, peerPublicDER: keyBytes) else { return violation("invalid hello key") }
        let hash = DCCrypto.transcript(local: localHello, peer: material)
        peerHello = material
        peerId = material.deviceId
        transcript = hash
        outKey = DCCrypto.trafficKey(shared: shared, transcript: hash, sender: role)
        inKey = DCCrypto.trafficKey(shared: shared, transcript: hash, sender: role.peer)
        secret = DCCrypto.pairSecret(shared: shared, transcript: hash)
        if mirrorPeerAccount, role == .responder { return } // identity follows the phone's
        sendIdentity()
    }

    // MARK: Identity

    private func identityPhase(_ i: DCIdentity) -> String { "identity|\(i.fingerprint)|\(i.anonymous)|\(i.resolved)|\(i.hasPair)" }

    private func sendIdentity() {
        guard let peer = peerHello else { return }
        savedPair = store.find(peerId: peer.deviceId, fingerprint: local.fingerprint, anonymous: local.anonymous)
        localHasPair = savedPair != nil
        // Neither the credential nor the account id is sent. With code pairing (both sides support
        // it) no account proof is needed: only the public fingerprint has to agree.
        let identity = DCIdentity(fingerprint: local.fingerprint, accountProof: "", anonymous: local.anonymous, resolved: local.resolved, hasPair: localHasPair, supportsCodePairing: local.supportsCodePairing)
        localIdentity = identity
        try? sendEncrypted(DCType.identity, identity)
    }

    private func flags(_ i: DCIdentity) -> DCCrypto.IdentityFlags {
        .init(fingerprint: i.fingerprint, anonymous: i.anonymous, resolved: i.resolved, hasPair: i.hasPair, supportsCodePairing: i.supportsCodePairing)
    }

    private func onIdentity(_ identity: DCIdentity) throws {
        if mirrorPeerAccount, role == .responder, localIdentity == nil, peerIdentity == nil {
            guard identity.resolved else { rejectAndClose("account-unresolved"); return }
            mirroredAccount = !identity.anonymous
            local.anonymous = identity.anonymous
            local.fingerprint = identity.anonymous ? "" : String(identity.fingerprint.prefix(64))
            local.resolved = true
            sendIdentity()
        }
        guard peerIdentity == nil, let mine = localIdentity, let hash = transcript, let base = secret else { return violation("duplicate identity") }
        guard local.resolved, identity.resolved else {
            log(local.resolved ? "the phone has not resolved its account id" : "this Mac has not read its account id (Settings > Devices > Read From YouTube Music)")
            rejectAndClose("account-unresolved")
            return
        }
        codePairing = mine.supportsCodePairing && identity.supportsCodePairing
        // Without code pairing the peer would have to prove the account with the credential. This
        // app only accepts the code-pairing form, so an older peer is refused rather than weakened.
        guard codePairing, identity.anonymous == local.anonymous, identity.fingerprint == local.fingerprint else { rejectAndClose("account-mismatch"); return }
        let pairingHash = DCCrypto.codePairingTranscript(hello: hash, localRole: role, local: flags(mine), peer: flags(identity))
        secret = DCCrypto.pairSecret(shared: base, transcript: pairingHash)
        transcript = pairingHash
        peerIdentity = identity
        peerHasPair = identity.hasPair
        if localHasPair && peerHasPair {
            sendPairProof()
        } else if role == .initiator {
            beginNewPairing()
        }
    }

    // MARK: Reconnect

    private func sendPairProof() {
        guard let pair = savedPair, let peer = peerId, let hash = transcript, !ourProofSent else { return }
        ourProofSent = true
        let proof = DCCrypto.proof(secret: pair.secret, phase: "reconnect", sender: role, senderId: local.deviceId, receiverId: peer, transcript: hash)
        try? sendEncrypted(DCType.pairProof, DCProofPayload(deviceId: local.deviceId, proof: proof))
    }

    private func onPairProof(_ payload: DCProofPayload) throws {
        guard let peer = peerId, let hash = transcript, payload.deviceId == peer, !pairRequestSent, !pairRequestReceived, localHasPair, peerHasPair else { return violation("unexpected pair proof") }
        guard let pair = savedPair, DCCrypto.proofMatches(secret: pair.secret, proof: payload.proof, phase: "reconnect", sender: role.peer, senderId: peer, receiverId: local.deviceId, transcript: hash) else {
            rejectAndClose("not-paired")
            return
        }
        peerProofVerified = true
        completeReconnect()
    }

    private func completeReconnect() {
        guard ourProofSent, peerProofVerified, phase != .connected else { return }
        phase = .connected
        sendDeviceInfo()
        onConnected()
    }

    // MARK: New pairing

    private func beginNewPairing() {
        guard !pairRequestSent else { return }
        pairRequestSent = true
        startPairingTimer()
        sendProofMessage(DCType.pairRequest, "pair-request")
        publishRequest()
    }

    private func onPairRequest(_ payload: DCProofPayload) throws {
        guard let peer = peerId, let hash = transcript, let secret else { return }
        guard role == .responder, !pairRequestReceived, !(localHasPair && peerHasPair), payload.deviceId == peer,
              DCCrypto.proofMatches(secret: secret, proof: payload.proof, phase: "pair-request", sender: role.peer, senderId: peer, receiverId: local.deviceId, transcript: hash)
        else { return violation("invalid pair request") }
        // A device that isn't already paired is turned away unless the person has opened pairing.
        guard allowNewPairing() else { rejectAndClose("pairing-rejected"); return }
        pairRequestReceived = true
        phase = .pairing
        startPairingTimer()
        publishRequest()
    }

    private func publishRequest() {
        guard let secret, let peer = peerId else { return }
        phase = .pairing
        onPairingRequest(DCPairingRequest(requestId: connectionId, peerId: peer, peerName: peerName.isEmpty ? peer : peerName, sas: DCCrypto.sas(pairSecret: secret),
                                           expires: Date().addingTimeInterval(Self.pairingTimeout)))
    }

    private func startPairingTimer() {
        timers.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingTimeout))
            guard let self, self.phase != .connected, self.phase != .closed else { return }
            self.log("pairing approval timed out")
            self.onPairingFailed()
            self.close(reason: "pairing timed out")
        })
    }

    /// The person compared the code on both devices and approved.
    func approvePairing() {
        guard phase == .pairing, pairRequestSent || pairRequestReceived, !localApproved else { return }
        localApproved = true
        sendProofMessage(DCType.pairApprove, "pair-approve")
        commitIfReady()
    }

    func rejectPairing() {
        guard phase == .pairing else { return }
        rejectAndClose("pairing-rejected")
    }

    private func sendProofMessage(_ type: String, _ phaseName: String) {
        guard let peer = peerId, let hash = transcript, let secret else { return }
        let proof = DCCrypto.proof(secret: secret, phase: phaseName, sender: role, senderId: local.deviceId, receiverId: peer, transcript: hash)
        try? sendEncrypted(type, DCProofPayload(deviceId: local.deviceId, proof: proof))
    }

    private func checkPairMessage(_ payload: DCProofPayload, phase phaseName: String) -> Bool {
        guard let peer = peerId, let hash = transcript, let secret, payload.deviceId == peer, pairRequestSent || pairRequestReceived else { return false }
        return DCCrypto.proofMatches(secret: secret, proof: payload.proof, phase: phaseName, sender: role.peer, senderId: peer, receiverId: local.deviceId, transcript: hash)
    }

    private func onPairApprove(_ payload: DCProofPayload) throws {
        guard !peerApproved, checkPairMessage(payload, phase: "pair-approve") else { return violation("invalid pair approval") }
        peerApproved = true
        commitIfReady()
    }

    private func commitIfReady() {
        guard localApproved, peerApproved, !localCommitted, !closing, let peer = peerId, let secret else { return }
        let pair = DCPair(peerId: peer, peerName: peerName, peerModel: peerModel, fingerprint: local.fingerprint, anonymous: local.anonymous, secret: secret)
        guard store.save(pair) else { rejectAndClose("pairing-storage-failed"); return }
        localCommitted = true
        sendProofMessage(DCType.pairCommit, "pair-commit")
        completeNewPairing()
    }

    private func onPairCommit(_ payload: DCProofPayload) throws {
        guard peerApproved, !peerCommitted, checkPairMessage(payload, phase: "pair-commit") else { return violation("invalid pair commit") }
        peerCommitted = true
        completeNewPairing()
    }

    private func completeNewPairing() {
        guard localCommitted, peerCommitted, phase != .connected else { return }
        phase = .connected
        onPairingCleared()
        sendDeviceInfo()
        onConnected()
    }

    private func onAuthResult(_ result: DCAuthResult) throws {
        if result.accepted { return violation("unexpected auth result") }
        log("peer refused: \(result.reason)")
        onPairingFailed()
        close(reason: "refused: \(result.reason)")
    }

    private func rejectAndClose(_ reason: String) {
        try? sendEncrypted(DCType.authResult, DCAuthResult(accepted: false, reason: reason))
        if reason == "pairing-rejected" || reason == "account-mismatch" { onPairingFailed() }
        close(reason: reason)
    }

    // MARK: After pairing

    func sendDeviceInfo() {
        let info = DCDeviceInfo(deviceId: local.deviceId, deviceName: local.name, model: local.model, playbackVersion: DCPlaybackLimits.version,
                                supportsPlaybackClock: false, supportsPlaybackPitch: false, deviceType: local.deviceType)
        try? sendEncrypted(DCType.deviceInfo, info)
    }

    private func onDeviceInfo(_ info: DCDeviceInfo) throws {
        guard info.deviceId == peerId, dcIsValidDeviceId(info.deviceId) else { return violation("invalid device info") }
        peerName = dcSanitizeDeviceName(info.deviceName)
        peerModel = dcSanitizeDeviceName(info.model)
        peerType = info.deviceType
        peerPlaybackVersion = info.playbackVersion
        onDeviceInfoReceived()
    }

    var onDeviceInfoReceived: () -> Void = {}

    var supportsPlayback: Bool { phase == .connected && peerPlaybackVersion == DCPlaybackLimits.version }

    private func onChunk(_ chunk: DCChunk) throws {
        guard supportsPlayback else { return violation("playback before capability negotiation") }
        do {
            if let bytes = try assembler.accept(chunk) { onPlayback(bytes) }
        } catch {
            violation("invalid playback assembly")
        }
    }

    /// Sends a heartbeat and closes the connection if the peer has gone quiet.
    func heartbeat() {
        guard phase == .connected else { return }
        if Date().timeIntervalSince(lastReceived) > Self.heartbeatTimeout { return close(reason: "heartbeat timeout") }
        try? sendEncrypted(DCType.ping, DCPing(t: Int64(Date().timeIntervalSince1970 * 1000)))
    }
}
