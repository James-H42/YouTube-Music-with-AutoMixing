import Foundation

/// Measurement of AutoMix's beat analysis against reference labels.
///
/// - `--dumppcm dir [groups.csv]` writes each cached song as 22.05 kHz mono WAV (decoded by the
///   app itself), for the Python tools in `Tools/ml`.
/// - `--analysisaudit truthDir [groups.csv] [--verbose]` scores the cached analysis of every
///   song with a reference file `truthDir/<videoId>.json` and prints the results per style
///   group: tempo octave, beat and downbeat F-measure (±70 ms) and meter.
///
/// A reference file holds `{"beats": [s…], "downbeats": [s…], "bpm": n, "meter": n, "source": "…"}`.
/// Labels made by a model are a development reference ("silver"), not ground truth; files whose
/// `source` starts with "owner" were checked by ear.
enum AnalysisAudit {
    struct Truth: Decodable {
        var beats: [Double]
        var downbeats: [Double]
        var bpm: Double
        var meter: Int?
        var source: String?
    }

    struct Score {
        var beatF: Double
        var downbeatF: Double
        /// "right", "half", "double", "third" (3:2 or 2:3) or "other".
        var octave: String
        var meterRight: Bool?
    }

    /// F-measure of detected event times against reference times, matching each reference to
    /// at most one detection within `tolerance` (as mir_eval does).
    static func fMeasure(_ detected: [Double], _ reference: [Double], tolerance: Double = 0.07) -> Double {
        guard !detected.isEmpty, !reference.isEmpty else { return detected.isEmpty && reference.isEmpty ? 1 : 0 }
        let found = detected.sorted()
        let truth = reference.sorted()
        var matched = 0
        var index = 0
        for time in truth {
            while index < found.count, found[index] < time - tolerance { index += 1 }
            if index < found.count, abs(found[index] - time) <= tolerance {
                matched += 1
                index += 1
            }
        }
        let precision = Double(matched) / Double(found.count)
        let recall = Double(matched) / Double(truth.count)
        return precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
    }

    static func octave(_ detected: Double, _ reference: Double) -> String {
        let ratio = detected / reference
        if abs(ratio - 1) <= 0.04 { return "right" }
        if abs(ratio - 0.5) <= 0.02 { return "half" }
        if abs(ratio - 2) <= 0.08 { return "double" }
        if abs(ratio - 1.5) <= 0.06 || abs(ratio - 2.0 / 3) <= 0.03 { return "third" }
        return "other"
    }

    /// Scores an analysis against a reference, over the part of the song both cover.
    static func score(_ analysis: TrackAnalysis, _ truth: Truth) -> Score {
        let start = max(analysis.audibleStart, truth.beats.first ?? 0) - 0.5
        let end = min(analysis.audibleEnd, truth.beats.last ?? analysis.duration) + 0.5
        let inside: ([Double]) -> [Double] = { $0.filter { $0 >= start && $0 <= end } }
        let beatF = fMeasure(inside(analysis.beats), inside(truth.beats))
        let downbeatF = fMeasure(inside(analysis.downbeats), inside(truth.downbeats))
        let meterRight = truth.meter.map { $0 == 4 }
        return Score(beatF: beatF, downbeatF: downbeatF, octave: octave(analysis.bpm, truth.bpm), meterRight: meterRight)
    }

    @MainActor
    static func dumpPCM() async {
        let arguments = Array(CommandLine.arguments.drop { $0 != "--dumppcm" }.dropFirst())
        guard let directory = arguments.first else { print("usage: --dumppcm dir [groups.csv]"); return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let media = MediaStore()
        var ids = arguments.dropFirst().first.map { MixAudit.readGroups($0).map(\.id) } ?? Array(media.records.keys)
        ids = ids.filter { media.records[$0] != nil }
        var written = 0
        for id in ids {
            let target = folder.appendingPathComponent("\(id).wav")
            if FileManager.default.fileExists(atPath: target.path) { continue }
            guard let record = media.records[id],
                  let samples = AudioDecode.mono(file: AppPaths.media.appendingPathComponent(record.fileName), rate: 22_050)
            else { print("\(id): could not decode"); continue }
            do {
                try AudioDecode.writeWAV(samples, rate: 22_050, to: target)
                written += 1
            } catch { print("\(id): \(error.localizedDescription)") }
        }
        print("wrote \(written) files to \(folder.path) (\(ids.count) songs with audio)")
    }

    /// `--beatmodeltest referenceDir [id…]`: runs the Core ML beat model on each song (the app's
    /// own decoding and front-end) and compares its beats and bar lines with reference files
    /// written by the same model in Python (`silver.py --checkpoint small0`). PASS needs beat
    /// and bar-line F-measure of at least 0.99.
    @MainActor
    static func beatModelTest() async {
        let arguments = Array(CommandLine.arguments.drop { $0 != "--beatmodeltest" }.dropFirst())
        guard let directory = arguments.first else { print("usage: --beatmodeltest referenceDir [id…]"); return }
        guard let model = BeatModel.shared else { print("FAIL: beat model not found (looked in \(BeatModel.modelFolder()?.path ?? "no Models folder"))"); return }
        print("model \(model.identity) from \(BeatModel.modelFolder()?.path ?? "?")")
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        var ids = Array(arguments.dropFirst())
        if ids.isEmpty {
            ids = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        }
        let media = MediaStore()
        var failures = 0
        for id in ids {
            guard let record = media.records[id],
                  let data = try? Data(contentsOf: folder.appendingPathComponent("\(id).json")),
                  let truth = try? JSONDecoder().decode(Truth.self, from: data)
            else { print("\(id): no audio or reference"); continue }
            let started = Date()
            guard let samples = AudioDecode.mono(file: AppPaths.media.appendingPathComponent(record.fileName), rate: BeatModel.rate) else { continue }
            let decoded = Date()
            guard let result = model.grid(samples: samples) else { print("FAIL \(id): no grid"); failures += 1; continue }
            let beatF = fMeasure(result.grid.beats, truth.beats, tolerance: 0.025)
            let downbeatF = fMeasure(result.grid.downbeats, truth.downbeats, tolerance: 0.025)
            let pass = beatF >= 0.99 && downbeatF >= 0.99
            if !pass { failures += 1 }
            print(String(format: "%@ %@: %d beats, %d bar lines, beat F %.3f, bar F %.3f (±25 ms), confidence %.2f; decode %.2f s, model %.2f s for %.0f s of audio",
                         pass ? "PASS" : "FAIL", id, result.grid.beats.count, result.grid.downbeats.count, beatF, downbeatF, result.confidence,
                         decoded.timeIntervalSince(started), Date().timeIntervalSince(decoded), Double(samples.count) / BeatModel.rate))
        }
        print(failures == 0 ? "PASS: all songs match" : "FAIL: \(failures) songs differ")
    }

    @MainActor
    static func run() async {
        let arguments = Array(CommandLine.arguments.drop { $0 != "--analysisaudit" }.dropFirst())
        guard let directory = arguments.first(where: { !$0.hasPrefix("--") }) else { print("usage: --analysisaudit truthDir [groups.csv]"); return }
        let groupsPath = arguments.dropFirst().first { $0.hasSuffix(".csv") } ?? "Tools/groundtruth/groups.csv"
        let groups = Dictionary(MixAudit.readGroups(groupsPath).map { ($0.id, $0.group) }, uniquingKeysWith: { first, _ in first })
        let verbose = arguments.contains("--verbose")
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let media = MediaStore()
        let library = LibraryStore()
        var results: [(id: String, group: String, score: Score, bpm: Double, truthBPM: Double)] = []
        for file in files {
            let id = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file), let truth = try? JSONDecoder().decode(Truth.self, from: data), truth.beats.count > 16 else { continue }
            var analysis = await TrackAnalyzer.shared.cached(id)
            if analysis == nil, let record = media.records[id] {
                analysis = await TrackAnalyzer.shared.analysis(videoId: id, file: AppPaths.media.appendingPathComponent(record.fileName))
            }
            guard let analysis else { continue }
            let score = score(analysis, truth)
            let group = groups[id] ?? "ungrouped"
            results.append((id, group, score, analysis.bpm, truth.bpm))
            if verbose {
                let title = library.song(id)?.title ?? id
                print(String(format: "%-10@ %@ %-40@ %6.1f vs %6.1f BPM %-6@ beat F %.2f downbeat F %.2f", group as NSString, id, String(title.prefix(40)) as NSString,
                             analysis.bpm, truth.bpm, score.octave as NSString, score.beatF, score.downbeatF))
            }
        }
        print("")
        print("group        songs  tempo right  half  double  other   beat F  downbeat F  meter right")
        for group in Array(Set(results.map(\.group))).sorted() + ["ALL"] {
            let set = group == "ALL" ? results : results.filter { $0.group == group }
            guard !set.isEmpty else { continue }
            func count(_ kind: String) -> Int { set.filter { $0.score.octave == kind }.count }
            let meters = set.compactMap(\.score.meterRight)
            print(String(format: "%-12@ %5d  %10.0f%%  %4d  %6d  %5d   %6.3f  %10.3f  %@", group as NSString, set.count,
                         100 * Double(count("right")) / Double(set.count), count("half"), count("double"), count("other") + count("third"),
                         set.map(\.score.beatF).reduce(0, +) / Double(set.count), set.map(\.score.downbeatF).reduce(0, +) / Double(set.count),
                         meters.isEmpty ? "-" : String(format: "%d/%d", meters.filter { $0 }.count, meters.count)))
        }
    }
}
