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
    static let artwork = directory(root.appendingPathComponent("Artwork", isDirectory: true))
    static let lyrics = directory(root.appendingPathComponent("Lyrics", isDirectory: true))
    /// Cached tempo, beat, key and energy analysis used by AutoMix.
    static let analysis = directory(root.appendingPathComponent("Analysis", isDirectory: true))

    static let library = root.appendingPathComponent("library.json")
    static let mediaIndex = root.appendingPathComponent("media.json")
    static let playerState = root.appendingPathComponent("player.json")
    /// Transitions edited by hand, by pair of songs.
    static let mixes = root.appendingPathComponent("mixes.json")

    private static func directory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
