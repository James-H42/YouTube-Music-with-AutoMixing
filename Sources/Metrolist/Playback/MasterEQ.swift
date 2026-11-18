import AVFoundation
import AudioToolbox
import Foundation
import Observation

// MARK: - Profiles

/// One filter of the equaliser.
struct EQBand: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case peak, lowShelf, highShelf, lowPass, highPass
        var id: String { rawValue }
        var title: String {
            switch self {
            case .peak: "Peak"
            case .lowShelf: "Low shelf"
            case .highShelf: "High shelf"
            case .lowPass: "Low pass"
            case .highPass: "High pass"
            }
        }
        /// Whether the gain control means anything for this filter.
        var hasGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }
    }

    var id = UUID()
    var kind: Kind = .peak
    var frequency: Double
    var gain: Double = 0
    var q: Double = 1
    var enabled = true

    static let frequencyRange = 20.0 ... 20_000.0
    static let gainRange = -15.0 ... 15.0
    static let qRange = 0.1 ... 10.0

    /// Filters that do nothing to the sound, so a profile made only of them is flat.
    var isNeutral: Bool { !enabled || (kind.hasGain && abs(gain) < 0.001) }
}

struct EQProfile: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var name: String
    /// Gain applied before the filters, in dB. AutoEQ profiles use it to leave headroom.
    var preamp: Double = 0
    var bands: [EQBand] = []

    static let maxBands = 10
    static let preampRange = -24.0 ... 12.0

    var isFlat: Bool { abs(preamp) < 0.001 && bands.allSatisfy(\.isNeutral) }
    /// Whether this profile can raise the level somewhere, which is when a limiter is needed.
    var addsGain: Bool { preamp > 0.001 || bands.contains { $0.enabled && $0.kind.hasGain && $0.gain > 0.001 } }

    static let flat = EQProfile(id: "flat", name: "Flat")

    static let presets: [EQProfile] = [
        flat,
        EQProfile(id: "bass", name: "Bass Boost", preamp: -4, bands: [
            EQBand(kind: .lowShelf, frequency: 90, gain: 5, q: 0.7),
            EQBand(kind: .peak, frequency: 250, gain: -1.5, q: 0.9),
        ]),
        EQProfile(id: "treble", name: "Treble Boost", preamp: -3, bands: [
            EQBand(kind: .highShelf, frequency: 7_000, gain: 4, q: 0.7),
        ]),
        EQProfile(id: "vocal", name: "Vocal", preamp: -3, bands: [
            EQBand(kind: .lowShelf, frequency: 120, gain: -3, q: 0.7),
            EQBand(kind: .peak, frequency: 3_000, gain: 3, q: 1.0),
            EQBand(kind: .highShelf, frequency: 9_000, gain: 1.5, q: 0.7),
        ]),
        EQProfile(id: "loudness", name: "Loudness", preamp: -4, bands: [
            EQBand(kind: .lowShelf, frequency: 100, gain: 4, q: 0.7),
            EQBand(kind: .peak, frequency: 1_000, gain: -1.5, q: 0.8),
            EQBand(kind: .highShelf, frequency: 8_000, gain: 3, q: 0.7),
        ]),
    ]
}

// MARK: - AutoEQ

/// Reads the `ParametricEQ.txt` files of the AutoEq project:
///
///     Preamp: -6.2 dB
///     Filter 1: ON PK Fc 31 Hz Gain 3.7 dB Q 1.10
enum AutoEQ {
    struct Result {
        var profile: EQProfile
        /// Filters in the file this equaliser can't represent or that were beyond the band limit.
        var skipped: Int
    }

    static let maxBytes = 64 * 1024

    static func parse(_ text: String, name: String) -> Result? {
        guard text.utf8.count <= maxBytes else { return nil }
        var profile = EQProfile(name: name)
        var skipped = 0
        var sawSomething = false
        for rawLine in text.split(whereSeparator: \.isNewline).prefix(200) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if line.lowercased().hasPrefix("preamp"), let dB = number(after: "Preamp:", in: words) ?? words.dropFirst().compactMap({ Double($0) }).first {
                profile.preamp = min(max(dB, EQProfile.preampRange.lowerBound), EQProfile.preampRange.upperBound)
                sawSomething = true
                continue
            }
            guard line.lowercased().hasPrefix("filter"), let state = words.firstIndex(where: { $0 == "ON" || $0 == "OFF" }),
                  state + 1 < words.count else { continue }
            sawSomething = true
            if words[state] == "OFF" { continue }
            let kind: EQBand.Kind?
            switch words[state + 1].uppercased() {
            case "PK", "PEQ": kind = .peak
            case "LSC", "LS", "LSQ": kind = .lowShelf
            case "HSC", "HS", "HSQ": kind = .highShelf
            case "LP", "LPQ": kind = .lowPass
            case "HP", "HPQ": kind = .highPass
            default: kind = nil
            }
            guard let kind, let frequency = number(after: "Fc", in: words) else { skipped += 1; continue }
            guard profile.bands.count < EQProfile.maxBands else { skipped += 1; continue }
            var band = EQBand(kind: kind, frequency: min(max(frequency, EQBand.frequencyRange.lowerBound), EQBand.frequencyRange.upperBound))
            band.gain = min(max(number(after: "Gain", in: words) ?? 0, EQBand.gainRange.lowerBound), EQBand.gainRange.upperBound)
            band.q = min(max(number(after: "Q", in: words) ?? 0.7, EQBand.qRange.lowerBound), EQBand.qRange.upperBound)
            profile.bands.append(band)
        }
        return sawSomething ? Result(profile: profile, skipped: skipped) : nil
    }

    private static func number(after key: String, in words: [String]) -> Double? {
        guard let index = words.firstIndex(of: key), index + 1 < words.count else { return nil }
        return Double(words[index + 1])
    }

    /// Fetches a profile from the AutoEq repository (or a copy of one of its result files). Only
    /// raw.githubusercontent.com is allowed, over HTTPS, and only a small file is read.
    static func download(_ address: String) async throws -> Result {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host == "raw.githubusercontent.com"
        else { throw EQError.badAddress }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let (data, response) = try await URLSession(configuration: configuration).data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EQError.notFound }
        guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else { throw EQError.notAProfile }
        let stem = url.deletingPathExtension().lastPathComponent
        let name = stem.replacingOccurrences(of: " ParametricEQ", with: "")
        guard let result = parse(text, name: name.isEmpty ? "AutoEQ" : name) else { throw EQError.notAProfile }
        return result
    }

    enum EQError: LocalizedError {
        case badAddress, notFound, notAProfile
        var errorDescription: String? {
            switch self {
            case .badAddress: "Use a https://raw.githubusercontent.com/… address of a ParametricEQ.txt file."
            case .notFound: "That file couldn't be downloaded."
            case .notAProfile: "That isn't an AutoEQ ParametricEQ.txt profile."
            }
        }
    }
}

// MARK: - Response curve

enum EQMath {
    /// Magnitude of one filter in dB at `frequency`, from the standard biquad formulas.
    static func response(_ band: EQBand, at frequency: Double, sampleRate: Double = 48_000) -> Double {
        guard band.enabled else { return 0 }
        let w0 = 2 * Double.pi * min(band.frequency, sampleRate / 2 - 1) / sampleRate
        let cosw = cos(w0), alpha = sin(w0) / (2 * band.q)
        let a = pow(10, band.gain / 40)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch band.kind {
        case .peak:
            b0 = 1 + alpha * a; b1 = -2 * cosw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosw; a2 = 1 - alpha / a
        case .lowShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosw + s); b1 = 2 * a * ((a - 1) - (a + 1) * cosw); b2 = a * ((a + 1) - (a - 1) * cosw - s)
            a0 = (a + 1) + (a - 1) * cosw + s; a1 = -2 * ((a - 1) + (a + 1) * cosw); a2 = (a + 1) + (a - 1) * cosw - s
        case .highShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosw + s); b1 = -2 * a * ((a - 1) + (a + 1) * cosw); b2 = a * ((a + 1) + (a - 1) * cosw - s)
            a0 = (a + 1) - (a - 1) * cosw + s; a1 = 2 * ((a - 1) - (a + 1) * cosw); a2 = (a + 1) - (a - 1) * cosw - s
        case .lowPass:
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = (1 - cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = (1 + cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        }
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let numerator = (b0 + b1 * c1 + b2 * c2) * (b0 + b1 * c1 + b2 * c2) + (b1 * s1 + b2 * s2) * (b1 * s1 + b2 * s2)
        let denominator = (a0 + a1 * c1 + a2 * c2) * (a0 + a1 * c1 + a2 * c2) + (a1 * s1 + a2 * s2) * (a1 * s1 + a2 * s2)
        guard denominator > 0, numerator > 0 else { return -120 }
        return 10 * log10(numerator / denominator)
    }

    /// The whole profile's response at `frequency`, in dB, including the preamp.
    static func response(_ profile: EQProfile, at frequency: Double) -> Double {
        profile.preamp + profile.bands.reduce(0) { $0 + response($1, at: frequency) }
    }
}

// MARK: - The audio units

/// The equaliser and limiter of one output. Each deck of the mixer has its own engine, so each
/// has one of these between its main mixer and its output; all of them follow one profile
/// (`MasterEQ`). Because the filters are linear, applying them to each deck alone gives the
/// same sound as applying them to the sum of the two. AutoMix's own per-deck EQ sits earlier
/// in the chain and is not touched.
final class MasterEQUnit {
    let equalizer = AVAudioUnitEQ(numberOfBands: EQProfile.maxBands)
    let limiter: AVAudioUnitEffect
    private weak var engine: AVAudioEngine?
    private var chained = false

    init() {
        _ = LimiterAU.registered
        limiter = AVAudioUnitEffect(audioComponentDescription: LimiterAU.description)
        equalizer.bypass = true
    }

    /// Attaches the units. They stay out of the signal path until a profile needs them, so
    /// with a flat equaliser the output is exactly what it was before this existed.
    func install(in engine: AVAudioEngine) {
        self.engine = engine
        engine.attach(equalizer)
        engine.attach(limiter)
    }

    private var chainFormat: AVAudioFormat?

    /// The units are connected with the main mixer's own format. Letting the engine choose
    /// leaves them at a default rate that doesn't match the device, and nothing renders.
    private func connectChain(_ engine: AVAudioEngine) {
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        engine.connect(mixer, to: equalizer, format: format)
        engine.connect(equalizer, to: limiter, format: format)
        engine.connect(limiter, to: engine.outputNode, format: format)
        chainFormat = format
    }

    private func setChained(_ wanted: Bool) {
        guard let engine, wanted != chained else { return }
        chained = wanted
        if wanted {
            connectChain(engine)
        } else {
            engine.disconnectNodeOutput(equalizer)
            engine.disconnectNodeOutput(limiter)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
            chainFormat = nil
        }
    }

    /// After the output changed (another device, another sample rate), connects the units again
    /// in the new format. Call from the queue that owns the engine's graph.
    func refreshFormat() {
        guard let engine, chained, chainFormat != engine.mainMixerNode.outputFormat(forBus: 0) else { return }
        connectChain(engine)
    }

    /// Sets the filters from a profile. Call from the queue that owns the engine's graph.
    func apply(_ profile: EQProfile, enabled: Bool, limit: Bool) {
        let active = enabled && !profile.isFlat
        let limiting = limit || (active && profile.addsGain)
        setChained(active || limiting)
        equalizer.bypass = !active
        limiter.bypass = !limiting
        guard active else { return }
        equalizer.globalGain = Float(profile.preamp)
        for index in 0 ..< EQProfile.maxBands {
            let target = equalizer.bands[index]
            guard index < profile.bands.count, profile.bands[index].enabled else {
                target.bypass = true
                continue
            }
            let band = profile.bands[index]
            switch band.kind {
            case .peak: target.filterType = .parametric
            case .lowShelf: target.filterType = .lowShelf
            case .highShelf: target.filterType = .highShelf
            case .lowPass: target.filterType = .resonantLowPass
            case .highPass: target.filterType = .resonantHighPass
            }
            target.frequency = Float(band.frequency)
            target.gain = band.kind.hasGain ? Float(band.gain) : 0
            if band.kind == .peak {
                // The unit takes a width in octaves; this is the width of a filter with this Q.
                target.bandwidth = Float(2 * asinh(1 / (2 * band.q)) / log(2.0))
            } else if band.kind == .lowPass || band.kind == .highPass {
                target.bandwidth = Float(min(5, max(0.05, 2 * asinh(1 / (2 * band.q)) / log(2.0))))
            }
            target.bypass = false
        }
    }
}

// MARK: - The shared profile

private struct EQFile: Codable {
    var enabled = false
    var active = EQProfile.flat
    var saved: [EQProfile] = []
}

/// The equaliser's settings, shared by every output. Stored in `eq.json`.
@MainActor
@Observable
final class MasterEQ {
    static let shared = MasterEQ()

    var enabled: Bool { didSet { changed() } }
    /// The profile being heard and edited. Choosing a preset or a saved profile copies it here.
    var profile: EQProfile { didSet { changed() } }
    private(set) var saved: [EQProfile]
    /// Set when loudness normalisation may add gain, so the limiter is on even for a flat profile.
    var boostsLevel = false { didSet { changed(save: false) } }

    typealias Applier = @Sendable (EQProfile, Bool, Bool) -> Void
    @ObservationIgnored private var appliers: [Applier] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let file: URL

    init(file: URL = AppPaths.eq) {
        self.file = file
        var loaded = EQFile()
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(EQFile.self, from: data) { loaded = decoded }
        enabled = loaded.enabled
        profile = loaded.active
        saved = loaded.saved
    }

    var presets: [EQProfile] { EQProfile.presets }

    /// Reads the file again, after a restore replaced it.
    func reload() {
        var loaded = EQFile()
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(EQFile.self, from: data) { loaded = decoded }
        saved = loaded.saved
        profile = loaded.active
        enabled = loaded.enabled
    }

    /// Called by each engine as it is created. `apply` must run the change on whatever queue
    /// owns that engine's graph.
    func register(_ apply: @escaping Applier) {
        appliers.append(apply)
        apply(profile, enabled, boostsLevel)
    }

    func choose(_ preset: EQProfile) {
        var copy = preset
        copy.bands = preset.bands.map { var band = $0; band.id = UUID(); return band }
        profile = copy
    }

    func saveCurrent(as name: String) {
        var copy = profile
        copy.id = UUID().uuidString
        copy.name = name
        saved.removeAll { $0.name == name }
        saved.append(copy)
        profile = copy
        persist()
    }

    func deleteSaved(_ id: String) {
        saved.removeAll { $0.id == id }
        persist()
    }

    func addBand() {
        guard profile.bands.count < EQProfile.maxBands else { return }
        let used = Set(profile.bands.map { Int($0.frequency) })
        let frequency = [1_000.0, 250, 4_000, 60, 10_000, 500, 2_000, 125, 8_000, 16_000].first { !used.contains(Int($0)) } ?? 1_000
        profile.bands.append(EQBand(kind: .peak, frequency: frequency))
    }

    func removeBand(_ id: UUID) {
        profile.bands.removeAll { $0.id == id }
    }

    private func changed(save: Bool = true) {
        for apply in appliers { apply(profile, enabled, boostsLevel) }
        if save { persist() }
    }

    private func persist() {
        let snapshot = EQFile(enabled: enabled, active: profile, saved: saved)
        let target = file
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: target, options: .atomic) }
        }
    }
}

// MARK: - Normalisation

/// How loud tracks are brought to, relative to YouTube's reference level.
enum NormalizationLevel: String, CaseIterable, Identifiable {
    case quiet, normal, loud
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var offsetDb: Double {
        switch self {
        case .quiet: -3
        case .normal: 0
        case .loud: 3
        }
    }
}

/// The normalisation target, readable from the audio threads.
enum Normalization {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedLevel = NormalizationLevel.normal
    nonisolated(unsafe) private static var storedBoost = false

    static var level: NormalizationLevel {
        get { lock.withLock { storedLevel } }
        set { lock.withLock { storedLevel = newValue } }
    }

    /// Whether quiet tracks may be raised, by at most `maxBoostDb`.
    static var allowsBoost: Bool {
        get { lock.withLock { storedBoost } }
        set { lock.withLock { storedBoost = newValue } }
    }

    static let maxBoostDb = 3.0

    /// Linear gain for a track YouTube measured `loudnessDb` above its reference. With the
    /// defaults (Normal, no boost) this is exactly "turn down only": min(1, 10^(-loudness/20)).
    static func gain(loudnessDb: Double) -> Float {
        let (level, boost) = lock.withLock { (storedLevel, storedBoost) }
        let decibels = min(-loudnessDb + level.offsetDb, boost ? maxBoostDb : 0)
        return Float(pow(10, decibels / 20))
    }
}
