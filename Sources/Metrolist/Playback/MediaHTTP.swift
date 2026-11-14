import Foundation
import Network

enum IPFamily: String {
    case v6, v4

    var other: IPFamily { self == .v6 ? .v4 : .v6 }

    fileprivate var version: NWProtocolIP.Options.Version { self == .v6 ? .v6 : .v4 }
}

struct MediaResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
    /// The URL that finally served the response, after redirects.
    var url: URL
}

/// A persistent HTTPS/1.1 connection pinned to one IP family.
///
/// Google's media servers can accept a signed stream URL over IPv6 and refuse the same URL
/// over IPv4 (or the reverse), typically behind VPNs and dual-stack ISPs. URLSession cannot
/// choose the address family, so media bytes are fetched over Network.framework instead.
private final class MediaConnection: @unchecked Sendable {
    let host: String
    let family: IPFamily
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "metrolist.media-connection")
    private var buffer = Data()
    private var started = false
    private(set) var isUsable = true

    init(host: String, family: IPFamily) {
        self.host = host
        self.family = family
        let parameters = NWParameters.tls
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = family.version
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: .https, using: parameters)
    }

    func cancel() {
        isUsable = false
        connection.cancel()
    }

    private func start() async throws {
        guard !started else { return }
        started = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                guard !resumed else {
                    if case .failed = state { self?.isUsable = false }
                    if case .cancelled = state { self?.isUsable = false }
                    return
                }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    // `.waiting` means there is no route for this family (for example no IPv6).
                    resumed = true
                    self?.isUsable = false
                    self?.connection.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Appends the next chunk from the socket to `buffer`; returns false at end of stream.
    private func receiveMore() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
                if let data, !data.isEmpty {
                    self?.buffer.append(data)
                    continuation.resume(returning: true)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: !isComplete)
                }
            }
        }
    }

    func get(target: String, headers: [String: String]) async throws -> (status: Int, headers: [String: String], body: Data) {
        try await start()
        var request = "GET \(target) HTTP/1.1\r\nHost: \(host)\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: keep-alive\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        request += "\r\n"
        try await send(Data(request.utf8))

        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            headerEnd = buffer.range(of: separator)
            if headerEnd == nil {
                guard buffer.count < 65_536, try await receiveMore() else {
                    isUsable = false
                    throw URLError(.badServerResponse)
                }
            }
        }
        guard let headerEnd, let head = String(data: buffer[buffer.startIndex ..< headerEnd.lowerBound], encoding: .isoLatin1) else {
            isUsable = false
            throw URLError(.badServerResponse)
        }
        buffer = Data(buffer[headerEnd.upperBound...])

        let lines = head.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            isUsable = false
            throw URLError(.badServerResponse)
        }
        var responseHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            responseHeaders[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var body = Data()
        if responseHeaders["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try await readChunked()
        } else if let length = responseHeaders["content-length"].flatMap({ Int($0) }) {
            while buffer.count < length {
                guard try await receiveMore() else {
                    isUsable = false
                    throw URLError(.networkConnectionLost)
                }
            }
            body = Data(buffer.prefix(length))
            buffer = Data(buffer.dropFirst(length))
        } else if status != 204, status != 304 {
            while try await receiveMore() {}
            body = buffer
            buffer = Data()
            isUsable = false
        }
        if responseHeaders["connection"]?.lowercased() == "close" { isUsable = false }
        return (status, responseHeaders, body)
    }

    private func readChunked() async throws -> Data {
        var body = Data()
        let lineBreak = Data("\r\n".utf8)
        while true {
            var lineEnd = buffer.range(of: lineBreak)
            while lineEnd == nil {
                guard try await receiveMore() else { throw URLError(.networkConnectionLost) }
                lineEnd = buffer.range(of: lineBreak)
            }
            let sizeText = String(decoding: buffer[buffer.startIndex ..< lineEnd!.lowerBound], as: UTF8.self)
            let size = Int(sizeText.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16) ?? 0
            buffer = Data(buffer[lineEnd!.upperBound...])
            while buffer.count < size + 2 {
                guard try await receiveMore() else { throw URLError(.networkConnectionLost) }
            }
            if size == 0 {
                buffer = Data(buffer.dropFirst(2))
                return body
            }
            body.append(buffer.prefix(size))
            buffer = Data(buffer.dropFirst(size + 2))
        }
    }
}

/// Fetches byte ranges of a stream, choosing whichever IP family the media servers accept.
final class MediaHTTPClient: @unchecked Sendable {
    private static let lock = NSLock()
    private static var preferred: IPFamily = .v6

    /// The family that last worked, shared by every download.
    static var preferredFamily: IPFamily {
        get { lock.withLock { preferred } }
        set { lock.withLock { preferred = newValue } }
    }

    private var connections: [String: MediaConnection] = [:]

    deinit {
        close()
    }

    func close() {
        connections.values.forEach { $0.cancel() }
        connections = [:]
    }

    /// Requests `range` of `url`, following redirects. Falls back to the other IP family when
    /// the preferred one is refused or unreachable.
    func fetch(_ url: URL, range: ClosedRange<Int64>, userAgent: String) async throws -> MediaResponse {
        let first = Self.preferredFamily
        do {
            let response = try await fetch(url, range: range, userAgent: userAgent, family: first)
            if response.status == 200 || response.status == 206 { return response }
            if let fallback = try? await fetch(url, range: range, userAgent: userAgent, family: first.other),
               fallback.status == 200 || fallback.status == 206 {
                Self.preferredFamily = first.other
                return fallback
            }
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let fallback = try await fetch(url, range: range, userAgent: userAgent, family: first.other)
            if fallback.status == 200 || fallback.status == 206 { Self.preferredFamily = first.other }
            return fallback
        }
    }

    private func fetch(_ url: URL, range: ClosedRange<Int64>, userAgent: String, family: IPFamily) async throws -> MediaResponse {
        var current = url
        for _ in 0 ..< 5 {
            try Task.checkCancellation()
            guard let host = current.host, current.scheme == "https" else { throw URLError(.badURL) }
            var target = current.path.isEmpty ? "/" : current.path
            if let query = current.query(percentEncoded: true) { target += "?" + query }
            let headers = ["User-Agent": userAgent, "Range": "bytes=\(range.lowerBound)-\(range.upperBound)"]

            let key = "\(family.rawValue)|\(host)"
            var result: (status: Int, headers: [String: String], body: Data)
            do {
                result = try await perform(connection(for: key, host: host, family: family), target: target, headers: headers)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A kept-alive connection may have been closed by the server: retry once on a new one.
                connections.removeValue(forKey: key)?.cancel()
                try Task.checkCancellation()
                result = try await perform(connection(for: key, host: host, family: family), target: target, headers: headers)
            }
            if connections[key]?.isUsable == false { connections.removeValue(forKey: key)?.cancel() }

            if (301 ... 308).contains(result.status), let location = result.headers["location"],
               let next = URL(string: location, relativeTo: current)?.absoluteURL {
                current = next
                continue
            }
            return MediaResponse(status: result.status, headers: result.headers, body: result.body, url: current)
        }
        throw URLError(.httpTooManyRedirects)
    }

    private func connection(for key: String, host: String, family: IPFamily) -> MediaConnection {
        if let existing = connections[key], existing.isUsable { return existing }
        connections[key]?.cancel()
        let created = MediaConnection(host: host, family: family)
        connections[key] = created
        return created
    }

    /// Runs one request, tearing the connection down if it stalls or the task is cancelled
    /// (Network.framework callbacks don't observe Swift task cancellation by themselves).
    private func perform(
        _ connection: MediaConnection, target: String, headers: [String: String]
    ) async throws -> (status: Int, headers: [String: String], body: Data) {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            connection.cancel()
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try await connection.get(target: target, headers: headers)
        } onCancel: {
            connection.cancel()
        }
    }
}
