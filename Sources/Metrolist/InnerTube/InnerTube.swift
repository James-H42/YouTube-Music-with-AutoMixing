import CryptoKit
import Foundation

enum YTError: LocalizedError {
    case http(Int)
    case unplayable(String)
    case noStream
    case parse(String)
    case offline
    /// YouTube refused every playback identity with its "confirm you're not a bot" check.
    case botCheck

    static let botCheckMessage = "YouTube is asking this connection to prove it isn't a bot, so new songs can't be streamed right now. Downloaded and cached songs still play. This usually clears by itself; turning a VPN off or changing network often fixes it straight away. Signing in (Settings) lets Metrolist+ play through your account instead."

    var errorDescription: String? {
        switch self {
        case .http(let code): "YouTube returned HTTP \(code)."
        case .unplayable(let reason): reason
        case .noStream: "No playable audio stream was found."
        case .parse(let what): "Couldn't read \(what) from YouTube's response."
        case .offline: "You're offline and this item isn't downloaded."
        case .botCheck: Self.botCheckMessage
        }
    }
}

/// Low-level InnerTube transport: visitor identity, request headers and optional account auth.
final class InnerTube: @unchecked Sendable {
    static let shared = InnerTube()

    private static let musicOrigin = "https://music.youtube.com"
    private static let wwwOrigin = "https://www.youtube.com"
    private static let visitorKey = "innertube.visitorData"
    private static let visitorDateKey = "innertube.visitorDataDate"
    private static let streamVisitorKey = "innertube.streamVisitorData"
    private static let streamVisitorDateKey = "innertube.streamVisitorDataDate"

    let session: URLSession
    private let lock = NSLock()
    private var visitor: String?
    private var visitorTask: Task<String?, Never>?
    /// Identity used only by the anonymous playback clients. It is kept apart from the one
    /// used for browsing so that account cookies are never sent alongside it: tying a
    /// signed-in account to a spoofed device session is what gets accounts bot-checked.
    private var streamVisitor: String?
    private var streamVisitorTask: Task<String?, Never>?
    private var cookieValue: String?

    let gl: String
    let hl = "en"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        gl = Locale.current.region?.identifier ?? "US"

        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: Self.visitorKey),
           let date = defaults.object(forKey: Self.visitorDateKey) as? Date,
           Date().timeIntervalSince(date) < 12 * 3600 {
            visitor = saved
        }
        if let saved = defaults.string(forKey: Self.streamVisitorKey),
           let date = defaults.object(forKey: Self.streamVisitorDateKey) as? Date,
           Date().timeIntervalSince(date) < 12 * 3600 {
            streamVisitor = saved
        }
    }

    /// The signed-in account's cookie header, or nil when browsing anonymously.
    var cookie: String? {
        get { lock.withLock { cookieValue } }
        set { lock.withLock { cookieValue = newValue } }
    }

    var isSignedIn: Bool { sapisid != nil }

    private var sapisid: String? {
        guard let cookie else { return nil }
        var values: [String: String] = [:]
        for part in cookie.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
        return values["SAPISID"] ?? values["__Secure-3PAPISID"] ?? values["__Secure-1PAPISID"]
    }

    // MARK: - Visitor data

    func visitorData() async -> String? {
        let task: Task<String?, Never> = lock.withLock {
            if let visitor { return Task { visitor } }
            if let visitorTask { return visitorTask }
            let task = Task { await self.fetchVisitorData() }
            visitorTask = task
            return task
        }
        let value = await task.value
        lock.withLock {
            visitorTask = nil
            if let value { visitor = value }
        }
        return value
    }

    func resetVisitorData() {
        lock.withLock { visitor = nil }
        UserDefaults.standard.removeObject(forKey: Self.visitorKey)
    }

    func streamVisitorData() async -> String? {
        let task: Task<String?, Never> = lock.withLock {
            if let streamVisitor { return Task { streamVisitor } }
            if let streamVisitorTask { return streamVisitorTask }
            let task = Task { await self.fetchVisitorData(store: false) }
            streamVisitorTask = task
            return task
        }
        let value = await task.value
        lock.withLock {
            streamVisitorTask = nil
            if let value, streamVisitor == nil {
                streamVisitor = value
                UserDefaults.standard.set(value, forKey: Self.streamVisitorKey)
                UserDefaults.standard.set(Date(), forKey: Self.streamVisitorDateKey)
            }
        }
        return lock.withLock { streamVisitor } ?? value
    }

    /// Drops the playback identity so the next stream request starts a fresh one.
    func resetStreamVisitorData() {
        lock.withLock { streamVisitor = nil }
        UserDefaults.standard.removeObject(forKey: Self.streamVisitorKey)
    }

    private func fetchVisitorData(store: Bool = true) async -> String? {
        var request = URLRequest(url: URL(string: "\(Self.musicOrigin)/sw.js_data")!)
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        var result: String?
        if let (data, _) = try? await session.data(for: request),
           let text = String(data: data, encoding: .utf8),
           let newline = text.firstIndex(of: "\n") {
            let json = JSON(data: Data(text[text.index(after: newline)...].utf8))
            result = json[0][2][0][0][13].string
        }
        if result == nil {
            var page = URLRequest(url: URL(string: Self.musicOrigin)!)
            page.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
            if let (data, _) = try? await session.data(for: page),
               let html = String(data: data, encoding: .utf8),
               let match = html.firstMatch(of: #/"VISITOR_DATA":"([^"]+)"/#) {
                result = String(match.1)
            }
        }
        if let result, store {
            UserDefaults.standard.set(result, forKey: Self.visitorKey)
            UserDefaults.standard.set(Date(), forKey: Self.visitorDateKey)
        }
        return result
    }

    // MARK: - Requests

    /// Authenticated GET used for YouTube's playback-statistics pings.
    func authorizedGet(_ url: URL) async throws -> Int {
        let client = YouTubeClient.webRemix
        var request = URLRequest(url: url)
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        request.setValue(client.clientId, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(Self.musicOrigin, forHTTPHeaderField: "Origin")
        request.setValue(Self.musicOrigin, forHTTPHeaderField: "X-Origin")
        request.setValue("\(Self.musicOrigin)/", forHTTPHeaderField: "Referer")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let visitor = await visitorData() { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let cookie, let sapisid {
            let timestamp = Int(Date().timeIntervalSince1970)
            let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(Self.musicOrigin)".utf8))
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            request.setValue("SAPISIDHASH \(timestamp)_\(digest.map { String(format: "%02x", $0) }.joined())", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    func post(
        _ endpoint: String,
        client: YouTubeClient = .webRemix,
        body: [String: Any],
        query: [String: String] = [:],
        anonymous: Bool = false
    ) async throws -> JSON {
        // Anonymous playback requests carry their own identity and never the account's cookies.
        let signedIn = client.loginSupported && !anonymous
        let visitor = signedIn ? await visitorData() : await streamVisitorData()
        let useMusicHost = client.clientName == "WEB_REMIX" || (endpoint == "player" && client.useMusicPlayerEndpoint)
        let origin = useMusicHost ? Self.musicOrigin : Self.wwwOrigin

        var components = URLComponents(string: "\(origin)/youtubei/v1/\(endpoint)")!
        components.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
            + query.map { URLQueryItem(name: $0.key, value: $0.value) }

        var payload = body
        payload["context"] = client.context(visitorData: visitor, gl: gl, hl: hl)

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        request.setValue(client.clientId, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue(client.isEmbedded ? "https://www.reddit.com/" : "\(origin)/", forHTTPHeaderField: "Referer")
        request.setValue("\(hl)-\(gl),\(hl);q=0.9", forHTTPHeaderField: "Accept-Language")
        if let visitor { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }

        if signedIn, let cookie, let sapisid {
            let timestamp = Int(Date().timeIntervalSince1970)
            let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(origin)".utf8))
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            request.setValue("SAPISIDHASH \(timestamp)_\(hash)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dataNotAllowed].contains(error.code) {
            throw YTError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else { throw YTError.http(status) }
        return JSON(data: data)
    }
}
