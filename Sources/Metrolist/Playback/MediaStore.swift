import Foundation
import Observation

/// A fully downloaded audio file on disk.
final class FileByteSource: ByteSource {
    let url: URL
    private let handle: FileHandle?
    private let size: Int64
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
        handle = try? FileHandle(forReadingFrom: url)
        size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    var availableBytes: Int64 { size }
    var totalBytes: Int64? { size }

    func read(offset: Int64, length: Int) -> Data? {
        guard let handle, offset >= 0, offset + Int64(length) <= size else { return nil }
        return lock.withLock {
            try? handle.seek(toOffset: UInt64(offset))
            return try? handle.read(upToCount: length)
        }
    }
}

/// Downloads an audio stream sequentially in bounded byte ranges while exposing the bytes
/// received so far, so playback can begin before the download finishes.
final class ProgressiveDownload: ByteSource, @unchecked Sendable {
    enum State {
        case downloading
        case complete
        case failed(Error)
    }

    let videoId: String
    private let quality: AudioQuality
    private let lock = NSLock()
    private var available: Int64 = 0
    private var total: Int64?
    private var currentState: State = .downloading
    private var currentStream: ResolvedStream?
    private var currentURL: URL?
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?
    private var task: Task<Void, Never>?
    private var observers: [UUID: () -> Void] = [:]

    init(videoId: String, quality: AudioQuality) {
        self.videoId = videoId
        self.quality = quality
    }

    var availableBytes: Int64 { lock.withLock { available } }
    var totalBytes: Int64? { lock.withLock { total } }
    var state: State { lock.withLock { currentState } }
    var stream: ResolvedStream? { lock.withLock { currentStream } }

    /// Location of the file, which changes when the finished download is moved into place.
    var fileURL: URL? {
        get { lock.withLock { currentURL } }
        set { lock.withLock { currentURL = newValue } }
    }

    var progress: Double {
        lock.withLock {
            guard let total, total > 0 else { return 0 }
            return Double(available) / Double(total)
        }
    }

    func read(offset: Int64, length: Int) -> Data? {
        lock.withLock {
            guard let readHandle, offset >= 0, offset + Int64(length) <= available else { return nil }
            try? readHandle.seek(toOffset: UInt64(offset))
            return try? readHandle.read(upToCount: length)
        }
    }

    @discardableResult
    func addObserver(_ block: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = block }
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.withLock { observers[id] = nil }
    }

    private func notify() {
        let blocks = lock.withLock { Array(observers.values) }
        blocks.forEach { $0() }
    }

    func start(onFinish: @escaping @Sendable (ProgressiveDownload) -> Void) {
        task = Task.detached(priority: .userInitiated) { [self] in
            do {
                try await run()
                lock.withLock { currentState = .complete }
            } catch {
                lock.withLock { currentState = .failed(error) }
            }
            try? writeHandle?.close()
            notify()
            onFinish(self)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run() async throws {
        var stream = try await StreamResolver.shared.resolve(videoId: videoId, quality: quality)
        let url = AppPaths.media.appendingPathComponent("\(videoId).part.\(stream.fileExtension)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try FileHandle(forWritingTo: url)
        let reader = try FileHandle(forReadingFrom: url)
        lock.withLock {
            currentStream = stream
            currentURL = url
            writeHandle = writer
            readHandle = reader
            total = stream.contentLength
        }
        notify()

        let client = MediaHTTPClient()
        defer { client.close() }
        var offset: Int64 = 0
        var failures = 0
        while true {
            try Task.checkCancellation()
            let knownTotal = totalBytes
            if let knownTotal, offset >= knownTotal { break }
            var end = offset + Int64(stream.chunkSize) - 1
            if let knownTotal { end = min(end, knownTotal - 1) }

            do {
                let response = try await client.fetch(stream.url, range: offset ... end, userAgent: stream.userAgent)
                let status = response.status
                let data = response.body
                guard status == 200 || status == 206, !data.isEmpty else { throw YTError.http(status) }
                // Keep talking to the server we were redirected to.
                stream.url = response.url

                if knownTotal == nil {
                    if status == 200 {
                        lock.withLock { total = Int64(data.count) }
                    } else if let size = response.headers["content-range"]?.split(separator: "/").last.flatMap({ Int64($0) }) {
                        lock.withLock { total = size }
                    } else if data.count < stream.chunkSize {
                        lock.withLock { total = offset + Int64(data.count) }
                    }
                }
                try writer.write(contentsOf: data)
                offset += Int64(data.count)
                lock.withLock { available = offset }
                failures = 0
                notify()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                if failures > 3 || Task.isCancelled { throw error }
                if case YTError.http(let status) = error, [403, 404, 410].contains(status) {
                    // The signed URL expired or this client identity was rejected: resolve again.
                    stream = try await StreamResolver.shared.resolve(videoId: videoId, quality: quality, forceRefresh: true)
                    lock.withLock { currentStream = stream }
                } else {
                    try await Task.sleep(for: .milliseconds(500 * failures))
                }
            }
        }
    }
}

struct MediaRecord: Codable {
    var videoId: String
    var fileName: String
    var bytes: Int64
    var itag: Int
    var mimeType: String
    var bitrate: Int
    var loudnessDb: Double?
    /// True for explicit downloads, which are never evicted; false for the automatic cache.
    var pinned: Bool
    var addedAt: Date
    var lastAccess: Date
    /// True once the file carries embedded tags and a readable name.
    var tagged: Bool?
}

/// Something the audio engine can play: a finished local file or a download in flight.
struct OpenedMedia {
    let videoId: String
    let source: ByteSource
    let download: ProgressiveDownload?
    let record: MediaRecord?

    var fileURL: URL? {
        if let record { return AppPaths.media.appendingPathComponent(record.fileName) }
        return download?.fileURL
    }

    var loudnessDb: Double? { record?.loudnessDb ?? download?.stream?.loudnessDb }
}

enum DownloadState: Equatable {
    case none
    case queued
    case downloading(Double)
    case downloaded
}

/// Owns every audio file on disk: the size-limited automatic cache of played songs and the
/// user's explicit downloads. Anything stored here plays without a network connection.
@MainActor
@Observable
final class MediaStore {
    private(set) var records: [String: MediaRecord] = [:]
    private(set) var progress: [String: Double] = [:]
    private(set) var queued: [String] = []
    private(set) var failed: Set<String> = []

    @ObservationIgnored private var active: [String: ProgressiveDownload] = [:]
    @ObservationIgnored private var pinRequested: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var settings: AppSettings?
    /// Looks up a song's metadata for naming and tagging its downloaded file.
    @ObservationIgnored var songProvider: ((String) -> Song?)?
    @ObservationIgnored private var tagging: Set<String> = []
    /// Song currently loaded in the player; never evicted.
    @ObservationIgnored var protectedId: String?

    private static let maxConcurrentDownloads = 3

    init() {
        if let data = try? Data(contentsOf: AppPaths.mediaIndex),
           let saved = try? JSONDecoder().decode([String: MediaRecord].self, from: data) {
            records = saved.filter { FileManager.default.fileExists(atPath: AppPaths.media.appendingPathComponent($0.value.fileName).path) }
        }
        // Remove partial files left behind by a previous session.
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.media, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.contains(".part.") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Queries

    func isAvailableOffline(_ videoId: String) -> Bool { records[videoId] != nil }

    func isDownloaded(_ videoId: String) -> Bool { records[videoId]?.pinned == true }

    func state(for videoId: String) -> DownloadState {
        if records[videoId]?.pinned == true { return .downloaded }
        if let value = progress[videoId], pinRequested.contains(videoId) { return .downloading(value) }
        if queued.contains(videoId) { return .queued }
        return .none
    }

    var downloadedIds: [String] {
        records.values.filter(\.pinned).sorted { $0.addedAt > $1.addedAt }.map(\.videoId)
    }

    /// A download that is a music video or live performance (listed under Music Videos, not
    /// Downloads): its picture is saved, or it is one by YouTube Music's own type.
    func isVideoDownload(_ videoId: String) -> Bool {
        VideoDownloads.shared.isDownloaded(videoId) || VideoDownloads.shared.isDownloading(videoId)
            || songProvider?(videoId)?.isMusicVideo == true
    }

    var downloadedBytes: Int64 { records.values.filter(\.pinned).reduce(0) { $0 + $1.bytes } }
    var cacheBytes: Int64 { records.values.filter { !$0.pinned }.reduce(0) { $0 + $1.bytes } }
    var activeDownloadCount: Int { queued.count + pinRequested.intersection(active.keys).count }

    // MARK: - Playback

    /// Returns a playable source for a song, starting a cached download when it isn't on disk yet.
    func open(videoId: String) -> OpenedMedia {
        if var record = records[videoId] {
            let url = AppPaths.media.appendingPathComponent(record.fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                record.lastAccess = Date()
                records[videoId] = record
                scheduleSave()
                return OpenedMedia(videoId: videoId, source: FileByteSource(url: url), download: nil, record: record)
            }
            records[videoId] = nil
        }
        let download = active[videoId] ?? startDownload(videoId)
        return OpenedMedia(videoId: videoId, source: download, download: download, record: nil)
    }

    /// Warms the cache for a song that is about to play.
    /// True while a song's audio is being downloaded.
    func isFetching(_ videoId: String) -> Bool { active[videoId] != nil }

    func prefetch(videoId: String) {
        guard records[videoId] == nil, active[videoId] == nil else { return }
        _ = startDownload(videoId)
    }

    private func startDownload(_ videoId: String) -> ProgressiveDownload {
        failed.remove(videoId)
        let download = ProgressiveDownload(videoId: videoId, quality: settings?.audioQuality ?? .high)
        active[videoId] = download
        download.addObserver { [weak self, weak download] in
            guard let value = download?.progress else { return }
            Task { @MainActor in
                guard let self, self.pinRequested.contains(videoId), self.active[videoId] != nil else { return }
                self.progress[videoId] = value
            }
        }
        download.start { [weak self] finished in
            Task { @MainActor in self?.finish(finished) }
        }
        return download
    }

    private func finish(_ download: ProgressiveDownload) {
        let videoId = download.videoId
        active[videoId] = nil
        progress[videoId] = nil
        defer { pumpQueue() }

        guard case .complete = download.state, let stream = download.stream, let partURL = download.fileURL else {
            if let partURL = download.fileURL { try? FileManager.default.removeItem(at: partURL) }
            if pinRequested.remove(videoId) != nil { failed.insert(videoId) }
            return
        }
        let fileName = "\(videoId).\(stream.fileExtension)"
        let finalURL = AppPaths.media.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: finalURL)
        do {
            try FileManager.default.moveItem(at: partURL, to: finalURL)
        } catch {
            return
        }
        download.fileURL = finalURL
        records[videoId] = MediaRecord(
            videoId: videoId,
            fileName: fileName,
            bytes: download.availableBytes,
            itag: stream.itag,
            mimeType: stream.mimeType,
            bitrate: stream.bitrate,
            loudnessDb: stream.loudnessDb,
            pinned: pinRequested.remove(videoId) != nil,
            addedAt: Date(),
            lastAccess: Date()
        )
        evictIfNeeded()
        scheduleSave()
        tagIfNeeded(videoId)
    }

    // MARK: - Tagging

    /// Tags every explicit download that hasn't been tagged yet (for example after an update).
    func tagPendingDownloads() {
        for record in records.values where record.pinned && record.tagged != true {
            tagIfNeeded(record.videoId)
        }
    }

    /// Gives a downloaded file a readable name and embeds its title, artist, album and cover.
    private func tagIfNeeded(_ videoId: String) {
        guard let record = records[videoId], record.pinned, record.tagged != true,
              !tagging.contains(videoId), let song = songProvider?(videoId)
        else { return }
        tagging.insert(videoId)

        let ext = (record.fileName as NSString).pathExtension
        let source = AppPaths.media.appendingPathComponent(record.fileName)
        var name = WebMTagger.fileName(for: song, extension: ext)
        // Two different songs can share an artist and title; keep both.
        let taken = Set(records.values.filter { $0.videoId != videoId }.map(\.fileName))
        if taken.contains(name) {
            name = (name as NSString).deletingPathExtension + " [\(videoId)]." + ext
        }
        let destination = AppPaths.media.appendingPathComponent(name)
        let artworkURL = song.thumbnail.map { $0.resizedThumbnail(600) }.flatMap(URL.init(string:))

        Task.detached(priority: .utility) { [weak self] in
            var succeeded = false
            if ext == "webm" {
                var artwork: Data?
                if let artworkURL, let (data, response) = try? await URLSession.shared.data(from: artworkURL),
                   (response as? HTTPURLResponse)?.statusCode == 200, data.count > 128 {
                    artwork = data
                }
                let temporary = AppPaths.media.appendingPathComponent(".tagging-\(videoId).\(ext)")
                do {
                    try WebMTagger.tag(source: source, destination: temporary, song: song, artwork: artwork)
                    if source != destination { try? FileManager.default.removeItem(at: destination) }
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                    if source != destination { try? FileManager.default.removeItem(at: source) }
                    succeeded = true
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                }
            } else if source != destination {
                // The rare AAC fallback is only renamed.
                succeeded = (try? FileManager.default.moveItem(at: source, to: destination)) != nil
            }
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.tagging.remove(videoId)
                guard succeeded, var updated = self.records[videoId] else { return }
                updated.fileName = name
                updated.bytes = bytes ?? updated.bytes
                updated.tagged = true
                self.records[videoId] = updated
                self.scheduleSave()
            }
        }
    }

    // MARK: - Downloads

    func download(_ videoIds: [String]) {
        for videoId in videoIds {
            failed.remove(videoId)
            // A music video or live performance keeps its picture too.
            if songProvider?(videoId)?.isMusicVideo == true { VideoDownloads.shared.download(videoId) }
            if var record = records[videoId] {
                if !record.pinned {
                    record.pinned = true
                    record.addedAt = Date()
                    records[videoId] = record
                }
                tagIfNeeded(videoId)
                continue
            }
            guard !pinRequested.contains(videoId), !queued.contains(videoId) else { continue }
            if active[videoId] != nil {
                // Already streaming into the cache: keep it when it finishes.
                pinRequested.insert(videoId)
                progress[videoId] = active[videoId]?.progress ?? 0
            } else {
                queued.append(videoId)
            }
        }
        scheduleSave()
        pumpQueue()
    }

    private func pumpQueue() {
        while !queued.isEmpty, pinRequested.intersection(active.keys).count < Self.maxConcurrentDownloads {
            let videoId = queued.removeFirst()
            guard records[videoId] == nil else { continue }
            pinRequested.insert(videoId)
            progress[videoId] = 0
            if active[videoId] == nil { _ = startDownload(videoId) }
        }
    }

    func removeDownload(_ videoId: String) {
        VideoDownloads.shared.remove(videoId)
        queued.removeAll { $0 == videoId }
        failed.remove(videoId)
        if pinRequested.remove(videoId) != nil {
            progress[videoId] = nil
            if videoId != protectedId { active[videoId]?.cancel() }
        }
        guard let record = records[videoId] else { return }
        if videoId == protectedId {
            // Still playing: demote to the cache instead of deleting the file under the player.
            records[videoId]?.pinned = false
        } else {
            try? FileManager.default.removeItem(at: AppPaths.media.appendingPathComponent(record.fileName))
            records[videoId] = nil
        }
        scheduleSave()
    }

    func clearCache() {
        for record in records.values where !record.pinned && record.videoId != protectedId {
            try? FileManager.default.removeItem(at: AppPaths.media.appendingPathComponent(record.fileName))
            records[record.videoId] = nil
        }
        scheduleSave()
    }

    func evictIfNeeded() {
        let limit = Int64((settings?.maxCacheGB ?? 2) * 1_073_741_824)
        var total = cacheBytes
        guard total > limit else { return }
        let candidates = records.values
            .filter { !$0.pinned && $0.videoId != protectedId }
            .sorted { $0.lastAccess < $1.lastAccess }
        for record in candidates where total > limit {
            try? FileManager.default.removeItem(at: AppPaths.media.appendingPathComponent(record.fileName))
            records[record.videoId] = nil
            total -= record.bytes
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            if let data = try? JSONEncoder().encode(self.records) {
                try? data.write(to: AppPaths.mediaIndex, options: .atomic)
            }
        }
    }
}
