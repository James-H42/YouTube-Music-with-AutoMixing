import Foundation
import Network
import Observation
import SwiftUI

extension DCPairingRequest: Identifiable { var id: String { requestId } }

struct DCPairedInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var model: String
}

/// Device Connect on this Mac. Everything here is off until the person switches it on, and
/// stops when they switch it off or quit.
///
/// The security posture is stricter than Metrolist's, because this Mac may share a network
/// with strangers:
///  - nothing listens and nothing is advertised while it is off;
///  - the listener refuses cellular, VPN and other tunnel interfaces, and every peer address must be
///    a private or local one;
///  - a device that is not already paired is refused unless the person has opened pairing, which
///    closes by itself after five minutes and after one pairing;
///  - pairing needs the same six-digit code approved on this Mac and on the phone;
///  - five failed pairings in fifteen minutes lock pairing for fifteen minutes;
///  - forgetting a device deletes its key and closes its connections at once;
///  - the advertised name is "Metrolist (Mac)" unless the person changes it, never their own name.
///
/// The same machinery runs twice. `shared` is for your own devices, which get full remote
/// control. `guests` is the shared queue: a second, always-anonymous device identity with its
/// own keys, which listens only while a shared queue is running and whose peers may only add
/// songs (see `docs/Shared queue design.md`). Both feed one playback target.
@MainActor
@Observable
final class DeviceConnect {
    enum Mode { case owner, guest }

    static let shared = DeviceConnect(mode: .owner)
    static let guests = DeviceConnect(mode: .guest)
    static let serviceType = "_metrolist-connect._tcp"
    static let guestPrefix = "guest:"

    let mode: Mode

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            // A shared queue is never remembered: it has to be started again after a relaunch.
            if mode == .owner { UserDefaults.standard.set(enabled, forKey: "deviceConnectEnabled") }
            enabled ? start() : stop()
        }
    }
    var deviceName: String {
        didSet {
            guard mode == .owner, deviceName != oldValue else { return }
            UserDefaults.standard.set(dcSanitizeDeviceName(deviceName), forKey: "deviceConnectName")
            // Typing a name would otherwise restart the listener, and drop every phone, per keystroke.
            renameTimer?.cancel()
            renameTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                if self.listener != nil { self.start() }
                if DeviceConnect.guests.listener != nil { DeviceConnect.guests.start() }
            }
        }
    }
    /// Present this Mac with the account the app is signed in to (the phone must use the same one),
    /// or anonymously (the phone must be signed out). Guests always meet the anonymous identity.
    var useAccount: Bool {
        didSet {
            guard mode == .owner else { return }
            UserDefaults.standard.set(useAccount, forKey: "deviceConnectUseAccount")
            closeAll("identity changed")
        }
    }
    private(set) var listening = false
    private(set) var port: UInt16?
    private(set) var paired: [DCPairedInfo] = []
    private(set) var connected: Set<String> = []
    private(set) var requests: [DCPairingRequest] = []
    private(set) var pairingOpenUntil: Date?
    private(set) var lockedUntil: Date?
    private(set) var message: String?
    private(set) var events: [String] = []
    private(set) var accountIdKnown = false

    @ObservationIgnored let store: DCPairStore & AnyObject
    @ObservationIgnored private let keychainStore: DCKeychainPairStore?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [String: Connection] = [:]
    @ObservationIgnored private var pending: [String: Int] = [:]
    @ObservationIgnored private var renameTimer: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var pairingTimer: Task<Void, Never>?
    @ObservationIgnored private var failures: [Date] = []

    struct Connection {
        var session: DCSession
        var connection: NWConnection
        var host: String
        /// Whether this connection still counts against the limit on unfinished connections.
        var pending = true
    }

    init(mode: Mode = .owner, store: (DCPairStore & AnyObject)? = nil) {
        self.mode = mode
        let keychain = DCKeychainPairStore(prefix: mode == .owner ? "deviceconnect" : "sharedqueue.guest")
        keychainStore = store == nil ? keychain : nil
        self.store = store ?? keychain
        enabled = mode == .owner && UserDefaults.standard.bool(forKey: "deviceConnectEnabled")
        deviceName = UserDefaults.standard.string(forKey: "deviceConnectName") ?? "Metrolist (Mac)"
        useAccount = mode == .owner && UserDefaults.standard.bool(forKey: "deviceConnectUseAccount")
        accountIdKnown = UserDefaults.standard.string(forKey: "deviceConnectDataSyncId") != nil
        refreshPaired()
    }

    // MARK: Identity

    var deviceId: String {
        let key = mode == .owner ? "deviceConnectId" : "sharedQueueDeviceId"
        if let saved = UserDefaults.standard.string(forKey: key), dcIsValidDeviceId(saved) { return saved }
        let made = DCCrypto.base64(DCCrypto.randomBytes(16)).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        UserDefaults.standard.set(made, forKey: key)
        return made
    }

    /// The name phones show for this endpoint.
    var advertisedName: String {
        let base = dcSanitizeDeviceName(DeviceConnect.shared.deviceName).isEmpty ? "Metrolist (Mac)" : dcSanitizeDeviceName(DeviceConnect.shared.deviceName)
        return mode == .owner ? base : dcSanitizeDeviceName(String(base.prefix(48)) + " · Shared queue")
    }

    /// How the playback target knows a peer, so a phone paired both ways counts as two peers.
    func peerKey(_ peerId: String) -> String { mode == .owner ? peerId : Self.guestPrefix + peerId }

    func localIdentity() -> DCLocal {
        var local = DCLocal(deviceId: deviceId, name: advertisedName, model: "Mac", deviceType: "desktop", fingerprint: "", anonymous: true, resolved: true)
        if mode == .owner, useAccount {
            local.anonymous = false
            if let id = UserDefaults.standard.string(forKey: "deviceConnectDataSyncId"), !id.isEmpty {
                local.fingerprint = DCCrypto.accountFingerprint(id)
            } else {
                local.resolved = false
            }
        }
        return local
    }

    /// Reads the signed-in account's id from YouTube Music, as Metrolist does, so the fingerprint can match.
    func lookUpAccountId() async {
        message = "Reading the account id…"
        guard let cookie = InnerTube.shared.cookie, !cookie.isEmpty else { message = "Sign in to YouTube Music in this app first (Settings > Account)."; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        var found: String?
        for address in ["https://music.youtube.com/", "https://music.youtube.com/library"] where found == nil {
            var request = URLRequest(url: URL(string: address)!)
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            guard let (data, _) = try? await session.data(for: request) else { continue }
            let html = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\\"", with: "\"")
            found = html.firstMatch(of: #/"DATASYNC_ID":"([^"]+)"/#).map { String($0.1) }
                ?? html.firstMatch(of: #/"datasyncId":"([^"]+)"/#).map { String($0.1) }
        }
        guard let raw = found?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            message = "YouTube Music didn't return an account id. Sign out and in again in Settings > Account, then retry."
            return
        }
        // Metrolist uses the part before "||" (or the part after, when that is empty).
        let parts = raw.components(separatedBy: "||")
        let id = (parts.first?.isEmpty == false ? parts.first : parts.last) ?? ""
        guard !id.isEmpty else { message = "The account id was empty."; return }
        UserDefaults.standard.set(id, forKey: "deviceConnectDataSyncId")
        accountIdKnown = true
        message = "Account id read (\(id.count) characters)."
    }

    // MARK: Switching on and off

    func serveForTesting() { testing = true; start() }

    func restoreIfEnabled() { if enabled { start() } }

    /// Set by `--dcserve` so a test can listen without changing the saved preference.
    @ObservationIgnored var testing = false

    /// The one playback target both endpoints feed, so there is one queue and one session.
    static var target: DCTarget {
        if let made = madeTarget { return made }
        let target = DCTarget(player: AppModel.shared.player)
        target.guestPolicy = SharedQueue.shared.policy
        target.send = { key, object in
            key.hasPrefix(guestPrefix) ? guests.sendPlayback(String(key.dropFirst(guestPrefix.count)), object) : shared.sendPlayback(key, object)
        }
        madeTarget = target
        return target
    }
    private static var madeTarget: DCTarget?

    private var target: DCTarget { Self.target }

    private func start() {
        stopServer()
        guard enabled || testing else { return }
        _ = target
        do {
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            ws.maximumMessageSize = DCPlaybackLimits.maxFrameBytes
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            // Only the local network: never over a cellular link or a VPN or other tunnel.
            parameters.prohibitedInterfaceTypes = [.cellular, .other, .loopback]
            parameters.includePeerToPeer = false
            let listener = try NWListener(using: parameters)
            let name = localIdentity().name
            listener.service = NWListener.Service(name: "metrolist-\(deviceId)-\(mode == .owner ? "mac" : "shared")", type: Self.serviceType, txtRecord: NWTXTRecord([
                "deviceId": deviceId, "deviceName": String(name.prefix(48)), "deviceType": "desktop",
            ]))
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.listenerState(state, listener) } }
            }
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(connection) } }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            message = "Couldn't start listening: \(error.localizedDescription)"
            log("listener failed: \(error)")
        }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.connections.values.forEach { $0.session.heartbeat() } }
        }
    }

    private func listenerState(_ state: NWListener.State, _ source: NWListener) {
        guard source === listener else { return }
        switch state {
        case .ready:
            listening = true
            port = source.port?.rawValue
            message = nil
            log("listening on port \(port.map(String.init) ?? "?")")
        case .failed(let error):
            listening = false
            message = "Device Connect stopped: \(error.localizedDescription)"
            log("listener failed: \(error)")
            stopServer()
        case .cancelled: listening = false
        default: break
        }
    }

    func stop() {
        stopServer()
        closePairing()
    }

    private func stopServer() {
        heartbeat?.invalidate()
        heartbeat = nil
        listener?.cancel()
        listener = nil
        listening = false
        port = nil
        closeAll("switched off")
        Self.madeTarget?.stop(guests: mode == .guest)
    }

    /// Called as the app quits, so nothing is left listening.
    func shutdown() { stopServer() }

    private func closeAll(_ reason: String) {
        for entry in connections.values { entry.session.close(reason: reason) }
        connections = [:]
        pending = [:]
        connected = []
        requests = []
    }

    // MARK: Incoming connections

    private func accept(_ connection: NWConnection) {
        guard enabled || testing, listener != nil else { connection.cancel(); return }
        var host = ""
        if case .hostPort(let remote, _) = connection.endpoint { host = "\(remote)" }
        let bare = host.split(separator: "%").first.map(String.init) ?? host
        // Strangers outside the local ranges, and a flood from one address, get nothing.
        guard DCAddress.isLAN(bare), pending[bare, default: 0] < 2, pending.values.reduce(0, +) < 4, connections.count < 8 else {
            log("refused a connection from \(DCAddress.isLAN(bare) ? "a busy address" : "outside the local network")")
            connection.cancel()
            return
        }
        pending[bare, default: 0] += 1
        let id = UUID().uuidString
        let session = DCSession(
            role: .responder, local: localIdentity(), store: store,
            send: { [weak connection] text in
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
                connection?.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
            },
            // A moment's grace, so a last message (why the peer was refused) is sent before the
            // socket closes; the session itself ignores anything that arrives meanwhile.
            closeTransport: { [weak connection] in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { connection?.cancel() } }
        )
        session.log = { [weak self] text in self?.log(text) }
        session.mirrorPeerAccount = mode == .guest && SharedQueue.shared.policy.allowSignedInGuests
        session.allowNewPairing = { [weak self] in self?.canPair() ?? false }
        session.onPairingRequest = { [weak self] request in self?.requestArrived(request) }
        session.onPairingCleared = { [weak self, weak session] in
            guard let self, let session else { return }
            self.requests.removeAll { $0.requestId == session.connectionId }
        }
        session.onPairingFailed = { [weak self] in self?.pairingFailed() }
        session.onConnected = { [weak self, weak session] in
            guard let self, let session, let peer = session.peerId else { return }
            self.peerConnected(peer, session)
        }
        session.onDeviceInfoReceived = { [weak self, weak session] in
            guard let self, let session, let peer = session.peerId else { return }
            (self.store as? DCKeychainPairStore)?.updateMetadata(peerId: peer, name: session.peerName, model: session.peerModel)
            self.refreshPaired()
        }
        session.onPlayback = { [weak self, weak session] data in
            guard let self, let peer = session?.peerId else { return }
            self.target.receive(data, from: self.peerKey(peer))
        }
        session.onClosed = { [weak self, id, bare] reason in self?.sessionClosed(id, host: bare, reason: reason) }
        connections[id] = Connection(session: session, connection: connection, host: bare)
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: session.start(); self?.receiveLoop(connection, session)
                    case .failed, .cancelled: session.close(reason: "connection lost")
                    default: break
                    }
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receiveLoop(_ connection: NWConnection, _ session: DCSession) {
        connection.receiveMessage { [weak self] data, context, _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if error != nil { session.close(reason: "receive failed"); return }
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                    if let metadata, metadata.opcode == .close { session.close(reason: "peer closed"); return }
                    if let data, metadata?.opcode == .text, let text = String(data: data, encoding: .utf8) { session.receive(text) }
                    else if data != nil, metadata?.opcode != .text, metadata?.opcode != .pong { session.close(reason: "binary frame") }
                    if session.phase != .closed { self?.receiveLoop(connection, session) }
                }
            }
        }
    }

    private func sessionClosed(_ id: String, host: String, reason: String) {
        guard let entry = connections.removeValue(forKey: id) else { return }
        if entry.pending { release(host) }
        requests.removeAll { $0.requestId == entry.session.connectionId }
        if let peer = entry.session.peerId, entry.session.phase == .closed {
            let stillConnected = connections.values.contains { $0.session.peerId == peer && $0.session.supportsPlayback }
            if !stillConnected { connected.remove(peer); target.peerDisconnected(peerKey(peer)) }
        }
        log("connection closed: \(reason)")
    }

    private func peerConnected(_ peer: String, _ session: DCSession) {
        // One live connection per device: a newer one replaces an older one.
        for (key, other) in connections where other.session !== session && other.session.peerId == peer { other.session.close(reason: "replaced"); connections[key] = nil }
        if let key = connections.first(where: { $0.value.session === session })?.key, connections[key]?.pending == true {
            connections[key]?.pending = false
            release(connections[key]!.host)
        }
        connected.insert(peer)
        refreshPaired()
        closePairing()
        log("connected to a paired device")
    }

    private func release(_ host: String) {
        if let count = pending[host] { pending[host] = count <= 1 ? nil : count - 1 }
    }

    fileprivate func sendPlayback(_ peer: String, _ object: [String: Any]) -> Bool {
        guard let entry = connections.values.first(where: { $0.session.peerId == peer && $0.session.phase == .connected }),
              JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object)
        else { return false }
        return entry.session.sendPlayback(data)
    }

    // MARK: Pairing

    var pairingIsOpen: Bool { (pairingOpenUntil ?? .distantPast) > Date() }
    var isLocked: Bool { (lockedUntil ?? .distantPast) > Date() }

    private func canPair() -> Bool { (enabled || testing) && pairingIsOpen && !isLocked && requests.isEmpty }

    /// "Pair a new device": for five minutes a phone that isn't paired yet may ask to pair.
    func openPairing() {
        guard enabled || testing, !isLocked else { return }
        pairingOpenUntil = Date().addingTimeInterval(DCSession.pairingTimeout)
        pairingTimer?.cancel()
        pairingTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DCSession.pairingTimeout))
            self?.closePairing()
        }
        log("pairing opened")
    }

    func closePairing() {
        pairingOpenUntil = nil
        pairingTimer?.cancel()
        pairingTimer = nil
    }

    private func requestArrived(_ request: DCPairingRequest) {
        requests = [request]
        NSApp.requestUserAttention(.criticalRequest)
        log("a device asked to pair")
    }

    func approve(_ request: DCPairingRequest) {
        connections.values.first { $0.session.connectionId == request.requestId }?.session.approvePairing()
    }

    func reject(_ request: DCPairingRequest) {
        connections.values.first { $0.session.connectionId == request.requestId }?.session.rejectPairing()
        requests.removeAll { $0.requestId == request.requestId }
    }

    /// A pairing that ended without success while pairing was open counts against the limit.
    private func pairingFailed() {
        guard pairingIsOpen else { return }
        failures = failures.filter { Date().timeIntervalSince($0) < 15 * 60 } + [Date()]
        if failures.count >= 5 {
            lockedUntil = Date().addingTimeInterval(15 * 60)
            failures = []
            closePairing()
            message = "Pairing is locked for 15 minutes after repeated failures."
            log("pairing locked after repeated failures")
        }
    }

    // MARK: Paired devices

    func refreshPaired() {
        paired = ((store as? DCKeychainPairStore)?.all() ?? []).map { DCPairedInfo(id: $0.peerId, name: $0.peerName.isEmpty ? "Device \($0.peerId.prefix(6))" : $0.peerName, model: $0.peerModel) }
    }

    /// Removes a device: its key is deleted and its connections close at once.
    func forget(_ id: String) {
        (store as? DCKeychainPairStore)?.forget(id)
        for (key, entry) in connections where entry.session.peerId == id { entry.session.close(reason: "forgotten"); connections[key] = nil }
        connected.remove(id)
        Self.madeTarget?.peerDisconnected(peerKey(id))
        refreshPaired()
        log("a device was forgotten")
    }

    func forgetAll() {
        for device in paired { forget(device.id) }
    }

    private func log(_ text: String) {
        events.append("\(Date().formatted(date: .omitted, time: .standard))  \(text)")
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
}
