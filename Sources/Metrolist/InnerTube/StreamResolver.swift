import Foundation

enum AudioQuality: String, CaseIterable, Identifiable, Codable {
    case high, low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: "Highest available (Opus, up to 256 kbps)"
        case .low: "Data saver (Opus ~50 kbps)"
        }
    }
}

struct ResolvedStream: Codable {
    var videoId: String
    var url: URL
    var itag: Int
    var mimeType: String
    var bitrate: Int
    var contentLength: Int64?
    var loudnessDb: Double?
    var durationSeconds: Double?
    var clientId: String
    var userAgent: String
    var chunkSize: Int
    var expiresAt: Date
    /// YouTube's "this was played" statistics URL for the stream.
    var trackingURL: String?
    var clientName: String?

    var isOpus: Bool { mimeType.contains("opus") }
    var fileExtension: String { mimeType.contains("webm") ? "webm" : "m4a" }
}

/// Resolves a direct audio URL for a video by presenting spoofed native-device identities to
/// the InnerTube player endpoint, falling back through them when one is refused.
actor StreamResolver {
    static let shared = StreamResolver()

    private var cache: [String: ResolvedStream] = [:]
    /// Identities that recently failed for a given video, so a retry moves on to the next one.
    private var failedClients: [String: (clients: Set<String>, at: Date)] = [:]
    /// Consecutive failures and cooldown per identity, across all videos.
    private var health: [String: (failures: Int, cooldownUntil: Date)] = [:]
    private var inFlight: [String: Task<ResolvedStream, Error>] = [:]
    /// While YouTube is bot-checking this connection, requests are held back instead of
    /// hammering the player endpoint, which only prolongs the block.
    private var blockedUntil = Date.distantPast
    private var blockCount = 0
    private var lastRequest = Date.distantPast

    private static let videoFailureLifetime = 300.0
    private static let failuresBeforeCooldown = 2
    private static let cooldown = 120.0
    /// Smallest gap between two player requests.
    private static let spacing = 0.35

    /// True while stream requests are being held back after a bot check.
    var isBlocked: Bool { Date() < blockedUntil }

    func resolve(videoId: String, quality: AudioQuality, forceRefresh: Bool = false) async throws -> ResolvedStream {
        let key = "\(videoId)|\(quality.rawValue)"
        if !forceRefresh, let cached = cache[key], cached.expiresAt.timeIntervalSinceNow > 600 {
            return cached
        }
        // Several parts of the app can ask for the same song at once; make one request.
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await self.fetch(videoId: videoId, quality: quality, key: key, forceRefresh: forceRefresh) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    private func fetch(videoId: String, quality: AudioQuality, key: String, forceRefresh: Bool) async throws -> ResolvedStream {
        if forceRefresh, let stale = cache.removeValue(forKey: key) {
            // The media server refused this identity's URL: try another one for this video.
            var failed = failedClients[videoId]?.clients ?? []
            failed.insert(stale.clientId)
            failedClients[videoId] = (failed, Date())
            recordFailure(stale.clientId)
        }
        guard Date() >= blockedUntil else { throw YTError.botCheck }

        var botChecked = false
        var lastError: Error = YTError.noStream
        // Second pass: a fresh anonymous identity, which is what a bot check is usually tied to.
        for attempt in 0 ..< 2 {
            if let failed = failedClients[videoId], Date().timeIntervalSince(failed.at) > Self.videoFailureLifetime {
                failedClients[videoId] = nil
            }
            let excluded = failedClients[videoId]?.clients ?? []
            let now = Date()
            var candidates = YouTubeClient.playbackClients.filter { !excluded.contains($0.id) }
            if candidates.isEmpty { candidates = YouTubeClient.playbackClients }
            // Healthy identities first; ones cooling down are a last resort, not skipped.
            candidates.sort { (health[$0.id]?.cooldownUntil ?? .distantPast > now ? 1 : 0) < (health[$1.id]?.cooldownUntil ?? .distantPast > now ? 1 : 0) }

            botChecked = false
            for client in candidates {
                do {
                    try await pace()
                    let stream = try await resolve(videoId: videoId, quality: quality, client: client)
                    cache[key] = stream
                    health[client.id] = nil
                    blockCount = 0
                    return stream
                } catch YTError.offline {
                    throw YTError.offline
                } catch YTError.botCheck {
                    botChecked = true
                    lastError = YTError.botCheck
                    recordFailure(client.id)
                } catch {
                    lastError = error
                    if case YTError.unplayable = error {} else { recordFailure(client.id) }
                }
            }
            guard botChecked, attempt == 0 else { break }
            InnerTube.shared.resetStreamVisitorData()
        }
        if botChecked, InnerTube.shared.isSignedIn, UserDefaults.standard.object(forKey: "accountPlayback") as? Bool ?? true {
            // The connection is refused anonymously. As Metrolist does, fall back to asking as
            // the signed-in listener, through YouTube Music's own web identity.
            do {
                try await pace()
                let stream = try await resolveSignedIn(videoId: videoId, quality: quality)
                cache[key] = stream
                return stream
            } catch YTError.offline {
                throw YTError.offline
            } catch YTError.botCheck {
                lastError = YTError.botCheck
            } catch {
                // Report why the account route failed rather than the bot check it was working around.
                blockCount += 1
                blockedUntil = Date().addingTimeInterval(min(600, 60 * pow(2, Double(blockCount - 1))))
                throw error
            }
        }
        if botChecked {
            // Back off: one minute, doubling up to ten, until a request gets through again.
            blockCount += 1
            blockedUntil = Date().addingTimeInterval(min(600, 60 * pow(2, Double(blockCount - 1))))
            throw YTError.botCheck
        }
        throw lastError
    }

    /// Asks for a stream as the signed-in account, with YouTube Music's web identity. Its
    /// answers carry scrambled addresses, which `PlayerCipher` puts right, and the media
    /// servers expect an attestation token, which `PoTokenGenerator` mints.
    private func resolveSignedIn(videoId: String, quality: AudioQuality) async throws -> ResolvedStream {
        let client = YouTubeClient.webRemixPlayback
        let player = try await PlayerCipher.shared.current()
        // As in Metrolist: the request's token is bound to the session, the media one to the video.
        let visitor = await InnerTube.shared.visitorData()
        var requestToken: String?
        if let visitor { requestToken = try? await PoTokenGenerator.shared.token(for: visitor) }
        let mediaToken = try? await PoTokenGenerator.shared.token(for: videoId)

        var body: [String: Any] = [
            "videoId": videoId, "contentCheckOk": true, "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": player.signatureTimestamp, "html5Preference": "HTML5_PREF_WANTS"]],
        ]
        if let requestToken { body["serviceIntegrityDimensions"] = ["poToken": requestToken] }
        let json = try await InnerTube.shared.post("player", client: client, body: body)

        let status = json["playabilityStatus"]
        let reason = status["reason"].string ?? status["messages"][0].string ?? ""
        if status["status"].string != "OK", reason.lowercased().contains("not a bot") { throw YTError.botCheck }
        guard status["status"].string == "OK" else { throw YTError.unplayable(reason.isEmpty ? "This track can't be played." : reason) }
        if let returned = json["videoDetails"]["videoId"].string, returned != videoId { throw YTError.noStream }

        let audio = json["streamingData"]["adaptiveFormats"].array.filter { ($0["mimeType"].string ?? "").hasPrefix("audio/") }
        let playable = try await PlayerCipher.shared.unscramble(audio, token: mediaToken)
        guard let format = Self.select(playable.map(\.format), quality: quality),
              let url = playable.first(where: { $0.format["itag"].int == format["itag"].int && $0.format["audioTrack"]["id"].string == format["audioTrack"]["id"].string })?.url
        else { throw YTError.noStream }

        let expire = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "expire" }?.value.flatMap(Double.init)
        let expirySeconds = json["streamingData"]["expiresInSeconds"].double ?? 21_600
        return ResolvedStream(
            videoId: videoId,
            url: url,
            itag: format["itag"].int ?? 0,
            mimeType: format["mimeType"].string ?? "",
            bitrate: format["bitrate"].int ?? 0,
            contentLength: format["contentLength"].string.flatMap(Int64.init),
            loudnessDb: json["playerConfig"]["audioConfig"]["loudnessDb"].double ?? format["loudnessDb"].double,
            durationSeconds: format["approxDurationMs"].double.map { $0 / 1000 } ?? json["videoDetails"]["lengthSeconds"].double,
            clientId: "WEB_REMIX_ACCOUNT",
            userAgent: client.userAgent,
            chunkSize: client.rangeChunkSize,
            expiresAt: expire.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(expirySeconds),
            trackingURL: nil,
            clientName: client.clientName
        )
    }

    private func recordFailure(_ clientId: String) {
        let failures = (health[clientId]?.failures ?? 0) + 1
        let until = failures >= Self.failuresBeforeCooldown ? Date().addingTimeInterval(Self.cooldown) : Date.distantPast
        health[clientId] = (failures, until)
    }

    /// Spaces player requests out so a burst of skips doesn't look like a scraper.
    private func pace() async throws {
        let wait = Self.spacing - Date().timeIntervalSince(lastRequest)
        lastRequest = Date().addingTimeInterval(max(0, wait))
        if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
    }

    /// Lets the next request through immediately (after signing in or out, or a manual retry).
    func clearBlock() {
        blockedUntil = .distantPast
        blockCount = 0
        health = [:]
        failedClients = [:]
    }

    private func resolve(videoId: String, quality: AudioQuality, client: YouTubeClient) async throws -> ResolvedStream {
        var body: [String: Any] = ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true]
        if !client.useMusicPlayerEndpoint { body["videoCheckOk"] = true }
        let json = try await InnerTube.shared.post("player", client: client, body: body)

        let status = json["playabilityStatus"]
        let reason = (status["reason"].string ?? status["messages"][0].string ?? "").lowercased()
        if status["status"].string != "OK", reason.contains("not a bot") || reason.contains("confirm you") && reason.contains("bot") {
            throw YTError.botCheck
        }
        guard status["status"].string == "OK" else {
            throw YTError.unplayable(status["reason"].string ?? status["messages"][0].string ?? "This track can't be played.")
        }
        // YouTube substitutes a placeholder video when it rejects a client.
        if let returned = json["videoDetails"]["videoId"].string, returned != videoId {
            throw YTError.noStream
        }

        let formats = json["streamingData"]["adaptiveFormats"].array.filter {
            ($0["mimeType"].string ?? "").hasPrefix("audio/") && $0["url"].string != nil
        }
        guard let format = Self.select(formats, quality: quality),
              let urlString = format["url"].string, let url = URL(string: urlString)
        else { throw YTError.noStream }

        let expire = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "expire" }?.value.flatMap(Double.init)
        let expirySeconds = json["streamingData"]["expiresInSeconds"].double ?? 21_600

        return ResolvedStream(
            videoId: videoId,
            url: url,
            itag: format["itag"].int ?? 0,
            mimeType: format["mimeType"].string ?? "",
            bitrate: format["bitrate"].int ?? 0,
            contentLength: format["contentLength"].string.flatMap(Int64.init),
            loudnessDb: json["playerConfig"]["audioConfig"]["loudnessDb"].double ?? format["loudnessDb"].double,
            durationSeconds: format["approxDurationMs"].double.map { $0 / 1000 }
                ?? json["videoDetails"]["lengthSeconds"].double,
            clientId: client.id,
            userAgent: client.userAgent,
            chunkSize: client.rangeChunkSize,
            expiresAt: expire.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(expirySeconds),
            trackingURL: json["playbackTracking"]["videostatsPlaybackUrl"]["baseUrl"].string,
            clientName: client.clientName
        )
    }

    /// Picks the best audio-only format, as Metrolist's "High" does, with one difference:
    ///
    /// - Only the original-language track (YouTube's `acont=original` tag, else the default
    ///   track), never a dub, and never the dynamic-range-compressed copy.
    /// - The highest bitrate wins: Opus 774 (~256 kbps) for accounts with Premium, Opus 251
    ///   (~160 kbps) otherwise.
    /// - Unlike Metrolist, Opus is kept over AAC unless the AAC stream has well over 1.5×
    ///   the bitrate. Opus at 160 kbps already matches AAC at 256 kbps in listening tests,
    ///   and only Opus (WebM) can play while still downloading, which gapless playback and
    ///   AutoMix rely on; an AAC file has to finish downloading first.
    static func select(_ formats: [JSON], quality: AudioQuality) -> JSON? {
        var pool = formats
        let originals = pool.filter { audioContent($0) == "original" }
        if !originals.isEmpty {
            pool = originals
        } else if pool.contains(where: { $0["audioTrack"].exists }) {
            let defaults = pool.filter { $0["audioTrack"]["audioIsDefault"].bool == true }
            if !defaults.isEmpty { pool = defaults }
        }
        let withoutDRC = pool.filter { $0["isDrc"].bool != true && audioContent($0) != "drc" }
        if !withoutDRC.isEmpty { pool = withoutDRC }

        let bitrate: (JSON) -> Int = { $0["bitrate"].int ?? 0 }
        let opus = pool.filter { ($0["mimeType"].string ?? "").contains("opus") }
        let others = pool.filter { !($0["mimeType"].string ?? "").contains("opus") }
        switch quality {
        case .high:
            let bestOpus = opus.max { bitrate($0) < bitrate($1) }
            let bestOther = others.max { bitrate($0) < bitrate($1) }
            guard let bestOpus else { return bestOther }
            if let bestOther, Double(bitrate(bestOther)) > Double(bitrate(bestOpus)) * 1.6 { return bestOther }
            return bestOpus
        case .low:
            return (opus.isEmpty ? pool : opus).min { bitrate($0) < bitrate($1) }
        }
    }

    /// YouTube's `acont` tag ("original", "dubbed", "drc"…) from a format's `xtags`, a
    /// base64url protobuf of repeated { 1: key, 2: value } entries.
    static func audioContent(_ format: JSON) -> String? {
        guard var text = format["xtags"].string, text.count <= 1024 else { return nil }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text) else { return nil }
        let bytes = [UInt8](data)
        var index = 0
        func varint() -> Int? {
            var result = 0, shift = 0
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                result |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 28 { return nil }
            }
            return nil
        }
        while index < bytes.count {
            guard let tag = varint(), tag & 7 == 2, let length = varint(), index + length <= bytes.count else { return nil }
            let entry = Array(bytes[index ..< index + length])
            index += length
            guard tag >> 3 == 1 else { continue }
            var key: String?, value: String?, position = 0
            while position + 1 < entry.count {
                let field = entry[position] >> 3, size = Int(entry[position + 1])
                position += 2
                guard position + size <= entry.count else { break }
                let string = String(decoding: entry[position ..< position + size], as: UTF8.self)
                if field == 1 { key = string } else if field == 2 { value = string }
                position += size
            }
            if key == "acont" { return value }
        }
        return nil
    }

    /// Every audio format each playback identity is offered for a video, for `--qualitytest`.
    func formatsReport(videoId: String) async -> [(client: String, formats: [JSON], error: String?)] {
        var report: [(String, [JSON], String?)] = []
        for client in YouTubeClient.playbackClients {
            do {
                var body: [String: Any] = ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true]
                if !client.useMusicPlayerEndpoint { body["videoCheckOk"] = true }
                let json = try await InnerTube.shared.post("player", client: client, body: body)
                let status = json["playabilityStatus"]["status"].string ?? "?"
                let formats = json["streamingData"]["adaptiveFormats"].array.filter { ($0["mimeType"].string ?? "").hasPrefix("audio/") }
                report.append((client.id, formats, status == "OK" ? nil : (json["playabilityStatus"]["reason"].string ?? status)))
            } catch {
                report.append((client.id, [], "\(error)"))
            }
        }
        return report
    }
}
