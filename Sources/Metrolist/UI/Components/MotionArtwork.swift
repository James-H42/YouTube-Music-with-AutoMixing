import AppKit
import AVFoundation
import SwiftUI
import Vision

/// A silent, endlessly looping video (Apple Music's motion artwork). It stays invisible until
/// its first frame is ready, so whatever is behind it (the still artwork) shows until then.
/// With Reduce Motion on, nothing plays and the still artwork stays.
struct LoopingVideoView: NSViewRepresentable {
    let url: URL
    var fill = true
    /// Called on the main thread once the first frame can be shown.
    var onReady: () -> Void = {}

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.onReady = onReady
        view.load(url, fill: fill)
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.onReady = onReady
        if view.url != url { view.load(url, fill: fill) }
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.stop() }

    final class PlayerView: NSView {
        private let player = AVPlayer()
        private let playerLayer = AVPlayerLayer()
        private var looper: NSObjectProtocol?
        private var readiness: NSKeyValueObservation?
        private(set) var url: URL?
        var onReady: () -> Void = {}

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            player.isMuted = true
            player.allowsExternalPlayback = false
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.actionAtItemEnd = .none
            playerLayer.player = player
            playerLayer.opacity = 0
            layer?.addSublayer(playerLayer)
            readiness = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.6)
                    self.playerLayer.opacity = 1
                    CATransaction.commit()
                    self.onReady()
                }
            }
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        func load(_ url: URL, fill: Bool) {
            self.url = url
            playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
            playerLayer.opacity = 0
            if let looper { NotificationCenter.default.removeObserver(looper) }
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let item = AVPlayerItem(url: url)
            // Artwork never needs more than a large screen's worth of pixels.
            item.preferredMaximumResolution = CGSize(width: 2160, height: 2160)
            player.replaceCurrentItem(with: item)
            looper = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                self?.player.seek(to: .zero)
                self?.player.play()
            }
            player.play()
        }

        func stop() {
            player.pause()
            player.replaceCurrentItem(with: nil)
            if let looper { NotificationCenter.default.removeObserver(looper) }
            looper = nil
        }

        deinit {
            if let looper { NotificationCenter.default.removeObserver(looper) }
        }
    }
}

/// An image from an address that fills whatever frame it is given (cropped, not squashed).
///
/// With `findFaces`, the crop is placed around the faces in the picture (found on this Mac
/// with Vision), so a square portrait shown in a wide banner keeps the faces in view instead
/// of a forehead or a shirt; without faces, just above the middle. Otherwise `alignment`
/// decides.
struct FillImage: View {
    let url: String?
    /// Where the crop keeps the picture: faces are usually in the upper part of a portrait.
    var alignment: Alignment = .center
    var findFaces = false

    @ViewState private var image: NSImage?
    /// The point to keep in view, as fractions of the picture's width and height from its
    /// top left corner.
    @ViewState private var focus: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.quaternary)
                if let image {
                    let frame = Self.placement(of: image.size, in: geometry.size, focus: focus, alignment: alignment)
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
        .task(id: url) {
            guard let url else { image = nil; focus = nil; return }
            let loaded: NSImage?
            if let cached = ImageLoader.shared.cachedImage(for: url) { loaded = cached } else { loaded = await ImageLoader.shared.image(for: url) }
            var found: CGPoint?
            // No face found (an illustration, a logo, a face turned away): the subject of a
            // portrait is usually just above the middle.
            if findFaces, let loaded { found = await Self.faceCentre(in: loaded) ?? CGPoint(x: 0.5, y: 0.45) }
            withAnimation(.easeInOut(duration: 0.4)) {
                focus = found
                image = loaded
            }
        }
    }

    /// Where the scaled picture goes so it covers `area`: centred on `focus` when there is
    /// one (as far as the picture's edges allow), else placed by `alignment`.
    static func placement(of picture: CGSize, in area: CGSize, focus: CGPoint?, alignment: Alignment) -> CGRect {
        guard picture.width > 0, picture.height > 0 else { return CGRect(origin: .zero, size: area) }
        let scale = max(area.width / picture.width, area.height / picture.height)
        let size = CGSize(width: picture.width * scale, height: picture.height * scale)
        let spare = CGSize(width: size.width - area.width, height: size.height - area.height)
        func clamp(_ value: CGFloat, _ limit: CGFloat) -> CGFloat { min(0, max(-limit, value)) }
        let x: CGFloat, y: CGFloat
        if let focus {
            x = clamp(area.width / 2 - focus.x * size.width, spare.width)
            y = clamp(area.height / 2 - focus.y * size.height, spare.height)
        } else {
            let horizontal: CGFloat = alignment.horizontal == .leading ? 0 : alignment.horizontal == .trailing ? 1 : 0.5
            let vertical: CGFloat = alignment.vertical == .top ? 0 : alignment.vertical == .bottom ? 1 : 0.5
            x = -spare.width * horizontal
            y = -spare.height * vertical
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The middle of the faces in a picture (fractions from the top left), or nil if there
    /// are none. Faces of a band are all kept in view as far as the frame allows.
    static func faceCentre(in image: NSImage) async -> CGPoint? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await Task.detached(priority: .utility) { () -> CGPoint? in
            let request = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: cgImage).perform([request])
            // Small faces are background people or posters; keep the main ones.
            let faces = (request.results ?? []).map(\.boundingBox)
            guard let largest = faces.map({ $0.width * $0.height }).max() else { return nil }
            let main = faces.filter { $0.width * $0.height >= largest * 0.25 }
            let union = main.dropFirst().reduce(main[0]) { $0.union($1) }
            // Vision measures from the bottom left; a little room above the faces for hair.
            return CGPoint(x: union.midX, y: 1 - union.midY - union.height * 0.1)
        }.value
    }
}
