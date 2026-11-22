import AVKit
import SwiftUI

/// Seek slider with elapsed and total time.
struct Scrubber: View {
    var showsTimes = true
    @Environment(AppModel.self) private var model
    @ViewState private var dragging: Double?

    var body: some View {
        let _ = Diagnostics.hit("Scrubber")
        let player = model.player
        let length = max(player.duration, 1)
        let value = min(dragging ?? player.position, length)
        HStack(spacing: 8) {
            if showsTimes {
                Text(formatDuration(value))
                    .frame(width: 40, alignment: .trailing)
            }
            Slider(
                value: Binding(get: { value }, set: { dragging = $0 }),
                in: 0 ... length
            ) { editing in
                if !editing, let target = dragging {
                    player.seek(to: target)
                    dragging = nil
                }
            }
            .controlSize(.small)
            .disabled(player.currentSong == nil)
            .accessibilityLabel("Playback position")
            if showsTimes {
                Text(formatDuration(player.duration))
                    .frame(width: 40, alignment: .leading)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

/// Icon buttons in the player controls. A plain button only answers inside its glyph, which
/// for these symbols is about 15 × 9 points, and a symbol with an animated transition is
/// drawn by a view of its own that swallows the click altogether. This takes the click on a
/// 30-point target around the glyph instead, and shows the press.
struct IconButtonStyle: ButtonStyle {
    var side: CGFloat = 30
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .allowsHitTesting(false)
            .frame(minWidth: side, minHeight: side)
            .contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? 0.5 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct TransportButtons: View {
    var large = false
    var showModes = true
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: large ? 8 : 2) {
            if showModes {
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.shuffle ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .help("Shuffle")
            }

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: large ? 22 : 15))
            }
            .help("Previous")

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    if player.isBuffering {
                        ProgressView().controlSize(large ? .regular : .small)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: large ? 34 : 21))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: large ? 48 : 32, height: large ? 44 : 30)
            }
            .help(player.isPlaying ? "Pause" : "Play")

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: large ? 22 : 15))
            }
            .disabled(!player.hasNext)
            .help("Next")

            if showModes {
                Button {
                    player.cycleRepeat()
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
                .help("Repeat")
            }
        }
        .buttonStyle(IconButtonStyle(side: large ? 44 : 30))
        .disabled(player.currentSong == nil)
    }
}

struct VolumeControl: View {
    var width: CGFloat = 90
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var player = model.player
        HStack(spacing: 0) {
            Button {
                player.toggleMute()
            } label: {
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : player.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IconButtonStyle())
            .help(player.volume == 0 ? "Unmute" : "Mute")
            .accessibilityLabel(player.volume == 0 ? "Unmute" : "Mute")
            Slider(value: $player.volume, in: 0 ... 1)
                .controlSize(.mini)
                .frame(width: width)
                .accessibilityLabel("Volume")
        }
    }
}

struct LikeButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let liked = model.player.currentSong.map { model.library.isLiked($0.id) } ?? false
        Button {
            model.player.toggleLikeCurrent()
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .foregroundStyle(liked ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IconButtonStyle())
        .disabled(model.player.currentSong == nil)
        .help(liked ? "Remove from Liked Songs" : "Add to Liked Songs")
    }
}

/// The floating Liquid Glass transport bar at the bottom of the main window. It sheds
/// secondary controls as the window narrows instead of running off the edge.
struct PlayerBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private enum Density { case full, medium, compact, minimal }

    /// Width available to the bar, measured from a spacer that never changes with playback.
    @ViewState private var available: CGFloat = 900

    private var density: Density {
        switch available {
        case 900...: .full
        case 680...: .medium
        case 500...: .compact
        default: .minimal
        }
    }

    var body: some View {
        let _ = Diagnostics.hit("PlayerBar")
        VStack(spacing: 0) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
            bar(density)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    private func bar(_ density: Density) -> some View {
        let player = model.player
        let tight = density == .compact || density == .minimal
        return HStack(spacing: tight ? 10 : 14) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy) { model.showExpandedPlayer = true }
                } label: {
                    ArtworkView(url: player.currentSong?.thumbnail, size: 44, cornerRadius: 8)
                }
                .buttonStyle(.plain)
                .help("Open Full Screen Player")

                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        if let song = player.currentSong { model.openAlbum(for: song) }
                    } label: {
                        Text(player.currentSong?.title ?? "Not Playing")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .id(player.currentSong?.id)
                            .transition(.blurReplace)
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.8), value: player.currentSong?.id)
                    .pointerStyle(.link)
                    .disabled(player.currentSong == nil)
                    .help(player.currentSong?.album.map { "Go to \($0.name)" } ?? "Go to album")

                    ArtistLinks(artists: player.currentSong?.artists ?? [])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    if let song = player.currentSong { SongMenu(song: song) }
                }

                if density != .minimal { LikeButton() }
            }
            .frame(
                minWidth: tight ? 100 : 170,
                idealWidth: density == .full ? 240 : (density == .medium ? 200 : (density == .compact ? 130 : 100)),
                maxWidth: 280
            )

            VStack(spacing: 2) {
                TransportButtons(showModes: !tight)
                Scrubber(showsTimes: !tight)
            }
            .frame(
                minWidth: tight ? 110 : 240,
                idealWidth: density == .full ? 420 : (density == .medium ? 300 : (density == .compact ? 140 : 110)),
                maxWidth: 520
            )
            .layoutPriority(1)

            if density != .minimal {
            HStack(spacing: 0) {
                if density == .full { VolumeControl().padding(.trailing, 6) }
                OutputButton()
                AutoMixButton()
                Button {
                    model.toggleInspector(.lyrics)
                } label: {
                    Image(systemName: "quote.bubble")
                        .foregroundStyle(model.showInspector && model.inspectorTab == .lyrics ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .help("Lyrics")
                Button {
                    model.path = []
                    model.sidebar = .sharedQueue
                } label: {
                    // Lit while this Mac shares its queue or has joined someone else's.
                    Image(systemName: "person.2.wave.2")
                        .foregroundStyle(DeviceConnect.guests.enabled || SharedQueueClient.shared.joined ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .help(DeviceConnect.guests.enabled ? "Shared Queue: on, \(DeviceConnect.guests.connected.count) guest\(DeviceConnect.guests.connected.count == 1 ? "" : "s") connected"
                      : SharedQueueClient.shared.joined ? "Shared Queue: joined \(SharedQueueClient.shared.hostName)" : "Shared Queue")
                Button {
                    model.toggleInspector(.queue)
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(model.showInspector && model.inspectorTab == .queue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .help("Up Next")
                if !tight {
                    Button {
                        openWindow(id: "mini")
                        dismissWindow(id: "main")
                    } label: {
                        Image(systemName: "pip.enter")
                            .foregroundStyle(.secondary)
                    }
                    .help("Switch to Mini Player")
                }
            }
            .buttonStyle(IconButtonStyle())
            .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// Chooses where sound comes out: any output Core Audio lists, including AirPlay speakers once
/// macOS has connected them. The mix is still made by this app, so AutoMix works on any of them.
struct OutputButton: View {
    @Bindable private var outputs = OutputDevices.shared
    @ViewState private var showing = false

    var body: some View {
        Button {
            outputs.refresh()
            showing.toggle()
        } label: {
            Image(systemName: outputs.selected?.symbol ?? "hifispeaker.2")
                .foregroundStyle(outputs.selected == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .help(outputs.selected.map { "Playing through \($0.name)" } ?? "Choose where sound plays")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Play through").font(.headline).padding(.bottom, 4)
                row(title: systemDefaultTitle, symbol: "macbook.and.iphone", chosen: outputs.selectedUID == nil) { outputs.select(nil) }
                ForEach(outputs.devices) { device in
                    row(title: device.name, symbol: device.symbol, chosen: device.uid == outputs.selectedUID) { outputs.select(device) }
                }
                Divider().padding(.vertical, 4)
                HStack {
                    Text("AirPlay speakers and TVs")
                    Spacer()
                    RoutePicker().frame(width: 28, height: 24)
                }
                Text("Pick one with the AirPlay button; once macOS has connected, it appears in the list above.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
            }
            .padding(14)
            .frame(minWidth: 280)
        }
    }

    /// "System Default", with the output it currently means, so it is clear where sound goes.
    private var systemDefaultTitle: String {
        guard let id = OutputDevices.playbackDevice(chosen: nil), let name = outputs.devices.first(where: { $0.id == id })?.name else { return "System Default" }
        return "System Default (\(name))"
    }

    private func row(title: String, symbol: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: symbol).frame(width: 22)
                Text(title).lineLimit(1)
                Spacer()
                if chosen { Image(systemName: "checkmark") }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}

/// The system's AirPlay picker.
struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
