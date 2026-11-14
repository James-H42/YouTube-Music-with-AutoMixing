import AppKit
import CryptoKit
import SwiftUI

/// Loads artwork with a memory cache backed by a persistent disk cache, so covers for
/// downloaded music remain visible offline.
actor ImageLoader {
    static let shared = ImageLoader()

    private nonisolated(unsafe) let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        memory.countLimit = 600
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    private nonisolated func diskURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return AppPaths.artwork.appendingPathComponent(digest)
    }

    nonisolated func cachedImage(for url: String) -> NSImage? {
        memory.object(forKey: url as NSString)
    }

    func image(for url: String) async -> NSImage? {
        if let cached = memory.object(forKey: url as NSString) { return cached }
        if let task = inFlight[url] { return await task.value }
        let task = Task<NSImage?, Never> { [session] in
            let file = diskURL(for: url)
            if let data = try? Data(contentsOf: file), let image = NSImage(data: data) { return image }
            guard let remote = URL(string: url),
                  let (data, response) = try? await session.data(from: remote),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data)
            else { return nil }
            try? data.write(to: file, options: .atomic)
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSString) }
        return image
    }
}

/// Square (or circular) artwork with a placeholder while loading.
struct ArtworkView: View {
    let url: String?
    var size: CGFloat
    var cornerRadius: CGFloat = 6
    var circular = false
    /// Pixel size requested from the image CDN; defaults to twice the point size.
    var pixelSize: Int?

    @ViewState private var image: NSImage?

    private var resolvedURL: String? {
        url?.resizedThumbnail(pixelSize ?? Int(min(size, 600) * 2))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: circular ? "person.fill" : "music.note")
                    .font(.system(size: size * 0.32))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        .task(id: resolvedURL) {
            guard let resolvedURL else {
                image = nil
                return
            }
            if let cached = ImageLoader.shared.cachedImage(for: resolvedURL) {
                image = cached
                return
            }
            image = await ImageLoader.shared.image(for: resolvedURL)
        }
    }
}
