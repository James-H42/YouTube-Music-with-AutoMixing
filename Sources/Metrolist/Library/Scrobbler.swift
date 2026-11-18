import CryptoKit
import Foundation
import Observation

/// One play, as sent to the scrobbling services: track data only, no credentials.
struct Listen: Codable, Hashable {
    var videoId: String
    var title: String
    var artist: String
    var album: String?
    var duration: Int?
    /// Unix time the song started playing.
    var timestamp: Int
}

/// A listen waiting to reach the services it hasn't reached yet.
private struct PendingListen: Codable {
    var listen: Listen
    var services: [String]
}

enum ScrobbleFailure: Error {
    /// Network trouble or a busy server: try again later.
    case temporary
    /// The service no longer accepts the saved credentials.
    case signedOut
    /// The service refused this listen: sending it again would not help.
    case rejected
}

protocol ScrobbleService: Sendable {
    var name: String { get }
    func nowPlaying(_ listen: Listen) async throws
    func submit(_ listens: [Listen]) async throws
}

// MARK: - Last.fm

struct LastFm: ScrobbleService {
    let name = "lastfm"
    let apiKey: String
    let secret: String
    let sessionKey: String
    var session: URLSession = Scrobbler.session
    static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    /// The request signature: the parameters sorted by name, joined as name and value, followed
    /// by the shared secret, hashed with MD5. `format` is not signed.
    static func signature(_ parameters: [String: String], secret: String) -> String {
        let text = parameters.filter { $0.key != "format" && $0.key != "callback" }.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + secret
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func call(_ method: String, _ parameters: [String: String], apiKey: String, secret: String, session: URLSession) async throws -> JSON {
        var fields = parameters
        fields["method"] = method
        fields["api_key"] = apiKey
        fields["api_sig"] = signature(fields, secret: secret)
        fields["format"] = "json"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw ScrobbleFailure.temporary }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = JSON(data: data)
        if let code = json["error"].int {
            switch code {
            case 9, 4, 14, 15: throw ScrobbleFailure.signedOut // invalid session, auth failed, token problems
            case 11, 16, 29: throw ScrobbleFailure.temporary // service offline, temporarily unavailable, rate limit
            default: throw ScrobbleFailure.rejected
            }
        }
        if status >= 500 || status == 429 { throw ScrobbleFailure.temporary }
        if status >= 400 { throw ScrobbleFailure.rejected }
        return json
    }

    private func fields(_ listen: Listen, index: Int? = nil) -> [String: String] {
        func key(_ name: String) -> String { index.map { "\(name)[\($0)]" } ?? name }
        var result = [key("artist"): listen.artist, key("track"): listen.title]
        if let album = listen.album, !album.isEmpty { result[key("album")] = album }
        if let duration = listen.duration, duration > 0 { result[key("duration")] = String(duration) }
        return result
    }

    func nowPlaying(_ listen: Listen) async throws {
        var parameters = fields(listen)
        parameters["sk"] = sessionKey
        _ = try await Self.call("track.updateNowPlaying", parameters, apiKey: apiKey, secret: secret, session: session)
    }

    func submit(_ listens: [Listen]) async throws {
        for start in stride(from: 0, to: listens.count, by: 50) {
            var parameters = ["sk": sessionKey]
            for (index, listen) in listens[start ..< min(start + 50, listens.count)].enumerated() {
                parameters.merge(fields(listen, index: index)) { $1 }
                parameters["timestamp[\(index)]"] = String(listen.timestamp)
            }
            _ = try await Self.call("track.scrobble", parameters, apiKey: apiKey, secret: secret, session: session)
        }
    }
}

// MARK: - ListenBrainz

struct ListenBrainz: ScrobbleService {
    let name = "listenbrainz"
    let token: String
    var session: URLSession = Scrobbler.session
    static let base = URL(string: "https://api.listenbrainz.org/1/")!

    private func send(_ path: String, body: [String: Any]?) async throws -> JSON {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw ScrobbleFailure.temporary }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw ScrobbleFailure.signedOut }
        if status == 429 || status >= 500 { throw ScrobbleFailure.temporary }
        if status >= 400 { throw ScrobbleFailure.rejected }
        return JSON(data: data)
    }

    /// The account name a token belongs to, or nil when ListenBrainz doesn't accept it.
    static func validate(token: String, session: URLSession = Scrobbler.session) async -> String? {
        let json = try? await ListenBrainz(token: token, session: session).send("validate-token", body: nil)
        guard json?["valid"].bool == true else { return nil }
        return json?["user_name"].string
    }

    private func metadata(_ listen: Listen) -> [String: Any] {
        var info: [String: Any] = ["media_player": "Metrolist for macOS", "submission_client": "Metrolist for macOS", "music_service": "music.youtube.com",
                                    "origin_url": "https://music.youtube.com/watch?v=\(listen.videoId)"]
        if let duration = listen.duration, duration > 0 { info["duration_ms"] = duration * 1000 }
        var track: [String: Any] = ["artist_name": listen.artist, "track_name": listen.title, "additional_info": info]
        if let album = listen.album, !album.isEmpty { track["release_name"] = album }
        return track
    }

    func nowPlaying(_ listen: Listen) async throws {
        _ = try await send("submit-listens", body: ["listen_type": "playing_now", "payload": [["track_metadata": metadata(listen)]]])
    }

    func submit(_ listens: [Listen]) async throws {
        for start in stride(from: 0, to: listens.count, by: 100) {
            let batch = Array(listens[start ..< min(start + 100, listens.count)])
            let payload = batch.map { ["listened_at": $0.timestamp, "track_metadata": metadata($0)] as [String: Any] }
            _ = try await send("submit-listens", body: ["listen_type": batch.count == 1 ? "single" : "import", "payload": payload])
        }
    }
}

// MARK: - The scrobbler

/// Sends what is played to Last.fm and ListenBrainz. A listen counts once half of the song, or
/// four minutes of it, has played (and the song is longer than 30 s). Listens that can't be
/// sent, because the Mac is offline or a service is down, wait in `scrobbles.json` and go out
/// later. Credentials are in the Keychain, not in that file.
@MainActor
@Observable
final class Scrobbler {
    static let shared = Scrobbler()
    /// Replaced in tests so no real service is contacted.
    nonisolated(unsafe) static var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private enum Key {
        static let lastFmKey = "lastfm.apikey"
        static let lastFmSecret = "lastfm.secret"
        static let lastFmSession = "lastfm.session"
        static let listenBrainzToken = "listenbrainz.token"
    }

    var lastFmEnabled: Bool { didSet { UserDefaults.standard.set(lastFmEnabled, forKey: "scrobbleLastFm") } }
    var listenBrainzEnabled: Bool { didSet { UserDefaults.standard.set(listenBrainzEnabled, forKey: "scrobbleListenBrainz") } }
    private(set) var lastFmUser: String? { didSet { UserDefaults.standard.set(lastFmUser, forKey: "lastFmUser") } }
    private(set) var listenBrainzUser: String? { didSet { UserDefaults.standard.set(listenBrainzUser, forKey: "listenBrainzUser") } }
    /// A service refused its saved credentials; sign in again.
    private(set) var needsSignIn: Set<String> = []
    private(set) var queued = 0
    private(set) var message: String?
    /// A Last.fm sign-in waiting for the listener to approve it in the browser.
    private(set) var pendingToken: String?

    private var pending: [PendingListen] = []
    private var flushing = false
    private var retryTimer: Timer?
    private let file: URL
    private static let maxPending = 5_000
    /// Last.fm refuses listens older than two weeks.
    private static let lastFmMaxAge = 14 * 24 * 3600

    init(file: URL = AppPaths.scrobbles) {
        self.file = file
        lastFmEnabled = UserDefaults.standard.bool(forKey: "scrobbleLastFm")
        listenBrainzEnabled = UserDefaults.standard.bool(forKey: "scrobbleListenBrainz")
        lastFmUser = UserDefaults.standard.string(forKey: "lastFmUser")
        listenBrainzUser = UserDefaults.standard.string(forKey: "listenBrainzUser")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([PendingListen].self, from: data) { pending = saved }
        queued = pending.count
    }

    /// Starts the retry timer and the retry on reconnecting. Called once by the app.
    func start() {
        NetworkStatus.shared.onReconnect = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.flush() } }
        }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        flush()
    }

    // MARK: Services

    private var lastFmCredentials: (key: String, secret: String)? {
        guard let key = Keychain.get(Key.lastFmKey), let secret = Keychain.get(Key.lastFmSecret) else { return nil }
        return (key, secret)
    }

    var hasLastFmKeys: Bool { lastFmCredentials != nil }
    var isLastFmSignedIn: Bool { lastFmUser != nil && Keychain.get(Key.lastFmSession) != nil }
    var isListenBrainzSignedIn: Bool { listenBrainzUser != nil && Keychain.get(Key.listenBrainzToken) != nil }

    /// The services that are switched on and signed in.
    private func activeServices() -> [ScrobbleService] {
        var services: [ScrobbleService] = []
        if lastFmEnabled, !needsSignIn.contains("lastfm"), let keys = lastFmCredentials, let session = Keychain.get(Key.lastFmSession) {
            services.append(LastFm(apiKey: keys.key, secret: keys.secret, sessionKey: session))
        }
        if listenBrainzEnabled, !needsSignIn.contains("listenbrainz"), let token = Keychain.get(Key.listenBrainzToken) {
            services.append(ListenBrainz(token: token))
        }
        return services
    }

    // MARK: Signing in

    func saveLastFmKeys(key: String, secret: String) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Key.lastFmKey)
        Keychain.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: Key.lastFmSecret)
    }

    /// Step one of Last.fm's desktop sign-in: a token, and the page where the listener approves it.
    func beginLastFmSignIn() async -> URL? {
        guard let keys = lastFmCredentials else { message = "Enter your Last.fm API key and shared secret first."; return nil }
        do {
            let json = try await LastFm.call("auth.getToken", [:], apiKey: keys.key, secret: keys.secret, session: Self.session)
            guard let token = json["token"].string else { message = "Last.fm didn't return a token."; return nil }
            pendingToken = token
            var components = URLComponents(string: "https://www.last.fm/api/auth/")!
            components.queryItems = [URLQueryItem(name: "api_key", value: keys.key), URLQueryItem(name: "token", value: token)]
            message = nil
            return components.url
        } catch {
            message = "Couldn't reach Last.fm with that API key."
            return nil
        }
    }

    /// Step two, once the listener has approved the request in the browser.
    func finishLastFmSignIn() async {
        guard let keys = lastFmCredentials, let token = pendingToken else { return }
        do {
            let json = try await LastFm.call("auth.getSession", ["token": token], apiKey: keys.key, secret: keys.secret, session: Self.session)
            guard let key = json["session"]["key"].string, let name = json["session"]["name"].string else { message = "Last.fm didn't sign you in."; return }
            Keychain.set(key, for: Key.lastFmSession)
            lastFmUser = name
            lastFmEnabled = true
            pendingToken = nil
            needsSignIn.remove("lastfm")
            message = nil
            flush()
        } catch {
            message = "Last.fm says the request wasn't approved yet. Approve it in the browser, then try again."
        }
    }

    func signOutLastFm() {
        Keychain.set(nil, for: Key.lastFmSession)
        lastFmUser = nil
        lastFmEnabled = false
        pendingToken = nil
        needsSignIn.remove("lastfm")
        forget(service: "lastfm")
    }

    func signInListenBrainz(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let user = await ListenBrainz.validate(token: trimmed) else { message = "ListenBrainz doesn't accept that token."; return }
        Keychain.set(trimmed, for: Key.listenBrainzToken)
        listenBrainzUser = user
        listenBrainzEnabled = true
        needsSignIn.remove("listenbrainz")
        message = nil
        flush()
    }

    func signOutListenBrainz() {
        Keychain.set(nil, for: Key.listenBrainzToken)
        listenBrainzUser = nil
        listenBrainzEnabled = false
        needsSignIn.remove("listenbrainz")
        forget(service: "listenbrainz")
    }

    /// Signing out drops what was still waiting for that service.
    private func forget(service: String) {
        for index in pending.indices { pending[index].services.removeAll { $0 == service } }
        pending.removeAll { $0.services.isEmpty }
        persist()
    }

    // MARK: Listening

    /// A song has started playing (for AutoMix, at the hand-over).
    func nowPlaying(_ song: Song, duration: Double) {
        let listen = Self.listen(song, duration: duration, started: Date())
        let services = activeServices()
        guard !services.isEmpty, NetworkStatus.shared.isOnline else { return }
        Task {
            for service in services {
                do { try await service.nowPlaying(listen) } catch ScrobbleFailure.signedOut { needsSignIn.insert(service.name) } catch {}
            }
        }
    }

    /// The song has been played for long enough to count.
    func scrobble(_ song: Song, duration: Double, started: Date) {
        let listen = Self.listen(song, duration: duration, started: started)
        let names = [lastFmEnabled && isLastFmSignedIn ? "lastfm" : nil, listenBrainzEnabled && isListenBrainzSignedIn ? "listenbrainz" : nil].compactMap { $0 }
        guard !names.isEmpty else { return }
        pending.append(PendingListen(listen: listen, services: names))
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        persist()
        flush()
    }

    private static func listen(_ song: Song, duration: Double, started: Date) -> Listen {
        Listen(videoId: song.id, title: song.title, artist: song.artists.first?.name ?? song.artistText, album: song.album?.name,
               duration: duration > 0 ? Int(duration.rounded()) : song.duration, timestamp: Int(started.timeIntervalSince1970))
    }

    /// Whether a listen of `position` seconds into a song of `duration` seconds counts.
    static func counts(position: Double, duration: Double) -> Bool {
        duration > 30 && (position >= duration / 2 || position >= 240)
    }

    // MARK: Sending

    /// Sends what is waiting. Safe to call at any time.
    func flush() {
        guard !flushing, !pending.isEmpty, NetworkStatus.shared.isOnline else { return }
        flushing = true
        Task { await flushNow(); flushing = false }
    }

    /// Sends what is waiting and returns when done (used by `flush` and the tests).
    func flushNow() async {
        let services = activeServices()
        for service in services {
            var batch = pending.filter { $0.services.contains(service.name) }.map(\.listen)
            if service.name == "lastfm" {
                let cutoff = Int(Date().timeIntervalSince1970) - Self.lastFmMaxAge
                let stale = batch.filter { $0.timestamp < cutoff }
                if !stale.isEmpty { finish(stale, for: "lastfm") }
                batch.removeAll { $0.timestamp < cutoff }
            }
            guard !batch.isEmpty else { continue }
            do {
                try await service.submit(batch)
                finish(batch, for: service.name)
            } catch ScrobbleFailure.signedOut {
                needsSignIn.insert(service.name)
                message = "\(service.name == "lastfm" ? "Last.fm" : "ListenBrainz") no longer accepts the saved sign-in. Sign in again."
            } catch ScrobbleFailure.rejected {
                // Send them one at a time, so a single bad listen doesn't hold up the rest.
                for listen in batch {
                    do { try await service.submit([listen]); finish([listen], for: service.name) }
                    catch ScrobbleFailure.rejected { finish([listen], for: service.name) }
                    catch { break }
                }
            } catch {}
        }
    }

    private func finish(_ listens: [Listen], for service: String) {
        let done = Set(listens)
        for index in pending.indices where done.contains(pending[index].listen) { pending[index].services.removeAll { $0 == service } }
        pending.removeAll { $0.services.isEmpty }
        persist()
    }

    func clearQueue() {
        pending = []
        persist()
    }

    private func persist() {
        queued = pending.count
        let snapshot = pending
        let target = file
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: target, options: .atomic) }
    }
}
