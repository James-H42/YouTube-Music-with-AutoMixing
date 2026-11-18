import Foundation

/// Stands in for Last.fm and ListenBrainz: records every request and answers as scripted.
final class FakeScrobbleServer: URLProtocol, @unchecked Sendable {
    struct Seen { var url: URL; var headers: [String: String]; var body: Data }
    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var offline = false
    nonisolated(unsafe) static var listenBrainzStatus = 200
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
            stream.close()
        }
        Self.lock.withLock { Self.seen.append(Seen(url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)) }
        if Self.offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        var status = 200
        var reply = "{}"
        let url = request.url!.absoluteString
        if url.contains("audioscrobbler") {
            let fields = String(data: body, encoding: .utf8) ?? ""
            if fields.contains("method=auth.getToken") { reply = #"{"token":"TOKEN123"}"# }
            else if fields.contains("method=auth.getSession") { reply = #"{"session":{"name":"tester","key":"SESSKEY123","subscriber":0}}"# }
            else { reply = #"{"scrobbles":{"@attr":{"accepted":1,"ignored":0}}}"# }
        } else if url.contains("validate-token") {
            reply = #"{"code":200,"message":"Token valid.","valid":true,"user_name":"lbtester"}"#
        } else {
            status = Self.listenBrainzStatus
            reply = status == 200 ? #"{"status":"ok"}"# : #"{"code":401,"error":"Invalid authorization token."}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `Metrolist --scrobbletest`: the scrobbler against a fake server and a throw-away Keychain
/// service, so no real account is involved.
@MainActor
enum ScrobbleTest {
    static func run() async {
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
            if !passed { failures += 1 }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scrobbletest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let queueFile = folder.appendingPathComponent("scrobbles.json")
        Keychain.service = "Metrolist.scrobbletest.\(UUID().uuidString)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeScrobbleServer.self]
        Scrobbler.session = URLSession(configuration: configuration)

        // Last.fm's documented signing rule, against a value worked out with another tool.
        let sig = LastFm.signature(["api_key": "xxxxxxxxxxxxxxxx", "method": "auth.getSession", "token": "yyyyyyyyyyyyyyyy", "format": "json"], secret: "mysecret")
        check("Last.fm request signature", sig == "0b73cde40bf83a186a8b7b53dcdd883b", sig)
        check("rule for when a listen counts",
              Scrobbler.counts(position: 100, duration: 200) && !Scrobbler.counts(position: 99, duration: 200)
              && Scrobbler.counts(position: 240, duration: 600) && !Scrobbler.counts(position: 20, duration: 25) && !Scrobbler.counts(position: 239, duration: 600))

        let scrobbler = Scrobbler(file: queueFile)
        scrobbler.saveLastFmKeys(key: "APIKEY", secret: "APISECRET")
        let url = await scrobbler.beginLastFmSignIn()
        check("Last.fm sign-in asks the browser to approve", url?.host == "www.last.fm" && url?.query?.contains("token=TOKEN123") == true, url?.absoluteString ?? "nil")
        await scrobbler.finishLastFmSignIn()
        check("Last.fm session obtained", scrobbler.isLastFmSignedIn && scrobbler.lastFmUser == "tester")
        await scrobbler.signInListenBrainz(token: "LBTOKEN456")
        check("ListenBrainz token validated", scrobbler.isListenBrainzSignedIn && scrobbler.listenBrainzUser == "lbtester")

        // Offline: the listen must wait on disk.
        FakeScrobbleServer.offline = true
        FakeScrobbleServer.seen = []
        let song = Song(id: "abcdefghijk", title: "Test Song", artists: [ArtistRef(name: "Test Artist")], album: AlbumRef(name: "Test Album"), duration: 200)
        scrobbler.scrobble(song, duration: 200, started: Date().addingTimeInterval(-120))
        await scrobbler.flushNow()
        let saved = (try? String(contentsOf: queueFile, encoding: .utf8)) ?? ""
        check("offline listen is queued", scrobbler.queued == 1 && saved.contains("Test Song"), "\(scrobbler.queued) queued")

        // Back online: both services receive it and the queue empties.
        FakeScrobbleServer.offline = false
        FakeScrobbleServer.seen = []
        await scrobbler.flushNow()
        let lastFm = FakeScrobbleServer.seen.first { $0.url.host == "ws.audioscrobbler.com" }
        let body = lastFm.flatMap { String(data: $0.body, encoding: .utf8) } ?? ""
        check("Last.fm receives the scrobble", body.contains("method=track.scrobble") && body.contains("sk=SESSKEY123") && body.contains("artist%5B0%5D=Test%20Artist")
              && body.contains("track%5B0%5D=Test%20Song") && body.contains("timestamp%5B0%5D=") && body.contains("album%5B0%5D=Test%20Album"), body.prefix(160) + "…")
        // The signature in the request is the one its own parameters give.
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1] }
        }
        let claimed = fields["api_sig"] ?? ""
        fields["api_sig"] = nil
        check("Last.fm request is signed correctly", !claimed.isEmpty && claimed == LastFm.signature(fields, secret: "APISECRET"))
        let brainz = FakeScrobbleServer.seen.first { $0.url.host == "api.listenbrainz.org" }
        let payload = brainz.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
        let listened = ((payload?["payload"] as? [[String: Any]])?.first?["track_metadata"] as? [String: Any])
        check("ListenBrainz receives the listen", brainz?.headers["Authorization"] == "Token LBTOKEN456" && payload?["listen_type"] as? String == "single"
              && listened?["track_name"] as? String == "Test Song" && listened?["artist_name"] as? String == "Test Artist", "")
        check("queue is empty after sending", scrobbler.queued == 0)

        // A refused token stops that service and keeps its listens.
        FakeScrobbleServer.listenBrainzStatus = 401
        scrobbler.scrobble(song, duration: 200, started: Date().addingTimeInterval(-60))
        await scrobbler.flushNow()
        check("refused ListenBrainz token asks for a new sign-in", scrobbler.needsSignIn.contains("listenbrainz") && scrobbler.queued == 1, "queued \(scrobbler.queued)")
        FakeScrobbleServer.listenBrainzStatus = 200

        // Secrets: in the Keychain, in none of the files.
        var leaked: [String] = []
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for secret in ["SESSKEY123", "LBTOKEN456", "APISECRET", "APIKEY"] where text.contains(secret) { leaked.append("\(file.lastPathComponent) has \(secret)") }
        }
        check("no credential in the queue file", leaked.isEmpty, leaked.joined(separator: ", "))
        check("credentials are in the Keychain", Keychain.get("lastfm.session") == "SESSKEY123" && Keychain.get("listenbrainz.token") == "LBTOKEN456")
        scrobbler.signOutLastFm()
        scrobbler.signOutListenBrainz()
        check("signing out deletes the Keychain items", Keychain.get("lastfm.session") == nil && Keychain.get("listenbrainz.token") == nil && scrobbler.queued == 0)
        Keychain.set(nil, for: "lastfm.apikey")
        Keychain.set(nil, for: "lastfm.secret")
        try? FileManager.default.removeItem(at: folder)
        print(failures == 0 ? "all scrobbling checks passed" : "\(failures) scrobbling checks FAILED")
    }
}
