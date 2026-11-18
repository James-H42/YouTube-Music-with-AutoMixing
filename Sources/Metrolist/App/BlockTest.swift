import Foundation

/// `Metrolist --blocktest`: the content filter on sample data, on the real AiSList download,
/// and on a real YouTube Music radio page.
@MainActor
enum BlockTest {
    static func run() async {
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
            if !passed { failures += 1 }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blocktest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = BlockedContent(file: folder.appendingPathComponent("blocked.json"), aiFile: folder.appendingPathComponent("ai.txt"))
        let sung = Song(id: "aaaaaaaaaaa", title: "A", artists: [ArtistRef(name: "Hidden Person", id: "UCaaaaaaaaaaaaaaaaaaaaaa")])
        let other = Song(id: "bbbbbbbbbbb", title: "B", artists: [ArtistRef(name: "Fine Person", id: "UCbbbbbbbbbbbbbbbbbbbbbb")])
        let duet = Song(id: "ccccccccccc", title: "C", artists: [ArtistRef(name: "Fine Person", id: "UCbbbbbbbbbbbbbbbbbbbbbb"), ArtistRef(name: "Hidden Person", id: "UCaaaaaaaaaaaaaaaaaaaaaa")])
        check("nothing is hidden at first", ContentFilter.shared.filter([sung, other, duet]).count == 3)
        store.hide(ArtistRef(name: "Hidden Person", id: "UCaaaaaaaaaaaaaaaaaaaaaa"))
        check("a hidden artist's songs are filtered, including duets", ContentFilter.shared.filter([sung, other, duet]).map(\.id) == ["bbbbbbbbbbb"])
        let sections = [ItemSection(title: "Songs", items: [.song(sung), .song(other)]), ItemSection(title: "Artists", items: [.artist(ArtistItem(id: "UCaaaaaaaaaaaaaaaaaaaaaa", title: "Hidden Person"))])]
        let filtered = ContentFilter.shared.filter(sections)
        check("search and home sections drop them too (and empty sections)", filtered.count == 1 && filtered[0].items.count == 1)
        let reread = BlockedContent(file: folder.appendingPathComponent("blocked.json"), aiFile: folder.appendingPathComponent("ai.txt"))
        check("hidden artists are saved", reread.artists.count == 1)
        store.unhide(store.artists[0])
        check("unhiding brings them back", ContentFilter.shared.filter([sung, other]).count == 2)

        check("list parser keeps only handles and channel ids", BlockedContent.parse("# comment\n@Some Handle\nUCabcdefghijklmnopqrstuv\nhello world\n<script>alert(1)</script>\n").count == 2)

        // The real list.
        store.blockAIArtists = true
        await store.refreshAIList(force: true)
        check("AiSList downloaded and parsed", store.aiCount > 100, "\(store.aiCount) entries")
        if let text = try? String(contentsOf: folder.appendingPathComponent("ai.txt"), encoding: .utf8) {
            let entries = BlockedContent.parse(text)
            if let id = entries.first(where: { $0.hasPrefix("uc") }) {
                let probe = Song(id: "ddddddddddd", title: "AI", artists: [ArtistRef(name: "Somebody", id: id.uppercased().replacingOccurrences(of: "UC", with: "UC"))])
                check("a channel id on the list blocks a song", ContentFilter.shared.isBlocked(probe) || ContentFilter.shared.isBlocked(Song(id: "e", title: "t", artists: [ArtistRef(name: "x", id: id)])))
            }
            if let handle = entries.first(where: { $0.hasPrefix("@") }) {
                let name = String(handle.dropFirst())
                check("a handle on the list blocks the artist of that name", ContentFilter.shared.isBlocked(Song(id: "f", title: "t", artists: [ArtistRef(name: name.capitalized, id: nil)])))
            }
        }
        // Live: a YouTube Music search for an artist whose name is a handle on the list.
        // Search applies the filter itself, so the same search is made with the switch off and on.
        func psyop(_ results: SearchResults?) -> Int { results?.sections.flatMap(\.items).compactMap(\.song).filter { $0.artists.contains { $0.name.lowercased() == "psyopanime" } }.count ?? -1 }
        store.blockAIArtists = false
        let open = try? await YTMusic.search("PsyopAnime", filter: .songs)
        store.blockAIArtists = true
        let blocked = try? await YTMusic.search("PsyopAnime", filter: .songs)
        if open != nil, blocked != nil {
            check("live search: an artist on the list appears with the switch off", psyop(open) > 0, "\(psyop(open)) songs")
            check("live search: and is gone with it on, other results kept", psyop(blocked) == 0 && (blocked?.sections.flatMap(\.items).count ?? 0) > 0,
                  "\(psyop(blocked)) songs, \(blocked?.sections.flatMap(\.items).count ?? 0) other results")
        } else { print("SKIP live search (no network)") }
        store.blockAIArtists = false
        check("switching the list off stops blocking", !ContentFilter.shared.isBlocked(Song(id: "g", title: "t", artists: [ArtistRef(name: "Fine Person", id: nil)])))

        // A real radio page, with one of its artists hidden.
        if let page = try? await YTMusic.radio(for: "y32ejtuxSjM"), page.songs.count > 3 {
            let counts = Dictionary(grouping: page.songs.flatMap(\.artists), by: \.name).mapValues(\.count)
            if let victim = counts.filter({ $0.key != "Michael Jackson" }).max(by: { $0.value < $1.value })?.key ?? counts.keys.first,
               let artist = page.songs.flatMap(\.artists).first(where: { $0.name == victim }) {
                store.hide(artist)
                let kept = ContentFilter.shared.filter(page.songs)
                check("a radio page loses the hidden artist's songs", kept.count < page.songs.count && !kept.contains { $0.artists.contains { $0.name == victim } },
                      "hid \(victim): \(page.songs.count) → \(kept.count) songs")
                store.unhide(store.artists.first { $0.name == victim }!)
            }
        } else { print("SKIP radio page (no network or blocked)") }
        try? FileManager.default.removeItem(at: folder)
        print(failures == 0 ? "all content-filter checks passed" : "\(failures) content-filter checks FAILED")
    }
}
