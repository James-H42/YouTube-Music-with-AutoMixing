import Foundation

/// `Metrolist --dctest`: the Device Connect protocol checked end to end in memory, with the
/// phone's side played by the initiator half of `DCSession`, plus the target's command handling.
@MainActor
enum DCTest {
    /// Two sessions joined by a pipe that can be tampered with.
    @MainActor final class Pipe {
        var toResponder: [String] = [], toInitiator: [String] = []
        var initiator: DCSession!, responder: DCSession!
        var tamper: ((String) -> String)?
        var drop = false
        var recordedForReplay: [String] = []

        init(initiatorLocal: DCLocal, responderLocal: DCLocal, initiatorStore: DCPairStore, responderStore: DCPairStore, openPairing: Bool = true) {
            initiator = DCSession(role: .initiator, local: initiatorLocal, store: initiatorStore, send: { [unowned self] in self.toResponder.append($0) }, closeTransport: {})
            responder = DCSession(role: .responder, local: responderLocal, store: responderStore, send: { [unowned self] in self.toInitiator.append($0) }, closeTransport: {})
            responder.allowNewPairing = { openPairing }
        }

        /// Delivers queued frames until both queues are empty.
        func run() {
            var rounds = 0
            while (!toResponder.isEmpty || !toInitiator.isEmpty) && rounds < 200 {
                rounds += 1
                let a = toResponder; toResponder = []
                for text in a { recordedForReplay.append(text); responder.receive(tamper?(text) ?? text) }
                let b = toInitiator; toInitiator = []
                for text in b { initiator.receive(text) }
            }
        }
    }

    static func local(_ id: String, name: String, fingerprint: String = "", anonymous: Bool = true) -> DCLocal {
        DCLocal(deviceId: id, name: name, model: "Test", deviceType: "desktop", fingerprint: fingerprint, anonymous: anonymous, resolved: true)
    }

    static func run() async {
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
            if !passed { failures += 1 }
        }
        func hex(_ text: String) -> Data { Data(stride(from: 0, to: text.count, by: 2).map { UInt8(text[text.index(text.startIndex, offsetBy: $0) ..< text.index(text.startIndex, offsetBy: $0 + 2)], radix: 16)! }) }

        // Vectors published in Metrolist's own tests.
        let okm = DCCrypto.hkdf(ikm: hex(String(repeating: "0b", count: 22)), salt: hex("000102030405060708090a0b0c"), info: hex("f0f1f2f3f4f5f6f7f8f9"))
        check("HKDF matches the RFC 5869 vector Metrolist tests against", okm == hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"))
        check("account fingerprint matches Metrolist's value", DCCrypto.accountFingerprint("same") == "2RyssyoEoI4Ek/IP7bvpvb0zzlcCIkYRt/7cSJBKYq8=")
        check("address filter", DCAddress.isLAN("192.168.1.20") && DCAddress.isLAN("10.0.0.5") && DCAddress.isLAN("172.20.1.1") && DCAddress.isLAN("100.100.1.1")
              && DCAddress.isLAN("fe80::1%en0") && DCAddress.isLAN("fd12::1") && DCAddress.isLAN("::ffff:192.168.0.4")
              && !DCAddress.isLAN("8.8.8.8") && !DCAddress.isLAN("172.32.0.1") && !DCAddress.isLAN("2001:db8::1") && !DCAddress.isLAN("example.com"))

        // New pairing, both people approve.
        let phoneStore = DCMemoryPairStore(), macStore = DCMemoryPairStore()
        let phone = local("phone-device-1234567890", name: "Phone"), mac = local("mac-device-0987654321", name: "Mac")
        var pipe = Pipe(initiatorLocal: phone, responderLocal: mac, initiatorStore: phoneStore, responderStore: macStore)
        var phoneSAS = "", macSAS = ""
        var phoneConnected = false, macConnected = false
        pipe.initiator.onPairingRequest = { phoneSAS = $0.sas }
        pipe.responder.onPairingRequest = { macSAS = $0.sas }
        pipe.initiator.onConnected = { phoneConnected = true }
        pipe.responder.onConnected = { macConnected = true }
        pipe.initiator.start(); pipe.responder.start(); pipe.run()
        check("both sides show the same six-digit code", phoneSAS.count == 6 && phoneSAS == macSAS, phoneSAS)
        check("nothing is paired before anyone approves", phoneStore.pairs.isEmpty && macStore.pairs.isEmpty && !phoneConnected && !macConnected)
        pipe.responder.approvePairing(); pipe.run()
        check("one approval is not enough", !macConnected && !phoneConnected && macStore.pairs.isEmpty)
        pipe.initiator.approvePairing(); pipe.run()
        check("both approved: paired and connected", phoneConnected && macConnected && macStore.pairs.count == 1 && phoneStore.pairs.count == 1)
        check("both ends saved the same secret", macStore.pairs["phone-device-1234567890"]?.secret == phoneStore.pairs["mac-device-0987654321"]?.secret && macStore.pairs.values.first?.secret.count == 32)
        check("playback version 4 negotiated", pipe.responder.supportsPlayback && pipe.initiator.supportsPlayback)

        // Playback chunks across the encrypted channel: a message bigger than one frame.
        var received = Data()
        pipe.responder.onPlayback = { received = $0 }
        let big = Data((0 ..< 100_000).map { UInt8($0 % 251) })
        _ = pipe.initiator.sendPlayback(big); pipe.run()
        check("a 100 kB playback message crosses in chunks and arrives intact", received == big, "\(received.count) bytes")

        // Reconnect with the saved secret: no code, no approval.
        let savedMac = macStore.pairs
        pipe = Pipe(initiatorLocal: phone, responderLocal: mac, initiatorStore: phoneStore, responderStore: macStore, openPairing: false)
        phoneConnected = false; macConnected = false
        pipe.initiator.onConnected = { phoneConnected = true }
        pipe.responder.onConnected = { macConnected = true }
        var asked = false
        pipe.responder.onPairingRequest = { _ in asked = true }
        pipe.initiator.start(); pipe.responder.start(); pipe.run()
        check("a paired phone reconnects without pairing being open and without a code", phoneConnected && macConnected && !asked)

        // Replay and tampering.
        let recorded = pipe.recordedForReplay
        var closedReason = ""
        pipe.responder.onClosed = { closedReason = $0 }
        for old in recorded.suffix(2) { pipe.responder.receive(old) }
        check("replayed frames are ignored, not obeyed", closedReason.isEmpty && pipe.responder.phase == .connected)
        pipe.initiator.heartbeat()
        var frame = pipe.toResponder.last ?? ""
        pipe.toResponder = []
        if var object = (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any], var payload = object["payload"] as? String, !payload.isEmpty {
            payload = String(payload.dropLast(4)) + (payload.hasSuffix("AAAA") ? "BBBB" : "AAAA")
            object["payload"] = payload
            frame = String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
        }
        pipe.responder.receive(frame)
        check("a frame altered in transit closes the connection", pipe.responder.phase == .closed, closedReason)

        // A phone with the wrong secret (forgotten and re-paired elsewhere).
        let impostorStore = DCMemoryPairStore()
        var wrong = savedMac["phone-device-1234567890"]!
        wrong.peerId = "mac-device-0987654321"
        wrong.secret = DCCrypto.randomBytes(32)
        impostorStore.pairs["mac-device-0987654321"] = wrong
        pipe = Pipe(initiatorLocal: phone, responderLocal: mac, initiatorStore: impostorStore, responderStore: macStore, openPairing: false)
        var reason = ""
        var impostorConnected = false
        pipe.initiator.onConnected = { impostorConnected = true }
        pipe.responder.onConnected = { impostorConnected = true }
        pipe.responder.onClosed = { reason = $0 }
        pipe.initiator.start(); pipe.responder.start(); pipe.run()
        check("a peer with the wrong secret is refused", !impostorConnected && reason == "not-paired", reason)

        // A stranger while pairing is closed.
        pipe = Pipe(initiatorLocal: local("stranger-device-0000000001", name: "Stranger"), responderLocal: mac, initiatorStore: DCMemoryPairStore(), responderStore: macStore, openPairing: false)
        var strangerAsked = false
        var strangerConnected = false
        var refusal = ""
        pipe.responder.onPairingRequest = { _ in strangerAsked = true }
        pipe.responder.onConnected = { strangerConnected = true }
        pipe.initiator.onClosed = { refusal = $0 }
        pipe.initiator.start(); pipe.responder.start(); pipe.run()
        check("an unpaired device is refused while pairing is closed, and no prompt appears", !strangerAsked && !strangerConnected && refusal.contains("pairing-rejected"), refusal)

        // Different accounts.
        pipe = Pipe(initiatorLocal: local("phone-signed-in-0000000001", name: "P", fingerprint: DCCrypto.accountFingerprint("a"), anonymous: false), responderLocal: mac, initiatorStore: DCMemoryPairStore(), responderStore: DCMemoryPairStore())
        var mismatchConnected = false
        var mismatchReason = ""
        pipe.responder.onConnected = { mismatchConnected = true }
        pipe.initiator.onClosed = { mismatchReason = $0 }
        pipe.initiator.start(); pipe.responder.start(); pipe.run()
        check("a signed-in phone and an anonymous Mac refuse each other", !mismatchConnected && mismatchReason.contains("account-mismatch"), mismatchReason)

        // Chunk assembler limits.
        var assembler = DCAssembler()
        let chunks = dcChunks(Data(repeating: 7, count: 60_000))
        check("chunker splits at 24 kB", chunks.count == 3 && chunks.allSatisfy { $0.count == 3 })
        var rejected = false
        do { _ = try assembler.accept(chunks[1]) } catch { rejected = true }
        check("an out-of-order chunk is rejected", rejected)
        var bad = chunks[0]; bad.totalBytes = DCPlaybackLimits.maxBytes + 1
        var tooBig = false
        do { _ = try assembler.accept(bad) } catch { tooBig = true }
        check("an oversized declared message is rejected", tooBig)

        // The target's handling of a phone's commands, against the real player (muted, not playing).
        let player = AppModel.shared.player
        player.volume = 0
        let target = DCTarget(player: player)
        var out: [(String, [String: Any])] = []
        target.send = { peer, message in out.append((peer, message)); return true }
        func item(_ id: String, _ title: String) -> [String: Any] {
            ["id": id, "title": title, "thumbnail": NSNull(), "artists": [["id": NSNull(), "name": "Artist"]], "album": NSNull(), "duration": 200]
        }
        func send(_ object: [String: Any]) { target.receive((try? JSONSerialization.data(withJSONObject: object)) ?? Data(), from: "phone-device-1234567890") }
        func last(_ type: String) -> [String: Any]? { out.last { ($0.1["type"] as? String) == type }?.1 }
        func state() -> [String: Any]? { ((last("STATE")?["snapshot"] as? [String: Any])?["playback"] as? [String: Any])?["queue"] as? [String: Any] }

        send(["type": "COMMAND", "sessionId": "nobody", "command": ["action": "PLAY"]])
        check("commands from a device that hasn't attached are ignored", out.isEmpty)
        send(["type": "ATTACH"])
        let session = last("STATE")?["sessionId"] as? String ?? ""
        check("attach starts a session and the phone is sent the state", !session.isEmpty && state() != nil)
        let songs = [item("y32ejtuxSjM", "A"), item("GTmbyuTKT_c", "B"), item("dBLzh47wdrU", "C")]
        func command(_ body: [String: Any], revision: Int = -1) {
            let rev = revision >= 0 ? revision : Int(last("STATE").flatMap { ($0["snapshot"] as? [String: Any])?["queueRevision"] as? NSNumber }?.intValue ?? 0)
            send(["type": "COMMAND", "sessionId": session, "queueRevision": rev, "command": body])
        }
        command(["action": "REPLACE_QUEUE", "songs": songs, "index": 0, "positionMs": 0, "enabled": false, "title": "Test"])
        check("replace-queue loads the songs into the player", player.queue.map(\.id) == ["y32ejtuxSjM", "GTmbyuTKT_c", "dBLzh47wdrU"] && player.currentIndex == 0)
        player.pause()
        let revision = ((last("STATE")?["snapshot"] as? [String: Any])?["queueRevision"] as? NSNumber)?.intValue ?? -1
        command(["action": "MOVE", "index": 2, "toIndex": 1], revision: revision)
        check("move reorders the queue", player.queue.map(\.id) == ["y32ejtuxSjM", "dBLzh47wdrU", "GTmbyuTKT_c"], "queue \(player.queue.map(\.id)) rev \(revision) last error \(last("ERROR")?["error"] ?? "none")")
        command(["action": "REMOVE", "index": 1], revision: revision)
        check("a command made against an old queue is refused as stale", (last("ERROR")?["error"] as? String) == "STALE_QUEUE" && player.queue.count == 3)
        let fresh = ((last("STATE")?["snapshot"] as? [String: Any])?["queueRevision"] as? NSNumber)?.intValue ?? -1
        command(["action": "REMOVE", "index": 1], revision: fresh)
        check("remove with the right revision works", player.queue.map(\.id) == ["y32ejtuxSjM", "GTmbyuTKT_c"])
        command(["action": "VOLUME", "volume": 0.5])
        check("volume goes through the player", abs(player.volume - 0.5) < 0.001)
        player.volume = 0
        command(["action": "REPEAT", "repeatMode": "ALL"])
        check("repeat mode is applied", player.repeatMode == .all)
        player.repeatMode = .off
        command(["action": "SPEED", "speed": 1.5])
        check("a command this target doesn't support is answered with an error", (last("ERROR")?["error"] as? String) == "INVALID_MESSAGE")
        let before = player.queue.count
        command(["action": "ADD", "songs": [item("short", "x")]])
        check("a song that isn't a YouTube video is refused", player.queue.count == before && (last("ERROR")?["error"] as? String) == "UNSHAREABLE_QUEUE")
        var local = item("abcdefghijk", "x"); local["isLocal"] = true
        command(["action": "ADD", "songs": [local]])
        check("a phone-local file is refused", player.queue.count == before)
        command(["action": "ADD", "songs": (0 ..< 1_001).map { _ in item("abcdefghijk", "x") }])
        check("an oversized queue is refused", (last("ERROR")?["error"] as? String) == "TOO_LARGE" && player.queue.count == before)
        send(["type": "RELEASE", "sessionId": session])
        check("release ends the session and playback stays", target.controllers.isEmpty && player.queue.count == before)
        player.pause()
        print(failures == 0 ? "all Device Connect checks passed" : "\(failures) Device Connect checks FAILED")
    }
}
