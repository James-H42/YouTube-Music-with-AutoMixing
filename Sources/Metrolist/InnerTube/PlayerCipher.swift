import Foundation
import JavaScriptCore

/// Unscrambles the stream addresses YouTube gives to browser clients.
///
/// A browser's player response carries each address with a scrambled signature (`s`) and a
/// throttling parameter (`n`); the player script holds the functions that put them right, and
/// they change with every player release. Rather than guess at them with patterns, this runs
/// yt-dlp's solver, which parses the player script and pulls the two functions out, inside
/// JavaScriptCore. The parsed result is kept on disk per player version.
actor PlayerCipher {
    static let shared = PlayerCipher()

    struct Player {
        var id: String
        var signatureTimestamp: Int
    }

    private var player: Player?
    private var playerFetched = Date.distantPast
    private var context: JSContext?
    /// Player script, raw or already digested by the solver, for `player.id`.
    private var source: (kind: String, text: String)?
    private var solved: [String: String] = [:]

    private static var directory: URL {
        let url = AppPaths.root.appendingPathComponent("Player", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The player release YouTube is serving now. Checked at most every few hours.
    func current() async throws -> Player {
        if let player, Date().timeIntervalSince(playerFetched) < 4 * 3600 { return player }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/iframe_api")!)
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await InnerTube.shared.session.data(for: request)
        guard let text = String(data: data, encoding: .utf8), let match = text.firstMatch(of: #/player\\?\/([0-9a-zA-Z_-]{8})\\?\//#) else {
            throw YTError.parse("the player version")
        }
        let id = String(match.1)
        let script = try await script(for: id)
        guard let timestamp = script.firstMatch(of: #/(?:signatureTimestamp|sts)\s*:\s*(\d{5})/#).flatMap({ Int($0.1) }) else {
            throw YTError.parse("the player's signature timestamp")
        }
        if player?.id != id {
            source = nil
            solved = [:]
        }
        let found = Player(id: id, signatureTimestamp: timestamp)
        player = found
        playerFetched = Date()
        return found
    }

    private func script(for id: String) async throws -> String {
        let file = Self.directory.appendingPathComponent("\(id).js")
        if let cached = try? String(contentsOf: file, encoding: .utf8), cached.count > 100_000 { return cached }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/s/player/\(id)/player_ias.vflset/en_US/base.js")!)
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await InnerTube.shared.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8), text.count > 100_000 else {
            throw YTError.parse("the player script")
        }
        // Only the newest player is needed.
        for old in (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: old)
        }
        try? text.write(to: file, atomically: true, encoding: .utf8)
        return text
    }

    /// Solves signature and `n` challenges with the current player's functions.
    func solve(signatures: [String], throttles: [String]) async throws -> (signatures: [String: String], throttles: [String: String]) {
        let player = try await current()
        let wantedSignatures = Set(signatures).filter { solved["sig:" + $0] == nil }
        let wantedThrottles = Set(throttles).filter { solved["n:" + $0] == nil }
        if !wantedSignatures.isEmpty || !wantedThrottles.isEmpty {
            if source == nil {
                let digested = Self.directory.appendingPathComponent("\(player.id).solved.js")
                if let text = try? String(contentsOf: digested, encoding: .utf8), !text.isEmpty {
                    source = ("preprocessed", text)
                } else {
                    source = ("player", try await script(for: player.id))
                }
            }
            guard let source else { throw YTError.parse("the player script") }
            var requests: [[String: Any]] = []
            if !wantedSignatures.isEmpty { requests.append(["type": "sig", "challenges": Array(wantedSignatures)]) }
            if !wantedThrottles.isEmpty { requests.append(["type": "n", "challenges": Array(wantedThrottles)]) }
            var input: [String: Any] = ["type": source.kind, "requests": requests]
            if source.kind == "player" {
                input["player"] = source.text
                input["output_preprocessed"] = true
            } else {
                input["preprocessed_player"] = source.text
            }
            let output = try run(input)
            if let digested = output["preprocessed_player"] as? String, !digested.isEmpty {
                self.source = ("preprocessed", digested)
                try? digested.write(to: Self.directory.appendingPathComponent("\(player.id).solved.js"), atomically: true, encoding: .utf8)
            }
            guard let responses = output["responses"] as? [[String: Any]], responses.count == requests.count else {
                throw YTError.parse("the cipher solver's answer (\(output["error"] as? String ?? "no detail"))")
            }
            for (request, response) in zip(requests, responses) {
                guard let kind = request["type"] as? String, let data = response["data"] as? [String: String] else {
                    throw YTError.parse("the \(request["type"] as? String ?? "") cipher (\(String((response["error"] as? String ?? "").prefix(160))))")
                }
                for (challenge, answer) in data { solved["\(kind):\(challenge)"] = answer }
            }
        }
        var signatureAnswers: [String: String] = [:]
        var throttleAnswers: [String: String] = [:]
        for challenge in signatures { signatureAnswers[challenge] = solved["sig:" + challenge] }
        for challenge in throttles { throttleAnswers[challenge] = solved["n:" + challenge] }
        return (signatureAnswers, throttleAnswers)
    }

    private func run(_ input: [String: Any]) throws -> [String: Any] {
        if context == nil {
            guard let created = JSContext() else { throw YTError.parse("the cipher solver") }
            created.evaluateScript(EJSSolver.library)
            created.evaluateScript("var meriyah = lib.meriyah, astring = lib.astring;")
            created.evaluateScript(EJSSolver.core)
            context = created
        }
        guard let context, let function = context.objectForKeyedSubscript("jsc"), !function.isUndefined else {
            throw YTError.parse("the cipher solver")
        }
        context.exception = nil
        // Pass the input as a JSON string: bridging a 3 MB dictionary value by value is slow.
        let json = String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8) ?? "{}"
        context.setObject(json, forKeyedSubscript: "__input" as NSString)
        let result = context.evaluateScript("JSON.stringify(jsc(JSON.parse(__input)))")
        context.evaluateScript("__input = undefined;")
        if let exception = context.exception {
            context.exception = nil
            throw YTError.parse("the cipher solver's answer (\(String(exception.toString().prefix(160))))")
        }
        guard let text = result?.toString(), let data = text.data(using: .utf8),
              let output = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw YTError.parse("the cipher solver's answer") }
        return output
    }

    /// Builds playable addresses from a player response's formats: unscrambles signatures and
    /// throttling parameters, and appends the attestation token the media servers ask for.
    /// Formats that cannot be solved are left out.
    func unscramble(_ formats: [JSON], token: String?) async throws -> [(format: JSON, url: URL)] {
        struct Pending {
            var format: JSON
            var base: URLComponents
            var signature: (parameter: String, challenge: String)?
        }
        var pending: [Pending] = []
        for format in formats {
            if let direct = format["url"].string, let components = URLComponents(string: direct) {
                pending.append(Pending(format: format, base: components, signature: nil))
            } else if let cipher = format["signatureCipher"].string ?? format["cipher"].string {
                var fields = URLComponents()
                fields.percentEncodedQuery = cipher
                let items = fields.queryItems ?? []
                guard let address = items.first(where: { $0.name == "url" })?.value, let components = URLComponents(string: address),
                      let challenge = items.first(where: { $0.name == "s" })?.value
                else { continue }
                pending.append(Pending(format: format, base: components, signature: (items.first { $0.name == "sp" }?.value ?? "signature", challenge)))
            }
        }
        guard !pending.isEmpty else { return [] }
        let throttles = pending.compactMap { $0.base.queryItems?.first { $0.name == "n" }?.value }
        let answers = try await solve(signatures: pending.compactMap { $0.signature?.challenge }, throttles: throttles)

        var result: [(JSON, URL)] = []
        for item in pending {
            var components = item.base
            var items = components.queryItems ?? []
            if let signature = item.signature {
                guard let answer = answers.signatures[signature.challenge] else { continue }
                items.append(URLQueryItem(name: signature.parameter, value: answer))
            }
            if let index = items.firstIndex(where: { $0.name == "n" }), let challenge = items[index].value {
                // Without the right `n` the server throttles the download to a crawl or refuses it.
                guard let answer = answers.throttles[challenge] else { continue }
                items[index].value = answer
            }
            if let token, !items.contains(where: { $0.name == "pot" }) { items.append(URLQueryItem(name: "pot", value: token)) }
            components.queryItems = items
            // Signatures can contain characters URLComponents leaves alone but YouTube wants escaped.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            if let url = components.url { result.append((item.format, url)) }
        }
        return result
    }
}
