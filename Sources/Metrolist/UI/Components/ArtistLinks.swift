import AppKit
import SwiftUI

/// Artist names where each one is its own link to that artist's page.
struct ArtistLinks: View {
    let artists: [ArtistRef]
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                ArtistLink(artist: artist)
                if index < artists.count - 1 {
                    Text(", ")
                }
            }
        }
        .lineLimit(1)
    }
}

private struct ArtistLink: View {
    let artist: ArtistRef
    @Environment(AppModel.self) private var model
    @ViewState private var hovering = false

    var body: some View {
        Button {
            model.openArtist(artist)
        } label: {
            Text(artist.name)
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help("Go to \(artist.name)")
    }
}

/// Soft colour wash taken from artwork, drawn behind a page header and under the toolbar.
struct ArtworkBackdrop: View {
    let url: String?

    var body: some View {
        ArtworkView(url: url, size: 520, cornerRadius: 0, pixelSize: 120)
            .frame(maxWidth: .infinity)
            .frame(height: 460)
            .scaleEffect(x: 4, y: 1.2)
            .blur(radius: 70)
            .saturation(1.4)
            .opacity(0.45)
            .mask {
                LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Lets a borderless window be dragged by its content.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Applies AppKit-only window behaviour once the hosting window exists.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            if let window = nsView?.window { configure(window) }
        }
    }
}

/// A corner handle that resizes a borderless window while keeping it square.
struct WindowResizeGrip: NSViewRepresentable {
    enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }
    }

    let corner: Corner
    let minSide: CGFloat
    let maxSide: CGFloat

    final class GripView: NSView {
        var corner: Corner = .bottomTrailing
        var minSide: CGFloat = 160
        var maxSide: CGFloat = 900
        private var startFrame = NSRect.zero
        private var startMouse = NSPoint.zero

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            let position: NSCursor.FrameResizePosition = switch corner {
            case .topLeading: .topLeft
            case .topTrailing: .topRight
            case .bottomLeading: .bottomLeft
            case .bottomTrailing: .bottomRight
            }
            addCursorRect(bounds, cursor: .frameResize(position: position, directions: .all))
        }

        override func mouseDown(with event: NSEvent) {
            startFrame = window?.frame ?? .zero
            startMouse = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y // screen coordinates: up is positive
            let growth: CGFloat = switch corner {
            case .bottomTrailing: max(dx, -dy)
            case .bottomLeading: max(-dx, -dy)
            case .topTrailing: max(dx, dy)
            case .topLeading: max(-dx, dy)
            }
            let side = min(max(startFrame.width + growth, minSide), maxSide)
            // The corner opposite the one being dragged stays where it is.
            let x = (corner == .bottomTrailing || corner == .topTrailing) ? startFrame.minX : startFrame.maxX - side
            let y = (corner == .topLeading || corner == .topTrailing) ? startFrame.minY : startFrame.maxY - side
            window.setFrame(NSRect(x: x, y: y, width: side, height: side), display: true)
        }
    }

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.corner = corner
        view.minSide = minSide
        view.maxSide = maxSide
        return view
    }

    func updateNSView(_ nsView: GripView, context: Context) {}
}
