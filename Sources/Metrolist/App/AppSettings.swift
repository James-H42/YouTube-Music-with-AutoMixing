import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    var audioQuality: AudioQuality { didSet { defaults.set(audioQuality.rawValue, forKey: "audioQuality") } }
    /// Swap music videos for their audio release whenever one exists.
    var preferAudioVersions: Bool { didSet { defaults.set(preferAudioVersions, forKey: "preferAudioVersions") } }
    /// Show the picture of a music video or live performance in the full-screen player.
    var showVideos: Bool { didSet { defaults.set(showVideos, forKey: "showVideos") } }
    /// Picture height of music videos: 0 lets the player choose (Auto), otherwise a fixed
    /// quality such as 1080 or 2160, or the nearest one below it that the video has.
    var videoQuality: Int { didSet { defaults.set(videoQuality, forKey: "videoQuality") } }
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
    /// Separate the songs into stems during a transition (`StemSeparator`), so the outgoing
    /// vocals can step aside and bass and drums hand over cleanly. Needs the stem model.
    var mixStems: Bool { didSet { defaults.set(mixStems, forKey: "mixStems") } }
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
    /// Artist pages use Apple Music's artist picture when one is found.
    var appleArtistImages: Bool { didSet { defaults.set(appleArtistImages, forKey: "appleArtistImages") } }
    /// Artist pages play Apple Music's animated artist picture when there is one.
    var animatedArtistArtwork: Bool { didSet { defaults.set(animatedArtistArtwork, forKey: "animatedArtistArtwork") } }
    /// Album pages play Apple Music's animated cover when there is one.
    var animatedAlbumCovers: Bool { didSet { defaults.set(animatedAlbumCovers, forKey: "animatedAlbumCovers") } }
    /// Shows romanised lyrics in place of the original script, rather than under it.
    var hideOriginalLyrics: Bool { didSet { defaults.set(hideOriginalLyrics, forKey: "hideOriginalLyrics") } }
    /// Shows the playing song as a Discord activity, through the Discord app on this Mac.
    var discordPresence: Bool { didSet { defaults.set(discordPresence, forKey: "discordPresence"); DiscordPresence.shared.setEnabled(discordPresence) } }

    var mixOptions: MixOptions {
        MixOptions(length: mixLength, style: mixStyle, keyMatch: mixKeyMatch, stems: mixStems && StemSeparator.isInstalled)
    }

    @ObservationIgnored private let defaults = AppPaths.settings

    init() {
        defaults.register(defaults: [
            "preferAudioVersions": true,
            "showVideos": true,
            "normalizeVolume": true,
            "autoplay": true,
            "maxCacheGB": 2.0,
            "showMenuBarPlayer": true,
            "miniPlayerOnTop": true,
            "volume": 1.0,
            "showRomanization": true,
            "mixKeyMatch": true,
            "mixStems": true,
            "mixSampleLookup": true,
            "mixOrdersQueue": true,
            "accountPlayback": true,
        ])
        audioQuality = AudioQuality(rawValue: defaults.string(forKey: "audioQuality") ?? "") ?? .high
        preferAudioVersions = defaults.bool(forKey: "preferAudioVersions")
        showVideos = defaults.bool(forKey: "showVideos")
        videoQuality = defaults.integer(forKey: "videoQuality")
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
        mixStems = defaults.bool(forKey: "mixStems")
        mixAlbums = defaults.bool(forKey: "mixAlbums")
        mixSampleLookup = defaults.bool(forKey: "mixSampleLookup")
        mixOrdersQueue = defaults.bool(forKey: "mixOrdersQueue")
        geniusToken = SampleDatabase.geniusToken ?? ""
        volume = defaults.double(forKey: "volume")
        accountPlayback = defaults.bool(forKey: "accountPlayback")
        appleArtistImages = defaults.bool(forKey: "appleArtistImages")
        animatedArtistArtwork = defaults.bool(forKey: "animatedArtistArtwork")
        animatedAlbumCovers = defaults.bool(forKey: "animatedAlbumCovers")
        hideOriginalLyrics = defaults.bool(forKey: "hideOriginalLyrics")
        discordPresence = defaults.bool(forKey: "discordPresence")
        applySound()
        // Observers don't run during init.
        if discordPresence { DiscordPresence.shared.setEnabled(true) }
    }

    private func applySound() {
        Normalization.level = normalizationLevel
        Normalization.allowsBoost = normalizationBoost
        // Raising a quiet track, or a loud target, can push the sum past full scale.
        MasterEQ.shared.boostsLevel = normalizationBoost || normalizationLevel == .loud
    }
}
