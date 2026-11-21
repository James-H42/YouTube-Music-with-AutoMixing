import Accelerate
import Foundation

enum MixLength: String, CaseIterable, Identifiable, Codable {
    case short, medium, long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: "Short"
        case .medium: "Medium"
        case .long: "Long"
        }
    }

    /// Target overlap for a plain crossfade, in seconds.
    var fadeSeconds: Double {
        switch self {
        case .short: 4
        case .medium: 7
        case .long: 11
        }
    }

    /// Preferred length of a beat-matched overlap, in seconds. Two full songs on top of each
    /// other get tiring quickly, so this is what lengths are judged against, not a bar count.
    var mixSeconds: Double {
        switch self {
        case .short: 6
        case .medium: 10
        case .long: 18
        }
    }

    /// Overlap lengths worth trying at a tempo, in bars.
    func bars(beatPeriod: Double) -> [Int] {
        let fitting = [1, 2, 4, 8, 16, 32].filter {
            let seconds = Double($0 * 4) * beatPeriod
            return seconds >= mixSeconds * 0.45 && seconds <= mixSeconds * 1.8
        }
        return fitting.isEmpty ? [max(1, Int((mixSeconds / (beatPeriod * 4)).rounded()))] : fitting
    }
}

/// How AutoMix picks transitions when left to itself.
enum MixStyle: String, CaseIterable, Identifiable, Codable {
    /// Find the best point and technique for each pair of songs.
    case smart
    /// Always a plain fade out / fade in at the end of the song.
    case fade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: "Smart mix"
        case .fade: "Fade only"
        }
    }
}

struct MixOptions: Equatable {
    var length: MixLength = .medium
    var style: MixStyle = .smart
    /// Allow the incoming track to be shifted by up to two semitones when that makes the keys agree.
    var keyMatch = true
    /// A sampling link between the two songs that a database records (`SampleDatabase`).
    var relation: SampleRelation?
    /// Use stems in beat-matched overlaps (`StemSeparator`): vocal, bass and drum hand-overs.
    var stems = false
}

/// What the similarity search measured about two songs sharing material: the best match at
/// another speed (a sample replayed faster or slower) and the best at the same speed. These are
/// the sample gate's inputs (`SampleGate`), and `--mixaudit --features` writes them out for
/// training.
struct SampleEvidence {
    /// Whether the tempos allowed a reading at another speed at all.
    var stretched = false
    /// Harmony agreement of the best match at another speed (diagonal mean of cosines).
    var value = 0.0
    /// Its standing against the same-speed, unshifted alignments (the old gate's measure).
    var standout = 0.0
    /// Its standing against the other alignments of its own speed and pitch.
    var variantStandout = 0.0
    /// How much better it is than the best match at the same speed and another pitch.
    var pitchMargin = 0.0
    /// Share of eight-second stretches of the outgoing song that match somewhere at that speed.
    var coverage = 0.0
    /// The same share for the best match at the same speed.
    var sameCoverage = 0.0
    /// Semitones from both readings a sample allows: pitch kept, or pitch moved with the speed.
    var tapeDeviation = 0.0
    /// Distance of the tempo ratio from a whole number of semitones.
    var semitoneFit = 1.0
    /// Size of the speed change, |log2(ratio)|.
    var logStretch = 0.0
    /// Where the match enters the incoming song, in seconds.
    var entry = 0.0
    /// Agreement of tone colour along the match, each song against its own average.
    var tone = 0.0
    var keysAgree = false
    var beatConfidence = 0.0
    /// The tempos are a whole number of semitones apart, like one record at two speeds.
    var record = false
    /// A database links the two songs.
    var known = false
    var sameValue = 0.0
    var sameStandout = 0.0
    var sameTone = 0.0
    var sameEntry = 0.0

    static let header = "stretched\tvalue\tstandout\tvariantStandout\tpitchMargin\tcoverage\tsameCoverage\ttapeDeviation\tsemitoneFit\tlogStretch\tentry\ttone\tkeysAgree\tbeatConfidence\trecord\tknown\tsameValue\tsameStandout\tsameTone\tsameEntry"

    var line: String {
        let values: [Double] = [stretched ? 1 : 0, value, standout, variantStandout, pitchMargin, coverage, sameCoverage, tapeDeviation,
                                semitoneFit, logStretch, entry, tone, keysAgree ? 1 : 0, beatConfidence, record ? 1 : 0, known ? 1 : 0,
                                sameValue, sameStandout, sameTone, sameEntry]
        return values.map { String(format: "%.4f", $0) }.joined(separator: "\t")
    }
}

/// Whether a match at another speed is real shared material, for songs no database links.
///
/// A logistic model trained on 2026-11-21 (`Tools/ml/train_gate.py`, see
/// docs/AUTOMIX_REFERENCE_MIXES.md): 204 known sample, interpolation and remix pairs, including
/// faster and slower replays of same-speed ones, against 826 DJ-adjacent, random and play-history
/// pairs, also replayed. Folds are grouped by song. The old rule (4.5 σ above the same-speed
/// alignments) fired on 70 % of those negatives, with up to 60 % speed changes on unrelated songs,
/// and its ranking was barely better than chance (AUC 0.650). This gate has AUC 0.710 held out. At
/// its threshold it passes about 8 % of negatives and 41 % of the real matches. Real tempo changes in DJ mixes stay
/// under 20 % in 98.6 % of transitions (Kim et al., ISMIR 2020), so a missed sample, which falls
/// back to a blend, costs far less than a false one. The strongest cue is `pitchMargin`: a real
/// sample matches at one pitch clearly better than at the others.
enum SampleGate {
    // Tools/ml/data/gate/gate-stretched-v1.json: variantStandout, pitchMargin, coverage, tone,
    // tapeDeviation, semitoneFit (standardised), L2 0.3.
    static let mean = [4.6777, 0.06507, 0.13705, 0.04625, 0.86306, 0.25808]
    static let scale = [0.75614, 0.07564, 0.10793, 0.30575, 0.70198, 0.14519]
    static let weights = [0.07479, 1.02688, 0.04011, -0.09277, -0.25263, -0.24013]
    static let bias = -0.21045
    static let threshold = 0.61722

    static func logit(_ evidence: SampleEvidence) -> Double {
        let values = [evidence.variantStandout, evidence.pitchMargin, evidence.coverage, evidence.tone,
                      evidence.tapeDeviation, evidence.semitoneFit]
        return zip(zip(values, zip(mean, scale)), weights).reduce(bias) { total, item in
            let ((value, (centre, spread)), weight) = item
            return total + weight * (value - centre) / spread
        }
    }

    static func accepts(_ evidence: SampleEvidence) -> Bool {
        evidence.stretched && logit(evidence) > threshold
    }
}

/// Decides how to move from one analysed track to the next, the way a DJ would. It proposes
/// several candidate transitions and ranks them:
///
/// - **Structure**: bar-aligned, tempo-matched blends between phrase boundaries, scored for
///   how much of either song is lost, harmonic agreement, clashing vocals and energy.
/// - **Lyrics**: where both songs sing the same words, hand over on that phrase.
/// - **Similarity**: where a passage of one song sounds like a passage of the other
///   (harmony and tone colour), dissolve between the two.
/// - **Ending**: a plain fade when nothing better is available or was asked for.
enum MixPlanner {
    /// Prints what the planner considered (for the `--mixplan` diagnostic).
    nonisolated(unsafe) static var debug = false

    /// Largest tempo change applied to a track for a beat-matched mix.
    static let maxStretch = 0.12

    /// How far a match at *another speed* must stand out (in standard deviations of how alike
    /// the two songs are in general) when no database says the songs share material. Such a
    /// match brings a large speed change, and unrelated songs reached the old bar of 4.5 in about
    /// a third of pairs in every style (measured with `--mixaudit`). Songs with a documented
    /// link keep the old bar. Adjustable for measurement (`--mixaudit --standout x`).
    nonisolated(unsafe) static var unlinkedStretchStandout = 4.5
    /// Latest entry into the next song for such an unconfirmed match, in seconds.
    nonisolated(unsafe) static var unlinkedStretchLatestEntry = 1_000.0
    /// Whether the tempo-ratio-only guess ("one record replayed at another speed") is offered
    /// without a documented link. The ratio alone matches by chance in about one pair in five.
    nonisolated(unsafe) static var unlinkedRecordGuess = true

    /// When set, `similar` records what it measured about the best match at another speed in
    /// `lastEvidence` (for `--mixaudit --features`, which trains the sample gate).
    nonisolated(unsafe) static var collectEvidence = false
    nonisolated(unsafe) static var lastEvidence: SampleEvidence?
    /// Whether unlinked matches at another speed go through the learned `SampleGate` (on) or the
    /// old standout rule (off, for comparison: `--mixaudit --no-gate`).
    nonisolated(unsafe) static var sampleGateEnabled = true
    /// Largest tempo gap bridged by a ramp (the playing song easing to the next one's tempo before
    /// a beat-matched overlap) when the songs share no material. DJs change tempo by more than 10 %
    /// in 5.5 % of transitions and by more than 20 % in 1.4 % (Kim et al., ISMIR 2020), so gaps
    /// past this fade instead. 0 turns ramps off (`--mixaudit --ramp 0`).
    nonisolated(unsafe) static var rampMaxStretch = 0.20

    static func harmonicallyCompatible(_ a: TrackAnalysis, _ b: TrackAnalysis, shift: Int = 0) -> Bool {
        let keyB = ((b.key + shift) % 12 + 12) % 12
        func camelot(_ key: Int, _ minor: Bool) -> Int { (((minor ? (key + 3) % 12 : key) * 7) % 12 + 7) % 12 + 1 }
        let numberA = camelot(a.key, a.isMinor)
        let numberB = camelot(keyB, b.isMinor)
        let distance = min((numberA - numberB + 12) % 12, (numberB - numberA + 12) % 12)
        // Same key, relative major/minor, or one step round the wheel.
        return a.isMinor == b.isMinor ? distance <= 1 : distance == 0
    }

    /// Multiplier (1, 2 or ½) for the incoming track's beat length that brings it closest to
    /// the outgoing one, so a song counted at half or double time still lines up.
    static func fold(_ periodA: Double, _ periodB: Double, forced: Bool = false) -> Double {
        let simple = [1.0, 2.0, 0.5].min { abs(periodB * $0 / periodA - 1) < abs(periodB * $1 / periodA - 1) } ?? 1
        guard forced, abs(periodB * simple / periodA - 1) > 0.2 else { return simple }
        // Asked to beat-match two tempos that are nowhere near each other: lock them three
        // against two (or four against three) instead of stretching either out of shape.
        return [1.0, 2.0, 0.5, 1.5, 2.0 / 3, 4.0 / 3, 0.75].min { abs(periodB * $0 / periodA - 1) < abs(periodB * $1 / periodA - 1) } ?? simple
    }

    /// Seconds of the outgoing track over which it eases to another speed or pitch before a
    /// mix. Slow enough not to be heard as a bend: about eight seconds a semitone.
    static func approachLength(rate: Double, pitch: Double) -> Double {
        guard abs(rate - 1) > 0.004 || abs(pitch) > 0.01 else { return 0 }
        return min(32, max(12, 8 * abs(pitch) + 45 * abs(log2(max(0.25, rate)))))
    }

    // MARK: - Per-bar view of a track

    private struct Bars {
        let analysis: TrackAnalysis
        /// Beat index of each bar line.
        var beat: [Int] = []
        var time: [Double] = []
        var chroma: [Float] = []
        var level: [Float] = []
        var vocal: [Float] = []
        var clarity: [Float] = []
        var boundary: [Bool] = []
        /// Beats in each bar (4 unless bars were found one by one).
        var beatsInBar: [Int] = []
        var count: Int { beat.count }

        /// True when every bar in the range has four beats, so a plan counted in four-beat
        /// bars lines up with the music there.
        func regular(_ range: Range<Int>) -> Bool {
            range.allSatisfy { $0 < 0 || $0 >= count || beatsInBar[$0] == 4 }
        }

        init(_ analysis: TrackAnalysis, lyrics: Lyrics?) {
            self.analysis = analysis
            let beats = analysis.beats
            let chromaBeats = analysis.beatChroma.values
            guard analysis.beatChroma.rows == beats.count, analysis.beatLow.count == beats.count else { return }
            let strength = analysis.beatStrength
            let overall = max(1e-6, strength.reduce(0, +) / Float(max(1, strength.count)))
            let boundaries = Set(analysis.boundaries)
            let voiced = MixPlanner.vocalIntervals(lyrics)
            var midShare: [Float] = []

            let lines = analysis.barLines
            for (position, index) in lines.enumerated() {
                // A bar runs to the next bar line: four beats unless the grid found bars one by
                // one (pickups, short bars, other metres).
                let span = position + 1 < lines.count ? lines[position + 1] - index : 4
                guard span > 0, span <= 8, index + span <= beats.count else { continue }
                beat.append(index)
                beatsInBar.append(span)
                time.append(beats[index])
                var sum = [Float](repeating: 0, count: 12)
                var level: Float = 0
                var clarity: Float = 0
                var middle: Float = 0
                for step in 0 ..< span {
                    let b = index + step
                    for pitch in 0 ..< 12 { sum[pitch] += chromaBeats[b * 12 + pitch] }
                    let total = analysis.beatLow[b] + analysis.beatMid[b] + analysis.beatHigh[b]
                    level += total / 3
                    clarity += strength[b] / overall
                    middle += analysis.beatMid[b] / max(total, 1e-6)
                }
                let length = max(1e-6, sum.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot())
                chroma.append(contentsOf: sum.map { $0 / length })
                self.level.append(level / Float(span))
                self.clarity.append(clarity / Float(span))
                midShare.append(middle / Float(span))
                boundary.append(boundaries.contains(index))
                if let voiced {
                    let start = beats[index]
                    let end = index + span < beats.count ? beats[index + span] : start + Double(span) * 60 / analysis.bpm
                    let covered = voiced.reduce(0.0) { $0 + max(0, min(end, $1.upperBound) - max(start, $1.lowerBound)) }
                    vocal.append(Float(min(1, covered / max(0.1, end - start))))
                }
            }
            if voiced == nil {
                // Without timed lyrics, guess: singing pushes energy into the mid band.
                let sorted = midShare.sorted()
                guard !sorted.isEmpty else { return }
                let low = sorted[sorted.count / 5]
                let high = max(low + 1e-3, sorted[min(sorted.count - 1, sorted.count * 4 / 5)])
                vocal = zip(midShare, self.level).map { share, level in
                    level < 0.3 ? 0 : min(1, max(0, (share - low) / (high - low)))
                }
            }
        }

        func meanLevel(_ range: Range<Int>) -> Float {
            let clamped = max(0, range.lowerBound) ..< min(count, range.upperBound)
            guard !clamped.isEmpty else { return 0 }
            return clamped.reduce(Float(0)) { $0 + level[$1] } / Float(clamped.count)
        }

        func isBoundary(_ bar: Int) -> Bool {
            bar >= 0 && bar < count && boundary[bar]
        }
    }

    /// Time ranges in which someone is singing, from line-timed lyrics.
    private static func vocalIntervals(_ lyrics: Lyrics?) -> [ClosedRange<Double>]? {
        guard let lyrics, lyrics.isSynced, lyrics.lines.count >= 4 else { return nil }
        let lines = lyrics.lines.filter { !$0.isBackground && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.enumerated().map { index, line in
            let start = line.start + lyrics.offset
            let next = index + 1 < lines.count ? lines[index + 1].start + lyrics.offset : start + 5
            let end = min(line.end.map { $0 + lyrics.offset } ?? next, start + 8, max(next, start + 0.5))
            return start ... max(start + 0.3, end)
        }
    }

    // MARK: - Entry points

    /// The transition AutoMix would use on its own.
    static func plan(from a: TrackAnalysis, to b: TrackAnalysis, lyricsA: Lyrics? = nil, lyricsB: Lyrics? = nil, options: MixOptions = MixOptions()) -> MixPlan? {
        candidates(from: a, to: b, lyricsA: lyricsA, lyricsB: lyricsB, options: options).first
    }

    /// Ranked transitions between two tracks, best first.
    static func candidates(from a: TrackAnalysis, to b: TrackAnalysis, lyricsA: Lyrics? = nil, lyricsB: Lyrics? = nil, options: MixOptions = MixOptions()) -> [MixPlan] {
        guard a.duration > 45, b.duration > 30 else { return [] }
        let fadeOut = ending(a, b, options: options)
        if options.style == .fade { return [fadeOut].compactMap { $0 } }

        let barsA = Bars(a, lyrics: lyricsA)
        let barsB = Bars(b, lyrics: lyricsB)
        var found: [MixPlan] = []
        if barsA.count >= 16, barsB.count >= 16 {
            found += structural(barsA, barsB, options: options)
            found += lyrical(barsA, barsB, lyricsA: lyricsA, lyricsB: lyricsB, options: options)
            found += similar(barsA, barsB, options: options)
        }
        if var fadeOut {
            // A plain fade is the fallback; it only wins when nothing musical was found.
            fadeOut.score = found.isEmpty ? 0.5 : min(0.45, (found.map(\.score).max() ?? 0.5) - 0.05)
            let freeTime = a.beatConfidence < 0.5 || b.beatConfidence < 0.5
            if freeTime { fadeOut.score = max(fadeOut.score, 0.62) }
            found.append(fadeOut)
        }
        found.sort { $0.score > $1.score }
        // Keep the best of each kind, then drop near-duplicates.
        var result: [MixPlan] = []
        for plan in found {
            let duplicate = result.contains { abs($0.outStart - plan.outStart) < 4 && abs($0.inPoint - plan.inPoint) < 4 && $0.sync == plan.sync }
            let sameKind = result.filter { $0.reason == plan.reason || ($0.reason == .sample && plan.reason == .similarity) || ($0.reason == .similarity && plan.reason == .sample) }.count
            if !duplicate, sameKind < (plan.reason == .structure ? 3 : 2) { result.append(plan) }
            if result.count >= 6 { break }
        }
        return result.map { describe(withStems($0, barsA, barsB, options: options), a, b) }
    }

    // MARK: - Stems

    /// Stem moves for a beat-matched overlap, as DJs make them with stems and as Mosaikbox
    /// (Sowula and Knees, ISMIR 2024) applies them: its rule-based stem changes raised listeners'
    /// ratings of transitions from 3.08 to 3.46 out of 5 (30 listeners, p < 0.0001).
    /// - Vocals: when both songs sing at once for more than two seconds, the outgoing vocals step
    ///   aside over the first quarter (not in a lyric match, where the shared words are the point).
    /// - Bass: never two basslines; they swap on the middle bar line. The stems do this, so the
    ///   EQ's low band stays open.
    /// - Drums: in a blend of two different songs, the new drums rise over the second quarter and
    ///   the old ones drop back (Mosaikbox's figure 2). Shared material keeps its drums.
    private static func withStems(_ plan: MixPlan, _ a: Bars, _ b: Bars, options: MixOptions) -> MixPlan {
        guard options.stems, plan.sync, plan.beats >= 8, plan.loop == nil, plan.reason != .ending, plan.reason != .manual else { return plan }
        var plan = plan
        let spanA = Double(plan.beats) * plan.periodA
        let spanB = Double(plan.beats) * plan.periodB
        func barsInside(_ bars: Bars, from start: Double, span: Double) -> [Int] {
            (0 ..< bars.count).filter { bars.time[$0] >= start - 0.05 && bars.time[$0] < start + span - 0.05 }
        }
        let insideA = barsInside(a, from: plan.outStart, span: spanA)
        let insideB = barsInside(b, from: plan.inPoint, span: spanB)
        var clashSeconds = 0.0
        for (barA, barB) in zip(insideA, insideB) where barA < a.vocal.count && barB < b.vocal.count {
            if a.vocal[barA] >= 0.5, b.vocal[barB] >= 0.5 { clashSeconds += 4 * plan.periodA }
        }
        var outgoing = StemLanes()
        var incoming = StemLanes()
        var moves: [String] = []
        if clashSeconds > 2, plan.reason != .lyrics {
            outgoing.vocals = MixCurve([(0, 1), (0.25, 0), (1, 0)])
            moves.append("the playing song's vocals step aside")
        }
        outgoing.bass = MixCurve([(0, 1), (0.5, 1), (0.53, 0), (1, 0)])
        incoming.bass = MixCurve([(0, 0), (0.5, 0), (0.53, 1), (1, 1)])
        moves.append("the basslines swap halfway")
        if plan.reason == .structure || plan.reason == .tempo {
            incoming.drums = MixCurve([(0, 0), (0.25, 0), (0.5, 1), (1, 1)])
            outgoing.drums = MixCurve([(0, 1), (0.25, 1), (0.5, 0.4), (1, 0.1)])
            moves.append("the drums hand over")
        }
        plan.outgoingStems = outgoing
        plan.incomingStems = incoming
        plan.outgoing.bass = .constant(1)
        plan.incoming.bass = .constant(1)
        plan.note += (plan.note.isEmpty ? "" : "; ") + "with stems: " + moves.joined(separator: ", ")
        return plan
    }

    // MARK: - Structure

    private static func chromaSimilarity(_ a: Bars, _ barA: Int, _ b: Bars, _ barB: Int, shift: Int) -> Float {
        var sum: Float = 0
        for pitch in 0 ..< 12 {
            sum += a.chroma[barA * 12 + pitch] * b.chroma[barB * 12 + ((pitch - shift) % 12 + 12) % 12]
        }
        return sum
    }

    /// Bar of the incoming track heard `step` bars of the outgoing one into an overlap that
    /// starts at `barB`. `multiple` is the incoming beat's fold (`fold`): 1 when both are
    /// counted alike, 2 when the incoming track is counted at double time (two of its bars pass
    /// per bar of the outgoing one), ½ when at half time.
    static func incomingBar(_ barB: Int, step: Int, multiple: Double) -> Int {
        multiple == 1 ? barB + step : barB + Int((Double(step) * multiple).rounded(.down))
    }

    /// Harmonic agreement of an overlap for each pitch shift from −2 to +2 semitones.
    private static func harmony(_ a: Bars, from barA: Int, _ b: Bars, from barB: Int, bars: Int, multiple: Double = 1) -> [Float] {
        (-2 ... 2).map { shift in
            var total: Float = 0
            var counted = 0
            for step in 0 ..< bars {
                let other = incomingBar(barB, step: step, multiple: multiple)
                guard barA + step < a.count, other < b.count else { continue }
                total += chromaSimilarity(a, barA + step, b, other, shift: shift)
                counted += 1
            }
            return counted > 0 ? total / Float(counted) : 0
        }
    }

    /// Picks the pitch shift for an overlap: none unless shifting clearly improves the harmony.
    private static func chooseShift(_ harmony: [Float], options: MixOptions) -> (shift: Int, value: Float) {
        let unshifted = harmony[2]
        guard options.keyMatch else { return (0, unshifted) }
        var best = 0
        var bestValue = unshifted
        for shift in [-1, 1, -2, 2] {
            // Larger shifts are more audible, so they need to buy more.
            let value = harmony[shift + 2] - Float(abs(shift)) * 0.05
            if value > bestValue + 0.06 {
                best = shift
                bestValue = value
            }
        }
        return (best, harmony[best + 2])
    }

    private static func structural(_ a: Bars, _ b: Bars, options: MixOptions) -> [MixPlan] {
        let trackA = a.analysis
        let trackB = b.analysis
        guard trackA.beatConfidence >= 0.5, trackB.beatConfidence >= 0.5 else { return [] }
        let roughA = 60 / trackA.bpm
        let multiple = fold(60 / trackA.bpm, 60 / trackB.bpm)
        let roughB = 60 / trackB.bpm * multiple
        guard abs(roughB / roughA - 1) <= maxStretch else { return [] }
        // Bars of B heard during `step` bars of A (B's bars are shorter or longer than A's when
        // one of the two is counted at half or double time).
        func barOfB(_ barB: Int, _ step: Int) -> Int { incomingBar(barB, step: step, multiple: multiple) }

        let endA = min(trackA.audibleEnd, trackA.beats.last ?? trackA.audibleEnd)
        let earliestA = max(trackA.duration * 0.25, min(trackA.introEnd + 20, trackA.duration * 0.5))
        let latestB = min(trackB.duration * 0.45, 100)
        let firstB = b.time.firstIndex { $0 >= trackB.audibleStart - 0.05 } ?? 0
        let lengths = options.length.bars(beatPeriod: roughA)
        let target = options.length.mixSeconds

        struct Scored {
            var score: Double
            var barA: Int
            var barB: Int
            var bars: Int
            var shift: Int
            var harmony: Float
            var clash: Float
        }
        var scored: [Scored] = []

        // What leaving at a given point costs: the music after it is never heard.
        for barA in 0 ..< a.count where a.time[barA] >= earliestA {
            for bars in lengths {
                let last = barA + bars
                guard last < a.count || (last == a.count && trackA.time(ofBeat: Double(a.beat[barA] + bars * 4)) <= endA + roughA) else { continue }
                let outEnd = last < a.count ? a.time[last] : trackA.time(ofBeat: Double(a.beat[barA] + bars * 4))
                guard outEnd <= endA + roughA else { continue }
                let lostA = trackA.energyShare(from: outEnd, to: trackA.duration)
                let clarityA = (barA ..< min(a.count, last)).reduce(Float(0)) { $0 + a.clarity[$1] } / Float(bars)
                // Hand over where the outgoing song changes section, or where it starts to wind down.
                let leavesOnBoundary = a.isBoundary(last) || abs(outEnd - trackA.outroStart) < roughA * 4
                let seconds = Double(bars * 4) * roughA
                var sideA = 1.0 - 1.0 * lostA + (leavesOnBoundary ? 0.14 : 0) - 0.10 * abs(log2(seconds / target))
                sideA += 0.1 * Double(min(1, clarityA)) - 0.1
                let levelA = a.meanLevel(max(0, barA - 4) ..< barA)

                // Counted in four-beat bars: a stretch with a short bar or another metre in it
                // would put the two songs' bar lines out of step.
                guard a.regular(barA ..< barA + bars) else { continue }
                for barB in firstB ..< b.count where b.time[barB] <= latestB && barOfB(barB, bars) + 4 < b.count {
                    let endB = barOfB(barB, bars)
                    guard b.regular(barB ..< endB) else { continue }
                    let skipB = trackB.energyShare(from: 0, to: b.time[barB])
                    let clarityB = (barB ..< max(barB + 1, endB)).reduce(Float(0)) { $0 + b.clarity[$1] } / Float(max(1, endB - barB))
                    let startsOnBoundary = barB == firstB || b.isBoundary(barB)
                    // The classic rule: the new song's next section should land as the old one leaves.
                    let landsOnBoundary = b.isBoundary(endB) || abs(b.time[endB] - trackB.introEnd) < roughB * 4
                    var score = sideA - 1.4 * skipB + (startsOnBoundary ? 0.08 : 0) + (landsOnBoundary ? 0.12 : 0)
                    score += 0.1 * Double(min(1, clarityB)) - 0.1

                    let (shift, harmonyValue) = chooseShift(harmony(a, from: barA, b, from: barB, bars: bars, multiple: multiple), options: options)
                    var clash: Float = 0
                    for step in 0 ..< bars where barA + step < a.count { clash += a.vocal[barA + step] * b.vocal[barOfB(barB, step)] }
                    clash /= Float(bars)
                    let levelB = b.meanLevel(endB ..< endB + 4)
                    // Two voices or two keys at once grate more the longer they last.
                    score += 0.30 * Double(harmonyValue - 0.55) - 0.05 * Double(abs(shift))
                    score -= 0.40 * Double(clash) * (0.5 + 0.5 * seconds / target)
                    score -= 0.25 * Double(max(0, 0.5 - harmonyValue)) * seconds / target
                    score -= 0.15 * Double(min(1, abs(levelA - levelB)))
                    score -= 1.5 * max(0, abs(roughB / roughA - 1) - 0.05)
                    scored.append(Scored(score: score, barA: barA, barB: barB, bars: bars, shift: shift, harmony: harmonyValue, clash: clash))
                }
            }
        }
        scored.sort { $0.score > $1.score }

        // Verify the best few against the actual beat grids: beat-matching a guessed grid sounds
        // worse than no beat-matching at all.
        var result: [MixPlan] = []
        for candidate in scored.prefix(60) {
            let outStart = a.time[candidate.barA]
            let inPoint = b.time[candidate.barB]
            let spanA = Double(candidate.bars * 4) * roughA
            let spanB = Double(candidate.bars * 4) * roughB
            guard trackA.beatsAreSteady(from: outStart - 8, to: outStart + spanA + 1),
                  trackB.beatsAreSteady(from: inPoint, to: inPoint + spanB + 8),
                  trackA.beatClarity(from: outStart - 2, to: outStart + spanA) >= 0.45,
                  trackB.beatClarity(from: inPoint, to: inPoint + spanB) >= 0.45
            else { continue }
            // Offer genuinely different places to leave the song, not three versions of one.
            if result.contains(where: { abs($0.outStart - outStart) < 20 }) { continue }
            var plan = synced(trackA, trackB, outStart: outStart, inPoint: inPoint, beats: candidate.bars * 4)
            guard plan.sync else { continue }
            if candidate.shift != 0 {
                // The playing song drifts to the new key beforehand, not while both are heard.
                plan.outgoingPitch = Double(-candidate.shift)
                plan.approach = approachLength(rate: 1, pitch: Double(candidate.shift))
            }
            let rough = candidate.harmony < 0.5 || candidate.clash > 0.45
            plan.applyShape(.blend)
            if rough {
                // Clashing harmony or two singers at once: the old song's middle steps back early.
                plan.outgoing.mid = MixCurve([(0, 1), (0.2, 1), (0.5, 0.45), (1, 0.3)])
            }
            plan.preset = .auto
            plan.reason = .structure
            plan.score = candidate.score
            plan.note = structureNote(a, b, candidate.barA, candidate.barB, candidate.bars, rough: rough)
            result.append(plan)
            if result.count >= 3 { break }
        }
        return result
    }

    private static func structureNote(_ a: Bars, _ b: Bars, _ barA: Int, _ barB: Int, _ bars: Int, rough: Bool) -> String {
        var parts: [String] = []
        if a.isBoundary(barA + bars) { parts.append("leaves on a section change") }
        if b.isBoundary(barB + bars) { parts.append("the next section lands as it takes over") }
        if parts.isEmpty { parts.append("phrase-aligned") }
        if rough { parts.append("the old song steps back early where the two would clash") }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// A tempo-matched plan between two points, using the tempo as played around the join.
    static func synced(_ a: TrackAnalysis, _ b: TrackAnalysis, outStart: Double, inPoint: Double, beats: Int, forced: Bool = false) -> MixPlan {
        let roughA = 60 / a.bpm
        let periodA = a.beatPeriod(from: outStart - 12, to: outStart + Double(beats) * roughA + 2)
        let rawB = b.beatPeriod(from: inPoint, to: inPoint + Double(beats) * 60 / b.bpm * 1.5 + 8)
        let periodB = rawB * fold(periodA, rawB, forced: forced)
        let canSync = forced || (a.beatConfidence >= 0.4 && b.beatConfidence >= 0.4 && abs(periodB / periodA - 1) <= maxStretch + 0.04)
        var plan = MixPlan(
            preset: .auto, outStart: outStart, inPoint: inPoint, sync: canSync, beats: beats,
            seconds: Double(beats) * periodA, periodA: periodA, periodB: periodB,
            outgoing: DeckLanes(volume: MixCurve([(0, 1), (1, 0)])), incoming: DeckLanes(volume: MixCurve([(0, 0), (1, 1)]))
        )
        plan.tempo = tempoCurve(seconds: plan.seconds)
        return plan
    }

    /// How the tempo moves across a synced overlap of a given length. A long one has room to
    /// glide from the old tempo to the new; in a short one that would be a lurch, so the new
    /// song is held at the old tempo and eases to its own afterwards.
    static func tempoCurve(seconds: Double) -> MixCurve {
        seconds >= 12 ? MixCurve([(0, 0), (0.15, 0), (0.85, 1), (1, 1)]) : .constant(0)
    }

    // MARK: - Ending

    /// A plain fade at the natural end of the outgoing track.
    private static func ending(_ a: TrackAnalysis, _ b: TrackAnalysis, options: MixOptions) -> MixPlan? {
        let endA = a.audibleEnd
        var duration = options.length.fadeSeconds
        // Start as the outgoing track begins to fall away, so a long fade-out isn't sat through.
        var outStart = min(a.outroStart - 0.5, endA - duration)
        outStart = max(outStart, endA - 25, a.duration * 0.5)
        duration = min(duration, endA - outStart)
        guard duration >= 1.5 else { return nil }
        var plan = MixPlan(
            preset: .auto, outStart: outStart, inPoint: b.audibleStart, sync: false, beats: 0, seconds: duration,
            periodA: 60 / a.bpm, periodB: 60 / b.bpm * fold(60 / a.bpm, 60 / b.bpm),
            outgoing: DeckLanes(volume: .constant(1)), incoming: DeckLanes(volume: .constant(1))
        )
        plan.applyShape(.fade)
        plan.reason = .ending
        plan.note = a.beatConfidence < 0.5 || b.beatConfidence < 0.5 ? "Free tempo, so a plain fade" : "Fade at the end of the song"
        return plan
    }

    // MARK: - Lyrics

    private struct Word {
        var text: String
        var start: Double
        var end: Double
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "i", "im", "you", "your", "youre", "me", "my", "we", "us", "it", "its", "is", "are", "was",
        "be", "to", "of", "in", "on", "at", "for", "with", "that", "this", "so", "oh", "ooh", "ah", "yeah", "yea", "uh", "la", "na", "da",
        "do", "dont", "got", "get", "like", "just", "all", "no", "not", "if", "when", "what", "up", "out", "now", "they", "he", "she", "hey",
        "can", "cant", "will", "its", "ive", "ill", "id", "from", "by", "as", "have", "has", "had", "were", "let", "go", "know", "baby",
    ]

    private static func words(_ lyrics: Lyrics?) -> [Word] {
        guard let lyrics, lyrics.isSynced else { return [] }
        var result: [Word] = []
        func clean(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let lines = lyrics.lines.filter { !$0.isBackground }
        for (index, line) in lines.enumerated() {
            let start = line.start + lyrics.offset
            if !line.words.isEmpty {
                for word in line.words {
                    let text = clean(word.text)
                    if !text.isEmpty { result.append(Word(text: text, start: word.start + lyrics.offset, end: word.end + lyrics.offset)) }
                }
            } else {
                // Line-timed only: spread the words evenly across the line.
                let tokens = line.text.split(whereSeparator: { $0 == " " || $0 == "-" }).map { clean(String($0)) }.filter { !$0.isEmpty }
                guard !tokens.isEmpty else { continue }
                let next = index + 1 < lines.count ? lines[index + 1].start + lyrics.offset : start + 4
                let end = min(line.end.map { $0 + lyrics.offset } ?? next, start + Double(tokens.count) * 0.6 + 1, max(next, start + 0.5))
                let step = (end - start) / Double(tokens.count)
                for (position, token) in tokens.enumerated() {
                    result.append(Word(text: token, start: start + Double(position) * step, end: start + Double(position + 1) * step))
                }
            }
        }
        return result
    }

    private struct Phrase {
        var text: String
        var length: Int
        var a: (start: Double, end: Double)
        var b: (start: Double, end: Double)
        var weight: Double
    }

    /// Word sequences sung in both songs, late in the first and early in the second.
    private static func sharedPhrases(_ wordsA: [Word], _ wordsB: [Word], a: TrackAnalysis, b: TrackAnalysis) -> [Phrase] {
        guard wordsA.count >= 8, wordsB.count >= 8 else { return [] }
        let zoneA = a.duration * 0.2 ... (a.audibleEnd - 1.5)
        let zoneB = 0.0 ... b.duration * 0.6
        var result: [Phrase] = []
        var used: Set<String> = []
        for length in stride(from: 6, through: 2, by: -1) {
            var index: [String: [Int]] = [:]
            guard wordsB.count >= length, wordsA.count >= length else { continue }
            for start in 0 ... wordsB.count - length where zoneB.contains(wordsB[start].start) {
                // Words of one phrase are sung together, not spread over several lines.
                guard wordsB[start + length - 1].end - wordsB[start].start < Double(length) * 1.2 + 1 else { continue }
                index[wordsB[start ..< start + length].map(\.text).joined(separator: " "), default: []].append(start)
            }
            var matches: [String: (a: [Int], b: [Int])] = [:]
            for start in 0 ... wordsA.count - length where zoneA.contains(wordsA[start].start) {
                guard wordsA[start + length - 1].end - wordsA[start].start < Double(length) * 1.2 + 1 else { continue }
                let key = wordsA[start ..< start + length].map(\.text).joined(separator: " ")
                if let positions = index[key] { matches[key, default: ([], positions)].a.append(start) }
            }
            for (key, match) in matches {
                let tokens = key.split(separator: " ").map(String.init)
                let content = tokens.filter { !stopWords.contains($0) && $0.count >= 3 }
                // Common filler ("oh yeah", "in the") says nothing about the two songs.
                // A phrase needs two words that carry meaning, or one if it is a hook: at least
                // three words long and sung more than once in both songs.
                let hook = length >= 3 && match.a.count >= 2 && match.b.count >= 2
                guard content.count >= 2 || (content.count >= 1 && hook), key.count >= 8, Set(tokens).count > 1 else { continue }
                if used.contains(where: { $0.contains(key) }) { continue }
                used.insert(key)
                // A hook is repeated: the more often both songs sing it, the stronger the link.
                let repeats = Double(min(match.a.count, 6) + min(match.b.count, 6)) / 12
                let last = match.a.last!
                let first = match.b.first!
                result.append(Phrase(
                    text: key, length: length,
                    a: (wordsA[last].start, wordsA[last + length - 1].end),
                    b: (wordsB[first].start, wordsB[first + length - 1].end),
                    weight: Double(content.count) + Double(length) * 0.5 + repeats * 2
                ))
            }
        }
        return result.sorted { $0.weight > $1.weight }
    }

    private static func lyrical(_ a: Bars, _ b: Bars, lyricsA: Lyrics?, lyricsB: Lyrics?, options: MixOptions) -> [MixPlan] {
        let trackA = a.analysis
        let trackB = b.analysis
        let phrases = sharedPhrases(words(lyricsA), words(lyricsB), a: trackA, b: trackB)
        var result: [MixPlan] = []
        for phrase in phrases.prefix(3) {
            // The outgoing song sings the phrase; the incoming one answers with the same words.
            let endBeat = trackA.beatIndex(nearest: phrase.a.end)
            var startBeat = trackB.beatIndex(nearest: phrase.b.start)
            if trackB.beats[startBeat] > phrase.b.start + 0.12, startBeat > 0 { startBeat -= 1 }
            var plan: MixPlan?
            let preferred = options.length.mixSeconds / (60 / trackA.bpm)
            for beats in [16, 8, 4, 2] where Double(beats) <= preferred * 1.3 && endBeat - beats >= 0 && startBeat - beats >= 0 {
                let candidate = synced(trackA, trackB, outStart: trackA.beats[endBeat - beats], inPoint: trackB.beats[startBeat - beats], beats: beats)
                let steady = trackA.beatsAreSteady(from: candidate.outStart - 8, to: candidate.outStart + Double(beats) * candidate.periodA + 1)
                    && trackB.beatsAreSteady(from: candidate.inPoint, to: candidate.inPoint + Double(beats) * candidate.periodB + 8)
                if candidate.sync, steady {
                    plan = candidate
                    break
                }
            }
            if plan == nil {
                // Tempos too far apart to line up: a quick hand-over on the phrase instead.
                let seconds = max(1.2, min(3, phrase.a.end - phrase.a.start))
                var free = synced(trackA, trackB, outStart: phrase.a.end - seconds, inPoint: max(0, phrase.b.start - seconds), beats: 0)
                free.sync = false
                free.seconds = min(seconds, phrase.b.start - free.inPoint + 0.01)
                plan = free
            }
            guard var plan, plan.outStart > trackA.duration * 0.15 else { continue }
            // The old song finishes the phrase in the clear; the new one comes up under it and
            // has the floor from the last beat.
            plan.outgoing = DeckLanes(volume: MixCurve([(0, 1), (0.8, 1), (1, 0)]))
            plan.incoming = DeckLanes(volume: MixCurve(plan.sync ? [(0, 0), (0.5, 0.5), (0.8, 0.75), (1, 1)] : [(0, 0), (0.6, 0), (1, 1)]))
            plan.incoming.bass = MixCurve([(0, 0), (0.75, 0), (0.9, 1), (1, 1)])
            if plan.sync, plan.beats >= 8,
               let barA = a.time.indices.min(by: { abs(a.time[$0] - plan.outStart) < abs(a.time[$1] - plan.outStart) }),
               let barB = b.time.indices.min(by: { abs(b.time[$0] - plan.inPoint) < abs(b.time[$1] - plan.inPoint) }) {
                // Where the two overlap for a few bars, their keys should agree as well.
                let multiple = fold(60 / trackA.bpm, 60 / trackB.bpm)
                let shift = chooseShift(harmony(a, from: barA, b, from: barB, bars: plan.beats / 4, multiple: multiple), options: options).shift
                if shift != 0 {
                    plan.outgoingPitch = Double(-shift)
                    plan.approach = approachLength(rate: 1, pitch: Double(shift))
                }
            }
            plan.reason = .lyrics
            plan.note = "Both songs sing “\(phrase.text)”"
            let lostA = trackA.energyShare(from: phrase.a.end, to: trackA.duration)
            let skipB = trackB.energyShare(from: 0, to: plan.inPoint)
            plan.score = 1.15 + min(0.3, phrase.weight * 0.04) - 0.7 * lostA - 0.6 * skipB
            result.append(plan)
        }
        return result
    }

    // MARK: - Similarity and samples

    /// Harmony of a track sampled at even time steps (rows of 12), with its level alongside.
    private static func timeGrid(_ track: TrackAnalysis, chroma: [Float], from start: Double, to end: Double, step: Double, rotate: Int = 0) -> (chroma: [Float], level: [Float], tone: [Float]) {
        let count = max(0, Int((end - start) / step))
        var result = [Float](repeating: 0, count: count * 12)
        var level = [Float](repeating: 0, count: count)
        var tone = [Float](repeating: 0, count: count * 7)
        let timbre = track.beatTimbre.values
        var beat = 0
        for index in 0 ..< count {
            let time = start + Double(index) * step
            while beat + 1 < track.beats.count, track.beats[beat + 1] <= time { beat += 1 }
            for pitch in 0 ..< 12 { result[index * 12 + pitch] = chroma[beat * 12 + ((pitch - rotate) % 12 + 12) % 12] }
            level[index] = (track.beatLow[beat] + track.beatMid[beat] + track.beatHigh[beat]) / 3
            var length: Float = 0
            for band in 0 ..< 7 { length += timbre[beat * 7 + band] * timbre[beat * 7 + band] }
            length = max(length.squareRoot(), 1e-6)
            for band in 0 ..< 7 { tone[index * 7 + band] = timbre[beat * 7 + band] / length }
        }
        return (result, level, tone)
    }

    /// Position in `b` near `guess` whose loudness pattern over the next few seconds best
    /// matches that of `a` from `time`, to about a fortieth of a second.
    private static func aligned(_ a: TrackAnalysis, at time: Double, _ b: TrackAnalysis, near guess: Double) -> Double {
        guard a.waveRate > 0, abs(a.waveRate - b.waveRate) < 0.01 else { return guess }
        func envelope(_ track: TrackAnalysis) -> [Float] {
            let low = [UInt8](track.waveLow)
            let mid = [UInt8](track.waveMid)
            return zip(low, mid).map { Float($0) + Float($1) }
        }
        let first = envelope(a)
        let second = envelope(b)
        let length = Int(5 * a.waveRate)
        let reach = Int(0.4 * a.waveRate)
        let origin = Int(time * a.waveRate)
        let centre = Int(guess * b.waveRate)
        guard origin >= 0, origin + length < first.count else { return guess }
        var reference = Array(first[origin ..< origin + length])
        let referenceMean = reference.reduce(0, +) / Float(length)
        reference = reference.map { $0 - referenceMean }
        var bestLag = 0
        var bestValue = -Float.infinity
        for lag in -reach ... reach {
            let start = centre + lag
            guard start >= 0, start + length < second.count else { continue }
            let slice = second[start ..< start + length]
            let mean = slice.reduce(0, +) / Float(length)
            var dot: Float = 0
            var energy: Float = 0
            for (index, value) in slice.enumerated() {
                dot += reference[index] * (value - mean)
                energy += (value - mean) * (value - mean)
            }
            let value = dot / max(energy.squareRoot(), 1e-6)
            if value > bestValue {
                bestValue = value
                bestLag = lag
            }
        }
        return max(0, guess + Double(bestLag) / b.waveRate)
    }

    /// Finds a passage of the outgoing track that sounds like a passage early in the incoming
    /// one, comparing harmony along every alignment. Besides like-for-like matches it looks
    /// for the incoming song having *sampled* the outgoing one: the same music a few semitones
    /// away, and, as with a record played slower or faster, correspondingly stretched in time.
    private static func similar(_ a: Bars, _ b: Bars, options: MixOptions) -> [MixPlan] {
        let trackA = a.analysis
        let trackB = b.analysis
        /// Removes a track's average harmony from every beat, leaving how the harmony *moves*.
        /// Two songs in related keys otherwise look alike everywhere, which hides real matches.
        func centred(_ values: [Float]) -> [Float] {
            let rows = values.count / 12
            guard rows > 0 else { return values }
            var mean = [Float](repeating: 0, count: 12)
            for row in 0 ..< rows { for pitch in 0 ..< 12 { mean[pitch] += values[row * 12 + pitch] / Float(rows) } }
            var result = values
            for row in 0 ..< rows {
                var length: Float = 0
                for pitch in 0 ..< 12 {
                    result[row * 12 + pitch] -= mean[pitch]
                    length += result[row * 12 + pitch] * result[row * 12 + pitch]
                }
                length = max(length.squareRoot(), 1e-4)
                for pitch in 0 ..< 12 { result[row * 12 + pitch] /= length }
            }
            return result
        }
        let chromaA = centred(trackA.beatChroma.values)
        let chromaB = centred(trackB.beatChroma.values)
        guard chromaA.count == trackA.beats.count * 12, chromaB.count == trackB.beats.count * 12,
              trackA.beatTimbre.values.count == trackA.beats.count * 7, trackB.beatTimbre.values.count == trackB.beats.count * 7
        else { return [] }

        let step = 0.4
        let window = 20
        let startA = trackA.duration * 0.25
        let gridA = timeGrid(trackA, chroma: chromaA, from: startA, to: trackA.audibleEnd, step: step)
        let rowsA = gridA.level.count
        guard rowsA > window + 8 else { return [] }
        let reachB = min(trackB.duration * 0.55, 120)

        /// rows × columns matrix of dot products between rows of `left` and rows of `right`.
        func products(_ left: [Float], _ right: [Float], width: Int) -> [Float] {
            var transposed = [Float](repeating: 0, count: right.count)
            vDSP_mtrans(right, 1, &transposed, 1, vDSP_Length(width), vDSP_Length(right.count / width))
            var result = [Float](repeating: 0, count: (left.count / width) * (right.count / width))
            vDSP_mmul(left, 1, transposed, 1, &result, 1, vDSP_Length(left.count / width), vDSP_Length(right.count / width), vDSP_Length(width))
            return result
        }

        struct Match {
            var value: Float
            var timeA: Double
            var timeB: Double
            /// Semitones the incoming track sits below the outgoing one.
            var shift: Int
            /// Seconds of the incoming track per second of the outgoing one (1 unless the same
            /// music runs at another speed there).
            var stretch: Double
            /// How the incoming track's beat is counted against the outgoing one's (1, 2 or ½).
            var multiple: Double
            /// Index into `variants`.
            var variant: Int = 0
        }
        let steadyBoth = trackA.beatConfidence >= 0.5 && trackB.beatConfidence >= 0.5
        // A database may say these two songs share material. That settles *whether* (so what
        // is found is ranked and named as a sample, and the tempo move is offered even when
        // the tempos give no clue of their own), but not *where*: a passage still has to stand
        // out in the audio as clearly as ever. Accepting weaker matches because a link is
        // known was tried, and it found "samples" in pairs that were only assumed to have one.
        let known = options.relation
        var variants: [(shift: Int, stretch: Double, multiple: Double)] = (options.keyMatch ? [0, -1, 1, -2, 2] : [0]).map { ($0, 1.0, 1.0) }
        // The next song may have *sampled* this one at another speed. How far the speed moved
        // is known from the two tempos; how far the pitch moved is a separate question, because
        // a producer can slow a sample with or without letting its pitch fall (a slowed record
        // drops about a semitone per 6 %, a time-stretched one not at all). So each tempo
        // reading is tried at several pitches and the harmony decides.
        var record: (shift: Int, stretch: Double, multiple: Double)?
        if steadyBoth {
            for multiple in [1.0, 2.0, 0.5] {
                let stretch = trackA.bpm / (trackB.bpm * multiple)
                // Nearby tempos are simply beat-matched; this is for the ones too far apart for that.
                guard stretch >= 0.62, stretch <= 1.6, abs(stretch - 1) > maxStretch else { continue }
                let semitones = 12 * log2(stretch)
                let tape = Int(semitones.rounded())
                for shift in Set([0, -1, 1, -2, 2, tape - 1, tape, tape + 1]).sorted() where abs(shift) <= 8 {
                    variants.append((shift, stretch, multiple))
                }
                // Tempos that differ by exactly a whole number of semitones' worth are a clue
                // in themselves: that is what replaying a record at another speed produces.
                if record == nil, tape != 0, abs(semitones - Double(tape)) < 0.06 { record = (tape, stretch, multiple) }
            }
            // A documented sample at another tempo: the speed is known even when the tempos
            // are not a tidy number of semitones apart.
            if record == nil, let known, known.isDirect {
                let readings = [1.0, 2.0, 0.5].map { (shift: 0, stretch: trackA.bpm / (trackB.bpm * $0), multiple: $0) }
                    .filter { $0.stretch >= 0.62 && $0.stretch <= 1.6 && abs($0.stretch - 1) > maxStretch }
                record = readings.min { abs($0.stretch - 1) < abs($1.stretch - 1) }
            }
        }

        var best: [Match] = []
        var baseline: [Float] = []
        // Per variant: how its alignments are spread, and each row of A's best value there. A
        // match is judged against its own variant too, since variants at another speed are tried
        // at many pitches and so give chance more goes (the sample gate's evidence).
        var variantCount = [Int](repeating: 0, count: variants.count)
        var variantSum = [Double](repeating: 0, count: variants.count)
        var variantSquares = [Double](repeating: 0, count: variants.count)
        var rowBest = [[Float]](repeating: [], count: variants.count)
        for (variantIndex, variant) in variants.enumerated() {
            let stepB = step * variant.stretch
            let gridB = timeGrid(trackB, chroma: chromaB, from: 0, to: min(trackB.audibleEnd, reachB + Double(window) * stepB), step: stepB, rotate: variant.shift)
            let colsB = gridB.level.count
            guard colsB > window + 2 else { continue }
            let matrix = products(gridA.chroma, gridB.chroma, width: 12)
            let penalty = Float(abs(variant.shift)) * (variant.stretch == 1 ? 0.02 : 0.004) + (variant.stretch == 1 ? 0 : 0.01)
            let lastColumn = min(colsB - window, Int(reachB / stepB))
            guard lastColumn > 0 else { continue }
            var rowMax = [Float](repeating: -1, count: rowsA)
            for row in 0 ..< rowsA - window {
                for column in 0 ..< lastColumn {
                    var sum: Float = 0
                    matrix.withUnsafeBufferPointer { pointer in
                        // Walk down the diagonal: moment for moment, both passages in step.
                        vDSP_sve(pointer.baseAddress! + row * colsB + column, colsB + 1, &sum, vDSP_Length(window))
                    }
                    var quiet = false
                    for offset in stride(from: 0, to: window, by: 5) where gridA.level[row + offset] < 0.2 || gridB.level[column + offset] < 0.2 { quiet = true }
                    guard !quiet else { continue }
                    let value = sum / Float(window) - penalty
                    if variant.shift == 0, variant.stretch == 1 { baseline.append(value) }
                    variantCount[variantIndex] += 1
                    variantSum[variantIndex] += Double(value)
                    variantSquares[variantIndex] += Double(value) * Double(value)
                    if value > rowMax[row] { rowMax[row] = value }
                    best.append(Match(value: value, timeA: startA + Double(row) * step, timeB: Double(column) * stepB, shift: variant.shift, stretch: variant.stretch, multiple: variant.multiple, variant: variantIndex))
                }
            }
            rowBest[variantIndex] = rowMax
        }
        guard baseline.count > 50 else { return [] }
        let mean = baseline.reduce(0, +) / Float(baseline.count)
        let deviation = max(1e-4, (baseline.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(baseline.count)).squareRoot())
        best.sort { $0.value > $1.value }

        /// Share of eight-second stretches of A that match somewhere in B, in this variant, nearly
        /// as well as `level`. A sampled loop recurs through both songs; a chance match is a one-off.
        func coverage(_ index: Int, level: Float) -> Double {
            let rows = rowBest[index]
            var chunks = 0
            var hits = 0
            for start in stride(from: 0, to: rows.count, by: window) {
                guard let top = rows[start ..< min(rows.count, start + window)].max(), top > -1 else { continue }
                chunks += 1
                if top >= level - 0.05 { hits += 1 }
            }
            return chunks > 0 ? Double(hits) / Double(chunks) : 0
        }
        func variantStandout(_ match: Match) -> Double {
            let count = Double(max(1, variantCount[match.variant]))
            let average = variantSum[match.variant] / count
            let spread = max(1e-4, (max(0, variantSquares[match.variant] / count - average * average)).squareRoot())
            return (Double(match.value) - average) / spread
        }
        /// How alike the two passages' tone colour is, each measured against its own song's average.
        func toneAgreement(_ match: Match) -> Double {
            let stepB = step * match.stretch
            let gridB = timeGrid(trackB, chroma: chromaB, from: 0, to: min(trackB.audibleEnd, reachB + Double(window) * stepB), step: stepB, rotate: match.shift)
            let row = Int(((match.timeA - startA) / step).rounded())
            let column = Int((match.timeB / stepB).rounded())
            let rowsB = gridB.level.count
            guard row >= 0, column >= 0, row + window <= rowsA, column + window <= rowsB else { return 0 }
            func average(_ tone: [Float], _ rows: Int) -> [Float] {
                var sum = [Float](repeating: 0, count: 7)
                for index in 0 ..< rows { for band in 0 ..< 7 { sum[band] += tone[index * 7 + band] / Float(rows) } }
                return sum
            }
            let meanA = average(gridA.tone, rowsA)
            let meanB = average(gridB.tone, rowsB)
            var total = 0.0
            for offset in 0 ..< window {
                var dot: Float = 0
                var lengthA: Float = 0
                var lengthB: Float = 0
                for band in 0 ..< 7 {
                    let x = gridA.tone[(row + offset) * 7 + band] - meanA[band]
                    let y = gridB.tone[(column + offset) * 7 + band] - meanB[band]
                    dot += x * y
                    lengthA += x * x
                    lengthB += y * y
                }
                total += Double(dot / max(1e-6, (lengthA * lengthB).squareRoot()))
            }
            return total / Double(window)
        }
        var evidence = SampleEvidence()
        evidence.known = known != nil
        evidence.beatConfidence = min(trackA.beatConfidence, trackB.beatConfidence)
        evidence.record = record != nil
        if let same = best.first(where: { $0.stretch == 1 }) {
            evidence.sameCoverage = coverage(same.variant, level: same.value)
            evidence.sameValue = Double(same.value)
            evidence.sameStandout = Double((same.value - mean) / deviation)
            evidence.sameEntry = same.timeB
            evidence.sameTone = toneAgreement(same)
        }
        if let top = best.first(where: { $0.stretch != 1 }) {
            evidence.stretched = true
            evidence.value = Double(top.value)
            evidence.standout = Double((top.value - mean) / deviation)
            evidence.variantStandout = variantStandout(top)
            let rival = best.first { $0.stretch == top.stretch && $0.multiple == top.multiple && $0.shift != top.shift }
            evidence.pitchMargin = Double(top.value - (rival?.value ?? top.value))
            evidence.coverage = coverage(top.variant, level: top.value)
            let semitones = 12 * log2(top.stretch)
            evidence.tapeDeviation = min(Double(abs(top.shift)), abs(Double(top.shift) - semitones))
            evidence.semitoneFit = abs(semitones - semitones.rounded())
            evidence.logStretch = abs(log2(top.stretch))
            evidence.entry = top.timeB
            evidence.tone = toneAgreement(top)
            let keyGap = ((trackA.key - trackB.key) % 12 + 12) % 12
            evidence.keysAgree = trackA.keyConfidence >= 0.35 && trackB.keyConfidence >= 0.35 && ((top.shift % 12) + 12) % 12 == keyGap
        }
        if collectEvidence { lastEvidence = evidence }
        // Without a database link, a match at another speed must pass the learned gate.
        let gateOpen = known != nil || !sampleGateEnabled || SampleGate.accepts(evidence)
        if debug, known == nil, evidence.stretched {
            print(String(format: "   sample gate: logit %.2f (threshold %.2f) → %@", SampleGate.logit(evidence), SampleGate.threshold, gateOpen ? "open" : "closed"))
        }
        if debug {
            print(String(format: "   similarity: %d alignments, mean %.3f, deviation %.3f", best.count, mean, deviation))
            for variant in variants {
                if let top = best.first(where: { $0.shift == variant.shift && $0.stretch == variant.stretch }) {
                    print(String(format: "     shift %+d stretch %.3f: best %.3f (%.1f σ) A %.1f ↔ B %.1f", variant.shift, variant.stretch, top.value, (top.value - mean) / deviation, top.timeA, top.timeB))
                }
            }
            if let record { print(String(format: "   tempo ratio fits a record replayed %d semitones %@ (%.0f %% speed)", abs(record.shift), record.shift > 0 ? "down" : "up", 100 / record.stretch)) }
        }
        var result: [MixPlan] = []

        /// A plan in which the playing song has eased to the next one's tempo (and `shift`
        /// semitones down) before the overlap, so the two run beat for beat from its first bar.
        func tempoMatched(outStart: Double, inPoint: Double, shift: Int, multiple: Double) -> MixPlan? {
            let roughA = 60 / trackA.bpm
            let periodA = trackA.beatPeriod(from: outStart - 12, to: outStart + 16 * roughA)
            let periodB = trackB.beatPeriod(from: inPoint, to: inPoint + 40 * 60 / trackB.bpm) / multiple
            let rate = periodA / periodB
            guard rate > 0.55, rate < 1.7 else { return nil }
            let endA = trackA.audibleEnd + 1
            for bars in options.length.bars(beatPeriod: periodB).sorted(by: { abs(Double($0 * 4) * periodB - options.length.mixSeconds) < abs(Double($1 * 4) * periodB - options.length.mixSeconds) }) + [2, 1] {
                guard outStart + Double(bars * 4) * periodA <= endA else { continue }
                var plan = MixPlan(
                    preset: .auto, outStart: outStart, inPoint: inPoint, sync: true, beats: bars * 4,
                    seconds: Double(bars * 4) * periodB, periodA: periodA, periodB: periodB,
                    outgoing: DeckLanes(volume: .constant(1)), incoming: DeckLanes(volume: .constant(1))
                )
                plan.tempo = .constant(1)
                plan.outgoingPitch = shift == 0 ? nil : Double(-shift)
                plan.approach = approachLength(rate: rate, pitch: Double(shift))
                guard outStart - (plan.approach ?? 0) > trackA.duration * 0.15 else { return nil }
                plan.applyShape(.fade)
                return plan
            }
            return nil
        }
        func change(_ rate: Double, _ shift: Int) -> String {
            var parts: [String] = []
            if abs(rate - 1) > 0.02 { parts.append(String(format: "%@ to %.0f %% speed", rate < 1 ? "slows" : "speeds up", rate * 100)) }
            if shift != 0 { parts.append("\(rate < 1 || abs(rate - 1) <= 0.02 ? "" : "and ")\(abs(rate - 1) > 0.02 ? "" : "drifts ")\(abs(shift)) semitone\(abs(shift) == 1 ? "" : "s") \(shift > 0 ? "down" : "up")") }
            return parts.joined(separator: abs(rate - 1) > 0.02 && shift != 0 ? ", " : "")
        }

        func admissible(_ match: Match) -> Bool {
            match.stretch == 1 ? match.value >= (steadyBoth ? 0.45 : 0.58) : match.value >= 0.42
        }
        let worthwhile = best.filter(admissible)
        if debug { print("   \(worthwhile.count) admissible matches; best \(worthwhile.first.map { String(format: "%.3f A %.0f ↔ B %.0f shift %+d stretch %.2f", $0.value, $0.timeA, $0.timeB, $0.shift, $0.stretch) } ?? "none")") }
        // The best match anywhere, and the best one at the very start of the incoming song
        // (which costs nothing to enter at, and is where a sample usually opens a track).
        let early = worthwhile.first { $0.timeB < 12 }
        for match in Array(worthwhile.prefix(200)) + [early].compactMap({ $0 }) {
            // It must stand out from how alike the two songs are in general. Matches at another
            // speed are tried at many pitches, so chance has more goes at them: they need more.
            let standout = (match.value - mean) / deviation
            let stretchBar: Float
            // A match at another speed in songs the gate says share no material: offered as a
            // tempo match (the playing song eases to the next one's tempo) at the old bar.
            let tempoOnly = match.stretch != 1 && known == nil && sampleGateEnabled && !gateOpen
            if known != nil {
                stretchBar = 4.5
            } else if sampleGateEnabled {
                // The gate decides whether the pair shares material; standout only ranks where.
                stretchBar = gateOpen ? 4 : Float(unlinkedStretchStandout)
            } else {
                stretchBar = Float(unlinkedStretchStandout)
            }
            let tooLate = match.stretch != 1 && known == nil && match.timeB > unlinkedStretchLatestEntry
            guard standout >= (match.stretch == 1 ? 4 : stretchBar), !tooLate else {
                if debug { print(String(format: "     (match %.3f at A %.0f s ↔ B %.0f s rejected: only %.1f σ)", match.value, match.timeA, match.timeB, standout)) }
                continue
            }
            if result.contains(where: { abs($0.outStart - match.timeA) < 14 && abs($0.inPoint - match.timeB) < 14 }) { continue }

            var plan: MixPlan
            if match.stretch == 1 {
                let seconds = Double(window) * step
                plan = synced(trackA, trackB, outStart: match.timeA, inPoint: match.timeB, beats: 16)
                var steady = false
                if steadyBoth, plan.sync {
                    // Same speed and a steady beat on both sides: put it on the bar lines and lock it.
                    let outStart = trackA.beats[trackA.barIndex(nearest: match.timeA)]
                    let inPoint = trackB.beats[trackB.barIndex(nearest: match.timeB)]
                    let bars = options.length.bars(beatPeriod: 60 / trackA.bpm)
                    let onGrid = synced(trackA, trackB, outStart: outStart, inPoint: inPoint, beats: (bars.count > 1 ? bars[bars.count / 2] : bars[0]) * 4)
                    steady = onGrid.sync
                    if steady {
                        plan = onGrid
                        let trusted = trackA.beatsAreSteady(from: outStart - 4, to: outStart + 16 * onGrid.periodA + 1)
                            && trackB.beatsAreSteady(from: inPoint, to: inPoint + 16 * onGrid.periodB + 4)
                        if !trusted {
                            // The beat grid wobbles here, so don't trust its bar lines to line the
                            // two up: slide the incoming song until the two passages' loudness
                            // patterns coincide. It is the same music, so they will.
                            plan.outStart = match.timeA
                            plan.inPoint = aligned(trackA, at: match.timeA, trackB, near: match.timeB)
                            // Likewise use each song's overall tempo, not the local reading.
                            plan.periodA = 60 / trackA.bpm
                            plan.periodB = 60 / trackB.bpm * fold(60 / trackA.bpm, 60 / trackB.bpm)
                            plan.seconds = Double(plan.beats) * plan.periodA
                        }
                    }
                }
                if !steady {
                    plan.sync = false
                    plan.seconds = seconds
                }
                plan.applyShape(.fade)
                if match.shift != 0 {
                    plan.outgoingPitch = Double(-match.shift)
                    plan.approach = approachLength(rate: 1, pitch: Double(match.shift))
                }
                plan.note = match.shift == 0
                    ? "These passages sound alike (\(Int((match.value * 100).rounded())) % match)"
                    : "These passages sound alike, \(abs(match.shift)) semitone\(abs(match.shift) == 1 ? "" : "s") apart: the playing song drifts \(match.shift > 0 ? "down" : "up") to meet it beforehand"
            } else {
                // The same music at another speed. Put the join on a bar line of the playing
                // song and at the corresponding moment of the next one.
                let outStart = trackA.beats[trackA.barIndex(nearest: match.timeA)]
                let corresponding = match.timeB + (outStart - match.timeA) * match.stretch
                guard corresponding >= -1 else { continue }
                var inBeat = trackB.beatIndex(nearest: max(0, corresponding))
                let inBar = trackB.barIndex(nearest: max(0, corresponding))
                if abs(trackB.beats[inBar] - corresponding) < 0.6 * 60 / trackB.bpm { inBeat = inBar }
                guard let matched = tempoMatched(outStart: outStart, inPoint: trackB.beats[inBeat], shift: match.shift, multiple: match.multiple) else {
                    if debug { print("     (sample match at A \(Int(match.timeA)) s rejected: no room for it)") }
                    continue
                }
                plan = matched
                let rate = plan.periodA / plan.periodB
                plan.note = "The next song uses this passage at another speed: the playing song \(change(rate, match.shift)) beforehand, then the two run together"
            }
            let end = plan.outStart + plan.span(glide: true).outgoing
            guard end <= trackA.audibleEnd + 1 else {
                if debug { print("     (match at A \(Int(match.timeA)) s rejected: runs past the end)") }
                continue
            }
            plan.preset = .auto
            plan.reason = match.stretch == 1 && known == nil ? .similarity : .sample
            if let known {
                plan.known = "\(known.text) (\(known.source))"
                if match.stretch == 1 {
                    plan.note = match.shift == 0
                        ? "The shared passage, as it sounds in each song"
                        : "The shared passage sits \(abs(match.shift)) semitone\(abs(match.shift) == 1 ? "" : "s") \(match.shift > 0 ? "lower" : "higher") in the next song: the playing song drifts to meet it beforehand"
                }
            }
            let lostA = trackA.energyShare(from: end, to: trackA.duration)
            let skipB = trackB.energyShare(from: 0, to: plan.inPoint)
            // Entering at the matching passage is the point, so skipped material costs less here.
            plan.score = 1.12 + Double(match.value - 0.45) * 2 - 0.6 * lostA - 0.5 * skipB
                + (match.stretch != 1 ? 0.1 : 0) + (match.timeB < 12 ? 0.08 : 0) + (known != nil ? 0.15 : 0)
            if tempoOnly {
                // Not a sample: no sample bonus, and below what the same tempo can offer.
                plan.reason = .tempo
                plan.score -= 0.35
                let rate = plan.periodA / plan.periodB
                plan.note = "The harmony lines up once the playing song \(change(rate, match.shift)) beforehand; the songs share no sampled material"
            }
            result.append(plan)
            if result.count >= 3 { break }
        }

        // The tempos say "the same record at another speed" but the harmony could not confirm
        // where (a chopped or replayed sample under new production). Still offer the DJ's move
        // for it: ease the playing song to the next one's tempo, and bring the next one in
        // from its first bar once it is there.
        // Not gated: a tempo ratio a whole number of semitones apart is its own evidence, and the
        // approved P.Y.T. → Good Life plan comes from here when no database link is cached. It
        // gave only about 6 % of the unlinked "samples" the gate was trained against.
        if let record, known != nil || unlinkedRecordGuess, !result.contains(where: { $0.reason == .sample }), b.count > 8, a.count > 16 {
            // The pitch that best matches the two at that speed, if any does at all well.
            let candidates = [0, -1, 1, -2, 2, record.shift].compactMap { shift in best.first { $0.stretch == record.stretch && $0.shift == shift } }
            let top = candidates.max { $0.value < $1.value }
            // Believed only if the two songs' keys say the same thing, or it is unmistakable;
            // otherwise the speed alone changes and the pitch is left where it is.
            let keyGap = ((trackA.key - trackB.key) % 12 + 12) % 12
            let shift = top.flatMap { found -> Int? in
                let standout = (found.value - mean) / deviation
                let keysAgree = trackA.keyConfidence >= 0.35 && trackB.keyConfidence >= 0.35 && ((found.shift % 12) + 12) % 12 == keyGap
                let runnerUp = candidates.filter { $0.shift != found.shift }.map(\.value).max() ?? 0
                return (standout >= 4.5 && found.value - runnerUp >= 0.015) || (standout >= 3.5 && keysAgree) ? found.shift : nil
            } ?? 0
            let endA = min(trackA.audibleEnd, trackA.beats.last ?? trackA.audibleEnd)
            let entry = (0 ..< b.count).first { b.time[$0] >= trackB.audibleStart - 0.05 }
            let seconds = options.length.mixSeconds
            let bars = (0 ..< a.count).filter { a.time[$0] > trackA.duration * 0.4 && a.time[$0] + seconds * record.stretch * 0.7 <= endA }
            // Arrive on a section change of the playing song where there is one near the end.
            let arrival = bars.last { a.boundary[$0] && trackA.energyShare(from: a.time[$0], to: trackA.duration) < 0.2 } ?? bars.last
            if let arrival, let entry, var plan = tempoMatched(outStart: a.time[arrival], inPoint: b.time[entry], shift: shift, multiple: record.multiple) {
                plan.applyShape(.blend)
                plan.preset = .auto
                plan.reason = .sample
                let rate = plan.periodA / plan.periodB
                plan.known = known.map { "\($0.text) (\($0.source))" }
                plan.note = known != nil
                    ? "The sample could not be placed by ear: the playing song \(change(rate, shift)) beforehand to the next one's tempo, then the next comes in on the bar"
                    : "The tempos fit one record replayed at another speed: the playing song \(change(rate, shift)) beforehand, then the next comes in on the bar"
                let end = plan.outStart + plan.span(glide: true).outgoing
                plan.score = 1.02 - 0.7 * trackA.energyShare(from: end, to: trackA.duration) - 0.5 * trackB.energyShare(from: 0, to: plan.inPoint)
                result.append(plan)
            }
        }

        // Tempos too far apart to beat-match as they are, but close enough for a DJ to ride the
        // tempo across: the playing song eases slowly to the next one's tempo before a
        // beat-matched overlap that leaves on a section change near its end. This replaces what
        // unconfirmed "samples" used to do for such pairs, at honest speeds.
        // Only when no passage lines up at the other tempo: a passage whose harmony lines up is
        // evidence for where to mix, a ramp at the song's end is the fallback. (This was first
        // justified by an owner-saved transition that turned out to be an accidental click.)
        if known == nil, steadyBoth, rampMaxStretch > 0, !result.contains(where: { $0.reason == .sample || $0.reason == .tempo }), b.count > 8, a.count > 16 {
            let readings = [1.0, 2.0, 0.5].map { (stretch: trackA.bpm / (trackB.bpm * $0), multiple: $0) }
            if let reading = readings.min(by: { abs($0.stretch - 1) < abs($1.stretch - 1) }),
               abs(reading.stretch - 1) > maxStretch, abs(reading.stretch - 1) <= rampMaxStretch {
                let gap = abs(reading.stretch - 1)
                let endA = min(trackA.audibleEnd, trackA.beats.last ?? trackA.audibleEnd)
                let entry = (0 ..< b.count).first { b.time[$0] >= trackB.audibleStart - 0.05 }
                let seconds = options.length.mixSeconds
                let bars = (0 ..< a.count).filter { a.time[$0] > trackA.duration * 0.45 && a.time[$0] + seconds * reading.stretch * 0.7 <= endA }
                let arrival = bars.last { a.boundary[$0] && trackA.energyShare(from: a.time[$0], to: trackA.duration) < 0.2 } ?? bars.last
                if let arrival, let entry, var plan = tempoMatched(outStart: a.time[arrival], inPoint: b.time[entry], shift: 0, multiple: reading.multiple) {
                    // Slower than a sample's approach, so the change isn't heard as a bend.
                    plan.approach = min(45, max(16, 220 * gap))
                    if plan.outStart - (plan.approach ?? 0) > trackA.duration * 0.15 {
                        plan.applyShape(.blend)
                        plan.preset = .auto
                        plan.reason = .structure
                        let rate = plan.periodA / plan.periodB
                        plan.note = "The tempos are \(Int((gap * 100).rounded())) % apart: the playing song \(change(rate, 0)) gradually beforehand, then the next comes in on the bar"
                        let end = plan.outStart + plan.span(glide: true).outgoing
                        // Below a natural blend or a real match: DJs rarely move tempo this far.
                        plan.score = 0.85 - 2.0 * (gap - maxStretch) - 0.7 * trackA.energyShare(from: end, to: trackA.duration) - 0.5 * trackB.energyShare(from: 0, to: plan.inPoint)
                        result.append(plan)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Editing

    /// Re-derives tempo, loop and labels after a plan's points or length were changed by hand.
    static func normalized(_ plan: MixPlan, _ a: TrackAnalysis, _ b: TrackAnalysis) -> MixPlan {
        var plan = plan
        plan.outStart = min(max(0, plan.outStart), max(0, a.duration - 1))
        plan.inPoint = min(max(0, plan.inPoint), max(0, b.duration - 5))
        if isTempoMatched(plan) {
            // The playing song goes all the way to the next one's tempo; keep it counted the
            // same way (whole, half or double time) as when the plan was made.
            let rawA = a.beatPeriod(from: plan.outStart - 12, to: plan.outStart + 16 * 60 / a.bpm)
            let rawB = b.beatPeriod(from: plan.inPoint, to: plan.inPoint + 40 * 60 / b.bpm)
            let multiple = [1.0, 2.0, 0.5].min { abs(rawB / $0 - plan.periodB) < abs(rawB / $1 - plan.periodB) } ?? 1
            plan.periodA = rawA
            plan.periodB = rawB / multiple
            plan.approach = approachLength(rate: plan.periodA / plan.periodB, pitch: plan.outgoingPitch ?? 0)
        } else {
            let fresh = synced(a, b, outStart: plan.outStart, inPoint: plan.inPoint, beats: max(plan.beats, 4), forced: plan.forceSync == true && plan.sync)
            plan.periodA = fresh.periodA
            plan.periodB = fresh.periodB
            if plan.sync, !fresh.sync { plan.sync = false }
            // A change of key is always made before the overlap, never during it.
            let bend = plan.outgoingPitch ?? 0
            plan.approach = bend == 0 ? nil : approachLength(rate: 1, pitch: bend)
            if !plan.sync, plan.tempo.isConstant, plan.tempo.value(at: 0) > 0.5 { plan.tempo = tempoCurve(seconds: plan.seconds) }
        }
        if plan.sync { plan.outgoingRate = nil }
        if plan.sync, plan.beats <= 0 { plan.beats = 16 }
        if !plan.sync, plan.seconds <= 0 { plan.seconds = Double(max(plan.beats, 8)) * plan.periodA }
        if plan.sync { plan.seconds = Double(plan.beats) * plan.periodA }
        if var loop = plan.loop {
            loop.start = plan.outStart
            loop.length = Double(loop.beats) * plan.periodA
            plan.loop = loop
        }
        return describe(plan, a, b)
    }

    /// The playing song eases to the next one's tempo before the overlap, however far that is,
    /// rather than the two meeting somewhere in between.
    static func isTempoMatched(_ plan: MixPlan) -> Bool {
        plan.sync && (plan.approach ?? 0) > 0 && plan.tempo.isConstant && plan.tempo.value(at: 0) > 0.99 && abs(plan.periodB / plan.periodA - 1) > 0.02
    }

    /// Turns any transition into a beat-matched one: whole bars, both ends on bar lines, the
    /// two tempos locked (stretching both towards each other across the overlap, or locking
    /// them three against two when they are far apart), and the key nudged if that helps.
    static func beatMatched(_ plan: MixPlan, _ a: TrackAnalysis, _ b: TrackAnalysis, options: MixOptions) -> MixPlan {
        var plan = plan
        if isTempoMatched(plan) { return normalized(plan, a, b) }
        plan.sync = true
        plan.forceSync = true
        // A record-style slow-down carried its own pitch drop; neither belongs in a locked mix.
        if plan.outgoingRate != nil { plan.outgoingPitch = nil }
        plan.outgoingRate = nil
        plan.loop = nil
        let length = plan.seconds > 0 ? plan.seconds : plan.duration(glide: true)
        let bars = max(1, Int((length / (60 / a.bpm) / 4).rounded()))
        plan.beats = [1, 2, 4, 8, 16, 32].min { abs($0 - bars) < abs($1 - bars) }! * 4
        let barA = a.barIndex(nearest: plan.outStart)
        let barB = b.barIndex(nearest: plan.inPoint)
        plan.outStart = a.beats[barA]
        plan.inPoint = b.beats[barB]
        if (plan.outgoingPitch ?? 0) == 0, plan.pitchShift == 0 {
            // Pick the key shift from the harmony of the bars that will actually overlap.
            let barsA = Bars(a, lyrics: nil)
            let barsB = Bars(b, lyrics: nil)
            if let indexA = barsA.beat.firstIndex(of: barA), let indexB = barsB.beat.firstIndex(of: barB) {
                let multiple = fold(60 / a.bpm, 60 / b.bpm, forced: true)
                let shift = chooseShift(harmony(barsA, from: indexA, barsB, from: indexB, bars: plan.beats / 4, multiple: multiple), options: MixOptions(keyMatch: true)).shift
                plan.outgoingPitch = shift == 0 ? nil : Double(-shift)
            }
        }
        return normalized(plan, a, b)
    }

    /// Applies a preset to a pair, starting from `base` (usually what AutoMix proposed).
    static func shaped(_ base: MixPlan, as preset: MixPreset, _ a: TrackAnalysis, _ b: TrackAnalysis, options: MixOptions) -> MixPlan {
        var plan = base
        plan.id = UUID()
        plan.loop = nil
        plan.isCustom = true
        plan.preset = preset
        plan.reason = .manual
        plan.note = preset.help
        // These moves are done on the beat: lock the tempos first if they weren't.
        if [.blend, .rise, .loop].contains(preset), !plan.sync {
            plan = beatMatched(plan, a, b, options: options)
            plan.note = preset.help
        }
        // Moves that switch on a bar line are placed so the switch falls on the phrase AutoMix
        // chose: where the two passages correspond if it matched them, otherwise where the
        // old song would have finished leaving, with the new one entering at its mix point.
        func handOver(beats: Int, seconds: Double, at fraction: Double) {
            let matched = base.reason == .sample || base.reason == .similarity
            let switchA = matched ? base.outStart : base.outStart + base.span(glide: true).outgoing
            let switchB = base.inPoint
            if plan.sync {
                plan.beats = beats
                plan.outStart = switchA - fraction * Double(beats) * plan.periodA
                plan.inPoint = switchB - fraction * Double(beats) * plan.periodB
                // No room before the start of the new song: let it come in a bar later.
                if plan.inPoint < 0 { plan.inPoint += (-plan.inPoint / (4 * plan.periodB)).rounded(.up) * 4 * plan.periodB }
                // Nothing glides across a switch; the new song eases to its own tempo afterwards.
                if !isTempoMatched(plan) { plan.tempo = .constant(0) }
            } else {
                plan.seconds = seconds
                plan.outStart = switchA - fraction * seconds
                plan.inPoint = max(0, switchB - fraction * seconds)
            }
        }
        switch preset {
        case .fade:
            if let fade = ending(a, b, options: options) {
                plan = fade
                plan.id = UUID()
                plan.isCustom = true
                plan.preset = .fade
                plan.reason = .manual
            }
        case .blend, .rise:
            plan.pitchShift = base.pitchShift
        case .cut:
            handOver(beats: 4, seconds: 3, at: MixPreset.cut.handover ?? 0.75)
        case .echo:
            handOver(beats: 8, seconds: 6, at: MixPreset.echo.handover ?? 0.5)
        case .loop:
            let beats = plan.sync ? 4 : 0
            if plan.sync { plan.loop = MixLoop(start: plan.outStart, length: Double(beats) * plan.periodA, beats: beats) }
        case .auto, .custom:
            break
        }
        if preset != .fade { plan.applyShape(preset) }
        return normalized(plan, a, b)
    }

    /// Fills in the text shown for a plan.
    static func describe(_ plan: MixPlan, _ a: TrackAnalysis, _ b: TrackAnalysis) -> MixPlan {
        var plan = plan
        let kind: String
        if plan.isCustom {
            kind = plan.preset == .custom ? "Custom" : plan.preset.title
        } else {
            switch plan.reason {
            case .lyrics: kind = "Lyric match"
            case .similarity: kind = "Sound match"
            case .sample: kind = plan.known != nil ? "Known sample" : "Sample match"
            case .tempo: kind = "Tempo match"
            case .ending: kind = "Fade"
            case .structure, .manual: kind = plan.outgoing.bass.isConstant ? "Mix" : "Blend"
            }
        }
        let duration = plan.duration(glide: true)
        let length = plan.sync && plan.beats >= 4
            ? "\(plan.beats / 4) bar\(plan.beats / 4 == 1 ? "" : "s")"
            : (plan.sync ? "\(plan.beats) beats" : "\(Int(duration.rounded())) s")
        plan.summary = "\(kind) · \(length)"

        var parts: [String] = []
        if plan.sync {
            let tempoA = 60 / plan.periodA
            let tempoB = 60 / plan.periodB
            parts.append(abs(tempoA - tempoB) < 0.6 ? String(format: "%.0f BPM", tempoA) : String(format: "%.0f → %.0f BPM", tempoA, tempoB))
        } else if a.beatConfidence < 0.5 || b.beatConfidence < 0.5 {
            parts.append("free tempo")
        } else {
            parts.append(String(format: "%.0f → %.0f BPM", a.bpm, b.bpm))
        }
        if a.keyConfidence >= 0.35, b.keyConfidence >= 0.35 { parts.append("\(a.camelot) → \(b.camelot)") }
        if isTempoMatched(plan) { parts.append(String(format: "first song eases to %.0f %% speed", plan.periodA / plan.periodB * 100)) }
        if let bend = plan.outgoingPitch, bend != 0 { parts.append(String(format: "first song %+.0f st", bend)) }
        if let approach = plan.approach, approach > 0.5 { parts.append(String(format: "over %.0f s beforehand", plan.approachDuration)) }
        if plan.pitchShift != 0 { parts.append(String(format: "next song %+.0f st", plan.pitchShift)) }
        plan.detail = parts.joined(separator: " · ")
        if let known = plan.known, !plan.isCustom, !plan.note.hasPrefix(known) {
            plan.note = "\(known). \(plan.note)"
        }
        return plan
    }
}
