import AppKit
import SwiftUI

/// The full-screen player while a music video or live performance plays with its picture:
/// the video fills the player edge to edge (never cropped or covered for long), with
/// controls floating over its lower edge that fade away while it plays untouched, as in
/// Apple Music and QuickTime Player. Lyrics or Up Next can open beside it, and the window
/// can enter macOS's own full screen.
struct VideoStageView: View {
    @Binding var showQueue: Bool
    @Environment(AppModel.self) private var model
    @ViewState private var controlsShown = true
    @ViewState private var lastActivity = Date()
    @ViewState private var overControls = false
    @ViewState private var window: NSWindow?
    @ViewState private var isFullScreen = false

    /// Whether this player put the window into full screen (so closing it leaves full screen).
    @MainActor static var enteredFullScreen = false
    static let idleDelay: TimeInterval = 3

    var body: some View {
        let player = model.player
        let showLyrics = model.settings.fullScreenLyrics && !showQueue
        let panel = showLyrics || showQueue
        let video = NowPlayingVideo.shared
        let visible = controlsShown || !player.isPlaying
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ZStack {
                    Color.black
                    // The video's thumbnail until its first frame is on screen.
                    if !video.isShowing {
                        FillImage(url: player.currentSong?.thumbnail)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .transition(.opacity)
                    }
                    VideoSurface()
                    if video.failure != nil, !video.isShowing {
                        Label("The video couldn't be loaded", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .padding(10)
                            .glassEffect(.regular, in: .rect(cornerRadius: 10))
                    }
                }
                .contentShape(.rect)
                .onTapGesture(count: 2) { toggleFullScreen() }
                .overlay(alignment: .bottom) {
                    ZStack(alignment: .bottom) {
                        // Keeps the controls readable over a bright picture.
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 220)
                            .allowsHitTesting(false)
                        VideoControls(showQueue: $showQueue, isFullScreen: isFullScreen, toggleFullScreen: toggleFullScreen)
                            .frame(maxWidth: 760)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 26)
                            .onHover { overControls = $0; poke() }
                    }
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                }
                .overlay(alignment: .topLeading) {
                    Button {
                        if isFullScreen { toggleFullScreen() } else { close() }
                    } label: {
                        Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(IconButtonStyle(side: 34))
                    .glassEffect(.regular.interactive(), in: .circle)
                    .keyboardShortcut(.cancelAction)
                    .help(isFullScreen ? "Exit Full Screen" : "Close")
                    .padding(.leading, 20)
                    // Below the window's close, minimise and zoom buttons; in full screen
                    // there are none.
                    .padding(.top, isFullScreen ? 20 : 44)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                }

                if panel {
                    Group {
                        if showQueue {
                            QueueView()
                                .padding(.vertical, 60)
                        } else {
                            VStack(spacing: 0) {
                                LyricsView(fontSize: min(30, max(22, geometry.size.width / 50)))
                                LyricsFooter()
                            }
                            .padding(.top, 40)
                        }
                    }
                    .frame(width: min(420, geometry.size.width * 0.34))
                    .frame(maxHeight: .infinity)
                    .background(.black.opacity(0.35))
                    .background(.ultraThinMaterial)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: visible)
        .animation(.easeInOut(duration: 0.4), value: video.isShowing)
        .background(Color.black)
        .background { WindowReader(window: $window) }
        .background { TitlebarFader(hidden: !visible) }
        .onContinuousHover { phase in
            if case .active = phase { poke() }
        }
        .task {
            // Fades the controls (and the pointer) after a few seconds without movement.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if controlsShown, player.isPlaying, !overControls, Date().timeIntervalSince(lastActivity) > Self.idleDelay {
                    controlsShown = false
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
        .onChange(of: window) { _, window in isFullScreen = window?.styleMask.contains(.fullScreen) == true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if (note.object as? NSWindow) === window { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if (note.object as? NSWindow) === window {
                isFullScreen = false
                Self.enteredFullScreen = false
            }
        }
        .onDisappear {
            // Closing the player leaves the full screen it entered; switching to the cover
            // (the player stays open) doesn't.
            if !model.showExpandedPlayer { Self.leaveFullScreen(window) }
        }
    }

    private func poke() {
        lastActivity = Date()
        if !controlsShown { controlsShown = true }
    }

    private func close() {
        withAnimation(.snappy) { model.showExpandedPlayer = false }
    }

    private func toggleFullScreen() {
        guard let window = window ?? NSApp.keyWindow else { return }
        if !window.styleMask.contains(.fullScreen) { Self.enteredFullScreen = true }
        window.toggleFullScreen(nil)
        poke()
    }

    static func leaveFullScreen(_ window: NSWindow?) {
        guard enteredFullScreen, let window, window.styleMask.contains(.fullScreen) else { return }
        enteredFullScreen = false
        window.toggleFullScreen(nil)
    }
}

/// The floating controls over a playing video.
private struct VideoControls: View {
    @Binding var showQueue: Bool
    let isFullScreen: Bool
    let toggleFullScreen: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let showLyrics = model.settings.fullScreenLyrics && !showQueue
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentSong?.title ?? "Not Playing")
                        .font(.headline)
                        .lineLimit(1)
                    ArtistLinks(artists: player.currentSong?.artists ?? [])
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                LikeButton()
                    .buttonStyle(IconButtonStyle(side: 28))
            }
            Scrubber()
            HStack(spacing: 14) {
                VolumeControl(width: 90)
                    .frame(width: 140, alignment: .leading)
                Spacer(minLength: 0)
                TransportButtons(large: false)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    VideoQualityMenu()
                    Button {
                        withAnimation(.snappy) {
                            if showQueue {
                                showQueue = false
                                model.settings.fullScreenLyrics = true
                            } else {
                                model.settings.fullScreenLyrics.toggle()
                            }
                        }
                    } label: {
                        Image(systemName: "quote.bubble")
                            .foregroundStyle(showLyrics ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    .help(showLyrics ? "Hide Lyrics" : "Show Lyrics")
                    Button {
                        withAnimation(.snappy) { showQueue.toggle() }
                    } label: {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(showQueue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    .help(showQueue ? "Hide Up Next" : "Show Up Next")
                    Button {
                        withAnimation(.snappy) { model.settings.showVideos = false }
                    } label: {
                        Image(systemName: "film").foregroundStyle(.tint)
                    }
                    .help("Show the Cover Instead of the Video")
                    Button(action: toggleFullScreen) {
                        Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .foregroundStyle(.secondary)
                    }
                    .help(isFullScreen ? "Exit Full Screen" : "Enter Full Screen")
                }
                .buttonStyle(IconButtonStyle(side: 28))
                .frame(width: 140 + 60, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// Chooses the picture quality: Auto, or one of the qualities this video has. The choice
/// is kept for later videos (the nearest quality at or below it is used).
struct VideoQualityMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let video = NowPlayingVideo.shared
        let chosen = model.settings.videoQuality
        Menu {
            Picker("Quality", selection: Bindable(model.settings).videoQuality) {
                Text(video.showingQuality.map { chosen == VideoQuality.auto ? "Auto (\($0)p)" : "Auto" } ?? "Auto").tag(VideoQuality.auto)
                ForEach(video.qualities, id: \.self) { Text(VideoQuality.title($0)).tag($0) }
            }
            .pickerStyle(.inline)
            if video.qualities.isEmpty {
                Text("Loading qualities…")
            }
        } label: {
            Text(badge(video.showingQuality))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, minHeight: 28)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Video Quality")
    }

    private func badge(_ quality: Int?) -> String {
        guard let quality else { return "AUTO" }
        switch quality {
        case 4320...: return "8K"
        case 2160...: return "4K"
        default: return "\(quality)p"
        }
    }
}

/// Hands the hosting window to SwiftUI.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView { Probe(window: $window) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        private let target: Binding<NSWindow?>
        init(window: Binding<NSWindow?>) {
            target = window
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let found = window
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === found else { return }
                if self.target.wrappedValue !== found { self.target.wrappedValue = found }
            }
        }
    }
}

/// While the controls are hidden, fades the window's title bar (its close, minimise and zoom
/// buttons) too, as QuickTime Player does. Only its transparency changes, never its size, so
/// macOS window tiling isn't disturbed.
private struct TitlebarFader: NSViewRepresentable {
    let hidden: Bool
    func makeNSView(context: Context) -> FaderView { FaderView() }
    func updateNSView(_ view: FaderView, context: Context) { view.setHidden(hidden) }
    static func dismantleNSView(_ view: FaderView, coordinator: ()) { view.setHidden(false) }

    final class FaderView: NSView {
        private weak var titlebar: NSView?

        func setHidden(_ hidden: Bool) {
            if titlebar == nil { titlebar = window?.standardWindowButton(.closeButton)?.superview?.superview }
            guard let titlebar else { return }
            let alpha: CGFloat = hidden ? 0 : 1
            guard titlebar.alphaValue != alpha else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                titlebar.animator().alphaValue = alpha
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { titlebar?.alphaValue = 1 }
        }
    }
}
