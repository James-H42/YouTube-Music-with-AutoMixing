import Foundation

/// Remembers which music videos have an audio release (and which have none), so a playlist
/// opened again swaps its videos at once, without searching. Entries expire after 30 days;
/// a "none" after 3, since releases can appear later.
actor AudioVersionCache {
    static let shared = AudioVersionCache()

    private struct Entry: Codable {
        var audio: Song?
        var date: Date
    }

    private var entries: [String: Entry]?
    private var saveTask: Task<Void, Never>?
    private let file: URL

    init(file: URL = AppPaths.audioVersions) { self.file = file }

    private func load() -> [String: Entry] {
        if let entries { return entries }
        var loaded = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))) ?? [:]
        let now = Date()
        loaded = loaded.filter { now.timeIntervalSince($0.value.date) < ($0.value.audio == nil ? 3 : 30) * 86_400 }
        entries = loaded
        return loaded
    }

    /// Known answers for these videos: a song, or nil inside the optional for "has none".
    func lookup(_ ids: [String]) -> [String: Song?] {
        let all = load()
        var result: [String: Song?] = [:]
        for id in ids { if let entry = all[id] { result[id] = .some(entry.audio) } }
        return result
    }

    func store(_ answers: [String: Song?]) {
        var all = load()
        for (id, audio) in answers { all[id] = Entry(audio: audio, date: Date()) }
        // Bounded: the oldest answers go first.
        if all.count > 20_000 {
            for key in all.sorted(by: { $0.value.date < $1.value.date }).prefix(all.count - 20_000).map(\.key) { all[key] = nil }
        }
        entries = all
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    func save() {
        guard let entries, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
