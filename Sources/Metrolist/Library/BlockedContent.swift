import Foundation
import Observation

/// What the filter looks at, readable from any thread: the artists the listener hid, and the
/// community list of AI-generated artists when that is switched on.
final class ContentFilter: @unchecked Sendable {
    static let shared = ContentFilter()
    private let lock = NSLock()
    private var ids: Set<String> = []
    private var names: Set<String> = []
    private var aiEntries: Set<String> = []
    private var aiEnabled = false

    func update(hidden: [BlockedArtist], aiEnabled: Bool, aiEntries: Set<String>) {
        lock.withLock {
            ids = Set(hidden.compactMap { $0.id?.lowercased() })
            names = Set(hidden.filter { $0.id == nil }.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() })
            self.aiEnabled = aiEnabled
            self.aiEntries = aiEntries
        }
    }

    func isBlocked(id: String?, name: String) -> Bool {
        lock.withLock {
            let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
            if let id, ids.contains(id.lowercased()) { return true }
            if names.contains(lowered) { return true }
            guard aiEnabled, !aiEntries.isEmpty else { return false }
            return (id.map { aiEntries.contains($0.lowercased()) } ?? false) || aiEntries.contains("@" + lowered)
        }
    }

    func isBlocked(_ song: Song) -> Bool { song.artists.contains { isBlocked(id: $0.id, name: $0.name) } }

    func isBlocked(_ item: YTItem) -> Bool {
        switch item {
        case .song(let song): isBlocked(song)
        case .album(let album): album.artists.contains { isBlocked(id: $0.id, name: $0.name) }
        case .artist(let artist): isBlocked(id: artist.id, name: artist.title)
        case .playlist: false
        }
    }

    func filter(_ songs: [Song]) -> [Song] { songs.filter { !isBlocked($0) } }

    /// Search and home results without the blocked artists' songs, albums and pages.
    func filter(_ sections: [ItemSection]) -> [ItemSection] {
        sections.compactMap { section in
            var kept = section
            kept.items = section.items.filter { !isBlocked($0) }
            return kept.items.isEmpty && !section.items.isEmpty ? nil : kept
        }
    }
}

struct BlockedArtist: Codable, Hashable, Identifiable {
    var name: String
    var id: String?
    var stableId: String { id ?? name.lowercased() }
}

extension BlockedArtist {
    var identity: String { stableId }
}

private struct BlockedFile: Codable {
    var artists: [BlockedArtist] = []
}

/// Artists the listener never wants to hear: hidden from a song's or artist's menu, plus an
/// optional community blocklist of AI-generated artists. The filter is applied to what
/// Autoplay adds to the queue (before any song is downloaded or analysed) and to search and
/// home results. Songs in the listener's own library and queue are left alone.
@MainActor
@Observable
final class BlockedContent {
    static let shared = BlockedContent()

    private(set) var artists: [BlockedArtist] = []
    var blockAIArtists: Bool {
        didSet {
            UserDefaults.standard.set(blockAIArtists, forKey: "hideAIArtists")
            publish()
            if blockAIArtists { Task { await refreshAIList() } }
        }
    }
    private(set) var aiCount = 0
    private(set) var aiUpdated: Date?
    private(set) var aiMessage: String?
    private(set) var aiRefreshing = false
    @ObservationIgnored private var aiEntries: Set<String> = []

    /// The list the AI-artist blocklist is read from: a public file on GitHub, fetched as data only.
    static let aiListAddress = URL(string: "https://raw.githubusercontent.com/Override92/AiSList/main/AiSList/aislist_blocklist.txt")!
    private static let maxListBytes = 8 * 1024 * 1024
    private static let refreshInterval: TimeInterval = 7 * 24 * 3600
    nonisolated(unsafe) static var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    private let file: URL
    private let aiFile: URL

    init(file: URL = AppPaths.blocked, aiFile: URL = AppPaths.aiBlocklist) {
        self.file = file
        self.aiFile = aiFile
        blockAIArtists = UserDefaults.standard.bool(forKey: "hideAIArtists")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(BlockedFile.self, from: data) { artists = saved.artists }
        if let text = try? String(contentsOf: aiFile, encoding: .utf8) {
            aiEntries = Self.parse(text)
            aiCount = aiEntries.count
            aiUpdated = (try? aiFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        publish()
    }

    /// Entries are "@handle" lines or YouTube channel ids ("UC…"). Everything else is ignored.
    static func parse(_ text: String) -> Set<String> {
        var result = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let entry = line.trimmingCharacters(in: .whitespaces)
            if entry.hasPrefix("@"), entry.count > 1, entry.count <= 120 { result.insert(entry.lowercased()) }
            else if entry.hasPrefix("UC"), (22 ... 26).contains(entry.count), entry.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) { result.insert(entry.lowercased()) }
        }
        return result
    }

    private func publish() {
        ContentFilter.shared.update(hidden: artists, aiEnabled: blockAIArtists, aiEntries: aiEntries)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(BlockedFile(artists: artists)) { try? data.write(to: file, options: .atomic) }
        publish()
    }

    func isHidden(_ artist: ArtistRef) -> Bool {
        artists.contains { $0.stableId == (artist.id ?? artist.name.lowercased()) }
    }

    func hide(_ artist: ArtistRef) {
        guard !isHidden(artist), !artist.name.isEmpty else { return }
        artists.append(BlockedArtist(name: artist.name, id: artist.id))
        save()
    }

    func unhide(_ artist: BlockedArtist) {
        artists.removeAll { $0.stableId == artist.stableId }
        save()
    }

    func reload() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(BlockedFile.self, from: data) { artists = saved.artists } else { artists = [] }
        publish()
    }

    /// Fetches the AI-artist list again when it's a week old (or `force`). The old list is kept
    /// if the download fails or isn't a plausible list.
    func refreshAIList(force: Bool = false) async {
        guard blockAIArtists, !aiRefreshing else { return }
        if !force, !aiEntries.isEmpty, let aiUpdated, Date().timeIntervalSince(aiUpdated) < Self.refreshInterval { return }
        aiRefreshing = true
        defer { aiRefreshing = false }
        do {
            let (data, response) = try await Self.session.data(from: Self.aiListAddress)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= Self.maxListBytes else { aiMessage = "The AI-artist list couldn't be updated."; return }
            let entries = Self.parse(String(decoding: data, as: UTF8.self))
            guard !entries.isEmpty else { aiMessage = "The downloaded AI-artist list was empty, so the old one is kept."; return }
            try data.write(to: aiFile, options: .atomic)
            aiEntries = entries
            aiCount = entries.count
            aiUpdated = Date()
            aiMessage = nil
            publish()
        } catch {
            aiMessage = "The AI-artist list couldn't be updated."
        }
    }

    /// Whether a name matches the AI list, for the status line.
    var aiListIsLoaded: Bool { !aiEntries.isEmpty }
}
