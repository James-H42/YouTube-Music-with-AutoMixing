import Foundation

/// Orders the songs Autoplay has lined up so that each mixes well out of the one before, the
/// way a DJ picks the next record: a tempo close enough to beat-match, and a key that sits
/// with the one playing, and, other things being equal, staying with the same artists
/// (One More Time → Around the World → Starboy, which features Daft Punk).
///
/// A song's tempo and key are only known once its audio has been analysed, so this works on
/// a short look-ahead: the next few Autoplay songs are fetched and analysed ahead of time and
/// the best fit is moved to the front. Songs the listener queued themselves are never moved.
enum MixSequencer {
    /// How many upcoming Autoplay songs are fetched ahead and considered for the next slot.
    static let pool = 5

    struct Fit {
        /// 0…1: how easily the tempos beat-match (counting half and double time).
        var tempo: Double
        /// 0…1: how well the keys sit together.
        var key: Double
        /// The two songs share an artist (credited or featured).
        var sameArtist = false
        var total: Double
        var note: String
    }

    /// How well `b` would mix out of `a`, from tempo and key alone.
    /// Everyone on a song, lower-cased: its credited artists and anyone its title features.
    static func names(of song: Song) -> Set<String> {
        var names = Set(song.artists.map { $0.name.lowercased() })
        if let range = song.title.range(of: "(feat\\.?|ft\\.?|featuring|with)\\s+[^\\)\\]]+", options: [.regularExpression, .caseInsensitive]) {
            let featured = song.title[range].replacingOccurrences(of: "^(feat\\.?|ft\\.?|featuring|with)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
            for name in featured.components(separatedBy: CharacterSet(charactersIn: ",&+")).flatMap({ $0.components(separatedBy: " and ") }) {
                let name = name.trimmingCharacters(in: .whitespaces).lowercased()
                if name.count >= 2 { names.insert(name) }
            }
        }
        return names
    }

    /// Places round the Camelot wheel between two keys, and whether they share a mode.
    private static func wheel(_ a: TrackAnalysis, _ b: TrackAnalysis) -> (steps: Int, sameMode: Bool) {
        func number(_ key: Int, _ minor: Bool) -> Int { (((minor ? (key + 3) % 12 : key) * 7) % 12 + 7) % 12 + 1 }
        let (one, two) = (number(a.key, a.isMinor), number(b.key, b.isMinor))
        return (min((one - two + 12) % 12, (two - one + 12) % 12), a.isMinor == b.isMinor)
    }

    static func fit(_ a: TrackAnalysis, _ b: TrackAnalysis, sameArtist: Bool = false, keyMatch: Bool = true) -> Fit {
        var notes: [String] = []
        // Tempo: the nearer the better; past what a beat-matched mix can stretch, no match at all.
        var tempo = 0.2
        if a.beatConfidence >= 0.5, b.beatConfidence >= 0.5, a.bpm > 0, b.bpm > 0 {
            let gap = [1.0, 2.0, 0.5].map { abs(a.bpm / (b.bpm * $0) - 1) }.min() ?? 1
            tempo = gap <= MixPlanner.maxStretch ? 1 - 0.6 * gap / MixPlanner.maxStretch : 0
            notes.append(String(format: "%.0f → %.0f BPM (%.0f %% apart)", a.bpm, b.bpm, gap * 100))
        } else {
            notes.append("free tempo")
        }
        // Key: the same, relative or neighbouring key mixes as it is; a semitone or two away
        // can be met by nudging the pitch; anything else clashes.
        var key = 0.5
        if a.keyConfidence >= 0.35, b.keyConfidence >= 0.35 {
            let (steps, sameMode) = wheel(a, b)
            if MixPlanner.harmonicallyCompatible(a, b) {
                key = 1
            } else if steps == 1, !sameMode {
                // A diagonal move on the wheel (say 10A to 9B): most notes shared.
                key = 0.75
            } else if keyMatch, [1, -1].contains(where: { MixPlanner.harmonicallyCompatible(a, b, shift: $0) }) {
                key = 0.7
            } else if keyMatch, [2, -2].contains(where: { MixPlanner.harmonicallyCompatible(a, b, shift: $0) }) {
                key = 0.5
            } else {
                key = 0.15
            }
            notes.append("\(a.camelot) → \(b.camelot)")
        }
        if sameArtist { notes.append("same artist") }
        return Fit(tempo: tempo, key: key, sameArtist: sameArtist, total: 0.5 * tempo + 0.3 * key + (sameArtist ? 0.2 : 0), note: notes.joined(separator: ", "))
    }

    /// Chains the pool greedily: the best fit for the playing song first, then the best fit
    /// for that one, and so on. `rank` is each song's place in the order Autoplay gave, which
    /// settles close calls so the queue does not drift far from what was recommended. Songs
    /// not analysed yet keep a neutral score.
    static func order(after current: Song, _ analysis: TrackAnalysis, pool: [(item: Song, analysis: TrackAnalysis?, rank: Int)], keyMatch: Bool = true)
        -> [(item: Song, fit: Fit?)] {
        var remaining = pool
        var result: [(item: Song, fit: Fit?)] = []
        var from: TrackAnalysis? = analysis
        var people = names(of: current)
        let first = pool.map(\.rank).min() ?? 0
        while !remaining.isEmpty {
            var best = 0
            var bestScore = -Double.infinity
            var bestFit: Fit?
            for (index, candidate) in remaining.enumerated() {
                let shared = !people.isDisjoint(with: names(of: candidate.item))
                let fit = from.flatMap { a in candidate.analysis.map { MixSequencer.fit(a, $0, sameArtist: shared, keyMatch: keyMatch) } }
                let score = (fit?.total ?? (0.4 + (shared ? 0.2 : 0))) - 0.03 * Double(candidate.rank - first)
                if score > bestScore { (best, bestScore, bestFit) = (index, score, fit) }
            }
            let chosen = remaining.remove(at: best)
            result.append((chosen.item, bestFit))
            from = chosen.analysis
            people = names(of: chosen.item)
        }
        return result
    }
}
