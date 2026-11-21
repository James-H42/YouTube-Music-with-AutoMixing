import Foundation
import Observation

/// One saved music-video picture.
struct VideoRecord: Codable, Equatable {
    var videoId: String
    var fileName: String
    var bytes: Int64
    var width: Int
    var height: Int
    var codecs: String
    var addedAt: Date
    var quality: Int { VideoQuality.label(width: width, height: height) }
}

/// The pictures of music videos and live performances saved for offline playback. Their
/// sound is downloaded by `MediaStore` like any song's, so AutoMix's analysis, the equaliser
/// and the audio engine work the same offline; this keeps the picture beside it, in the best
/// quality YouTube offers that this Mac plays.
///
/// Files are fetched the way the audio is: through the same playback identity the stream
/// came from, in bounded byte ranges of the size that identity's own app asks for, one video
/// at a time and with pauses after failures. That is what keeps the downloads looking like
/// ordinary playback rather than bulk fetching.
@MainActor
@Observable
final class VideoDownloads {
    static let shared = VideoDownloads()

    private(set) var records: [String: VideoRecord] = [:]
    /// Videos waiting or downloading, with their progress (0…1).
    private(set) var progress: [String: Double] = [:]
    private(set) var failed: Set<String> = []
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var running: (id: String, task: Task<Void, Never>)?

    init() {
        if let data = try? Data(contentsOf: AppPaths.videoIndex),
           let saved = try? JSONDecoder().decode([String: VideoRecord].self, from: data) {
            records = saved.filter { FileManager.default.fileExists(atPath: AppPaths.videos.appendingPathComponent($0.value.fileName).path) }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.videos, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func isDownloaded(_ videoId: String) -> Bool { records[videoId] != nil }
    /// Size of the saved pictures, in bytes.
    var bytes: Int64 { records.values.reduce(0) { $0 + $1.bytes } }
    func isDownloading(_ videoId: String) -> Bool { progress[videoId] != nil }
    var activeCount: Int { progress.count }

    func fileURL(_ videoId: String) -> URL? {
        records[videoId].map { AppPaths.videos.appendingPathComponent($0.fileName) }
    }

    func download(_ videoId: String) {
        guard records[videoId] == nil, progress[videoId] == nil else { return }
        failed.remove(videoId)
        progress[videoId] = 0
        queue.append(videoId)
        pump()
    }

    func remove(_ videoId: String) {
        queue.removeAll { $0 == videoId }
        if running?.id == videoId { running?.task.cancel() }
        progress[videoId] = nil
        failed.remove(videoId)
        guard let record = records.removeValue(forKey: videoId) else { return }
        try? FileManager.default.removeItem(at: AppPaths.videos.appendingPathComponent(record.fileName))
        save()
    }

    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        let task = Task { [weak self] in
            let result = await Self.fetch(id) { value in
                Task { @MainActor in if self?.progress[id] != nil { self?.progress[id] = value } }
            }
            guard let self else { return }
            self.running = nil
            let wanted = self.progress.removeValue(forKey: id) != nil
            switch result {
            case .success(let record) where wanted:
                self.records[id] = record
                self.save()
            case .success(let record):
                try? FileManager.default.removeItem(at: AppPaths.videos.appendingPathComponent(record.fileName))
            case .failure(let error):
                if wanted, !(error is CancellationError) {
                    self.failed.insert(id)
                    MixLog.write("video download failed for \(id): \(error)")
                }
            }
            self.pump()
        }
        running = (id, task)
    }

    /// Saves the best picture file of one video, in ranges, re-asking for an address once
    /// the old one expires or is refused.
    nonisolated private static func fetch(_ videoId: String, progress: @escaping @Sendable (Double) -> Void) async -> Result<VideoRecord, Error> {
        do {
            var source = try await VideoStreamResolver.shared.resolve(videoId: videoId)
            guard var file = source.bestFile else { throw YTError.noStream }
            let clientId = source.clientId
            let chunk = Int64(YouTubeClient.playbackClients.first { $0.id == clientId }?.rangeChunkSize ?? 1_048_576)
            let fileName = "\(videoId).\(file.quality)p.mp4"
            let part = AppPaths.videos.appendingPathComponent(fileName + ".part")
            FileManager.default.createFile(atPath: part.path, contents: nil)
            let writer = try FileHandle(forWritingTo: part)
            defer { try? writer.close() }
            let client = MediaHTTPClient()
            defer { client.close() }
            var url = file.url
            var offset: Int64 = 0
            var total: Int64? = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "clen" }?.value.flatMap { Int64($0) }
            var failures = 0
            do {
                while true {
                    try Task.checkCancellation()
                    if let total, offset >= total { break }
                    var end = offset + chunk - 1
                    if let total { end = min(end, total - 1) }
                    do {
                        let response = try await client.fetch(url, range: offset ... end, userAgent: source.userAgent)
                        guard response.status == 200 || response.status == 206, !response.body.isEmpty else { throw YTError.http(response.status) }
                        url = response.url
                        if total == nil {
                            if response.status == 200 {
                                total = Int64(response.body.count)
                            } else if let size = response.headers["content-range"]?.split(separator: "/").last.flatMap({ Int64($0) }) {
                                total = size
                            } else if response.body.count < chunk {
                                total = offset + Int64(response.body.count)
                            }
                        }
                        try writer.write(contentsOf: response.body)
                        offset += Int64(response.body.count)
                        failures = 0
                        if let total, total > 0 { progress(Double(offset) / Double(total)) }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failures += 1
                        if failures > 4 { throw error }
                        if case YTError.http(let status) = error, [403, 404, 410].contains(status) {
                            await VideoStreamResolver.shared.forget(videoId)
                            source = try await VideoStreamResolver.shared.resolve(videoId: videoId)
                            guard let same = source.renditions.first(where: { $0.kind == .mp4 && $0.itag == file.itag }) else { throw error }
                            file = same
                            url = same.url
                        }
                        try await Task.sleep(for: .milliseconds(800 * failures))
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: part)
                throw error
            }
            let final = AppPaths.videos.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: part, to: final)
            return .success(VideoRecord(videoId: videoId, fileName: fileName, bytes: offset, width: file.width, height: file.height, codecs: file.codecs, addedAt: Date()))
        } catch {
            return .failure(error)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: AppPaths.videoIndex, options: .atomic)
        }
    }
}
