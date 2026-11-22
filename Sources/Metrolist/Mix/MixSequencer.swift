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

    /// What DJs weigh when they choose the next record, learned on 2026-11-21 from 501 transitions
    /// in 28 DJ-made sequences (12 Spotify "Mixed By" playlists and 16 parts of DJ-mixed albums,
    /// among them Kanye West & A-Trak's Soul Mix Show; `Tools/ml/train_sequencer.py`). Each
    /// transition's next song competed against four others from the same sequence, in a
    /// conditional logit model. Re-measured on 2026-11-22, held out by sequence: the DJ's choice
    /// ranked first 29.9 % of the time against 27.8 % for the hand-set weights this replaces (0.5
    /// tempo, 0.3 key, 0.2 artist) and 20 % by chance. Mean reciprocal rank rose by 0.020, but the
    /// 95 % interval (−0.002 … 0.040) includes zero, so the gain is not yet clear. DJs care most
    /// about tempo; key matters far less than the hand-set weights assumed. Values are log-odds;
    /// the tempo gap is in units of 12 %.
    private enum Learned {
        static let tempoGap = -0.632
        static let tempoOver12 = -0.150
        static let tempoFree = -0.985
        static let halfDouble = 0.301
        static let compatible = 0.162
        static let diagonal = -0.111
        static let shift1 = 0.107
        static let shift2 = -0.253
        static let clash = 0.063
        static let keyUnknown = 0.032
        static let sameArtist = 0.214
        /// Per 6 dB of loudness difference, capped at 12 dB.
        static let loudnessStep = -0.177
    }

    private static func loudness(_ track: TrackAnalysis) -> Double {
        let levels = track.energy.filter { $0 > 0 }
        guard !levels.isEmpty else { return -60 }
        return 20 * log10(max(1e-6, Double(levels.reduce(0, +)) / Double(levels.count)))
    }

    static func fit(_ a: TrackAnalysis, _ b: TrackAnalysis, sameArtist: Bool = false, keyMatch: Bool = true) -> Fit {
        var notes: [String] = []
        var logit = 0.0
        // Tempo: the nearer the better; past what a beat-matched mix can stretch, no match at all.
        var tempo = 0.2
        if a.beatConfidence >= 0.5, b.beatConfidence >= 0.5, a.bpm > 0, b.bpm > 0 {
            let readings = [1.0, 2.0, 0.5].map { (gap: abs(a.bpm / (b.bpm * $0) - 1), multiple: $0) }
            let nearest = readings.min { $0.gap < $1.gap }!
            let gap = nearest.gap
            tempo = gap <= MixPlanner.maxStretch ? 1 - 0.6 * gap / MixPlanner.maxStretch : 0
            logit += Learned.tempoGap * min(gap, 0.24) / 0.12 + (gap > 0.12 ? Learned.tempoOver12 : 0) + (nearest.multiple != 1 ? Learned.halfDouble : 0)
            notes.append(String(format: "%.0f → %.0f BPM (%.0f %% apart)", a.bpm, b.bpm, gap * 100))
        } else {
            logit += Learned.tempoFree
            notes.append("free tempo")
        }
        // Key: the same, relative or neighbouring key mixes as it is; a semitone or two away
        // can be met by nudging the pitch; anything else clashes.
        var key = 0.5
        if a.keyConfidence >= 0.35, b.keyConfidence >= 0.35 {
            let (steps, sameMode) = wheel(a, b)
            if MixPlanner.harmonicallyCompatible(a, b) {
                key = 1
                logit += Learned.compatible
            } else if steps == 1, !sameMode {
                // A diagonal move on the wheel (say 10A to 9B): most notes shared.
                key = 0.75
                logit += Learned.diagonal
            } else if keyMatch, [1, -1].contains(where: { MixPlanner.harmonicallyCompatible(a, b, shift: $0) }) {
                key = 0.7
                logit += Learned.shift1
            } else if keyMatch, [2, -2].contains(where: { MixPlanner.harmonicallyCompatible(a, b, shift: $0) }) {
                key = 0.5
                logit += Learned.shift2
            } else {
                key = 0.15
                logit += Learned.clash
            }
            notes.append("\(a.camelot) → \(b.camelot)")
        } else {
            logit += Learned.keyUnknown
        }
        if sameArtist {
            logit += Learned.sameArtist
            notes.append("same artist")
        }
        logit += Learned.loudnessStep * min(12, abs(loudness(a) - loudness(b))) / 6
        // As a probability, so it sits on the same 0 … 1 scale as the neutral score for songs not
        // analysed yet and the small nudge that keeps Autoplay's own order in close calls.
        let total = 1 / (1 + exp(-logit))
        return Fit(tempo: tempo, key: key, sameArtist: sameArtist, total: total, note: notes.joined(separator: ", "))
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
