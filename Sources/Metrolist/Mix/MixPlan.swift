import Foundation

/// One automation lane of a deck during a transition. Every lane runs from 0 to 1.
enum MixLane: String, Codable, CaseIterable, Identifiable {
    /// Fader. 1 is full level; the fader law is equal-power, so straight lines cross-fade cleanly.
    case volume
    /// Three-band EQ: 1 is flat, 0 removes the band.
    case bass, mid, high
    /// High-pass sweep: 0 is off, 1 leaves only the top of the spectrum.
    case filter
    /// Echo send: 0 is dry, 1 is a heavy repeating echo.
    case echo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volume: "Volume"
        case .bass: "Bass"
        case .mid: "Mids"
        case .high: "Highs"
        case .filter: "Filter"
        case .echo: "Echo"
        }
    }

    /// Value that leaves the sound untouched.
    var neutral: Double {
        switch self {
        case .volume, .bass, .mid, .high: 1
        case .filter, .echo: 0
        }
    }
}

struct MixPoint: Codable, Equatable {
    /// Position through the transition, 0…1.
    var x: Double
    var y: Double
}

/// A breakpoint curve across a transition.
struct MixCurve: Codable, Equatable {
    var points: [MixPoint]

    init(_ pairs: [(Double, Double)]) {
        points = pairs.map { MixPoint(x: $0.0, y: $0.1) }
    }

    static func constant(_ value: Double) -> MixCurve { MixCurve([(0, value), (1, value)]) }

    func value(at x: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for index in 1 ..< points.count where x <= points[index].x {
            let a = points[index - 1]
            let b = points[index]
            let width = b.x - a.x
            return width <= 1e-9 ? b.y : a.y + (b.y - a.y) * (x - a.x) / width
        }
        return last.y
    }

    var isConstant: Bool {
        guard let first = points.first else { return true }
        return points.allSatisfy { abs($0.y - first.y) < 1e-6 }
    }

    /// Mean value over 0…1.
    var mean: Double {
        (0 ..< 64).reduce(0.0) { $0 + value(at: (Double($1) + 0.5) / 64) } / 64
    }

    mutating func normalize() {
        points = points.map { MixPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }.sorted { $0.x < $1.x }
        if points.isEmpty { points = [MixPoint(x: 0, y: 0), MixPoint(x: 1, y: 0)] }
    }
}

/// All lanes of one deck.
struct DeckLanes: Codable, Equatable {
    var volume: MixCurve
    var bass = MixCurve.constant(1)
    var mid = MixCurve.constant(1)
    var high = MixCurve.constant(1)
    var filter = MixCurve.constant(0)
    var echo = MixCurve.constant(0)

    subscript(lane: MixLane) -> MixCurve {
        get {
            switch lane {
            case .volume: volume
            case .bass: bass
            case .mid: mid
            case .high: high
            case .filter: filter
            case .echo: echo
            }
        }
        set {
            switch lane {
            case .volume: volume = newValue
            case .bass: bass = newValue
            case .mid: mid = newValue
            case .high: high = newValue
            case .filter: filter = newValue
            case .echo: echo = newValue
            }
        }
    }
}

/// Ready-made shapes for a transition, in the spirit of a DJ's stock moves.
enum MixPreset: String, Codable, CaseIterable, Identifiable {
    case auto, fade, blend, rise, cut, echo, loop, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .fade: "Fade"
        case .blend: "Blend"
        case .rise: "Rise"
        case .cut: "Cut"
        case .echo: "Echo Out"
        case .loop: "Loop"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .auto: "sparkles"
        case .fade: "arrow.up.right.and.arrow.down.left"
        case .blend: "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .rise: "chart.line.uptrend.xyaxis"
        case .cut: "scissors"
        case .echo: "dot.radiowaves.right"
        case .loop: "repeat"
        case .custom: "slider.horizontal.3"
        }
    }

    var help: String {
        switch self {
        case .auto: "Let AutoMix choose where and how to mix these two songs"
        case .fade: "Plain fade out and fade in, no tempo matching"
        case .blend: "Beat-matched cross-fade that hands the bass over halfway"
        case .rise: "The next song builds underneath, then takes over on the bar"
        case .cut: "Switch on the bar line, with a short echo tail"
        case .echo: "The playing song is cut into an echo as the next one starts on the bar"
        case .loop: "Repeat one bar of the playing song while the next one comes in"
        case .custom: "Your own edit of this transition"
        }
    }

    /// For presets that switch on a bar line rather than blend: how far through the overlap
    /// the switch falls. The mix points are placed so that it lands on the phrase.
    var handover: Double? {
        switch self {
        case .cut: 0.75
        case .echo: 0.5
        default: nil
        }
    }

    /// Presets a listener can pick; `custom` only appears after editing.
    static let selectable: [MixPreset] = [.auto, .fade, .blend, .rise, .cut, .echo, .loop]
}

/// A section of the outgoing track that repeats during the transition.
struct MixLoop: Codable, Equatable {
    /// Position in the outgoing track where the repeated section starts.
    var start: Double
    /// Length of the section in seconds of the track's own time.
    var length: Double
    var beats: Int
}

/// Why AutoMix proposed a transition, shown beside it in the editor.
enum MixReason: String, Codable {
    /// `tempo`: harmony that lines up once the playing song eases to the next one's tempo, in
    /// songs that share no material (the sample gate said no), under its own name. Since
    /// 2026-11-21 (the owner heard MONTERO → Body at 163 % speed and found it unnatural) only
    /// within `MixPlanner.tempoMatchMaxStretch` (20 %) and `tempoMatchMaxShift` (2 semitones).
    case structure, lyrics, similarity, sample, tempo, ending, manual
}

/// Gain of each stem of one deck across an overlap (x: 0 at its start, 1 at its end), in
/// `StemSeparator.sources` order. 1 leaves a stem as it is; the engine removes `1 - gain` of it.
struct StemLanes: Codable, Equatable {
    var drums = MixCurve.constant(1)
    var bass = MixCurve.constant(1)
    var other = MixCurve.constant(1)
    var vocals = MixCurve.constant(1)

    func gains(at progress: Double) -> [Float] {
        let x = min(1, max(0, progress))
        return [drums, bass, other, vocals].map { Float(min(1, max(0, $0.value(at: x)))) }
    }

    var isNeutral: Bool {
        [drums, bass, other, vocals].allSatisfy { lane in lane.points.allSatisfy { abs($0.y - 1) < 1e-6 } }
    }
}

/// A decided transition between two specific tracks. Everything the engine does is in here,
/// so a plan can be edited by hand and stored.
struct MixPlan: Codable, Equatable, Identifiable {
    var id = UUID()
    var preset: MixPreset
    /// Position in the outgoing track where the overlap begins.
    var outStart: Double
    /// Position in the incoming track that is heard first.
    var inPoint: Double
    /// Tempo-matched and beat-aligned. When false the overlap is `seconds` long and free-running.
    var sync: Bool
    /// Length of a synced overlap, in beats of the music.
    var beats: Int
    /// Length of a free-running overlap.
    var seconds: Double
    /// Local beat length of each track around the join. The incoming one may be counted at
    /// half or double time so the two are close.
    var periodA: Double
    var periodB: Double
    /// Semitones the incoming track is shifted so the keys agree; eased away after the mix.
    var pitchShift: Double = 0
    /// Semitones the outgoing track has glided by when the overlap ends (following the tempo
    /// curve), so that it meets the incoming track's key and the incoming one plays untouched.
    var outgoingPitch: Double?
    /// In a free-running overlap, the speed the outgoing track has glided to by the end
    /// (1 = unchanged). Together with `outgoingPitch` this is a record slowing down or speeding
    /// up, which is how a song meets another that sampled it at a different speed.
    var outgoingRate: Double?
    /// Seconds of the outgoing track, before the overlap, over which it eases to the speed and
    /// pitch it has when the overlap begins. A DJ rides the pitch fader *before* bringing the
    /// next record in, so that nothing bends while both are heard.
    var approach: Double?
    /// Beat-matching was asked for by hand, so it is kept even when the tempos are far apart.
    var forceSync: Bool?
    /// Tempo across the overlap: 0 is the outgoing track's tempo, 1 the incoming one's.
    var tempo = MixCurve([(0, 0), (0.15, 0), (0.85, 1), (1, 1)])
    var outgoing: DeckLanes
    var incoming: DeckLanes
    /// Per-stem gains across a synced overlap, when stems are used (`StemSeparator`): the
    /// outgoing song's vocals stepping aside, bass and drums handed over. Nil plays whole songs.
    var outgoingStems: StemLanes?
    var incomingStems: StemLanes?
    var loop: MixLoop?
    var reason: MixReason = .structure
    /// Short description for the interface, e.g. "Blend · 8 bars".
    var summary = ""
    var detail = ""
    /// One line on why this point was chosen, e.g. "Both songs sing “one more time”".
    var note = ""
    /// The documented sampling link between the two songs, when a database confirms one.
    var known: String?
    var score = 0.0
    /// Edited by hand; kept for this pair of songs until reset.
    var isCustom = false

    var bars: Int { max(1, beats / 4) }

    /// Tempo ratio that would make the incoming track match the outgoing one.
    var tempoRatio: Double { periodB / periodA }

    /// Beats per second at `progress` through a synced overlap.
    func beatRate(at progress: Double, glide: Bool) -> Double {
        guard glide else { return 1 / periodA }
        let amount = min(1, max(0, tempo.value(at: progress)))
        return 1 / periodA + (1 / periodB - 1 / periodA) * amount
    }

    /// Length of the overlap in real time. With `glide` both tracks follow the tempo curve;
    /// without it the incoming track is simply held at the outgoing tempo.
    func duration(glide: Bool) -> Double {
        guard sync, beats > 0 else { return max(0.2, seconds) }
        let steps = 64
        let mean = (0 ..< steps).reduce(0.0) { $0 + beatRate(at: (Double($1) + 0.5) / Double(steps), glide: glide) } / Double(steps)
        return Double(beats) / mean
    }

    /// How far the outgoing track's glide has come at `progress`, 0…1.
    func glideAmount(at progress: Double) -> Double {
        min(1, max(0, tempo.value(at: min(1, max(0, progress)))))
    }

    /// How much of `outgoingPitch` applies at `progress`. With an approach the pitch has
    /// already arrived when the overlap starts.
    func pitchAmount(at progress: Double) -> Double {
        (approach ?? 0) > 0 ? 1 : glideAmount(at: progress)
    }

    /// Speed and pitch of the outgoing track at a position *before* the overlap, while it eases
    /// towards the state it starts the overlap in. Nil when the plan has no approach.
    func approachState(at position: Double) -> (rate: Double, pitch: Double)? {
        guard let approach, approach > 0.5 else { return nil }
        let amount = min(1, max(0, (position - (outStart - approach)) / approach))
        // Ease in and out: no moment at which the change starts or stops being heard.
        let eased = amount * amount * amount * (amount * (amount * 6 - 15) + 10)
        let target = max(0.5, rates(at: 0, glide: true).outgoing)
        return (pow(target, eased), (outgoingPitch ?? 0) * eased)
    }

    /// Real time the approach takes, allowing for the change of speed along it.
    var approachDuration: Double {
        guard let approach, approach > 0.5 else { return 0 }
        let steps = 32
        return (0 ..< steps).reduce(0.0) { sum, step in
            let position = outStart - approach + (Double(step) + 0.5) / Double(steps) * approach
            return sum + approach / Double(steps) / (approachState(at: position)?.rate ?? 1)
        }
    }

    /// Playback rates of both decks at `progress`.
    func rates(at progress: Double, glide: Bool) -> (outgoing: Double, incoming: Double) {
        guard sync else {
            guard glide, let target = outgoingRate, target > 0, abs(target - 1) > 0.001 else { return (1, 1) }
            // Geometric, so each moment of the glide changes the speed by the same proportion.
            return (pow(target, glideAmount(at: progress)), 1)
        }
        let rate = beatRate(at: progress, glide: glide)
        return (glide ? rate * periodA : 1, rate * periodB)
    }

    /// Seconds of the outgoing track consumed from the start of a free-running overlap up to
    /// `progress`, allowing for its glide.
    func outgoingTravel(to progress: Double) -> Double {
        let steps = 48
        let width = min(1, max(0, progress)) / Double(steps)
        let sum = (0 ..< steps).reduce(0.0) { $0 + rates(at: (Double($1) + 0.5) * width, glide: true).outgoing }
        return sum * width * duration(glide: true)
    }

    /// Seconds of each track consumed by the overlap (ignoring any loop).
    func span(glide: Bool) -> (outgoing: Double, incoming: Double) {
        guard sync, beats > 0 else { return (glide ? outgoingTravel(to: 1) : duration(glide: glide), duration(glide: glide)) }
        return (Double(beats) * periodA, Double(beats) * periodB)
    }

    /// Identity of everything the engine acts on, to notice edits to a plan that is already cued.
    var signature: Int {
        var hasher = Hasher()
        hasher.combine(outStart)
        hasher.combine(inPoint)
        hasher.combine(sync)
        hasher.combine(beats)
        hasher.combine(seconds)
        hasher.combine(pitchShift)
        hasher.combine(outgoingPitch)
        hasher.combine(outgoingRate)
        hasher.combine(approach)
        hasher.combine(loop?.start)
        hasher.combine(loop?.length)
        for curve in [tempo] + MixLane.allCases.flatMap({ [outgoing[$0], incoming[$0]] }) {
            for point in curve.points {
                hasher.combine(point.x)
                hasher.combine(point.y)
            }
        }
        return hasher.finalize()
    }
}

extension MixPlan {
    /// Mixer settings for one deck at a point in the transition.
    struct Levels {
        var gain: Float
        /// EQ gains in dB.
        var bass: Float
        var mid: Float
        var high: Float
        /// High-pass cutoff in Hz, or nil for none.
        var highPass: Float?
        /// Echo wet level, 0…1.
        var echo: Float
    }

    func levels(outgoing isOutgoing: Bool, at progress: Double) -> Levels {
        let lanes = isOutgoing ? outgoing : incoming
        let p = min(1, max(0, progress))
        func value(_ lane: MixLane) -> Double { min(1, max(0, lanes[lane].value(at: p))) }
        // Equal-power fader law: two straight opposing lines keep the combined level steady.
        let gain = sin(value(.volume) * .pi / 2)
        let decibels: (Double) -> Float = { Float(-32 * pow(1 - $0, 1.4)) }
        let sweep = value(.filter)
        return Levels(
            gain: Float(gain),
            bass: decibels(value(.bass)), mid: decibels(value(.mid)), high: decibels(value(.high)),
            // 30 Hz up to about 5 kHz on a logarithmic curve.
            highPass: sweep > 0.01 ? Float(30 * pow(170, sweep)) : nil,
            echo: Float(value(.echo))
        )
    }
}

// MARK: - Presets

extension DeckLanes {
    static var flatOut: DeckLanes { DeckLanes(volume: .constant(1)) }
    static var flatIn: DeckLanes { DeckLanes(volume: .constant(1)) }
}

extension MixPlan {
    /// Replaces the automation with a preset's shapes, leaving the mix points alone.
    mutating func applyShape(_ shape: MixPreset) {
        var out = DeckLanes(volume: .constant(1))
        var into = DeckLanes(volume: .constant(1))
        switch shape {
        case .fade, .auto, .custom:
            out.volume = MixCurve([(0, 1), (1, 0)])
            into.volume = MixCurve([(0, 0), (1, 1)])
        case .blend:
            // A straight cross-fade (equal-power, so the level stays even) in which only one
            // bass line plays at a time: it changes hands around halfway. The outgoing track
            // also loses some top and middle as it leaves, so two singers never compete.
            out.volume = MixCurve([(0, 1), (1, 0)])
            into.volume = MixCurve([(0, 0), (1, 1)])
            out.bass = MixCurve([(0, 1), (0.35, 1), (0.55, 0.1), (1, 0)])
            into.bass = MixCurve([(0, 0.1), (0.42, 0.15), (0.6, 1), (1, 1)])
            out.mid = MixCurve([(0, 1), (0.4, 1), (0.8, 0.6), (1, 0.5)])
            out.high = MixCurve([(0, 1), (0.5, 1), (1, 0.6)])
        case .rise:
            // The new track builds underneath, thin and filtered, then lands on the bar.
            out.volume = MixCurve([(0, 1), (0.8, 1), (1, 0)])
            out.bass = MixCurve([(0, 1), (0.8, 1), (0.9, 0), (1, 0)])
            into.volume = MixCurve([(0, 0), (0.8, 0.6), (0.92, 1), (1, 1)])
            into.bass = MixCurve([(0, 0), (0.8, 0), (0.9, 1), (1, 1)])
            into.filter = MixCurve([(0, 0.5), (0.8, 0.12), (0.9, 0), (1, 0)])
        case .cut:
            // Switch on the bar line three quarters of the way in; before it only the old
            // track is heard, after it only the new one over a short tail of the old.
            out.volume = MixCurve([(0, 1), (0.74, 1), (0.76, 0), (1, 0)])
            out.echo = MixCurve([(0, 0), (0.6, 0), (0.74, 0.7), (0.9, 0.3), (1, 0)])
            into.volume = MixCurve([(0, 0), (0.74, 0), (0.76, 1), (1, 1)])
        case .echo:
            // The old track is thinned, sent into the echo and cut on the bar line at halfway;
            // the new one starts there at full level while the echo dies away beneath it.
            out.volume = MixCurve([(0, 1), (0.49, 1), (0.51, 0), (1, 0)])
            out.echo = MixCurve([(0, 0), (0.25, 0), (0.48, 0.9), (0.7, 0.5), (1, 0)])
            out.filter = MixCurve([(0, 0), (0.25, 0), (0.5, 0.45), (1, 0.6)])
            out.bass = MixCurve([(0, 1), (0.3, 1), (0.48, 0), (1, 0)])
            into.volume = MixCurve([(0, 0), (0.49, 0), (0.51, 1), (1, 1)])
        case .loop:
            // The repeated bar thins out and falls away while the new track comes up.
            out.volume = MixCurve([(0, 1), (0.4, 0.9), (1, 0)])
            out.filter = MixCurve([(0, 0), (1, 0.7)])
            out.bass = MixCurve([(0, 1), (0.35, 1), (0.5, 0), (1, 0)])
            into.volume = MixCurve([(0, 0), (1, 1)])
            into.bass = MixCurve([(0, 0), (0.4, 0), (0.55, 1), (1, 1)])
        }
        outgoing = out
        incoming = into
    }
}
