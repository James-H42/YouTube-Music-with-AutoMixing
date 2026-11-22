import Foundation

/// This app's own backup: a ZIP of the library, hand-edited transitions, sample links,
/// equaliser profiles, hand-edited lyrics and the preferences. Nothing secret goes in: no
/// cookies, tokens or Keychain items, and no scrobbling queue. Restoring checks everything
/// before it writes anything, and keeps a copy of the data it replaces.
enum LibraryBackup {
    static let appName = "Metrolist"
    static let formatVersion = 1

    struct Manifest: Codable {
        var formatVersion: Int
        var app: String
        var createdAt: Date
        var includesAnalysis: Bool
    }

    struct Result {
        var files: Int
        var settings: Int
        var replacedCopy: URL?
    }

    /// Preferences that go into a backup. Anything not listed is left out, and so is anything
    /// whose name suggests a credential.
    static let settingsKeys = [
        "audioQuality", "preferAudioVersions", "showVideos", "videoQuality", "appleArtistImages", "animatedArtistArtwork", "animatedAlbumCovers", "hideOriginalLyrics", "discordPresence", "normalizeVolume", "normalizationLevel", "normalizationBoost", "autoplay", "maxCacheGB",
        "showMenuBarPlayer", "miniPlayerOnTop", "fullScreenLyrics", "showRomanization", "autoMix", "mixLength", "mixStyle", "mixKeyMatch", "mixStems",
        "mixSampleLookup", "mixOrdersQueue", "mixAlbums", "volume", "accountPlayback", "lyricsProviderOrder", "lyricsProvidersDisabled",
        "lyricsPreferWordSynced", "outputDeviceUID", "hideAIArtists", "bitPerfect", "exclusiveOutput",
    ]

    private static let plainFiles = ["library.json", "mixes.json", "samples.json", "eq.json", "blocked.json"]

    private static func isCredentialName(_ key: String) -> Bool {
        ["token", "secret", "session", "cookie", "password", "apikey"].contains { key.lowercased().contains($0) }
    }

    /// Whether `name` is an entry a backup may contain, and so may be restored.
    static func isAllowed(_ name: String) -> Bool {
        if plainFiles.contains(name) || name == "settings.json" || name == BackupName.manifest { return true }
        if name.hasPrefix("lyrics/"), name.hasSuffix(".user.json") {
            let id = String(name.dropFirst(7).dropLast(10))
            return ForeignBackup.isYouTubeVideoId(id)
        }
        if name.hasPrefix("analysis/"), name.hasSuffix(".json") {
            let id = String(name.dropFirst(9).dropLast(5))
            return !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
        return false
    }

    enum BackupName { static let manifest = "backup.json" }

    // MARK: Writing

    @discardableResult
    static func create(at destination: URL, includeAnalysis: Bool, root: URL = AppPaths.root, defaults: UserDefaults = AppPaths.settings) throws -> Int {
        var zip = ZipWriter()
        var count = 0
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        zip.add(BackupName.manifest, try encoder.encode(Manifest(formatVersion: formatVersion, app: appName, createdAt: Date(), includesAnalysis: includeAnalysis)))
        for name in plainFiles {
            if let data = try? Data(contentsOf: root.appendingPathComponent(name)) { zip.add(name, data); count += 1 }
        }
        let lyrics = root.appendingPathComponent("Lyrics", isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: lyrics, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasSuffix(".user.json") {
            let name = "lyrics/" + file.lastPathComponent
            if isAllowed(name), let data = try? Data(contentsOf: file) { zip.add(name, data); count += 1 }
        }
        if includeAnalysis {
            let folder = root.appendingPathComponent("Analysis", isDirectory: true)
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
                let name = "analysis/" + file.lastPathComponent
                if isAllowed(name), let data = try? Data(contentsOf: file) { zip.add(name, data); count += 1 }
            }
        }
        var settings: [String: Any] = [:]
        for key in settingsKeys where !isCredentialName(key) {
            if let value = defaults.object(forKey: key), value is String || value is NSNumber { settings[key] = value }
        }
        zip.add("settings.json", try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .prettyPrinted]))
        try zip.finished().write(to: destination, options: .atomic)
        return count + 1
    }

    // MARK: Reading

    /// Opens and checks an archive without restoring anything.
    static func inspect(_ url: URL) throws -> (manifest: Manifest, files: [String]) {
        let (archive, manifest) = try open(url)
        return (manifest, archive.entries.map(\.name).filter(isAllowed))
    }

    private static func open(_ url: URL) throws -> (ZipReader, Manifest) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 300 * 1024 * 1024 else { throw ZipError.tooLarge }
        let archive = try ZipReader(data: Data(contentsOf: url, options: .mappedIfSafe), limits: .backup)
        guard let entry = archive.entry(named: BackupName.manifest), entry.size <= 64 * 1024 else { throw RestoreError.notABackup }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: archive.contents(of: entry)), manifest.app == appName else { throw RestoreError.notABackup }
        guard manifest.formatVersion >= 1, manifest.formatVersion <= formatVersion else { throw RestoreError.newerFormat }
        return (archive, manifest)
    }

    enum RestoreError: LocalizedError {
        case notABackup, newerFormat, invalidContent(String)

        var errorDescription: String? {
            switch self {
            case .notABackup: "That isn't a Metrolist+ backup."
            case .newerFormat: "That backup was made by a newer version of Metrolist+."
            case .invalidContent(let name): "The backup's \(name) isn't valid, so nothing was restored."
            }
        }
    }

    // MARK: Restoring

    /// Replaces the app's data with the backup's. Everything is read and validated first; only
    /// then is the current data copied to `Backups/before-restore-…` and the new data written.
    @discardableResult
    static func restore(from url: URL, root: URL = AppPaths.root, defaults: UserDefaults = AppPaths.settings) throws -> Result {
        let (archive, _) = try open(url)
        var files: [(name: String, data: Data)] = []
        var settings: [String: Any] = [:]
        for entry in archive.entries where !entry.isDirectory && entry.name != BackupName.manifest && isAllowed(entry.name) {
            let data = try archive.contents(of: entry)
            if entry.name == "settings.json" {
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw RestoreError.invalidContent(entry.name) }
                // Only the known preferences, and only plain values.
                for (key, value) in object where settingsKeys.contains(key) && !isCredentialName(key) && (value is String || value is NSNumber) { settings[key] = value }
            } else {
                // Every file must at least be well-formed JSON of the right shape.
                guard let object = try? JSONSerialization.jsonObject(with: data) else { throw RestoreError.invalidContent(entry.name) }
                let expectsList = entry.name == "blocked.json" ? false : (entry.name == "mixes.json" || entry.name == "samples.json" || entry.name == "library.json" || entry.name == "eq.json" || entry.name.hasPrefix("lyrics/") || entry.name.hasPrefix("analysis/"))
                if expectsList, !(object is [String: Any]) { throw RestoreError.invalidContent(entry.name) }
                files.append((entry.name, data))
            }
        }
        // Keep what is there now.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let copy = root.appendingPathComponent("Backups/before-restore-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for name in plainFiles {
            let current = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: current.path) { try FileManager.default.copyItem(at: current, to: copy.appendingPathComponent(name)) }
        }
        let userLyrics = root.appendingPathComponent("Lyrics", isDirectory: true)
        if let existing = try? FileManager.default.contentsOfDirectory(at: userLyrics, includingPropertiesForKeys: nil) {
            for file in existing where file.lastPathComponent.hasSuffix(".user.json") {
                try? FileManager.default.createDirectory(at: copy.appendingPathComponent("lyrics"), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: file, to: copy.appendingPathComponent("lyrics/" + file.lastPathComponent))
            }
        }
        for (name, data) in files {
            // The name was checked by `isAllowed`, so the destination is always inside the data folder.
            let target = name.hasPrefix("lyrics/") ? userLyrics.appendingPathComponent(String(name.dropFirst(7)))
                : name.hasPrefix("analysis/") ? root.appendingPathComponent("Analysis", isDirectory: true).appendingPathComponent(String(name.dropFirst(9)))
                : root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        return Result(files: files.count, settings: settings.count, replacedCopy: copy)
    }
}
