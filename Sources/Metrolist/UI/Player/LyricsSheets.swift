import SwiftUI

/// "Search lyrics…": what each source has for the playing song, to choose from.
struct LyricsSearchSheet: View {
    @Environment(AppModel.self) private var model
    @ViewState private var results: [LyricsCandidate]?

    var body: some View {
        let player = model.player
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Search Lyrics").font(.headline)
                    if let song = player.currentSong {
                        Text("\(song.title) — \(song.artistText)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { model.showLyricsSearch = false }
            }
            .padding(14)
            Divider()
            if let results {
                if results.isEmpty {
                    ContentUnavailableView("Nothing Found", systemImage: "quote.bubble", description: Text("None of the enabled sources has lyrics for this song. You can write them yourself with Edit Lyrics."))
                } else {
                    List(results) { candidate in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(candidate.source.title).font(.headline)
                                    Text(candidate.isWordSynced ? "Word-synced" : (candidate.lyrics.isSynced ? "Line-synced" : "Not timed"))
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary, in: .capsule)
                                    Text("\(candidate.lyrics.lines.count) lines").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(candidate.lyrics.lines.prefix(3).map(\.text).filter { !$0.isEmpty }.joined(separator: " / "))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button("Use") {
                                player.useLyrics(candidate)
                                model.showLyricsSearch = false
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                ProgressView("Asking the sources…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 560, height: 460)
        .task {
            guard let song = player.currentSong else { results = []; return }
            results = await LyricsService.shared.search(for: song, duration: Double(song.duration ?? Int(player.duration)))
        }
    }
}

/// Edits the playing song's lyrics line by line: text and start time, with "tap to time" to
/// set a line from the playback position. Saved as the song's own "User" lyrics.
struct LyricsEditorSheet: View {
    @Environment(AppModel.self) private var model
    @ViewState private var lines: [LyricLine] = []
    @ViewState private var selected: Int?
    @ViewState private var loaded = false
    @ViewState private var asText = false
    @ViewState private var raw = ""
    @ViewState private var hadUserCopy = false

    var body: some View {
        let player = model.player
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Edit Lyrics").font(.headline)
                    Text("Times are in the song's own time. Edits are kept when lyrics are searched again, and AutoMix re-plans pairs with this song.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("As text", isOn: $asText).toggleStyle(.button)
                    .onChange(of: asText) { _, text in
                        if text { raw = LRCWriter.write(lines) } else { lines = Self.reparse(raw, keeping: lines) }
                    }
            }
            .padding(14)
            Divider()
            if asText {
                TextEditor(text: $raw)
                    .font(.system(.body, design: .monospaced))
                    .padding(6)
            } else {
                List(selection: $selected) {
                    ForEach($lines) { $line in
                        HStack(spacing: 8) {
                            TextField("0:00.00", text: Binding(
                                get: { LRCWriter.stamp(line.start) },
                                set: { if let value = Self.parseStamp($0) { Self.move(&line, to: value) } }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 84)
                            TextField("Lyric", text: Binding(
                                get: { line.text },
                                set: { if $0 != line.text { line.text = $0; line.words = [] } }
                            ))
                            if !line.words.isEmpty {
                                Image(systemName: "waveform").foregroundStyle(.secondary).help("This line has word timing; editing its text removes it")
                            }
                        }
                        .tag(line.id)
                    }
                    .onDelete { lines.remove(atOffsets: $0) }
                }
            }
            Divider()
            HStack {
                if !asText {
                    Button("Set Time to Now") { stampSelected(player.currentTime) }
                        .disabled(selected == nil)
                        .help("Sets the selected line to start at the playback position")
                    Button("Set and Next") {
                        stampSelected(player.currentTime)
                        if let index = selected.flatMap({ id in lines.firstIndex { $0.id == id } }), index + 1 < lines.count { selected = lines[index + 1].id }
                    }
                    .disabled(selected == nil)
                    .keyboardShortcut(.return, modifiers: .command)
                    Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                    Button("Add Line") {
                        let id = (lines.map(\.id).max() ?? -1) + 1
                        lines.append(LyricLine(id: id, start: lines.last.map { $0.start + 3 } ?? 0, text: ""))
                        selected = id
                    }
                }
                Spacer()
                if hadUserCopy { Button("Discard My Edits", role: .destructive) { player.discardEditedLyrics(); model.showLyricsEditor = false } }
                Button("Cancel") { model.showLyricsEditor = false }
                Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 560)
        .task {
            guard !loaded, let song = player.currentSong else { return }
            loaded = true
            hadUserCopy = await LyricsService.shared.hasUserCopy(song.id)
            if let current = player.lyrics {
                lines = current.lines.filter { !$0.isBackground }
                if !current.isSynced {
                    // Plain lyrics have no times yet: space them out for the listener to fix.
                    for index in lines.indices { lines[index].start = Double(index) * 4 }
                }
            } else {
                lines = [LyricLine(id: 0, start: 0, text: "")]
            }
        }
    }

    private func stampSelected(_ time: Double) {
        guard let id = selected, let index = lines.firstIndex(where: { $0.id == id }) else { return }
        // The audio position is song time; lyric times are shown with the user's offset added.
        let offset = model.player.lyrics?.offset ?? 0
        Self.move(&lines[index], to: max(0, time - offset))
    }

    /// Moves a line, with its words, to start at `seconds`.
    static func move(_ line: inout LyricLine, to seconds: Double) {
        let delta = seconds - line.start
        line.start = seconds
        line.end = line.end.map { $0 + delta }
        for index in line.words.indices {
            line.words[index].start += delta
            line.words[index].end += delta
        }
    }

    static func parseStamp(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard !parts.isEmpty, parts.count <= 2, let seconds = Double(parts.last!) else { return nil }
        return (parts.count == 2 ? (Double(parts[0]) ?? 0) * 60 : 0) + seconds
    }

    /// Reads edited LRC text back into lines, keeping the word timing of lines whose text is unchanged.
    static func reparse(_ text: String, keeping old: [LyricLine]) -> [LyricLine] {
        var parsed = LRCParser.parse(text)
        for index in parsed.indices {
            if let match = old.first(where: { $0.text == parsed[index].text && !$0.words.isEmpty }), parsed[index].words.isEmpty {
                var line = match
                move(&line, to: parsed[index].start)
                parsed[index].words = line.words
            }
        }
        return parsed
    }

    private func save() {
        var final = asText ? Self.reparse(raw, keeping: lines) : lines
        final = final.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.start < $1.start }
        for index in final.indices {
            final[index].id = index
            final[index].end = index + 1 < final.count ? final[index + 1].start : final[index].end
        }
        guard !final.isEmpty else { return }
        var lyrics = model.player.lyrics ?? Lyrics(provider: "User", isSynced: true, lines: [])
        lyrics.lines = final
        lyrics.isSynced = true
        model.player.saveEditedLyrics(lyrics)
        model.showLyricsEditor = false
    }
}
