import Darwin
import Foundation
import Observation

/// Optional Discord activity ("Listening to …") for the playing song, through the Discord
/// desktop app's local connection (its "RPC" socket in the per-user temporary folder). No
/// Discord login, token or network request is involved: if Discord isn't running, nothing
/// happens, and the app retries now and then while the setting is on.
///
/// Metrolist's desktop app signs in to Discord's Social SDK instead; that needs an approved
/// Discord application with a redirect back to the app, which a local build can't have. The
/// local socket is what other Mac music apps use.
@MainActor
@Observable
final class DiscordPresence {
    static let shared = DiscordPresence()

    /// The Discord application whose name and icon the activity shows. Metrolist's own
    /// public application id is the default; Settings can use another (create one free at
    /// discord.com/developers and paste its Application ID).
    static let defaultApplicationId = "1447278780795064401"
    static var applicationId: String {
        let saved = UserDefaults.standard.string(forKey: "discordApplicationId")?.trimmingCharacters(in: .whitespaces) ?? ""
        return saved.isEmpty || !saved.allSatisfy(\.isNumber) ? defaultApplicationId : saved
    }

    /// Folders searched for `discord-ipc-0` … `discord-ipc-9`; tests replace them.
    nonisolated(unsafe) static var socketDirectories: [String] = {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [environment["XDG_RUNTIME_DIR"], environment["TMPDIR"], NSTemporaryDirectory(), "/tmp"].compactMap { $0 }
        var seen = Set<String>()
        return candidates.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.filter { seen.insert($0).inserted }
    }()

    struct Track: Equatable {
        var videoId: String
        var title: String
        var artist: String
        var album: String?
        var artwork: String?
        var playing: Bool
        /// When the song (would have) started, given the current position.
        var started: Date
        var duration: Double
    }

    private(set) var enabled = false
    /// "Connected to Discord", "Discord isn't running"… for Settings.
    private(set) var status = "Off"
    private var current: Track?
    private var sent: Track?
    private var lastSend = Date.distantPast
    private var retryAt = Date.distantPast
    private var pendingSend: Task<Void, Never>?
    private let connection = DiscordConnection()

    /// The player's song, play state, position and duration, set by the player. Switching
    /// the setting on mid-song uses it; otherwise only the next player change would tell
    /// Discord anything.
    @ObservationIgnored var currentState: (() -> (Song?, Bool, Double, Double)?)?

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            retryAt = .distantPast
            if let (song, playing, position, duration) = currentState?() ?? nil {
                update(song: song, playing: playing, position: position, duration: duration)
            }
            sendSoon()
        } else {
            pendingSend?.cancel()
            sent = nil
            let connection = connection
            Task.detached { connection.clear(); connection.close() }
            status = "Off"
        }
    }

    /// The player's state changed. Cheap to call often: Discord is only told when the song,
    /// play/pause or the position (a seek) changes, at most once every 4 seconds.
    func update(song: Song?, playing: Bool, position: Double, duration: Double) {
        guard enabled else { return }
        let track = song.map {
            Track(videoId: $0.id, title: $0.title, artist: $0.artistText, album: $0.album?.name, artwork: $0.thumbnail,
                  playing: playing, started: Date().addingTimeInterval(-position), duration: duration > 0 ? duration : Double($0.duration ?? 0))
        }
        current = track
        if let track, let sent, track.videoId == sent.videoId, track.playing == sent.playing, abs(track.started.timeIntervalSince(sent.started)) < 3 { return }
        if track == nil, sent == nil { return }
        sendSoon()
    }

    private func sendSoon() {
        guard pendingSend == nil else { return }
        // Discord accepts five activity updates per 20 seconds; stay well inside that.
        let wait = max(0, 4 - Date().timeIntervalSince(lastSend))
        pendingSend = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 150))
            guard let self, !Task.isCancelled else { return }
            self.pendingSend = nil
            await self.send()
        }
    }

    private func send() async {
        guard enabled else { return }
        if Date() < retryAt { return }
        let track = current
        let connection = connection
        let applicationId = Self.applicationId
        let payload = Self.activity(for: track)
        let result = await Task.detached { () -> String? in
            if !connection.isOpen {
                if let failure = connection.open(applicationId: applicationId, directories: DiscordPresence.socketDirectories) { return failure }
            }
            return connection.setActivity(payload) ? nil : "Discord closed the connection."
        }.value
        lastSend = Date()
        if let result {
            status = result
            sent = nil
            retryAt = Date().addingTimeInterval(20)
            // Try again later while something is playing.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(21))
                guard let self, self.enabled, self.current != nil else { return }
                self.sendSoon()
            }
        } else {
            status = track == nil ? "Connected to Discord" : "Showing “\(track!.title)” on Discord"
            sent = track
        }
    }

    /// The activity Discord shows, or nil to clear it. Paused songs show without a timer.
    nonisolated static func activity(for track: Track?) -> [String: Any]? {
        guard let track else { return nil }
        // Discord wants 2–128 characters in each text field.
        func field(_ text: String) -> String {
            let trimmed = String(text.prefix(128))
            return trimmed.count >= 2 ? trimmed : trimmed + "  "
        }
        var activity: [String: Any] = [
            "type": 2, // Listening
            "status_display_type": 2, // "Listening to <song>" in the member list
            "details": field(track.title),
            "state": field(track.playing ? track.artist : "Paused · \(track.artist)"),
            "buttons": [["label": "Listen on YouTube Music", "url": "https://music.youtube.com/watch?v=\(track.videoId)"]],
        ]
        var assets: [String: Any] = [:]
        if let artwork = track.artwork, artwork.hasPrefix("https://") {
            assets["large_image"] = artwork.resizedThumbnail(512)
            if let album = track.album, !album.isEmpty { assets["large_text"] = field(album) }
        }
        if !assets.isEmpty { activity["assets"] = assets }
        if track.playing {
            let start = Int64(track.started.timeIntervalSince1970 * 1000)
            var timestamps: [String: Any] = ["start": start]
            if track.duration > 0 { timestamps["end"] = start + Int64(track.duration * 1000) }
            activity["timestamps"] = timestamps
        }
        return activity
    }
}

/// The socket to the Discord app. Used from one background task at a time.
final class DiscordConnection: @unchecked Sendable {
    private var socket: Int32 = -1
    private let lock = NSLock()

    var isOpen: Bool { lock.withLock { socket >= 0 } }

    /// Connects and sends the handshake. Returns why it failed, or nil.
    func open(applicationId: String, directories: [String]) -> String? {
        close()
        for directory in directories {
            for index in 0 ..< 10 {
                let path = "\(directory)/discord-ipc-\(index)"
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }
                var yes: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array(path.utf8)
                guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); continue }
                withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                    buffer.copyBytes(from: bytes)
                    buffer[bytes.count] = 0
                }
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                guard connected == 0 else { Darwin.close(fd); continue }
                lock.withLock { socket = fd }
                // Handshake, then Discord answers with READY (or an error and a close).
                guard write(op: 0, ["v": 1, "client_id": applicationId]), let reply = read(), reply.op == 1,
                      (reply.json["evt"] as? String) == "READY"
                else {
                    close()
                    return "Discord refused the connection (check the application id)."
                }
                return nil
            }
        }
        return "Discord isn't running."
    }

    func setActivity(_ activity: [String: Any]?) -> Bool {
        var args: [String: Any] = ["pid": Int(getpid())]
        args["activity"] = activity ?? NSNull()
        guard write(op: 1, ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString]) else { close(); return false }
        // Discord answers each command; read it so the socket never backs up.
        guard let reply = read(), reply.op == 1 else { close(); return false }
        return (reply.json["evt"] as? String) != "ERROR"
    }

    func clear() { if isOpen { _ = setActivity(nil) } }

    func close() {
        lock.withLock {
            if socket >= 0 { Darwin.close(socket) }
            socket = -1
        }
    }

    private func write(op: UInt32, _ object: [String: Any]) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return false }
        var frame = Data()
        withUnsafeBytes(of: op.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        let fd = lock.withLock { socket }
        guard fd >= 0 else { return false }
        return frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    private func read() -> (op: UInt32, json: [String: Any])? {
        let fd = lock.withLock { socket }
        guard fd >= 0, let header = readExactly(fd, 8) else { return nil }
        let op = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }.littleEndian)
        guard length <= 1 << 20, let body = readExactly(fd, length) else { return nil }
        return (op, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let got = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + offset, count - offset, 0) }
            if got <= 0 { return nil }
            offset += got
        }
        return data
    }
}
