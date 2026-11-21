import SwiftUI

struct QueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if player.queue.isEmpty {
            ContentUnavailableView("Queue Is Empty", systemImage: "list.bullet", description: Text("Play something to fill your queue."))
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { index, song in
                        QueueRow(song: song, index: index)
                            .id(index)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                        if index == player.currentIndex {
                            // How AutoMix will get from this track to the next.
                            TransitionRow()
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                                .moveDisabled(true)
                        }
                    }
                    .onMove { source, destination in
                        if let first = source.first { player.moveInQueue(from: first, to: destination) }
                    }
                    if player.radioSeed != nil {
                        Label("Radio: similar songs keep coming", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    } else if model.settings.autoplay, player.repeatMode == .off {
                        Label("Autoplay adds similar songs when the queue ends", systemImage: "infinity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear {
                    if let current = player.currentIndex { proxy.scrollTo(current, anchor: .top) }
                }
            }
        }
    }
}

private struct QueueRow: View {
    let song: Song
    let index: Int
    @Environment(AppModel.self) private var model
    @ViewState private var hovering = false

    var body: some View {
        let player = model.player
        let isCurrent = player.currentIndex == index
        HStack(spacing: 10) {
            ArtworkView(url: song.thumbnail, size: 36, cornerRadius: 5)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.45))
                        PlayingIndicator(animating: player.isPlaying).foregroundStyle(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Text(song.artistText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let guest = SharedQueue.shared.addedByName(song.id) {
                    Label("Added by \(guest)", systemImage: "person.2.wave.2")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if hovering, !isCurrent {
                Button {
                    player.removeFromQueue(at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(IconButtonStyle(side: 22))
                .help("Remove from Queue")
            } else {
                Text(song.duration.map { formatDuration(Double($0)) } ?? "")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        .opacity(index < (player.currentIndex ?? 0) ? 0.5 : 1)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { player.jump(to: index) }
        .contextMenu {
            Button("Play Now", systemImage: "play") { player.jump(to: index) }
            if !isCurrent {
                Button("Remove from Queue", systemImage: "minus.circle") { player.removeFromQueue(at: index) }
            }
            Divider()
            SongMenu(song: song)
        }
    }
}

/// Footer under the lyrics: provider credit and sync adjustment.
struct LyricsFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let lyrics = model.player.lyrics {
            HStack(spacing: 8) {
                Text(lyrics.provider)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if lyrics.isSynced {
                    Button {
                        model.player.adjustLyricsOffset(by: -0.1)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help("Show lyrics earlier")
                    Button {
                        model.player.adjustLyricsOffset(by: 0)
                    } label: {
                        Text(lyrics.offset == 0 ? "Sync" : String(format: "%+.1fs", lyrics.offset))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(minWidth: 38)
                    }
                    .help("Reset lyrics timing")
                    Button {
                        model.player.adjustLyricsOffset(by: 0.1)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Show lyrics later")
                }
                Menu {
                    Button("Search Lyrics…", systemImage: "magnifyingglass") { model.showLyricsSearch = true }
                    Button("Edit Lyrics and Timing…", systemImage: "pencil") { model.showLyricsEditor = true }
                    Divider()
                    Button("Search Again", systemImage: "arrow.clockwise") { model.player.reloadLyrics() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose another lyrics source, or edit these lyrics")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

/// Trailing sidebar with lyrics and the queue.
struct NowPlayingInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("View", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            switch model.inspectorTab {
            case .lyrics:
                LyricsView(fontSize: 21)
                    .frame(maxHeight: .infinity)
                LyricsFooter()
            case .queue:
                QueueModeBar()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                HStack {
                    Text("\(model.player.upcoming.count) upcoming")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.player.clearUpcoming() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(model.player.upcoming.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                QueueView()
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

/// Immersive player on a backdrop drawn from the cover. The artwork is centred by default;
/// lyrics or the queue can be opened beside it.
struct ExpandedPlayerView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var showQueue = false

    var body: some View {
        let isVideo = model.player.currentSong?.isMusicVideo == true
        let showVideo = isVideo && model.settings.showVideos
        if showVideo {
            VideoStageView(showQueue: $showQueue)
                .environment(\.colorScheme, .dark)
                .ignoresSafeArea()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            coverPlayer(isVideo: isVideo)
        }
    }

    private func coverPlayer(isVideo: Bool) -> some View {
        let player = model.player
        let showLyrics = model.settings.fullScreenLyrics && !showQueue
        let split = showLyrics || showQueue
        return GeometryReader { geometry in
            let artSize = split
                ? min(geometry.size.width * 0.34, geometry.size.height * 0.5, 440)
                : min(geometry.size.width * 0.5, geometry.size.height * 0.54, 560)
            ZStack {
                ArtworkView(url: player.currentSong?.thumbnail, size: max(geometry.size.width, geometry.size.height), cornerRadius: 0, pixelSize: 240)
                    .blur(radius: 90, opaque: true)
                    .overlay(.black.opacity(0.55))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    // Nothing of the page shows through, even before the artwork loads.
                    .background(Color.black)

                HStack(spacing: 0) {
                    VStack(spacing: 18) {
                        Spacer(minLength: 0)
                        ArtworkView(url: player.currentSong?.thumbnail, size: artSize, cornerRadius: 16, pixelSize: 1000)
                            .id(player.currentSong?.thumbnail)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            .animation(.easeInOut(duration: 0.9), value: player.currentSong?.thumbnail)
                            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                            .scaleEffect(player.isPlaying ? 1 : 0.92)
                            .animation(.spring(duration: 0.5), value: player.isPlaying)
                        VStack(spacing: 4) {
                            Text(player.currentSong?.title ?? "Not Playing")
                                .font(.title2.bold())
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .id(player.currentSong?.id)
                                .transition(.blurReplace)
                            ArtistLinks(artists: player.currentSong?.artists ?? [])
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            if let album = player.currentSong?.album {
                                Button {
                                    if let id = album.id { model.push(.album(id)) }
                                } label: {
                                    Text(album.name)
                                        .font(.callout)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .disabled(album.id == nil)
                            }
                        }
                        .animation(.easeInOut(duration: 0.8), value: player.currentSong?.id)
                        Scrubber()
                            .frame(width: max(artSize, 360))
                            .overlay(alignment: .top) {
                                MixingBadge()
                                    .offset(y: -34)
                                    .animation(.snappy, value: player.mixActivity != nil)
                            }
                        TransportButtons(large: true)
                        HStack(spacing: 16) {
                            LikeButton()
                            VolumeControl(width: 120)
                            AutoMixButton(size: 15)
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
                            if isVideo {
                                Button {
                                    withAnimation(.snappy) { model.settings.showVideos = true }
                                } label: {
                                    Image(systemName: "film").foregroundStyle(.secondary)
                                }
                                .help("Show the Video")
                            }
                        }
                        .buttonStyle(IconButtonStyle(side: 30))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .glassEffect(.regular, in: .capsule)
                        NextMixChip()
                        Spacer(minLength: 0)
                    }
                    .frame(width: split ? geometry.size.width * 0.44 : geometry.size.width)
                    .padding(.vertical, 30)

                    if split {
                        Group {
                            if showQueue {
                                QueueView()
                                    .padding(.vertical, 60)
                            } else {
                                VStack(spacing: 0) {
                                    LyricsView(fontSize: min(34, max(24, geometry.size.width / 42)))
                                    LyricsFooter()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.trailing, 24)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                VStack {
                    HStack {
                        Button {
                            withAnimation(.snappy) { model.showExpandedPlayer = false }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(IconButtonStyle(side: 34))
                        .glassEffect(.regular.interactive(), in: .circle)
                        .keyboardShortcut(.cancelAction)
                        .help("Close")
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.top, 44)
            }
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
