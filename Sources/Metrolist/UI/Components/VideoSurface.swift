import AppKit
import AVFoundation
import SwiftUI

/// Shows `NowPlayingVideo`'s picture. While on screen it asks for the video; its first
/// frame fades in over whatever is behind it (the cover art).
struct VideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }
    func updateNSView(_ view: SurfaceView, context: Context) {}
    static func dismantleNSView(_ view: SurfaceView, coordinator: ()) { view.detach() }

    final class SurfaceView: NSView {
        let playerLayer = AVPlayerLayer()
        private var readiness: NSKeyValueObservation?
        private var attached = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            playerLayer.opacity = 0
            layer?.addSublayer(playerLayer)
            readiness = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async {
                    guard let self else { return }
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(ready ? 0.5 : 0)
                    self.playerLayer.opacity = ready ? 1 : 0
                    CATransaction.commit()
                    NowPlayingVideo.shared.surfaceReady(ready)
                }
            }
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, !attached {
                attached = true
                playerLayer.player = NowPlayingVideo.shared.player
                NowPlayingVideo.shared.attach()
            } else if window == nil {
                detach()
            }
        }

        func detach() {
            guard attached else { return }
            attached = false
            playerLayer.player = nil
            NowPlayingVideo.shared.surfaceReady(false)
            NowPlayingVideo.shared.detach()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
