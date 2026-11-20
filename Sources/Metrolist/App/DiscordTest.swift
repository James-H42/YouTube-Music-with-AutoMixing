import Darwin
import Foundation

/// `--discordtest`: the Discord activity against a stand-in for the Discord app (a local
/// socket that answers as Discord does), plus what happens when Discord isn't running.
enum DiscordTest {
    private static func check(_ ok: Bool, _ label: String, _ detail: String = "") -> Bool {
        print("\(ok ? "PASS" : "FAIL") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
        return ok
    }

    /// Reads one frame from a connected socket.
    private static func readFrame(_ fd: Int32) -> (UInt32, [String: Any])? {
        func exactly(_ n: Int) -> Data? {
            var data = Data(count: n), got = 0
            while got < n {
                let r = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, n - got, 0) }
                if r <= 0 { return nil }
                got += r
            }
            return data
        }
        guard let header = exactly(8) else { return nil }
        let op = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
        guard let body = exactly(length) else { return nil }
        return (op, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
    }

    private static func writeFrame(_ fd: Int32, op: UInt32, _ object: [String: Any]) {
        let body = try! JSONSerialization.data(withJSONObject: object)
        var frame = Data()
        withUnsafeBytes(of: op) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count)) { frame.append(contentsOf: $0) }
        frame.append(body)
        _ = frame.withUnsafeBytes { send(fd, $0.baseAddress!, $0.count, 0) }
    }

    static func run() async {
        var ok = true
        let folder = "/tmp/claude/dtest-\(getpid())"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        DiscordPresence.socketDirectories = [folder]

        // Not running: no socket at all.
        let connection = DiscordConnection()
        let missing = connection.open(applicationId: "123", directories: [folder])
        ok = check(missing == "Discord isn't running.", "no Discord app: reported, nothing sent", missing ?? "connected?!") && ok

        // A stand-in Discord.
        let path = folder + "/discord-ipc-0"
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8)
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(server, 1) == 0 else { print("FAIL could not create the stand-in socket (errno \(errno))"); exit(1) }

        final class Received: @unchecked Sendable { var frames: [(UInt32, [String: Any])] = []; var second: [(UInt32, [String: Any])] = [] }
        let received = Received()
        let serverDone = DispatchSemaphore(value: 0)
        Thread {
            // Two connections: the connection on its own, then the whole setting.
            for session in 0 ..< 2 {
                let client = accept(server, nil, nil)
                while let frame = readFrame(client) {
                    if session == 0 { received.frames.append(frame) } else { received.second.append(frame) }
                    if frame.0 == 0 {
                        writeFrame(client, op: 1, ["cmd": "DISPATCH", "evt": "READY", "data": ["v": 1]])
                    } else {
                        writeFrame(client, op: 1, ["cmd": frame.1["cmd"] ?? "", "evt": NSNull(), "nonce": frame.1["nonce"] ?? "", "data": [:]])
                    }
                }
                close(client)
                serverDone.signal()
            }
        }.start()

        let failure = connection.open(applicationId: "1447278780795064401", directories: [folder])
        ok = check(failure == nil, "connects to a running Discord and completes the handshake", failure ?? "") && ok
        let song = Song(id: "2ulp_AMut14", title: "Stronger", artists: [ArtistRef(name: "Kanye West", id: nil)], album: AlbumRef(name: "Graduation", id: nil),
                        duration: 311, thumbnail: "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj")
        let track = DiscordPresence.Track(videoId: song.id, title: song.title, artist: song.artistText, album: song.album?.name, artwork: song.thumbnail,
                                          playing: true, started: Date().addingTimeInterval(-30), duration: 311)
        ok = check(connection.setActivity(DiscordPresence.activity(for: track)), "sends the playing song") && ok
        var paused = track
        paused.playing = false
        ok = check(connection.setActivity(DiscordPresence.activity(for: paused)), "sends a pause") && ok
        connection.clear()
        connection.close()
        serverDone.wait()

        // Switching the setting on while a song plays shows that song straight away, not
        // only after the next song or pause.
        await MainActor.run {
            DiscordPresence.shared.currentState = { (song, true, 42, 311) }
            DiscordPresence.shared.setEnabled(true)
        }
        try? await Task.sleep(for: .seconds(1.5))
        let status = await MainActor.run { DiscordPresence.shared.status }
        await MainActor.run { DiscordPresence.shared.setEnabled(false) }
        serverDone.wait()
        close(server)
        let firstSent = received.second.first { $0.0 == 1 }.flatMap { ($0.1["args"] as? [String: Any])?["activity"] as? [String: Any] }
        ok = check(firstSent?["details"] as? String == "Stronger" && status.contains("Stronger"),
                   "switching the setting on mid-song shows that song at once", "status “\(status)”, sent \(String(describing: firstSent))") && ok

        let frames = received.frames
        let handshake = frames.first
        ok = check(handshake?.0 == 0 && handshake?.1["client_id"] as? String == "1447278780795064401" && handshake?.1["v"] as? Int == 1,
                   "handshake carries the application id", "\(String(describing: handshake))") && ok
        let playing = frames.count > 1 ? (frames[1].1["args"] as? [String: Any])?["activity"] as? [String: Any] : nil
        let timestamps = playing?["timestamps"] as? [String: Any]
        let start = (timestamps?["start"] as? NSNumber)?.int64Value ?? 0
        let end = (timestamps?["end"] as? NSNumber)?.int64Value ?? 0
        ok = check(playing?["type"] as? Int == 2 && playing?["details"] as? String == "Stronger" && playing?["state"] as? String == "Kanye West"
                   && end - start == 311_000 && abs(Double(start) / 1000 - Date().timeIntervalSince1970 + 30) < 5,
                   "activity: Listening, title, artist and a timer from the current position", "\(String(describing: playing))") && ok
        let assets = playing?["assets"] as? [String: Any]
        ok = check((assets?["large_image"] as? String)?.contains("=w512-h512") == true && assets?["large_text"] as? String == "Graduation",
                   "artwork (enlarged) and album name", "\(String(describing: assets))") && ok
        let buttons = playing?["buttons"] as? [[String: Any]]
        ok = check(buttons?.first?["url"] as? String == "https://music.youtube.com/watch?v=2ulp_AMut14", "a Listen on YouTube Music button") && ok
        let pausedActivity = frames.count > 2 ? (frames[2].1["args"] as? [String: Any])?["activity"] as? [String: Any] : nil
        ok = check(pausedActivity?["timestamps"] == nil && (pausedActivity?["state"] as? String)?.hasPrefix("Paused") == true, "a paused song shows no timer") && ok
        let cleared = frames.last.flatMap { ($0.1["args"] as? [String: Any])?["activity"] }
        ok = check(frames.count == 4 && cleared is NSNull, "turning it off clears the activity", "\(frames.count) frames") && ok
        print(ok ? "all Discord checks passed" : "some Discord checks failed")
        exit(ok ? 0 : 1)
    }
}
