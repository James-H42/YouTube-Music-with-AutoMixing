import SwiftUI
import UniformTypeIdentifiers

/// File → Import Playlist…: read a playlist from another service, match its tracks on
/// YouTube Music, review what was found, and create a local playlist.
struct PlaylistImportSheet: View {
    @Environment(AppModel.self) private var model
    private enum Phase { case input, matching, review }
    @ViewState private var phase = Phase.input
    @ViewState private var address = ""
    @ViewState private var playlist: ImportedPlaylist?
    @ViewState private var matches: [TrackMatch] = []
    @ViewState private var progress = 0
    @ViewState private var name = ""
    @ViewState private var failure: String?
    @ViewState private var choosingFile = false
    @ViewState private var working = false
    @ViewState private var showingExportify = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import Playlist").font(.headline)
                Spacer()
                Button("Cancel") { model.showPlaylistImport = false }
            }
            .padding(14)
            Divider()
            switch phase {
            case .input: input
            case .matching: matching
            case .review: review
            }
        }
        .frame(width: 620, height: 520)
        .sheet(isPresented: $showingExportify) {
            ExportifySheet(onCSV: { url in
                showingExportify = false
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                do { begin(try PlaylistImporter.load(file: url)) } catch { failure = error.localizedDescription }
            }, onCancel: { showingExportify = false })
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { begin(try PlaylistImporter.load(file: url)) } catch { failure = error.localizedDescription }
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste the address of a public Spotify, Apple Music or Deezer playlist, or choose a CSV or text file exported from any service (including Tidal and Amazon Music).")
                .foregroundStyle(.secondary)
            HStack {
                TextField("https://open.spotify.com/playlist/…", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(load)
                Button("Read", action: load).disabled(address.isEmpty || working)
            }
            HStack {
                Button("Choose File…") { choosingFile = true }
                Button("Sign In to Spotify…") { failure = nil; showingExportify = true }
                    .help("For private, collaborative or long Spotify playlists: export them through Exportify without leaving the app")
            }
            if working { ProgressView("Reading the playlist…") }
            if let failure { Text(failure).foregroundStyle(.red) }
            Text("Only public playlists can be read from their address, and Spotify and Apple Music pages list up to about 50 songs. For private, collaborative or longer Spotify playlists, use Sign In to Spotify: it opens Exportify, an open-source exporter, in this window. Only the title, artist, album and length are used, and each is searched on YouTube Music.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(18)
    }

    private var matching: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView(value: Double(progress), total: Double(max(1, playlist?.tracks.count ?? 1)))
            Text("Finding songs on YouTube Music… \(progress) of \(playlist?.tracks.count ?? 0)").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(30)
    }

    private var review: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Playlist name", text: $name).textFieldStyle(.roundedBorder)
                Text("\(matches.filter(\.include).count) of \(matches.count) will be added").foregroundStyle(.secondary)
            }
            .padding(12)
            List {
                ForEach($matches) { $match in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $match.include).labelsHidden().disabled(match.chosen == nil)
                        Image(systemName: match.kind == .matched ? "checkmark.circle.fill" : (match.kind == .uncertain ? "questionmark.circle.fill" : "xmark.circle.fill"))
                            .foregroundStyle(match.kind == .matched ? .green : (match.kind == .uncertain ? .orange : .red))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(match.track.title) — \(match.track.artist)").lineLimit(1)
                            if match.candidates.isEmpty {
                                Text("Not found on YouTube Music").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Picker("", selection: Binding(get: { match.chosen?.id ?? "" }, set: { id in
                                    match.chosen = match.candidates.first { $0.id == id }
                                    match.include = match.chosen != nil
                                })) {
                                    if match.kind == .missing { Text("None").tag("") }
                                    ForEach(match.candidates) { song in
                                        Text("\(song.title) — \(song.artistText)\(song.duration.map { " (\(formatDuration(Double($0))))" } ?? "")\(song.isVideo ? " · video" : "")").tag(song.id)
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("Green: title, artist and length agree. Orange: close but not certain, so it starts unchecked. Red: nothing close was found.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Create Playlist") {
                    let songs = matches.filter(\.include).compactMap(\.chosen)
                    let created = model.library.createPlaylist(name: name.isEmpty ? "Imported playlist" : name, songs: songs)
                    model.showPlaylistImport = false
                    model.sidebar = .localPlaylist(created.id)
                }
                .buttonStyle(.borderedProminent)
                .disabled(matches.filter(\.include).isEmpty)
            }
            .padding(12)
        }
    }

    private func load() {
        failure = nil
        working = true
        Task {
            defer { working = false }
            do { begin(try await PlaylistImporter.load(address: address)) } catch { failure = error.localizedDescription }
        }
    }

    private func begin(_ loaded: ImportedPlaylist) {
        playlist = loaded
        name = loaded.name
        progress = 0
        phase = .matching
        Task {
            matches = await TrackMatcher.matchAll(loaded.tracks) { done in DispatchQueue.main.async { progress = done } }
            phase = .review
        }
    }
}
