import Foundation
import VideoToolbox

/// Video qualities as YouTube names them (by picture height: 1080p, 2160p…). 0 is Auto.
enum VideoQuality {
    static let auto = 0
    /// What can be chosen in Settings; the player's menu lists only what a video has.
    static let choices = [0, 4320, 2160, 1440, 1080, 720, 480, 360, 240, 144]
    private static let ladder = [144, 240, 360, 480, 720, 1080, 1440, 2160, 4320]

    static func title(_ quality: Int) -> String {
        switch quality {
        case 0: "Auto"
        case 4320: "4320p (8K)"
        case 2160: "2160p (4K)"
        case 1440: "1440p (QHD)"
        case 1080: "1080p (HD)"
        case 720: "720p (HD)"
        default: "\(quality)p"
        }
    }

    /// The quality YouTube would call a picture: a landscape picture by its height or, if it
    /// is wider than 16:9, by its width (1920 × 800 is 1080p, 3144 × 2160 is 2160p); a
    /// portrait one by its width (1080 × 1920 is 1080p).
    static func label(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        let size = width >= height ? max(Double(height), Double(width) * 9 / 16) : Double(width)
        return ladder.last { Double($0) * 0.94 <= size } ?? Int(size)
    }
}

/// The picture of a music video or live performance, for showing while its sound plays
/// through the audio engine (so AutoMix, the equaliser and gapless playback are unchanged).
/// As in Metrolist, the video comes from YouTube with the same playback identities the audio
/// uses. Only formats AVFoundation plays are taken:
///
/// - The HLS manifest (`hlsManifestUrl`), which Apple-platform identities are offered. Auto
///   plays it whole and lets AVPlayer adapt; a fixed quality plays one of its variants.
/// - Video-only MP4 files: H.264 (YouTube offers it up to 1080p), and AV1 (up to 4K and
///   beyond) on Macs that decode AV1 in hardware.
/// - The combined 360p MP4 (itag 18), which almost every video has.
///
/// VP9 WebM files are left out: AVPlayer doesn't play WebM.
actor VideoStreamResolver {
    static let shared = VideoStreamResolver()

    /// One picture stream of a fixed quality.
    struct Rendition: Equatable, Sendable {
        enum Kind: String, Sendable { case hls, mp4 }
        var url: URL
        var kind: Kind
        var width: Int
        var height: Int
        var bandwidth: Int
        var codecs: String
        /// YouTube's format number (files only), to find the same file again.
        var itag: Int?
        var quality: Int { VideoQuality.label(width: width, height: height) }
    }

    /// Everything one player reply offers for a video.
    struct VideoSource: Equatable, Sendable {
        var videoId: String
        /// The HLS master playlist (all qualities), when the identity was offered one.
        var manifest: URL?
        var renditions: [Rendition]
        var userAgent: String
        var expiresAt: Date
        var clientId: String

        /// The qualities this video has, best first.
        var qualities: [Int] { Array(Set(renditions.map(\.quality))).sorted(by: >) }

        /// What to play for a quality setting: the manifest for Auto (or a file of up to 1080p
        /// when there's none), otherwise the chosen quality or the nearest one below it.
        func stream(for quality: Int) -> (url: URL, kind: Rendition.Kind, quality: Int?)? {
            if quality == VideoQuality.auto {
                if let manifest { return (manifest, .hls, nil) }
                return pick(atMost: 1080).map { ($0.url, $0.kind, $0.quality) }
            }
            return pick(atMost: quality).map { ($0.url, $0.kind, $0.quality) }
        }

        private func pick(atMost quality: Int) -> Rendition? {
            let available = qualities
            let target = available.first { $0 <= quality } ?? available.last
            guard let target else { return nil }
            // An HLS variant before a file (it is fetched in small pieces), H.264 before
            // HEVC before AV1 (cheapest to decode), then the higher bit rate.
            func rank(_ r: Rendition) -> (Int, Int, Int) {
                let codec = r.codecs.hasPrefix("avc") ? 0 : r.codecs.hasPrefix("hvc") || r.codecs.hasPrefix("hev") ? 1 : 2
                return (r.kind == .hls ? 0 : 1, codec, -r.bandwidth)
            }
            return renditions.filter { $0.quality == target }.min { rank($0) < rank($1) }
        }

        /// The file to save for offline playback: the best quality this Mac plays, then
        /// H.264 over AV1 at the same quality (cheaper to decode), then the higher bit rate.
        var bestFile: Rendition? {
            renditions.filter { $0.kind == .mp4 }.max {
                ($0.quality, $0.codecs.hasPrefix("avc") ? 1 : 0, $0.bandwidth) < ($1.quality, $1.codecs.hasPrefix("avc") ? 1 : 0, $1.bandwidth)
            }
        }
    }

    private var cache: [String: VideoSource] = [:]
    private var inFlight: [String: Task<VideoSource, Error>] = [:]

    func resolve(videoId: String) async throws -> VideoSource {
        if let cached = cache[videoId], cached.expiresAt.timeIntervalSinceNow > 600 { return cached }
        if let running = inFlight[videoId] { return try await running.value }
        let task = Task { try await self.fetch(videoId: videoId) }
        inFlight[videoId] = task
        defer { inFlight[videoId] = nil }
        let source = try await task.value
        cache[videoId] = source
        return source
    }

    /// Drops a stream the media server refused, so the next request asks again.
    func forget(_ videoId: String) { cache[videoId] = nil }

    private func fetch(videoId: String) async throws -> VideoSource {
        var lastError: Error = YTError.noStream
        for client in YouTubeClient.playbackClients {
            do {
                var body: [String: Any] = ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true]
                if !client.useMusicPlayerEndpoint { body["videoCheckOk"] = true }
                let json = try await InnerTube.shared.post("player", client: client, body: body)
                let status = json["playabilityStatus"]
                guard status["status"].string == "OK" else {
                    let reason = status["reason"].string ?? status["messages"][0].string ?? "This video can't be played."
                    if reason.lowercased().contains("bot") { lastError = YTError.botCheck } else { lastError = YTError.unplayable(reason) }
                    continue
                }
                if let returned = json["videoDetails"]["videoId"].string, returned != videoId { continue }
                guard var source = Self.source(json["streamingData"], videoId: videoId, client: client) else { continue }
                if let manifest = source.manifest {
                    source.renditions += await Self.variants(of: manifest, userAgent: client.userAgent)
                }
                if !source.renditions.isEmpty || source.manifest != nil { return source }
            } catch YTError.offline {
                throw YTError.offline
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Which codecs this Mac plays in AVFoundation. AV1 needs a hardware decoder (M3 and later).
    static let decodesAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    static func playable(codecs: String) -> Bool {
        let video = codecs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("mp4a") && !$0.hasPrefix("opus") && !$0.hasPrefix("ac-3") && !$0.hasPrefix("ec-3") }
        guard let codec = video.first else { return true }
        if codec.hasPrefix("avc1") || codec.hasPrefix("avc3") || codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") { return true }
        if codec.hasPrefix("av01") { return decodesAV1 }
        return false
    }

    /// The MP4 files (and the manifest) one player reply offers, or nil when there's nothing
    /// AVFoundation can play.
    static func source(_ streaming: JSON, videoId: String, client: YouTubeClient) -> VideoSource? {
        let lifetime = streaming["expiresInSeconds"].double ?? 21_600
        var expiry = Date().addingTimeInterval(lifetime)
        let manifest = streaming["hlsManifestUrl"].string.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        var renditions: [Rendition] = []
        for format in streaming["adaptiveFormats"].array + streaming["formats"].array {
            let mime = format["mimeType"].string ?? ""
            guard mime.hasPrefix("video/mp4"), let text = format["url"].string, let url = URL(string: text) else { continue }
            let codecs = mime.components(separatedBy: "codecs=\"").dropFirst().first?.components(separatedBy: "\"").first ?? ""
            guard playable(codecs: codecs) else { continue }
            let width = format["width"].int ?? 0, height = format["height"].int ?? 0
            guard height > 0 else { continue }
            // Some HDR and 3D formats need more than AVPlayer will do with a bare file.
            if (format["colorInfo"]["transferCharacteristics"].string ?? "").contains("SMPTEST2084") { continue }
            renditions.append(Rendition(url: url, kind: .mp4, width: width, height: height, bandwidth: format["bitrate"].int ?? 0, codecs: codecs, itag: format["itag"].int))
            if let expire = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "expire" })?.value.flatMap(Double.init) {
                expiry = min(expiry, Date(timeIntervalSince1970: expire))
            }
        }
        guard manifest != nil || !renditions.isEmpty else { return nil }
        return VideoSource(videoId: videoId, manifest: manifest, renditions: renditions, userAgent: client.userAgent, expiresAt: expiry, clientId: client.id)
    }

    /// The variants an HLS master playlist lists (one per quality and codec), or none if it
    /// couldn't be read; Auto still plays the master playlist itself.
    static func variants(of manifest: URL, userAgent: String) async -> [Rendition] {
        var request = URLRequest(url: manifest)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await InnerTube.shared.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else { return [] }
        return parseMaster(text, base: manifest)
    }

    static func parseMaster(_ text: String, base: URL) -> [Rendition] {
        var result: [Rendition] = []
        var pending: [String: String]?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if !line.isEmpty, !line.hasPrefix("#"), let info = pending {
                pending = nil
                let size = (info["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
                let codecs = info["CODECS"] ?? ""
                guard size.count == 2, size[1] > 0, playable(codecs: codecs), let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                result.append(Rendition(url: url, kind: .hls, width: size[0], height: size[1], bandwidth: Int(info["BANDWIDTH"] ?? "") ?? 0, codecs: codecs))
            }
        }
        return result
    }

    /// `KEY=value,KEY="quoted, value"` → a dictionary.
    private static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func flush() {
            if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }
            key = ""; value = ""; inKey = true
        }
        for character in text {
            if inKey {
                if character == "=" { inKey = false } else if character != "," { key.append(character) }
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                flush()
            } else {
                value.append(character)
            }
        }
        flush()
        return result
    }
}
