import Accelerate
import Foundation

/// `Metrolist --mixaudit groups.csv [--pairs N] [--seed S] [--group name] [--out file.tsv]`
///
/// Plans many pairs from cached analyses (no network) and reports, per style group, what
/// AutoMix would do: how often it beat-matches, falls back to a fade or proposes an unconfirmed
/// sample move, where it leaves and enters, and whether the kicks of the two songs actually
/// line up through a beat-matched plan. The kick check uses each song's own low-band onsets,
/// not the beat grids the plan was built from, so it can catch a grid that sits on the snare.
///
/// Pairs are drawn within each group with a fixed seed, plus mixed pairs across groups, so a
/// baseline run and a later run plan exactly the same pairs. `--approved` plans the owner's
/// approved reference pairs instead. Group labels only label the report; the planner never
/// sees them.
enum MixAudit {
    struct Row {
        var group: String
        var a: String
        var b: String
        var plan: MixPlan?
        var durationA: Double
        var kick: KickCheck?
        var exitInLine: Bool?
        /// The owner's own transition for the pair, when known: (out, in, synced).
        var gold: (out: Double, in: Double, sync: Bool)?
        /// Whether the first proposal / any proposal lands within two bars of the owner's.
        var goldFirst: Bool?
        var goldAny: Bool?
    }

    struct KickCheck {
        /// Lag (in beats of A) at which B's kicks best match A's, searched over ±2 beats.
        var bestLag: Double
        /// Correlation at the planned alignment relative to the best one (1 = planned is best).
        var ratio: Double
        var aligned: Bool { ratio >= 0.9 || abs(bestLag) <= 0.125 }
    }

    static let approvedPairs: [(String, String)] = [
        ("y32ejtuxSjM", "GTmbyuTKT_c"), ("dBLzh47wdrU", "V4HdD2Fu_64"), ("JhulBGMA7G4", "2ulp_AMut14"),
        ("WTgNu7XHrrU", "G8u3P7Xqlvo"), ("_cUM4SlY2_o", "fa5IWHDbftI"), ("-lyBxb7nagk", "Lu-edhQJBWI"),
        ("JiNxvNtlBPM", "Osvg7Ofd5d0"), ("JiNxvNtlBPM", "tEXYfT_G0W0"), ("2VPAdf9dkmQ", "4xtwjLqdaj0"),
        ("WYhv-hR6Q2U", "l4L78W66kCI"),
    ]

    /// Small deterministic generator, so runs pick the same pairs.
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func readGroups(_ path: String) -> [(id: String, group: String)] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let fields = trimmed.split(separator: ",", maxSplits: 2).map { String($0).trimmingCharacters(in: .whitespaces) }
            return fields.count >= 2 ? (fields[0], fields[1]) : nil
        }
    }

    @MainActor
    static func run() async {
        let arguments = Array(CommandLine.arguments.drop { $0 != "--mixaudit" }.dropFirst())
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let path = arguments.first { !$0.hasPrefix("--") && $0.hasSuffix(".csv") } ?? "Tools/groundtruth/groups.csv"
        let perGroup = Int(option("--pairs") ?? "") ?? 20
        var generator = Generator(state: UInt64(option("--seed") ?? "") ?? 2026)
        let only = option("--group")
        // Planner settings under test (defaults are the app's).
        if let value = option("--standout").flatMap(Double.init) { MixPlanner.unlinkedStretchStandout = value }
        if let value = option("--latest-entry").flatMap(Double.init) { MixPlanner.unlinkedStretchLatestEntry = value }
        if arguments.contains("--no-record-guess") { MixPlanner.unlinkedRecordGuess = false }
        if arguments.contains("--no-gate") { MixPlanner.sampleGateEnabled = false }
        if let value = option("--ramp").flatMap(Double.init) { MixPlanner.rampMaxStretch = value }
        if let value = option("--tempo-cap").flatMap(Double.init) { MixPlanner.tempoMatchMaxStretch = value }
        let media = MediaStore()
        let library = LibraryStore()

        var analyses: [String: TrackAnalysis] = [:]
        func analysis(_ id: String) async -> TrackAnalysis? {
            if let known = analyses[id] { return known }
            if let cached = await TrackAnalyzer.shared.cached(id) {
                analyses[id] = cached
                return cached
            }
            guard let record = media.records[id] else { return nil }
            let file = AppPaths.media.appendingPathComponent(record.fileName)
            let result = await TrackAnalyzer.shared.analysis(videoId: id, file: file)
            analyses[id] = result
            return result
        }

        // Which pairs to plan.
        var pairs: [(group: String, a: String, b: String)] = []
        var golds: [String: (out: Double, in: Double, sync: Bool)] = [:]
        if arguments.contains("--approved") {
            pairs = approvedPairs.map { ("approved", $0.0, $0.1) }
        } else if let file = option("--pairs-file") {
            // Lines: group, idA, idB[, ownerOut, ownerIn, ownerSync] (tab-separated).
            let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let fields = line.split(separator: "\t").map(String.init)
                guard fields.count >= 3 else { continue }
                pairs.append((fields[0], fields[1], fields[2]))
                if fields.count >= 6, let out = Double(fields[3]), let entry = Double(fields[4]) {
                    golds["\(fields[1])|\(fields[2])"] = (out, entry, fields[5] == "1")
                }
            }
        } else {
            let listed = readGroups(path)
            guard !listed.isEmpty else { print("no songs in \(path)"); return }
            var available: [String: [String]] = [:]
            for (id, group) in listed where only == nil || group == only {
                if await analysis(id) != nil { available[group, default: []].append(id) }
            }
            for group in available.keys.sorted() {
                let ids = available[group]!
                print("\(group): \(ids.count) analysed songs of \(listed.filter { $0.group == group }.count) listed")
                guard ids.count >= 2 else { continue }
                var seen = Set<String>()
                var attempts = 0
                while seen.count < min(perGroup, ids.count * (ids.count - 1)), attempts < perGroup * 20 {
                    attempts += 1
                    let a = ids.randomElement(using: &generator)!
                    let b = ids.randomElement(using: &generator)!
                    guard a != b, seen.insert("\(a)|\(b)").inserted else { continue }
                    pairs.append((group, a, b))
                }
            }
            // Mixed pairs: any group into any other, as a playlist of mixed styles would be.
            if only == nil {
                let all = available.values.flatMap { $0 }.sorted()
                var seen = Set<String>()
                var attempts = 0
                while seen.count < perGroup, attempts < perGroup * 20, all.count > 2 {
                    attempts += 1
                    let a = all.randomElement(using: &generator)!
                    let b = all.randomElement(using: &generator)!
                    let groupA = listed.first { $0.id == a }?.group
                    let groupB = listed.first { $0.id == b }?.group
                    guard a != b, groupA != groupB, seen.insert("\(a)|\(b)").inserted else { continue }
                    pairs.append(("mixed", a, b))
                }
            }
        }

        // Plan them, as the player would: cached lyrics and cached sample links only.
        var envelopes: [String: (values: [Float], fps: Double)] = [:]
        func kickEnvelope(_ id: String) -> (values: [Float], fps: Double)? {
            if let known = envelopes[id] { return known }
            guard let record = media.records[id],
                  let (samples, rate) = TrackAnalyzer.decodeMono(file: AppPaths.media.appendingPathComponent(record.fileName))
            else { return nil }
            let result = lowBandOnsets(samples, rate: rate)
            envelopes[id] = result
            return result
        }

        var rows: [Row] = []
        let started = Date()
        // `--features FILE`: what the similarity search measured for each pair (sample gate training).
        let featuresPath = option("--features")
        MixPlanner.collectEvidence = featuresPath != nil
        var featureLines = ["group\ta\tb\tbpmA\tbpmB\tratio\tconfA\tconfB\treason\tsync\tplanStretch\t" + SampleEvidence.header]
        for pair in pairs {
            guard let a = await analysis(pair.a), let b = await analysis(pair.b) else { continue }
            let lyricsA = await LyricsService.shared.cached(pair.a)
            let lyricsB = await LyricsService.shared.cached(pair.b)
            var options = MixOptions()
            options.stems = arguments.contains("--stems")
            if let songA = library.song(pair.a), let songB = library.song(pair.b) {
                options.relation = await SampleDatabase.shared.relation(current: songA, next: songB, cachedOnly: !arguments.contains("--lookup"))
            }
            MixPlanner.lastEvidence = nil
            let candidates = MixPlanner.candidates(from: a, to: b, lyricsA: lyricsA, lyricsB: lyricsB, options: options)
            let plan = candidates.first
            if featuresPath != nil {
                // Tempo ratio with half and double time folded away (1 = same tempo).
                let ratio = 60 / b.bpm * MixPlanner.fold(60 / a.bpm, 60 / b.bpm) / (60 / a.bpm)
                let reason = plan.map { $0.known != nil ? "knownSample" : $0.reason.rawValue } ?? "none"
                let stretch = plan.map { $0.sync ? $0.periodA / $0.periodB : 1 } ?? 1
                featureLines.append([pair.group, pair.a, pair.b, String(format: "%.2f", a.bpm), String(format: "%.2f", b.bpm), String(format: "%.4f", ratio),
                                     String(format: "%.2f", a.beatConfidence), String(format: "%.2f", b.beatConfidence), reason, plan?.sync == true ? "1" : "0",
                                     String(format: "%.4f", stretch), (MixPlanner.lastEvidence ?? SampleEvidence()).line].joined(separator: "\t"))
                // `--augment rate:semitones,...`: the same pair with the next song replayed faster or
                // slower, which turns a same-speed sample into one at another speed.
                for spec in (option("--augment") ?? "").split(separator: ",") {
                    let parts = spec.split(separator: ":")
                    guard parts.count == 2, let rate = Double(parts[0]), let semitones = Int(parts[1]) else { continue }
                    let moved = respeed(b, rate: rate, semitones: semitones)
                    MixPlanner.lastEvidence = nil
                    let augmented = MixPlanner.candidates(from: a, to: moved, lyricsA: lyricsA, lyricsB: nil, options: options).first
                    let movedRatio = 60 / moved.bpm * MixPlanner.fold(60 / a.bpm, 60 / moved.bpm) / (60 / a.bpm)
                    featureLines.append(["\(pair.group)~\(spec)", pair.a, pair.b, String(format: "%.2f", a.bpm), String(format: "%.2f", moved.bpm), String(format: "%.4f", movedRatio),
                                         String(format: "%.2f", a.beatConfidence), String(format: "%.2f", moved.beatConfidence),
                                         augmented.map { $0.known != nil ? "knownSample" : $0.reason.rawValue } ?? "none", augmented?.sync == true ? "1" : "0",
                                         String(format: "%.4f", augmented.map { $0.sync ? $0.periodA / $0.periodB : 1 } ?? 1),
                                         (MixPlanner.lastEvidence ?? SampleEvidence()).line].joined(separator: "\t"))
                }
            }
            var row = Row(group: pair.group, a: pair.a, b: pair.b, plan: plan, durationA: a.duration)
            if let gold = golds["\(pair.a)|\(pair.b)"] {
                row.gold = gold
                func near(_ candidate: MixPlan) -> Bool {
                    abs(candidate.outStart - gold.out) <= 8 * 60 / a.bpm + 0.5 && abs(candidate.inPoint - gold.in) <= 8 * 60 / b.bpm + 0.5
                }
                row.goldFirst = plan.map(near) ?? false
                row.goldAny = candidates.contains(where: near)
            }
            if let plan, plan.sync, plan.beats >= 4, let envA = kickEnvelope(pair.a), let envB = kickEnvelope(pair.b) {
                row.kick = kickCheck(plan, envA, envB)
            }
            if let plan, let lyricsA, lyricsA.isSynced {
                row.exitInLine = exitsInsideLine(plan, lyricsA)
            }
            rows.append(row)
        }

        // Per-pair lines.
        var lines = ["group\ta\tb\treason\tsync\tbeats\tout\tleftOfA\tin\tstretch\tapproach\tkick\tkickLag\texitInLine\tsummary\tnote\towner"]
        for row in rows {
            guard let plan = row.plan else {
                lines.append("\(row.group)\t\(row.a)\t\(row.b)\tnone\t\t\t\t\t\t\t\t\t\t\t")
                continue
            }
            let stretch = plan.sync ? plan.periodA / plan.periodB : 1
            lines.append([
                row.group, row.a, row.b, plan.known != nil ? "knownSample" : plan.reason.rawValue, plan.sync ? "1" : "0", "\(plan.beats)",
                String(format: "%.2f", plan.outStart), String(format: "%.1f", row.durationA - plan.outStart), String(format: "%.2f", plan.inPoint),
                String(format: "%.3f", stretch), String(format: "%.1f", plan.approach ?? 0),
                row.kick.map { $0.aligned ? "ok" : "OFF" } ?? "", row.kick.map { String(format: "%+.2f@%.2f", $0.bestLag, $0.ratio) } ?? "",
                row.exitInLine.map { $0 ? "yes" : "no" } ?? "", plan.summary, plan.note,
                row.gold.map { String(format: "owner %.1f→%.1f first=%@ any=%@", $0.out, $0.in, row.goldFirst == true ? "yes" : "no", row.goldAny == true ? "yes" : "no") } ?? "",
            ].joined(separator: "\t"))
        }
        if let featuresPath {
            try? (featureLines.joined(separator: "\n") + "\n").write(toFile: featuresPath, atomically: true, encoding: .utf8)
            print("wrote features of \(featureLines.count - 1) pairs to \(featuresPath)")
        }
        if let out = option("--out") {
            try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
            print("wrote \(rows.count) pairs to \(out)")
        } else if arguments.contains("--verbose") {
            for line in lines { print(line) }
        }

        // Summary per group.
        print("")
        print("group        pairs  sync  fade  unlinkedSample  enterB>30s  stretch>12%  kickOff/checked  exitInLine/checked  medianIn  medianLeft")
        for group in Array(Set(rows.map(\.group))).sorted() + ["ALL"] {
            let set = group == "ALL" ? rows : rows.filter { $0.group == group }
            let plans = set.compactMap(\.plan)
            guard !set.isEmpty else { continue }
            func share(_ count: Int) -> String { String(format: "%3.0f%%", 100 * Double(count) / Double(max(1, set.count))) }
            let sync = plans.filter(\.sync).count
            let fade = plans.filter { $0.reason == .ending }.count + (set.count - plans.count)
            let unlinked = plans.filter { $0.reason == .sample && $0.known == nil }.count
            let late = plans.filter { $0.inPoint > 30 }.count
            let stretched = plans.filter { $0.sync && abs($0.periodA / $0.periodB - 1) > 0.12 }.count
            let checked = set.compactMap(\.kick)
            let off = checked.filter { !$0.aligned }.count
            let exits = set.compactMap(\.exitInLine)
            let entries = plans.map(\.inPoint).sorted()
            let lefts = zip(set, set.map(\.plan)).compactMap { row, plan in plan.map { row.durationA - $0.outStart } }.sorted()
            print(String(format: "%-12@ %5d  %@  %@  %14@  %10@  %11@  %8d/%-6d  %10d/%-7d  %7.1fs  %9.1fs",
                         group as NSString, set.count, share(sync), share(fade), share(unlinked) as NSString, share(late) as NSString, share(stretched) as NSString,
                         off, checked.count, exits.filter { $0 }.count, exits.count,
                         entries.isEmpty ? 0 : entries[entries.count / 2], lefts.isEmpty ? 0 : lefts[lefts.count / 2]))
        }
        if arguments.contains("--stems") {
            let plans = rows.compactMap(\.plan)
            let stemmed = plans.filter { $0.outgoingStems != nil }
            let vocals = stemmed.filter { !($0.outgoingStems?.vocals.isConstant ?? true) }.count
            let drums = stemmed.filter { !($0.outgoingStems?.drums.isConstant ?? true) }.count
            print(String(format: "stems: %d of %d plans use them (vocals step aside in %d, drums hand over in %d)", stemmed.count, plans.count, vocals, drums))
        }
        let judged = rows.filter { $0.gold != nil }
        if !judged.isEmpty {
            print("")
            print("Owner's own transitions (within 2 bars at both ends):")
            for group in Array(Set(judged.map(\.group))).sorted() + ["ALL"] {
                let set = group == "ALL" ? judged : judged.filter { $0.group == group }
                print(String(format: "  %-28@ %3d pairs  first proposal %3d  any proposal %3d  synced like the owner's %3d", group as NSString, set.count,
                             set.filter { $0.goldFirst == true }.count, set.filter { $0.goldAny == true }.count,
                             set.filter { $0.plan?.sync == $0.gold?.sync }.count))
            }
        }
        print(String(format: "planned %d pairs in %.1f s", rows.count, Date().timeIntervalSince(started)))
    }

    // MARK: - Augmentation for training the sample gate

    /// The same track played `rate` times as fast and `semitones` higher, as a producer replays a
    /// sample: with the pitch moved along with the speed (a record) or kept (time-stretched).
    /// Almost everything in an analysis is per beat, so only times, tempo and harmony change.
    static func respeed(_ track: TrackAnalysis, rate: Double, semitones: Int) -> TrackAnalysis {
        var result = track
        result.beats = track.beats.map { $0 / rate }
        result.bpm = track.bpm * rate
        result.duration = track.duration / rate
        result.audibleStart = track.audibleStart / rate
        result.audibleEnd = track.audibleEnd / rate
        result.introEnd = track.introEnd / rate
        result.outroStart = track.outroStart / rate
        // Loudness is kept in half-second steps: resample it onto the new time line.
        let steps = Int(Double(track.energy.count) / rate)
        result.energy = (0 ..< steps).map { track.energy[min(track.energy.count - 1, Int(Double($0) * rate))] }
        result.waveRate = track.waveRate * rate
        let shift = ((semitones % 12) + 12) % 12
        result.key = (track.key + shift) % 12
        let chroma = track.beatChroma.values
        var moved = [Float](repeating: 0, count: chroma.count)
        for row in 0 ..< chroma.count / 12 {
            for pitch in 0 ..< 12 { moved[row * 12 + (pitch + shift) % 12] = chroma[row * 12 + pitch] }
        }
        result.beatChroma = FloatMatrix(rows: track.beatChroma.rows, columns: 12, values: moved)
        return result
    }

    // MARK: - Measurements independent of the beat grids

    /// Onset strength below about 150 Hz (where kick drums and bass attacks live), at about 47
    /// frames a second.
    static func lowBandOnsets(_ samples: [Float], rate: Double) -> (values: [Float], fps: Double) {
        let size = 1_024
        let hop = 256
        let fft = RealFFT(size: size)
        let count = max(0, (samples.count - size) / hop)
        let top = max(2, Int(150 / (rate / Double(size))))
        var previous = [Float](repeating: 0, count: size / 2)
        var current = [Float](repeating: 0, count: size / 2)
        var values = [Float](repeating: 0, count: count)
        for frame in 0 ..< count {
            fft.logMagnitudes(samples, at: frame * hop, into: &current)
            var rise: Float = 0
            for bin in 1 ... top where current[bin] > previous[bin] { rise += current[bin] - previous[bin] }
            values[frame] = rise
            swap(&previous, &current)
        }
        return (values, rate / Double(hop))
    }

    /// Correlates A's kicks with B's kicks mapped through the plan over the overlap, at lags of
    /// up to two beats either way. Well-aligned grids give the best match at no lag.
    static func kickCheck(_ plan: MixPlan, _ a: (values: [Float], fps: Double), _ b: (values: [Float], fps: Double)) -> KickCheck? {
        let seconds = Double(plan.beats) * plan.periodA
        let step = plan.periodA / 16
        let samples = Int(seconds / step)
        guard samples > 32 else { return nil }
        func value(_ envelope: (values: [Float], fps: Double), at time: Double) -> Float {
            let index = Int((time * envelope.fps).rounded())
            guard index >= 0, index < envelope.values.count else { return 0 }
            // A little reach, so an attack between two frames isn't missed.
            return max(envelope.values[index], index + 1 < envelope.values.count ? envelope.values[index + 1] : 0)
        }
        let seriesA = (0 ..< samples).map { value(a, at: plan.outStart + Double($0) * step) }
        let scale = plan.periodB / plan.periodA
        func correlation(lagBeats: Double) -> Double {
            var sum = 0.0
            for index in 0 ..< samples {
                let timeA = Double(index) * step + lagBeats * plan.periodA
                sum += Double(seriesA[index]) * Double(value(b, at: plan.inPoint + timeA * scale))
            }
            return sum
        }
        // Up to one beat either way: half a beat is a grid on the off-beat, one beat is kick
        // against snare. Whole-bar offsets don't make kicks clash, so they are not searched.
        var best = (lag: 0.0, value: -Double.infinity)
        for step in -16 ... 16 {
            let lag = Double(step) / 16
            let result = correlation(lagBeats: lag)
            if result > best.value { best = (lag, result) }
        }
        let planned = correlation(lagBeats: 0)
        guard best.value > 0 else { return nil }
        return KickCheck(bestLag: best.lag, ratio: planned / best.value)
    }

    /// Whether the outgoing song drops below half volume in the middle of a sung line.
    static func exitsInsideLine(_ plan: MixPlan, _ lyrics: Lyrics) -> Bool {
        let length = plan.sync ? Double(plan.beats) * plan.periodA : plan.span(glide: true).outgoing
        var fraction = 1.0
        for step in 0 ... 100 where plan.outgoing.volume.value(at: Double(step) / 100) < 0.5 {
            fraction = Double(step) / 100
            break
        }
        let time = plan.outStart + fraction * length
        let lines = lyrics.lines.filter { !$0.isBackground && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        for (index, line) in lines.enumerated() {
            let start = line.start + lyrics.offset
            let next = index + 1 < lines.count ? lines[index + 1].start + lyrics.offset : start + 5
            let end = min(line.end.map { $0 + lyrics.offset } ?? next, start + 8)
            if time > start + 0.3, time < end - 0.3 { return true }
        }
        return false
    }
}
