import SwiftUI

/// Wraps subviews onto multiple lines, like text.
struct FlowLayout: Layout {
    var trailing = false
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, max(width, 0)) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

/// One lyric line. When the line is active and has word timing, each word fills as it is sung.
private struct LyricLineView: View, Equatable {
    let line: LyricLine
    let isActive: Bool
    let isPast: Bool
    /// Playback time, supplied only while the line is active so idle lines never re-render.
    let time: Double?
    let fontSize: CGFloat
    let synced: Bool
    var showRomanized = true

    private var font: Font {
        .system(size: line.isBackground ? fontSize * 0.72 : fontSize, weight: .bold, design: .rounded)
    }

    private var idleOpacity: Double { synced ? (isPast ? 0.32 : 0.38) : 0.9 }

    /// Syllables that belong to one word stay together when wrapping.
    private var wordGroups: [[LyricWord]] {
        var groups: [[LyricWord]] = [[]]
        for word in line.words {
            groups[groups.count - 1].append(word)
            if word.text.hasSuffix(" ") { groups.append([]) }
        }
        return groups.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: line.isSecondary ? .trailing : .leading, spacing: fontSize * 0.14) {
            lineText
            if showRomanized, let romanized = line.romanized {
                Text(romanized)
                    .font(.system(size: max(12, fontSize * 0.58), weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(isActive ? 0.8 : idleOpacity * 0.85))
                    .multilineTextAlignment(line.isSecondary ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: line.isSecondary ? .trailing : .leading)
        .scaleEffect(isActive && synced ? 1 : 0.97, anchor: line.isSecondary ? .trailing : .leading)
        .animation(.easeInOut(duration: 0.3), value: isActive)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var lineText: some View {
        Group {
            if isActive, let time, !line.words.isEmpty {
                FlowLayout(trailing: line.isSecondary) {
                    ForEach(Array(wordGroups.enumerated()), id: \.offset) { _, group in
                        HStack(spacing: 0) {
                            ForEach(Array(group.enumerated()), id: \.offset) { _, word in
                                wordView(word, time: time)
                            }
                        }
                    }
                }
            } else {
                Text(line.text.isEmpty ? "♪" : line.text)
                    .font(font)
                    .foregroundStyle(.primary.opacity(isActive ? 1 : idleOpacity))
                    .multilineTextAlignment(line.isSecondary ? .trailing : .leading)
                    .lineSpacing(4)
            }
        }
    }

    private func wordView(_ word: LyricWord, time: Double) -> some View {
        let length = max(0.05, word.end - word.start)
        let progress = min(1, max(0, (time - word.start) / length))
        return Text(word.text)
            .font(font)
            .foregroundStyle(.primary.opacity(0.38))
            .overlay {
                if progress > 0 {
                    Text(word.text)
                        .font(font)
                        .foregroundStyle(.primary)
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: progress),
                                    .init(color: .clear, location: min(1, progress + (progress >= 1 ? 0 : 0.12))),
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                        }
                }
            }
            .offset(y: progress > 0 && progress < 1 ? -1 : 0)
    }
}

/// Karaoke-style lyrics that follow playback, highlighting the current line and word.
struct LyricsView: View {
    var fontSize: CGFloat = 22
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if let lyrics = player.lyrics {
            if lyrics.isSynced {
                SyncedLyricsView(lyrics: lyrics, fontSize: fontSize)
                    .id(player.currentSong?.id)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(lyrics.lines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: fontSize * 0.8, weight: .semibold, design: .rounded))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if model.settings.showRomanization, let romanized = line.romanized {
                                Text(romanized)
                                    .font(.system(size: max(12, fontSize * 0.52), weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Text("These lyrics aren't time-synced.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    .textSelection(.enabled)
                    .padding(20)
                }
            }
        } else if player.lyricsLoading || (player.currentSong != nil && player.isBuffering) {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if player.currentSong == nil {
            ContentUnavailableView("Nothing Playing", systemImage: "quote.bubble", description: Text("Lyrics appear here when you play a song."))
        } else {
            ContentUnavailableView {
                Label("No Lyrics Found", systemImage: "quote.bubble")
            } actions: {
                Button("Search Again") { player.reloadLyrics() }
                Button("Choose a Source…") { model.showLyricsSearch = true }
                Button("Write Lyrics…") { model.showLyricsEditor = true }
            }
        }
    }
}

private struct SyncedLyricsView: View {
    let lyrics: Lyrics
    let fontSize: CGFloat
    @Environment(AppModel.self) private var model
    @ViewState private var userScrolledAt = Date.distantPast

    var body: some View {
        let player = model.player
        // Reading the coarse position keeps the view current while paused (after a seek).
        let _ = player.position
        ScrollViewReader { proxy in
            ScrollView {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !player.isPlaying)) { _ in
                    let time = player.currentTime - lyrics.offset
                    let active = activeIndex(at: time)
                    LazyVStack(alignment: .leading, spacing: fontSize * 0.75) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                            let isActive = index == active || isSinging(line, at: time)
                            LyricLineView(
                                line: line,
                                isActive: isActive,
                                isPast: index < (active ?? -1),
                                time: isActive ? time : nil,
                                fontSize: fontSize,
                                synced: true,
                                showRomanized: model.settings.showRomanization
                            )
                            .equatable()
                            .id(line.id)
                            .onTapGesture { player.seek(to: max(0, line.start + lyrics.offset)) }
                        }
                    }
                    .onChange(of: active) { _, newValue in
                        guard let newValue, Date().timeIntervalSince(userScrolledAt) > 3 else { return }
                        withAnimation(.easeInOut(duration: 0.55)) {
                            proxy.scrollTo(lyrics.lines[newValue].id, anchor: .center)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 140)
            }
            .scrollIndicators(.never)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { userScrolledAt = Date() }
            }
            .onAppear {
                if let active = activeIndex(at: player.currentTime - lyrics.offset) {
                    proxy.scrollTo(lyrics.lines[active].id, anchor: .center)
                }
            }
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    /// The most recently started lead-vocal line.
    private func activeIndex(at time: Double) -> Int? {
        var result: Int?
        for (index, line) in lyrics.lines.enumerated() {
            if line.start > time { break }
            if !line.isBackground { result = index }
        }
        return result
    }

    /// Background vocals and overlapping duet lines light up while they are being sung.
    private func isSinging(_ line: LyricLine, at time: Double) -> Bool {
        guard !line.words.isEmpty, let end = line.end ?? line.words.last?.end else { return false }
        return line.start <= time && time < end
    }
}
