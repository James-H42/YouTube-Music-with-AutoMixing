import Foundation

/// On-disk locations, all under ~/Library/Application Support/Metrolist.
enum AppPaths {
    static let root: URL = {
        // Tests and snapshots can redirect all storage with METROLIST_HOME.
        if let override = ProcessInfo.processInfo.environment["METROLIST_HOME"], !override.isEmpty {
            return directory(URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Metrolist", isDirectory: true)
        // Early builds kept their data in "Metrolist AutoMix". Carry it over, once, but never
        // into a folder that is already there: that would mix it with another app's data.
        let earlier = base.appendingPathComponent("Metrolist AutoMix", isDirectory: true)
        let files = FileManager.default
        if files.fileExists(atPath: earlier.path), !files.fileExists(atPath: folder.path) {
            do { try files.moveItem(at: earlier, to: folder) } catch { return directory(earlier) }
        }
        return directory(folder)
    }()

    /// Audio files, both automatically cached and explicitly downloaded.
    static let media = directory(root.appendingPathComponent("Media", isDirectory: true))
    /// The pictures of downloaded music videos (their sound is in `media`).
    static let videos = directory(root.appendingPathComponent("Videos", isDirectory: true))
    static let videoIndex = root.appendingPathComponent("videos.json")
    static let artwork = directory(root.appendingPathComponent("Artwork", isDirectory: true))
    /// Copies of the data that a restore replaced.
    static let backups = directory(root.appendingPathComponent("Backups", isDirectory: true))
    static let lyrics = directory(root.appendingPathComponent("Lyrics", isDirectory: true))
    /// Cached tempo, beat, key and energy analysis used by AutoMix.
    static let analysis = directory(root.appendingPathComponent("Analysis", isDirectory: true))

    static let library = root.appendingPathComponent("library.json")
    static let mediaIndex = root.appendingPathComponent("media.json")
    static let playerState = root.appendingPathComponent("player.json")
    /// Transitions edited by hand, by pair of songs.
    static let mixes = root.appendingPathComponent("mixes.json")
    /// Artists the listener hid, and the cached community list of AI-generated artists.
    static let blocked = root.appendingPathComponent("blocked.json")
    static let aiBlocklist = root.appendingPathComponent("ai-blocklist.txt")
    /// Plays waiting to be sent to Last.fm and ListenBrainz (track data only).
    static let scrobbles = root.appendingPathComponent("scrobbles.json")
    /// The equaliser's active profile and saved profiles.
    static let eq = root.appendingPathComponent("eq.json")
    /// Which music videos have an audio release, as found for playlists (video id → song).
    static let audioVersions = root.appendingPathComponent("audio-versions.json")
    /// Apple Music artist pictures and animated covers found so far (addresses only).
    static let appleArtwork = root.appendingPathComponent("apple-artwork.json")

    private static func directory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
