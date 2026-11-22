import SwiftUI

/// Borderless floating window showing the album cover; hovering reveals Liquid Glass controls.
/// It can be dragged anywhere by the cover and resized from any edge, staying square.
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @ViewState private var hovering = false

    static let minSide: CGFloat = 160
    static let maxSide: CGFloat = 900

    var body: some View {
        let player = model.player
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let compact = side < 250
            let corner = max(16, side * 0.085)
            ZStack {
                ArtworkView(url: player.currentSong?.thumbnail, size: side, cornerRadius: 0, pixelSize: 1000)
                WindowDragArea()

                if hovering || player.currentSong == nil {
                    VStack(spacing: 0) {
                        HStack {
                            Button {
                                openWindow(id: "main")
                                dismissWindow(id: "mini")
                                NSApp.activate()
                            } label: {
                                Image(systemName: "pip.exit")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(IconButtonStyle())
                            .glassEffect(.regular.interactive(), in: .circle)
                            .help("Return to Metrolist+")

                            Spacer()

                            Button {
                                dismissWindow(id: "mini")
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(IconButtonStyle())
                            .glassEffect(.regular.interactive(), in: .circle)
                            .help("Close Mini Player")
                        }
                        .padding(.horizontal, 38)
                        .padding(.top, 10)

                        Spacer()

                        VStack(spacing: 8) {
                            if !compact {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(player.currentSong?.title ?? "Not Playing")
                                            .font(.callout.weight(.semibold))
                                            .lineLimit(1)
                                        Text(player.currentSong?.artistText ?? "Choose something to play")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    AutoMixButton(size: 13)
                                    LikeButton()
                                }
                                Scrubber(showsTimes: false)
                            }
                            TransportButtons(showModes: !compact)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, compact ? 8 : 12)
                        .frame(maxWidth: 420)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                        .padding(10)
                    }
                    .transition(.opacity)
                }

                // Drag any corner to resize; the window stays square so the cover is never cropped.
                ForEach(WindowResizeGrip.Corner.allCases, id: \.self) { corner in
                    WindowResizeGrip(corner: corner, minSide: Self.minSide, maxSide: Self.maxSide)
                        .frame(width: 34, height: 34)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                }
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: corner, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: Self.minSide, idealWidth: 300, maxWidth: Self.maxSide,
            minHeight: Self.minSide, idealHeight: 300, maxHeight: Self.maxSide
        )
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.2)) { hovering = inside }
        }
        .contextMenu {
            if let song = player.currentSong { SongMenu(song: song) }
        }
        .background {
            WindowConfigurator { window in
                window.isMovableByWindowBackground = true
                window.contentAspectRatio = NSSize(width: 1, height: 1)
                // Keep it square even if something else changed the frame.
                if abs(window.frame.width - window.frame.height) > 1 {
                    let side = min(max(window.frame.width, Self.minSide), Self.maxSide)
                    window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - side, width: side, height: side), display: true)
                }
                window.contentMinSize = NSSize(width: Self.minSide, height: Self.minSide)
                window.contentMaxSize = NSSize(width: Self.maxSide, height: Self.maxSide)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
            }
        }
    }
}

/// Popover shown from the app's menu bar item.
struct MenuBarPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let player = model.player
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(url: player.currentSong?.thumbnail, size: 64, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentSong?.title ?? "Not Playing")
                        .font(.headline)
                        .lineLimit(2)
                    Text(player.currentSong?.artistText ?? "Open Metrolist+ to choose music")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                LikeButton()
            }
            Scrubber()
            TransportButtons()
            VolumeControl(width: 180)

            if let line = currentLyric {
                Text(line)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }

            Divider()
            HStack {
                Button("Open Metrolist+") {
                    dismissWindow(id: "mini")
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Button("Mini Player") {
                    openWindow(id: "mini")
                    dismissWindow(id: "main")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 320)
    }

    /// The lyric line being sung right now, refreshed with the coarse position.
    private var currentLyric: String? {
        guard let lyrics = model.player.lyrics, lyrics.isSynced else { return nil }
        let time = model.player.position - lyrics.offset
        return lyrics.lines.last { !$0.isBackground && $0.start <= time }?.text
    }
}
