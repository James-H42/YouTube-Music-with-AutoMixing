import Foundation

/// Songs saved before the app kept YouTube Music's kind of video have none, so an official
/// music video among them would play as audio. Once per launch this asks YouTube Music about
/// them, 50 at a time (as its web player's "add to queue" does), and stores the answers.
@MainActor
enum VideoTypeRefresh {
    private static var running = false

    /// Returns how many videos got a type.
    @discardableResult
    static func run(library: LibraryStore, player: PlayerController?, pause: Duration = .seconds(2)) async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false }
        var pending = library.untypedVideoIds
        guard !pending.isEmpty else { return 0 }
        MixLog.write("video types: asking about \(pending.count) saved videos")
        var learned = 0
        while !pending.isEmpty {
            let batch = Array(pending.prefix(50))
            pending.removeFirst(batch.count)
            guard let found = await types(of: batch) else { break } // offline or refused: next launch
            library.setVideoTypes(found)
            player?.applyVideoTypes(found)
            learned += found.values.filter { !$0.isEmpty }.count
            if !pending.isEmpty { try? await Task.sleep(for: pause) }
        }
        MixLog.write("video types: \(learned) learned")
        return learned
    }

    /// The types of a batch; every id gets an entry ("" when YouTube Music doesn't know it).
    /// One removed video makes the server refuse the whole batch, so a refused batch is
    /// halved until the removed ones are found. Nil when the request failed otherwise.
    private static func types(of ids: [String]) async -> [String: String]? {
        do {
            var found = try await YTMusic.videoTypes(ids)
            for id in ids where found[id] == nil { found[id] = "" }
            return found
        } catch YTError.http(let status) where status == 404 || status == 400 {
            guard ids.count > 1 else { return [ids[0]: ""] }
            let middle = ids.count / 2
            guard let first = await types(of: Array(ids[..<middle])), let second = await types(of: Array(ids[middle...])) else { return nil }
            return first.merging(second) { a, _ in a }
        } catch {
            return nil
        }
    }
}
