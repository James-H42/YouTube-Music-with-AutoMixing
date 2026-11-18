import AppKit
import Foundation

/// Shared-queue checks.
///  - `--sqtest`: every guest rule against the real player (muted, not playing), plus a guest
///    Mac joining over the encrypted protocol through an in-memory pipe.
///  - `--sqnettest`: the same over real sockets on this Mac's LAN address, with the ports this
///    process listens on checked by `lsof` before, during and after.
///  - `--sqmixtest A B`: AutoMix plans and plays the transition into a song a guest added.
@MainActor
enum SQTest {
    private static var failures = 0

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
        if !passed { failures += 1 }
    }

    static func item(_ id: String, _ title: String, artist: String = "Artist", artistId: String? = nil) -> [String: Any] {
        ["id": id, "title": title, "thumbnail": NSNull(), "artists": [["id": artistId as Any? ?? NSNull(), "name": artist]], "album": NSNull(), "duration": 200]
    }

    /// Eleven-character ids that pass the YouTube video-id check. The first three are songs in
    /// the test data folder's cache, so the "playing" song loads without the network.
    static func fakeId(_ n: Int) -> String {
        switch n {
        case 1: "y32ejtuxSjM"
        case 2: "GTmbyuTKT_c"
        case 3: "dBLzh47wdrU"
        default: "sqtest" + String(format: "%05d", n)
        }
    }

    // MARK: In memory

    static func run() async {
        failures = 0
        // Never the real Keychain items (a test binary reading them makes macOS ask for permission).
        Keychain.service = "Metrolist.sqtest.\(UUID().uuidString)"
        let player = AppModel.shared.player
        AppModel.shared.settings.autoplay = false
        let autoMixWas = AppModel.shared.settings.autoMix
        AppModel.shared.settings.autoMix = false
        defer { AppModel.shared.settings.autoMix = autoMixWas }
        player.volume = 0
        let policy = SharedQueuePolicy(persisting: false)
        policy.open = true
        let target = DCTarget(player: player)
        target.guestPolicy = policy
        var out: [(String, [String: Any])] = []
        var revisions: [String: Int] = [:]
        target.send = { peer, message in
            out.append((peer, message))
            if let r = ((message["snapshot"] as? [String: Any])?["queueRevision"] as? NSNumber)?.intValue { revisions[peer] = r }
            return true
        }
        let owner = "phone-owner-000000001", g1 = "guest:guest-phone-0000001", g2 = "guest:guest-phone-0000002"
        func send(_ object: [String: Any], from peer: String) { target.receive((try? JSONSerialization.data(withJSONObject: object)) ?? Data(), from: peer) }
        func last(_ type: String, to peer: String) -> [String: Any]? { out.last { $0.0 == peer && ($0.1["type"] as? String) == type }?.1 }
        func lastError(_ peer: String) -> String? { last("ERROR", to: peer)?["error"] as? String }
        func revision(_ peer: String) -> Int { revisions[peer] ?? 0 }
        var sessionId = ""
        func command(_ body: [String: Any], from peer: String) {
            send(["type": "COMMAND", "sessionId": sessionId, "queueRevision": revision(peer), "command": body], from: peer)
        }
        func ids() -> [String] { player.queue.map(\.id) }

        // The host's own phone sets a queue: A playing, then the host's B and C.
        send(["type": "ATTACH"], from: owner)
        sessionId = last("STATE", to: owner)?["sessionId"] as? String ?? ""
        command(["action": "REPLACE_QUEUE", "songs": [item(fakeId(1), "A"), item(fakeId(2), "B"), item(fakeId(3), "C")], "index": 0, "positionMs": 0], from: owner)
        player.pause()
        check("the host's queue is set", ids() == [fakeId(1), fakeId(2), fakeId(3)] && player.currentIndex == 0)

        // A guest's phone with its own queue hands it over (TRANSFER): the host's queue must stay.
        out = []
        send(["type": "TRANSFER", "sessionId": "guest-session", "snapshot": ["sessionId": "guest-session", "playback": ["queue": ["displayedItems": [item(fakeId(99), "Guest's own")], "currentIndex": 0], "playing": true, "positionMs": 0]]], from: g1)
        let guestState = last("STATE", to: g1)
        check("a guest's transfer doesn't replace the host's queue", ids() == [fakeId(1), fakeId(2), fakeId(3)])
        check("the guest is sent the shared queue and the host's session instead", (guestState?["sessionId"] as? String) == sessionId
              && (((guestState?["snapshot"] as? [String: Any])?["playback"] as? [String: Any])?["queue"] as? [String: Any])?["displayedItems"].map { ($0 as? [Any])?.count } == 3)
        send(["type": "ATTACH"], from: g2)

        // Fair turns: each contributor's first song before anyone's second.
        command(["action": "ADD", "songs": [item(fakeId(4), "D (guest 1)")]], from: g1)
        check("a guest's song goes after the host's first queued song", ids() == [1, 2, 4, 3].map(fakeId), "\(ids())")
        command(["action": "PLAY_NEXT", "songs": [item(fakeId(5), "E (guest 2)")]], from: g2)
        check("a second guest's first song comes before anyone's second (play next is no jump)", ids() == [1, 2, 4, 5, 3].map(fakeId), "\(ids())")
        command(["action": "ADD", "songs": [item(fakeId(6), "F (guest 1)")]], from: g1)
        check("the first guest's second song waits for the second round", ids() == [1, 2, 4, 5, 3, 6].map(fakeId), "\(ids())")
        check("the owner is told about guest additions", (((last("STATE", to: owner)?["snapshot"] as? [String: Any])?["playback"] as? [String: Any])?["queue"] as? [String: Any])
            .flatMap { ($0["displayedItems"] as? [Any])?.count } == 6)
        check("who added what is recorded", policy.contributor(of: fakeId(4)) == g1 && policy.contributor(of: fakeId(5)) == g2 && policy.contributor(of: fakeId(2)) == nil)

        // Things guests may not do.
        let volume = player.volume
        player.repeatMode = .off
        for (action, extra) in [("PAUSE", [:]), ("PLAY", [:]), ("NEXT", [:]), ("SEEK", ["positionMs": 1000]), ("VOLUME", ["volume": 1.0]), ("CLEAR", [:]),
                                ("SHUFFLE", ["enabled": true]), ("REPEAT", ["repeatMode": "ALL"]), ("MOVE", ["index": 2, "toIndex": 1]), ("SELECT", ["index": 3, "positionMs": 0])] as [(String, [String: Any])] {
            out = []
            command(["action": action].merging(extra) { a, _ in a }, from: g1)
            check("a guest's \(action) is refused as not allowed", lastError(g1) == "NOT_ALLOWED" && ids() == [1, 2, 4, 5, 3, 6].map(fakeId) && player.currentIndex == 0 && player.volume == volume && !player.isPlaying && player.repeatMode == .off,
                  "error \(lastError(g1) ?? "none"), index \(player.currentIndex ?? -1), playing \(player.isPlaying), repeat \(player.repeatMode)")
        }
        out = []
        send(["type": "PULL", "sessionId": sessionId], from: g1)
        check("a guest can't pull playback away from the Mac", lastError(g1) == "NOT_ALLOWED" && target.controllers.contains(owner))
        command(["action": "REMOVE", "index": 4], from: g1)
        check("a guest can't remove the host's song", lastError(g1) == "NOT_ALLOWED" && ids().count == 6)
        command(["action": "REMOVE", "index": 3], from: g1)
        check("a guest can't remove another guest's song", lastError(g1) == "NOT_ALLOWED" && ids().count == 6)
        command(["action": "REMOVE", "index": 5], from: g1)
        check("a guest can remove a song they added", ids() == [1, 2, 4, 5, 3].map(fakeId), "\(ids())")

        // Tapping a song on the phone (REPLACE_QUEUE) adds only that song.
        command(["action": "REPLACE_QUEUE", "songs": [item(fakeId(7), "G"), item(fakeId(8), "H")], "index": 1, "positionMs": 0], from: g2)
        check("a guest tapping a song adds just that song and keeps the queue", ids().contains(fakeId(8)) && !ids().contains(fakeId(7)) && ids().first == fakeId(1) && player.currentIndex == 0, "\(ids())")

        // Limits and validation.
        out = []
        let before = ids()
        command(["action": "ADD", "songs": (10 ..< 21).map { item(fakeId($0), "x") }], from: g1)
        check("more than ten songs in one request is refused", lastError(g1) == "TOO_LARGE" && ids() == before)
        out = []
        command(["action": "ADD", "songs": [item(fakeId(4), "D again")]], from: g1)
        check("a song already waiting isn't added twice, and that's no error", lastError(g1) == nil && ids() == before)
        command(["action": "ADD", "songs": [item("bad id!", "bad")]], from: g1)
        check("a song that isn't a YouTube video is refused", lastError(g1) == "UNSHAREABLE_QUEUE" && ids() == before)
        var local = item(fakeId(30), "phone file"); local["isLocal"] = true
        command(["action": "ADD", "songs": [local]], from: g1)
        check("a file from the guest's phone is refused", ids() == before)
        out = []
        for batch in 0 ..< 3 { command(["action": "ADD", "songs": (0 ..< 7).map { item(fakeId(100 + batch * 7 + $0), "cap") }], from: g2) }
        let waitingG2 = player.queue.filter { policy.contributor(of: $0.id) == g2 }.count
        check("a guest can't have more than 20 songs waiting", waitingG2 == 16 && lastError(g2) == "NOT_ALLOWED", "\(waitingG2) waiting")
        let g2Order = player.queue.map(\.id).filter { $0.hasPrefix("sqtest001") }
        check("a guest's own songs keep the order they were sent in", g2Order == g2Order.sorted(), "\(g2Order)")
        let now = Date()
        let rate = SharedQueuePolicy(persisting: false)
        rate.open = true
        rate.record(guest: "guest:x", songIds: (0 ..< 30).map { fakeId(500 + $0) }, now: now)
        check("thirty songs in ten minutes is the most", rate.refusal(guest: "guest:x", count: 1, waiting: 0, now: now.addingTimeInterval(60)) == "NOT_ALLOWED"
              && rate.refusal(guest: "guest:x", count: 1, waiting: 0, now: now.addingTimeInterval(601)) == nil && rate.refusal(guest: "guest:y", count: 1, waiting: 0, now: now) == nil)

        // Hidden artists stay hidden.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sqtest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocked = BlockedContent(file: folder.appendingPathComponent("blocked.json"), aiFile: folder.appendingPathComponent("ai.txt"))
        blocked.hide(ArtistRef(name: "Hidden Person", id: "UCaaaaaaaaaaaaaaaaaaaaaa"))
        out = []
        let beforeHidden = ids()
        command(["action": "ADD", "songs": [item(fakeId(40), "hidden", artist: "Hidden Person", artistId: "UCaaaaaaaaaaaaaaaaaaaaaa")]], from: g1)
        check("a song by an artist the host hid is refused", lastError(g1) == "NOT_ALLOWED" && ids() == beforeHidden)
        blocked.unhide(blocked.artists[0])

        // With "Let guests play, pause and skip" on.
        policy.guestsCanControl = true
        out = []
        command(["action": "PAUSE"], from: g1)
        check("with control allowed, a guest's pause is obeyed", lastError(g1) == nil && !player.isPlaying)
        command(["action": "VOLUME", "volume": 0.25], from: g1)
        check("with control allowed, a guest can change the volume", lastError(g1) == nil && abs(player.volume - 0.25) < 0.001, "\(player.volume)")
        command(["action": "REPEAT", "repeatMode": "ONE"], from: g1)
        check("and switch repeat", lastError(g1) == nil && player.repeatMode == .one)
        command(["action": "CLEAR"], from: g1)
        check("but still can't clear the queue", lastError(g1) == "NOT_ALLOWED" && !player.queue.isEmpty)
        player.volume = volume
        player.repeatMode = .off
        policy.guestsCanControl = false

        // Leaving never pauses the host.
        send(["type": "RELEASE", "sessionId": sessionId, "pause": true], from: g2)
        check("a guest leaving is removed and can't pause the host", !target.controllers.contains(g2) && target.controllers.contains(owner))

        // Autoplay songs keep their mark through guest edits, so AutoMix still orders them.
        player.appendAutoQueued([Song(id: fakeId(60), title: "Auto 1"), Song(id: fakeId(61), title: "Auto 2")])
        send(["type": "ATTACH"], from: g1)
        command(["action": "ADD", "songs": [item(fakeId(62), "after the queued ones")]], from: g1)
        let position = ids().firstIndex(of: fakeId(62)) ?? -1
        check("a guest's song goes before the songs Autoplay lined up", position >= 0 && position < (ids().firstIndex(of: fakeId(60)) ?? -1), "\(ids())")
        check("Autoplay's songs are still marked as Autoplay's after a remote edit", player.isAutoQueued(fakeId(60)) && player.isAutoQueued(fakeId(61)))

        // Your own phone, with commands shaped exactly as Metrolist sends them (volume as a float).
        out = []
        send(["type": "COMMAND", "sessionId": sessionId, "queueRevision": revision(owner), "command": ["action": "VOLUME", "volume": NSNumber(value: Float(0.4))]], from: owner)
        check("the host's phone sets the Mac's volume", abs(player.volume - 0.4) < 0.001, "\(player.volume)")
        send(["type": "COMMAND", "sessionId": sessionId, "queueRevision": revision(owner), "command": ["action": "REPEAT", "repeatMode": "ONE"]], from: owner)
        check("the host's phone switches repeat (loop one) on the Mac", player.repeatMode == .one)
        let update = last("UPDATE", to: owner)
        check("and is told the new volume and repeat mode", (update?["repeatMode"] as? String) == "ONE" && abs(((update?["volume"] as? NSNumber)?.doubleValue ?? -1) - 0.4) < 0.001, "\(update ?? [:])")
        send(["type": "COMMAND", "sessionId": sessionId, "queueRevision": revision(owner), "command": ["action": "REPEAT"]], from: owner)
        check("repeat without a mode cycles, as on the phone", player.repeatMode == .off, "\(player.repeatMode)")
        // A change made on the Mac itself, while paused, reaches the phone.
        player.pause()
        out = []
        player.volume = 0.7
        player.repeatMode = .all
        try? await Task.sleep(for: .seconds(2.5))
        let paused = last("UPDATE", to: owner)
        check("volume and repeat changed on the Mac while paused show on the phone", (paused?["repeatMode"] as? String) == "ALL" && abs(((paused?["volume"] as? NSNumber)?.doubleValue ?? -1) - 0.7) < 0.001, "\(paused ?? [:])")
        player.volume = volume
        player.repeatMode = .off

        // The owner still has full control.
        let ownerBefore = ids().count
        command(["action": "REMOVE", "index": 1], from: owner)
        check("the host's own phone keeps full control", ids().count == ownerBefore - 1)

        // Ending the shared queue.
        target.stop(guests: true)
        check("ending lets go of guests and keeps the host's phone", !target.controllers.contains(g1) && target.controllers.contains(owner))
        policy.open = false
        out = []
        send(["type": "ATTACH"], from: g1)
        check("after it ends, a guest is refused", lastError(g1) == "NOT_ALLOWED" && !target.controllers.contains(g1))
        target.stop()
        player.pause()

        signedInGuests()
        await clientOverPipe()
        await endpointChecks()
        print(failures == 0 ? "all shared-queue checks passed" : "\(failures) shared-queue checks FAILED")
    }

    /// A guest Mac (the client) and the host's guest endpoint over the real encrypted protocol, in memory.
    private static func clientOverPipe() async {
        let player = AppModel.shared.player
        let policy = SharedQueuePolicy(persisting: false)
        policy.open = true
        let target = DCTarget(player: player)
        target.guestPolicy = policy
        let hostStore = DCMemoryPairStore()
        let client = SharedQueueClient(store: DCMemoryPairStore())
        let pipe = DCTest.Pipe(initiatorLocal: DCTest.local("guest-mac-000000000001", name: "Guest Mac"), responderLocal: DCTest.local("host-shared-0000000001", name: "Host · Shared queue"),
                               initiatorStore: DCMemoryPairStore(), responderStore: hostStore)
        var hostCode = ""
        pipe.responder.onPairingRequest = { hostCode = $0.sas }
        pipe.responder.onPlayback = { data in target.receive(data, from: DeviceConnect.guestPrefix + "guest-mac-000000000001") }
        target.send = { _, object in
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            return pipe.responder.sendPlayback(data)
        }
        client.attach(pipe.initiator)
        pipe.initiator.start(); pipe.responder.start(); pipe.run()
        guard case .pairing(let code) = client.phase else { return check("the guest Mac is asked to compare a code", false, "\(client.phase)") }
        check("the guest Mac and the host show the same code", code == hostCode && code.count == 6, code)
        client.approve(); pipe.responder.approvePairing(); pipe.run()
        check("after both approve, the guest Mac has joined and sees the host's queue", client.joined && client.queue.map(\.id) == player.queue.map(\.id), "\(client.phase), \(client.queue.count) vs \(player.queue.count)")
        let song = Song(id: fakeId(70), title: "From the guest Mac", artists: [ArtistRef(name: "Someone")])
        client.add([song]); pipe.run()
        check("a song added on the guest Mac reaches the host's queue", player.queue.contains { $0.id == fakeId(70) })
        check("and the guest Mac's view follows", client.queue.contains { $0.id == fakeId(70) })
        client.control("PAUSE"); pipe.run()
        check("the guest Mac is told when the host doesn't allow something", client.message == "The host doesn't allow that.", client.message ?? "")
        client.leave(); pipe.run()
        check("leaving disconnects the guest Mac and keeps the host playing state", client.phase == .idle && target.controllers.isEmpty)
        player.pause()
    }

    /// A phone signed in to its own YouTube account joining the guest endpoint. The phone's side
    /// is played by the initiator half of `DCSession`, which applies Metrolist's account check.
    private static func signedInGuests() {
        let phone = DCTest.local("guest-phone-signed-in-01", name: "Guest phone", fingerprint: DCCrypto.accountFingerprint("someone-elses-account"), anonymous: false)
        let mac = DCTest.local("host-shared-0000000001", name: "Host · Shared queue")
        func attempt(mirror: Bool, phoneStore: DCMemoryPairStore, macStore: DCMemoryPairStore, open: Bool = true) -> (connected: Bool, phoneCode: String, macCode: String, reason: String, mirrored: Bool) {
            let pipe = DCTest.Pipe(initiatorLocal: phone, responderLocal: mac, initiatorStore: phoneStore, responderStore: macStore, openPairing: open)
            pipe.responder.mirrorPeerAccount = mirror
            var phoneCode = "", macCode = "", reason = "", connected = false
            pipe.initiator.onPairingRequest = { phoneCode = $0.sas }
            pipe.responder.onPairingRequest = { macCode = $0.sas }
            pipe.initiator.onClosed = { reason = $0 }
            pipe.initiator.onConnected = { connected = true }
            pipe.initiator.start(); pipe.responder.start(); pipe.run()
            if !macCode.isEmpty { pipe.responder.approvePairing(); pipe.initiator.approvePairing(); pipe.run() }
            return (connected && pipe.responder.phase == .connected, phoneCode, macCode, reason, pipe.responder.mirroredAccount)
        }
        let off = attempt(mirror: false, phoneStore: DCMemoryPairStore(), macStore: DCMemoryPairStore())
        check("switch off: a signed-in phone is refused, as before", !off.connected && off.reason.contains("account-mismatch"), off.reason)
        let phoneStore = DCMemoryPairStore(), macStore = DCMemoryPairStore()
        let on = attempt(mirror: true, phoneStore: phoneStore, macStore: macStore)
        check("switch on: a signed-in phone is asked for the same code on both sides", on.phoneCode.count == 6 && on.phoneCode == on.macCode, on.phoneCode)
        check("and pairs once both approve", on.connected && on.mirrored && macStore.pairs.count == 1)
        let again = attempt(mirror: true, phoneStore: phoneStore, macStore: macStore, open: false)
        check("it reconnects later without a code", again.connected && again.macCode.isEmpty)
        let closed = attempt(mirror: true, phoneStore: DCMemoryPairStore(), macStore: DCMemoryPairStore(), open: false)
        check("a new signed-in phone is still refused while joining is closed", !closed.connected && closed.reason.contains("pairing-rejected"), closed.reason)
        var unresolved = phone
        unresolved.resolved = false
        let pipe = DCTest.Pipe(initiatorLocal: unresolved, responderLocal: mac, initiatorStore: DCMemoryPairStore(), responderStore: DCMemoryPairStore())
        pipe.responder.mirrorPeerAccount = true
        var reason = ""
        pipe.initiator.onClosed = { reason = $0 }
        pipe.initiator.start(); pipe.responder.start(); pipe.run()
        check("a phone whose account isn't resolved is still refused", pipe.responder.phase == .closed && !reason.isEmpty, reason)
    }

    /// The guest endpoint's identity is separate from the owner's.
    private static func endpointChecks() async {
        let guests = DeviceConnect(mode: .guest, store: DCMemoryPairStore())
        let owner = DeviceConnect(mode: .owner, store: DCMemoryPairStore())
        check("the guest identity has its own device id", guests.deviceId != owner.deviceId && dcIsValidDeviceId(guests.deviceId))
        check("the guest identity is always anonymous", guests.localIdentity().anonymous && guests.localIdentity().fingerprint.isEmpty)
        check("phones see it as a shared queue", guests.advertisedName.hasSuffix("· Shared queue"), guests.advertisedName)
        check("guests are not switched on at launch", !guests.enabled && !guests.listening)
        check("guest peers are namespaced", guests.peerKey("abc") == "guest:abc" && owner.peerKey("abc") == "abc")
    }

    // MARK: Real sockets

    static func network() async {
        failures = 0
        Keychain.service = "Metrolist.sqtest.\(UUID().uuidString)"
        NSApplication.shared.setActivationPolicy(.accessory)
        func wait(_ seconds: Double, until done: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if done() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
            return done()
        }
        func listeningPorts() -> [String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-nP", "-a", "-p", "\(getpid())", "-iTCP", "-sTCP:LISTEN"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").dropFirst().map { String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(8).joined(separator: " ")) }
        }

        let player = AppModel.shared.player
        AppModel.shared.settings.autoplay = false
        player.volume = 0
        check("nothing listens before a shared queue is started", listeningPorts().isEmpty, listeningPorts().joined(separator: ", "))
        guard let address = SharedQueue.lanAddresses().first else { return check("this Mac has a private LAN address to test with", false) }

        let connect = DeviceConnect.guests
        SharedQueue.shared.policy.open = true
        connect.serveForTesting()
        connect.openPairing()
        _ = await wait(5) { connect.port != nil }
        guard let port = connect.port else { return check("the guest listener starts", false, connect.message ?? "") }
        let ports = listeningPorts()
        check("while it runs, exactly one port is open, the guest listener's", ports.count == 1 && ports[0].contains(":\(port)"), ports.joined(separator: ", "))
        check("your own Device Connect stays off", !DeviceConnect.shared.listening)

        // The host's queue: two songs, paused.
        DeviceConnect.target.receive((try? JSONSerialization.data(withJSONObject: ["type": "ATTACH"])) ?? Data(), from: "local-test-owner")
        player.applyRemoteQueue([Song(id: fakeId(1), title: "A"), Song(id: fakeId(2), title: "B")], index: 0, position: 0, playing: false, restart: false)

        let client = SharedQueueClient(store: DCKeychainPairStore(prefix: "sqtest.joined"))
        client.log = { print("   client:", $0) }
        client.join(address: address, port: port)
        _ = await wait(10) { if case .pairing = client.phase { return !connect.requests.isEmpty }; return false }
        guard case .pairing(let code) = client.phase, let request = connect.requests.first else { return check("a guest Mac connecting over the network is asked to pair", false, "\(client.phase); host events: \(connect.events)") }
        check("over the network both show the same six digits", request.sas == code, code)
        connect.approve(request)
        client.approve()
        _ = await wait(10) { client.joined }
        check("the guest Mac joins over the network", client.joined && connect.connected.count == 1, "\(client.phase)")
        check("it sees the host's queue", client.queue.map(\.id).prefix(2) == [fakeId(1), fakeId(2)], "\(client.queue.map(\.id))")
        client.add([Song(id: fakeId(3), title: "Added over the network", artists: [ArtistRef(name: "Guest")])])
        _ = await wait(5) { player.queue.contains { $0.id == fakeId(3) } && client.queue.contains { $0.id == fakeId(3) } }
        check("a song added over the network reaches the host and the guest's view", player.queue.contains { $0.id == fakeId(3) } && client.queue.contains { $0.id == fakeId(3) })
        check("the host knows who added it", SharedQueue.shared.addedByName(fakeId(3)) != nil, SharedQueue.shared.addedByName(fakeId(3)) ?? "nobody")
        client.control("NEXT")
        _ = await wait(5) { client.message != nil }
        check("skipping is refused over the network", client.message == "The host doesn't allow that." && player.currentIndex == 0, client.message ?? "")
        check("pairing closed by itself after one guest joined", !connect.pairingIsOpen)

        // A second Mac while pairing is closed.
        let stranger = SharedQueueClient(store: DCMemoryPairStore())
        stranger.join(address: address, port: port)
        _ = await wait(10) { if case .failed = stranger.phase { return true }; return false }
        check("a new device is refused while joining is closed, with no prompt on the host", { if case .failed(let text) = stranger.phase { return text.contains("didn't let") }; return false }() && connect.requests.isEmpty, "\(stranger.phase)")

        // Reconnecting with the remembered key, without a code.
        client.leave()
        _ = await wait(3) { connect.connected.isEmpty }
        client.join(address: address, port: port)
        _ = await wait(10) { client.joined }
        check("a remembered guest rejoins without a code while the shared queue runs", client.joined)

        // Removing the guest.
        let guestId = connect.paired.first?.id ?? ""
        SharedQueue.shared.remove(guest: guestId)
        _ = await wait(5) { if case .failed = client.phase { return true }; return false }
        check("removing a guest disconnects them at once", { if case .failed = client.phase { return true }; return false }() && connect.paired.isEmpty, "\(client.phase)")
        client.join(address: address, port: port)
        _ = await wait(10) { if case .failed = client.phase { return true }; return false }
        check("a removed guest can't get back in", !client.joined, "\(client.phase)")

        // Ending it.
        connect.shutdown()
        _ = await wait(3) { listeningPorts().isEmpty }
        check("after it ends nothing listens", listeningPorts().isEmpty && !connect.listening, listeningPorts().joined(separator: ", "))
        client.join(address: address, port: port)
        _ = await wait(10) { if case .failed = client.phase { return true }; return false }
        check("and joining fails", !client.joined)

        client.forgetHosts()
        (connect.store as? DCKeychainPairStore)?.forgetAll()
        player.pause()
        print(failures == 0 ? "all shared-queue network checks passed" : "\(failures) shared-queue network checks FAILED")
    }

    // MARK: AutoMix

    /// Plays A alone; a guest adds B; AutoMix must plan A → B and make the transition.
    static func mixTest() async {
        failures = 0
        let model = AppModel.shared
        let player = model.player
        let args = Array(CommandLine.arguments.drop { $0 != "--sqmixtest" }.dropFirst()).filter { !$0.hasPrefix("--") }
        guard args.count >= 2 else { print("need two video ids"); return }
        let a = model.library.song(args[0]) ?? Song(id: args[0], title: args[0])
        let b = model.library.song(args[1]) ?? Song(id: args[1], title: args[1])
        let wasOn = model.settings.autoMix
        model.settings.autoMix = true
        model.settings.autoplay = false
        player.volume = 0
        defer { model.settings.autoMix = wasOn }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

        player.play([a])
        for _ in 0 ..< 100 where player.position < 1 { await wait(0.1) }
        let policy = SharedQueuePolicy(persisting: false)
        policy.open = true
        let target = DCTarget(player: player)
        target.guestPolicy = policy
        var sessionId = ""
        var revision = 0
        target.send = { _, message in
            if let id = message["sessionId"] as? String { sessionId = id }
            if let r = ((message["snapshot"] as? [String: Any])?["queueRevision"] as? NSNumber)?.intValue { revision = r }
            return true
        }
        func send(_ object: [String: Any]) { target.receive((try? JSONSerialization.data(withJSONObject: object)) ?? Data(), from: "guest:mix-test-guest") }
        send(["type": "ATTACH"])
        send(["type": "COMMAND", "sessionId": sessionId, "queueRevision": revision, "command": ["action": "ADD", "songs": [target.item(for: b)]]])
        check("the guest's song is next", player.nextSong?.id == b.id && player.currentSong?.id == a.id && player.isPlaying)
        check("AutoMix is available for the pair", player.autoMixActive && player.mixPair != nil)
        for _ in 0 ..< 600 where player.nextMixPlan == nil { await wait(0.1) }
        guard let plan = player.nextMixPlan else { return check("AutoMix planned the transition into the guest's song", false) }
        print("planned: \(plan.summary) — \(plan.detail); leaves at \(String(format: "%.1f", plan.outStart)) s")
        check("AutoMix planned the transition into the guest's song", true)
        player.seek(to: max(0, plan.outStart - 6))
        var mixed = false, handed = false
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            await wait(0.1)
            if player.mixActivity != nil { mixed = true }
            if player.currentSong?.id == b.id { handed = true }
            if mixed, handed, player.mixActivity == nil { break }
        }
        check("the transition ran and handed over to the guest's song", mixed && handed && player.isPlaying, "mixed \(mixed), handed over \(handed)")
        player.pause()
        target.stop()
        print(failures == 0 ? "all shared-queue AutoMix checks passed" : "\(failures) shared-queue AutoMix checks FAILED")
    }
}
