import Foundation
import Network
import Observation

/// This Mac as a guest of someone else's shared queue: it finds shared queues on the local
/// network (or takes an address), pairs with the six-digit code, then shows the host's queue
/// and adds songs to it. It never plays the audio; the host's Mac does, with its AutoMix.
///
/// It uses the controller half of Device Connect with an anonymous identity and its own
/// Keychain items (`sharedqueue.joined.*`), and it only connects to private-range addresses.
@MainActor
@Observable
final class SharedQueueClient {
    static let shared = SharedQueueClient()

    enum Phase: Equatable { case idle, connecting, pairing(code: String), joined, failed(String) }

    struct Found: Identifiable, Hashable {
        var id: String
        var name: String
        var endpoint: NWEndpoint
    }

    private(set) var phase = Phase.idle
    private(set) var found: [Found] = []
    private(set) var browsing = false
    private(set) var hostName = ""
    private(set) var queue: [Song] = []
    private(set) var currentIndex = -1
    private(set) var playing = false
    private(set) var message: String?
    private(set) var rememberedHosts = 0

    var joined: Bool { phase == .joined && sessionId != nil }
    var nowPlaying: Song? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }

    @ObservationIgnored private let store: DCPairStore & AnyObject
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var resolver: NWConnection?
    @ObservationIgnored private var session: DCSession?
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private(set) var sessionId: String?
    @ObservationIgnored private var queueRevision: Int64 = 0
    /// Where session events are reported (the tests print them).
    @ObservationIgnored var log: (String) -> Void = { _ in }

    init(store: (DCPairStore & AnyObject)? = nil) {
        self.store = store ?? DCKeychainPairStore(prefix: "sharedqueue.joined")
        refreshRemembered()
    }

    private var deviceId: String {
        if let saved = UserDefaults.standard.string(forKey: "sharedQueueClientId"), dcIsValidDeviceId(saved) { return saved }
        let made = DCCrypto.base64(DCCrypto.randomBytes(16)).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        UserDefaults.standard.set(made, forKey: "sharedQueueClientId")
        return made
    }

    private func refreshRemembered() { rememberedHosts = (store as? DCKeychainPairStore)?.ids.count ?? 0 }

    // MARK: Finding shared queues

    func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: DeviceConnect.serviceType, domain: nil), using: parameters)
        let own = [DeviceConnect.shared.deviceId, DeviceConnect.guests.deviceId]
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let list: [Found] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint, !own.contains(where: { name.contains($0) }) else { return nil }
                var shown = name
                if case .bonjour(let txt) = result.metadata, let named = txt["deviceName"] { shown = dcSanitizeDeviceName(named) }
                return Found(id: name, name: shown.isEmpty ? name : shown, endpoint: result.endpoint)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Shared queues first: other Metrolist devices offer full control, not a shared queue.
                    self?.found = list.sorted { ($0.name.hasSuffix("Shared queue") ? 0 : 1, $0.name) < ($1.name.hasSuffix("Shared queue") ? 0 : 1, $1.name) }
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.message = "Couldn't look for shared queues: \(error.localizedDescription)" } }
            }
        }
        self.browser = browser
        browsing = true
        browser.start(queue: .main)
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        browsing = false
        found = []
    }

    // MARK: Joining

    func join(_ found: Found) {
        leave(quietly: true)
        message = nil
        phase = .connecting
        // The WebSocket client needs an address, so the service is resolved first, over IPv4.
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        parameters.includePeerToPeer = false
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let probe = NWConnection(to: found.endpoint, using: parameters)
        resolver = probe
        probe.stateUpdateHandler = { [weak self, weak probe] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let probe, probe === self.resolver else { return }
                    switch state {
                    case .ready:
                        let remote = probe.currentPath?.remoteEndpoint
                        probe.cancel()
                        self.resolver = nil
                        guard case .hostPort(let host, let port)? = remote else { return self.ended("Couldn't find that shared queue's address.") }
                        let address = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                        self.join(address: address, port: port.rawValue)
                        self.hostName = found.name
                    case .failed(let error), .waiting(let error):
                        probe.cancel()
                        self.resolver = nil
                        self.ended("Couldn't reach that shared queue: \(error.localizedDescription)")
                    default: break
                    }
                }
            }
        }
        probe.start(queue: .main)
    }

    /// For networks that block discovery: an address and port the host's Mac shows.
    func join(address: String, port: UInt16) {
        let host = address.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard DCAddress.isLAN(host) else { phase = .failed("Only addresses on the local network can be joined."); return }
        guard let nwPort = NWEndpoint.Port(rawValue: port), port > 0 else { phase = .failed("That port isn't valid."); return }
        hostName = host
        // The WebSocket client needs a ws:// address to send its handshake to.
        let shown = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "ws://\(shown):\(nwPort.rawValue)/connect") else { phase = .failed("That address isn't valid."); return }
        connect(to: .url(url))
    }

    private func connect(to endpoint: NWEndpoint) {
        leave(quietly: true)
        message = nil
        phase = .connecting
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = DCPlaybackLimits.maxFrameBytes
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        parameters.includePeerToPeer = false
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let connection, connection === self.connection else { return }
                    switch state {
                    case .ready: self.connected(connection)
                    case .failed(let error): self.ended("Couldn't connect: \(error.localizedDescription)")
                    case .waiting(let error): self.ended("Couldn't connect: \(error.localizedDescription)")
                    case .cancelled: if self.connection === connection { self.ended(nil) }
                    default: break
                    }
                }
            }
        }
        connection.start(queue: .main)
    }

    private func connected(_ connection: NWConnection) {
        // Whatever discovery said, the far end must be on the local network.
        var host = ""
        if case .hostPort(let remote, _)? = connection.currentPath?.remoteEndpoint { host = "\(remote)" }
        guard DCAddress.isLAN(host) else { return ended("That device isn't on the local network.") }
        let local = DCLocal(deviceId: deviceId, name: DeviceConnect.shared.advertisedName, model: "Mac", deviceType: "desktop", fingerprint: "", anonymous: true, resolved: true)
        let session = DCSession(
            role: .initiator, local: local, store: store,
            send: { [weak connection] text in
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
                connection?.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
            },
            closeTransport: { [weak connection] in connection?.cancel() }
        )
        attach(session)
        receiveLoop(connection, session)
        session.start()
    }

    /// Wires a session's callbacks. Tests use it to drive a session over an in-memory pipe.
    func attach(_ session: DCSession) {
        self.session = session
        session.log = { [weak self] text in self?.log(text) }
        session.onPairingRequest = { [weak self] request in self?.phase = .pairing(code: request.sas) }
        session.onConnected = { [weak self] in
            self?.phase = .joined
            self?.refreshRemembered()
        }
        session.onDeviceInfoReceived = { [weak self, weak session] in
            guard let self, let session else { return }
            if !session.peerName.isEmpty { self.hostName = session.peerName }
            if session.supportsPlayback { self.sendPlayback(["type": "ATTACH"]) } else { session.close(reason: "that device can't share its queue") }
        }
        session.onPlayback = { [weak self] data in self?.receive(data) }
        session.onClosed = { [weak self, weak session] reason in
            guard let self, session === self.session else { return }
            self.ended(Self.explain(reason))
        }
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.heartbeat() }
        }
    }

    private func receiveLoop(_ connection: NWConnection, _ session: DCSession) {
        connection.receiveMessage { [weak self] data, context, _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if error != nil { session.close(reason: "connection lost"); return }
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                    if let metadata, metadata.opcode == .close { session.close(reason: "the host closed the connection"); return }
                    if let data, metadata?.opcode == .text, let text = String(data: data, encoding: .utf8) { session.receive(text) }
                    else if data != nil, metadata?.opcode != .text, metadata?.opcode != .pong { session.close(reason: "binary frame") }
                    if session.phase != .closed { self?.receiveLoop(connection, session) }
                }
            }
        }
    }

    /// The six digits on both screens match.
    func approve() { session?.approvePairing() }

    func refuse() { session?.rejectPairing() }

    func leave(quietly: Bool = false) {
        if let sessionId, session?.phase == .connected { sendPlayback(["type": "RELEASE", "sessionId": sessionId, "pause": false]) }
        let old = session
        session = nil
        old?.close(reason: "left", sendBye: true)
        connection?.cancel()
        connection = nil
        heartbeat?.invalidate()
        heartbeat = nil
        sessionId = nil
        queue = []
        currentIndex = -1
        playing = false
        if !quietly { phase = .idle }
    }

    /// Deletes the keys of every shared queue this Mac has joined; each needs a code again.
    func forgetHosts() {
        (store as? DCKeychainPairStore)?.forgetAll()
        refreshRemembered()
    }

    private func ended(_ reason: String?) {
        let wasJoined = phase == .joined
        session = nil
        connection?.cancel()
        connection = nil
        heartbeat?.invalidate()
        heartbeat = nil
        sessionId = nil
        queue = []
        currentIndex = -1
        if let reason { phase = .failed(wasJoined ? "Left the shared queue: \(reason)" : reason) } else { phase = .idle }
    }

    private static func explain(_ reason: String) -> String {
        if reason.contains("pairing-rejected") { return "The host didn't let this Mac join. Ask them to choose “Let Someone Join” first." }
        if reason.contains("account-mismatch") { return "That device only accepts phones signed in to its own YouTube Music account. Join its “Shared queue” entry instead." }
        if reason.contains("not-paired") { return "The host no longer knows this Mac. Use “Forget Shared Queues I've Joined” and join again." }
        if reason.contains("forgotten") || reason.contains("switched off") { return "The host ended the shared queue or removed this Mac." }
        return reason
    }

    // MARK: Playback messages

    private func sendPlayback(_ object: [String: Any]) {
        guard let session, JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        _ = session.sendPlayback(data)
    }

    private func command(_ body: [String: Any]) {
        guard let sessionId else { message = "Not joined yet."; return }
        message = nil
        sendPlayback(["type": "COMMAND", "sessionId": sessionId, "queueRevision": queueRevision, "command": body])
    }

    /// Adds songs to the host's queue (ten at a time, the host's limit per request).
    func add(_ songs: [Song]) {
        let playable = songs.filter { ForeignBackup.isYouTubeVideoId($0.id) }
        guard !playable.isEmpty else { message = "Those songs can't be shared."; return }
        for start in stride(from: 0, to: playable.count, by: SharedQueuePolicy.maxPerRequest) {
            command(["action": "ADD", "songs": playable[start ..< min(start + SharedQueuePolicy.maxPerRequest, playable.count)].map(DCTarget.item(for:))])
        }
    }

    /// Only works if the host lets guests change what's playing; otherwise the host says so.
    func control(_ action: String) { command(["action": action]) }

    func remove(at index: Int) { command(["action": "REMOVE", "index": index]) }

    private func receive(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "STATE":
            guard let snapshot = message["snapshot"] as? [String: Any], let id = snapshot["sessionId"] as? String, !id.isEmpty,
                  let playback = snapshot["playback"] as? [String: Any], let queue = playback["queue"] as? [String: Any],
                  let items = queue["displayedItems"] as? [[String: Any]], items.count <= DCTarget.maxQueue
            else { return }
            sessionId = id
            queueRevision = (snapshot["queueRevision"] as? NSNumber)?.int64Value ?? queueRevision
            self.queue = items.compactMap(DCTarget.song(from:))
            currentIndex = (queue["currentIndex"] as? NSNumber)?.intValue ?? -1
            playing = (playback["playing"] as? Bool) ?? false
            if phase != .joined { phase = .joined }
        case "UPDATE":
            guard message["sessionId"] as? String == sessionId else { return }
            let revision = (message["queueRevision"] as? NSNumber)?.int64Value ?? queueRevision
            playing = (message["playing"] as? Bool) ?? playing
            if revision != queueRevision {
                sendPlayback(["type": "ATTACH"]) // ask for the whole state again
            } else if let index = (message["index"] as? NSNumber)?.intValue {
                currentIndex = index
            }
        case "ERROR":
            let code = message["error"] as? String ?? ""
            self.message = switch code {
            case "NOT_ALLOWED": "The host doesn't allow that."
            case "TOO_LARGE": "That's too many songs at once."
            case "UNSHAREABLE_QUEUE": "Those songs can't be shared."
            case "STALE_QUEUE": "The queue had just changed. Try again."
            default: "The host couldn't do that."
            }
            if sessionId == nil { ended("The host isn't sharing its queue right now.") }
        case "RELEASE":
            ended("The host ended the shared queue.")
        default: break
        }
    }
}
