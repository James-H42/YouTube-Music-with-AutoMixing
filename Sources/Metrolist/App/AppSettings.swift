import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    var audioQuality: AudioQuality { didSet { defaults.set(audioQuality.rawValue, forKey: "audioQuality") } }
    /// Swap music videos for their audio release whenever one exists.
    var preferAudioVersions: Bool { didSet { defaults.set(preferAudioVersions, forKey: "preferAudioVersions") } }
    var normalizeVolume: Bool { didSet { defaults.set(normalizeVolume, forKey: "normalizeVolume") } }
    /// Keep playing similar music when the queue runs out.
    /// Where tracks are levelled to, and whether quiet ones may be raised (by up to 3 dB).
    var normalizationLevel: NormalizationLevel { didSet { defaults.set(normalizationLevel.rawValue, forKey: "normalizationLevel"); applySound() } }
    var normalizationBoost: Bool { didSet { defaults.set(normalizationBoost, forKey: "normalizationBoost"); applySound() } }
    var autoplay: Bool { didSet { defaults.set(autoplay, forKey: "autoplay") } }
    var maxCacheGB: Double { didSet { defaults.set(maxCacheGB, forKey: "maxCacheGB") } }
    var showMenuBarPlayer: Bool { didSet { defaults.set(showMenuBarPlayer, forKey: "showMenuBarPlayer") } }
    var miniPlayerOnTop: Bool { didSet { defaults.set(miniPlayerOnTop, forKey: "miniPlayerOnTop") } }
    /// Show lyrics beside the artwork in the full-screen player (otherwise artwork is centred).
    var fullScreenLyrics: Bool { didSet { defaults.set(fullScreenLyrics, forKey: "fullScreenLyrics") } }
    /// Show a Latin-script reading under lyrics in Japanese, Korean, Chinese and other scripts.
    var showRomanization: Bool { didSet { defaults.set(showRomanization, forKey: "showRomanization") } }
    /// DJ-style transitions between tracks. Off by default; gapless playback is used otherwise.
    var autoMix: Bool { didSet { defaults.set(autoMix, forKey: "autoMix") } }
    var mixLength: MixLength { didSet { defaults.set(mixLength.rawValue, forKey: "mixLength") } }
    /// Whether AutoMix looks for the best point and technique, or always fades at the end.
    var mixStyle: MixStyle { didSet { defaults.set(mixStyle.rawValue, forKey: "mixStyle") } }
    /// Let AutoMix nudge the next song's pitch when that makes the two keys agree.
    var mixKeyMatch: Bool { didSet { defaults.set(mixKeyMatch, forKey: "mixKeyMatch") } }
    /// Mix between consecutive tracks of one album too (off: albums play as sequenced).
    /// Ask MusicBrainz whether the two songs of a transition are known to share a sample.
    var mixSampleLookup: Bool { didSet { defaults.set(mixSampleLookup, forKey: "mixSampleLookup") } }
    /// Let AutoMix order the songs Autoplay adds so that each mixes well out of the last.
    var mixOrdersQueue: Bool { didSet { defaults.set(mixOrdersQueue, forKey: "mixOrdersQueue") } }
    /// Optional Genius API access token, for fuller sample information.
    var geniusToken: String { didSet { if geniusToken != oldValue { SampleDatabase.geniusToken = geniusToken } } }
    var mixAlbums: Bool { didSet { defaults.set(mixAlbums, forKey: "mixAlbums") } }
    var volume: Double { didSet { defaults.set(volume, forKey: "volume") } }
    /// When YouTube refuses anonymous playback, ask for streams as the signed-in account.
    var accountPlayback: Bool { didSet { defaults.set(accountPlayback, forKey: "accountPlayback") } }

    var mixOptions: MixOptions { MixOptions(length: mixLength, style: mixStyle, keyMatch: mixKeyMatch) }

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            "preferAudioVersions": true,
            "normalizeVolume": true,
            "autoplay": true,
            "maxCacheGB": 2.0,
            "showMenuBarPlayer": true,
            "miniPlayerOnTop": true,
            "volume": 1.0,
            "showRomanization": true,
            "mixKeyMatch": true,
            "mixSampleLookup": true,
            "mixOrdersQueue": true,
            "accountPlayback": true,
        ])
        audioQuality = AudioQuality(rawValue: defaults.string(forKey: "audioQuality") ?? "") ?? .high
        preferAudioVersions = defaults.bool(forKey: "preferAudioVersions")
        normalizeVolume = defaults.bool(forKey: "normalizeVolume")
        autoplay = defaults.bool(forKey: "autoplay")
        normalizationLevel = NormalizationLevel(rawValue: defaults.string(forKey: "normalizationLevel") ?? "") ?? .normal
        normalizationBoost = defaults.bool(forKey: "normalizationBoost")
        maxCacheGB = defaults.double(forKey: "maxCacheGB")
        showMenuBarPlayer = defaults.bool(forKey: "showMenuBarPlayer")
        miniPlayerOnTop = defaults.bool(forKey: "miniPlayerOnTop")
        fullScreenLyrics = defaults.bool(forKey: "fullScreenLyrics")
        showRomanization = defaults.bool(forKey: "showRomanization")
        autoMix = defaults.bool(forKey: "autoMix")
        mixLength = MixLength(rawValue: defaults.string(forKey: "mixLength") ?? "") ?? .medium
        mixStyle = MixStyle(rawValue: defaults.string(forKey: "mixStyle") ?? "") ?? .smart
        mixKeyMatch = defaults.bool(forKey: "mixKeyMatch")
        mixAlbums = defaults.bool(forKey: "mixAlbums")
        mixSampleLookup = defaults.bool(forKey: "mixSampleLookup")
        mixOrdersQueue = defaults.bool(forKey: "mixOrdersQueue")
        geniusToken = SampleDatabase.geniusToken ?? ""
        volume = defaults.double(forKey: "volume")
        accountPlayback = defaults.bool(forKey: "accountPlayback")
        applySound()
    }

    private func applySound() {
        Normalization.level = normalizationLevel
        Normalization.allowsBoost = normalizationBoost
        // Raising a quiet track, or a loud target, can push the sum past full scale.
        MasterEQ.shared.boostsLevel = normalizationBoost || normalizationLevel == .loud
    }
}
