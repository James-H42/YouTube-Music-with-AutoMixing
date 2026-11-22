import SwiftUI
import WebKit

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Playback", systemImage: "play.circle") { PlaybackSettings() }
            Tab("Sound", systemImage: "slider.vertical.3") { SoundSettings() }
            Tab("Lyrics", systemImage: "quote.bubble") { LyricsSettings() }
            Tab("Devices", systemImage: "iphone.and.arrow.forward") { DevicesSettings() }
            Tab("Content", systemImage: "eye.slash") { ContentSettings() }
            Tab("Integrations", systemImage: "point.3.connected.trianglepath.dotted") { IntegrationsSettings() }
            Tab("Storage", systemImage: "internaldrive") { StorageSettings() }
            Tab("Account", systemImage: "person.crop.circle") { AccountSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Toggle("Show player in the menu bar", isOn: $settings.showMenuBarPlayer)
            Toggle("Keep Mini Player on top of other windows", isOn: $settings.miniPlayerOnTop)
            Text("Playback also appears in Control Center's Now Playing and responds to the media keys.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Section("Artwork from Apple Music") {
                Toggle("Use Apple Music's artist pictures", isOn: $settings.appleArtistImages)
                Toggle("Play animated artist pictures", isOn: $settings.animatedArtistArtwork)
                Toggle("Play animated album covers", isOn: $settings.animatedAlbumCovers)
                Text("Artist and album pages ask Apple Music (through its public web player and the iTunes Search API, without an Apple account) for the artist's picture and, where Apple has made them, moving artwork. Only the artist's name and the album's title are sent. Videos play silently and loop; with Reduce Motion on they don't play.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Picker("Audio quality", selection: $settings.audioQuality) {
                ForEach(AudioQuality.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Prefer audio versions over music videos", isOn: $settings.preferAudioVersions)
                .help("For videos in playlists, radio and Autoplay. A video you choose yourself plays as a video.")
            Toggle("Show the video of music videos and live performances", isOn: $settings.showVideos)
            Picker("Video quality", selection: $settings.videoQuality) {
                ForEach(VideoQuality.choices, id: \.self) { Text(VideoQuality.title($0)).tag($0) }
            }
            .disabled(!settings.showVideos)
            .help("Auto adapts to the window and the connection. A fixed quality uses the nearest one a video has at or below it.")
            Toggle("Show romanised lyrics for non-Latin scripts", isOn: $settings.showRomanization)
            Toggle("Show only the romanised lyrics (hide the original script)", isOn: $settings.hideOriginalLyrics)
                .disabled(!settings.showRomanization)
            Toggle("Autoplay similar songs when the queue ends", isOn: $settings.autoplay)
            Section("AutoMix") {
                Toggle("Mix between songs like a DJ", isOn: $settings.autoMix)
                if settings.autoMix, settings.bitPerfect {
                    Text("Paused while bit-perfect output is on (Sound settings): songs play gaplessly instead.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Picker("Transitions", selection: $settings.mixStyle) {
                    ForEach(MixStyle.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!settings.autoMix)
                Picker("Transition length", selection: $settings.mixLength) {
                    ForEach(MixLength.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!settings.autoMix)
                Toggle("Match keys by shifting pitch when it helps", isOn: $settings.mixKeyMatch)
                    .disabled(!settings.autoMix || settings.mixStyle == .fade)
                Toggle("Mix with stems (vocals, bass, drums)", isOn: $settings.mixStems)
                    .disabled(!settings.autoMix || settings.mixStyle == .fade || !StemSeparator.isInstalled)
                    .help(StemSeparator.isInstalled
                        ? "During a beat-matched transition, splits both songs into vocals, drums, bass and the rest on this Mac, so the outgoing vocals can step aside for the new ones and bass and drums hand over cleanly, as DJs do with stems."
                        : "Needs the stem model (Models/HTDemucs.mlpackage), which isn't installed.")
                Toggle("Order Autoplay songs for smoother mixes", isOn: $settings.mixOrdersQueue)
                    .disabled(!settings.autoMix || settings.mixStyle == .fade)
                    .help("Looks a few Autoplay songs ahead and plays next the one whose tempo and key fit the playing song best. Songs you queue yourself, albums and playlists keep their order.")
                Toggle("Look up known samples online", isOn: $settings.mixSampleLookup)
                    .disabled(!settings.autoMix || settings.mixStyle == .fade)
                    .help("Sends the title and artist of the playing and next song to musicbrainz.org (and to Genius, if you add a token), once per song, to learn whether one samples the other. Nothing about you is sent.")
                SecureField("Genius API token (optional)", text: $settings.geniusToken, prompt: Text("Client access token"))
                    .disabled(!settings.autoMix || !settings.mixSampleLookup)
                    .help("MusicBrainz is asked without an account but knows fewer samples. Genius knows far more: create a free API client at genius.com/api-clients and paste its client access token here.")
                Toggle("Mix within albums", isOn: $settings.mixAlbums)
                    .disabled(!settings.autoMix)
                Text("AutoMix listens to each song on this Mac: tempo and beats, key, sections, and (with lyrics) which words are sung where. For each pair it looks for a point where the two fit: a phrase-aligned, beat-matched blend, a hand-over on words both songs share, or a dissolve between passages that sound alike, stretching tempo and nudging pitch gradually where needed. “Fade only” keeps to a plain fade out and fade in. Click the AutoMix button in the player to switch it quickly, and hold it to edit a transition yourself. Albums play straight through unless you allow mixing within them. When AutoMix is off, playback is gapless and unprocessed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Quality and normalisation changes apply from the next song. Songs already downloaded keep the quality they were saved at.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct SoundSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Bindable private var eq = MasterEQ.shared

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Output") {
                Toggle(isOn: $settings.bitPerfect) {
                    Text("Bit-perfect output").info(Explain.bitPerfect)
                }
                // Only the switch is disabled without bit-perfect output: a disabled label would
                // switch its ⓘ off too, and the explanation is most wanted while it is unavailable.
                LabeledContent {
                    Toggle("Keep the output to Metrolist alone", isOn: $settings.exclusiveOutput)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(!settings.bitPerfect)
                } label: {
                    Text("Keep the output to Metrolist alone")
                        .foregroundStyle(settings.bitPerfect ? .primary : .secondary)
                        .info(Explain.exclusive)
                }
                Text("Plays the audio exactly as it was decoded. The equalizer, loudness normalisation and AutoMix pause while it is on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Signal path").font(.callout.weight(.semibold)).info(Explain.signalPath)
                SignalPathView()
            }
            Section("Equalizer") {
                Toggle("Use the equalizer", isOn: $eq.enabled)
                    .disabled(settings.bitPerfect)
                LabeledContent("Profile", value: eq.profile.name)
                Button("Open Equalizer…") { openWindow(id: "equalizer") }
                Text(settings.bitPerfect ? "Bypassed while bit-perfect output is on." : "Applied to everything you hear, after AutoMix has mixed the songs, so transitions don't change.")
                    .font(.callout)
                    .foregroundStyle(settings.bitPerfect ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Section("Loudness") {
                Toggle("Normalise loudness", isOn: $settings.normalizeVolume)
                    .disabled(settings.bitPerfect)
                Picker("Target level", selection: $settings.normalizationLevel) {
                    ForEach(NormalizationLevel.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!settings.normalizes)
                Toggle("Raise quiet songs (up to +3 dB)", isOn: $settings.normalizationBoost)
                    .disabled(!settings.normalizes)
                Text("By default loud songs are turned down to a common level and quiet ones are left alone. Louder targets and boosting switch on a limiter so the result can't clip. Changes apply from the next song.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if settings.bitPerfect {
                    Text("Skipped while bit-perfect output is on.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The hover explanations (ⓘ) for the Output settings, in plain words.
private enum Explain {
    static let bitPerfect = "Sends the sound to your headphones, speakers or DAC exactly as it was decoded, with nothing in Metrolist changing it. The output is switched to the song's own sample rate, and the equalizer, loudness normalisation and AutoMix pause. The volume slider then controls the device's own volume (the same as the volume keys), so the audio itself is never turned down in the app. Worth turning on with wired headphones or an external DAC; leave it off if you want AutoMix or the equalizer."
    static let exclusive = "Gives Metrolist sole use of the output while it plays, so no other app, notification or alert sound is mixed in and nothing can change its sample rate. While it is on, macOS sends other apps' sound to another output, such as the built-in speakers. Everything goes back to normal when you turn this or bit-perfect output off, or quit Metrolist. Available while bit-perfect output is on."
    static let signalPath = "Every step the sound takes from YouTube's stream to your output, checked once a second. A green tick means that step leaves the audio untouched; an orange warning shows what is changing it."
    static let source = "What YouTube sends: the audio format, its bitrate, sample rate and number of channels. YouTube's audio is compressed (Opus), so bit-perfect output keeps it exactly as decoded rather than making it lossless."
    static let output = "The device the sound is playing through, the sample rate it is running at and the bit depth it is fed."
    static let sampleRate = "\u{201C}Matched\u{201D} means the output runs at the song's own rate, so macOS doesn't have to convert (resample) the audio. \u{201C}Resampled\u{201D} means the device can't run at that rate and the audio is converted on the way."
    static let processing = "Anything in Metrolist that changes the sound: the equalizer, the limiter, loudness normalisation or AutoMix. For bit-perfect output this should say None."
    static let volume = "Where the volume is set. Turning the volume down inside the app scales every sample, which is no longer bit-perfect. With bit-perfect output the app stays at full level and the slider sets the device's own volume instead."
    static let exclusiveRow = "Whether other apps can play through the same output at the same time. Turn on \u{201C}Keep the output to Metrolist alone\u{201D} to keep them out."
    static let wireless = "Bluetooth and AirPlay compress the audio again to send it over the air, so no wireless output can be bit-perfect. Use a wired output or a USB DAC for that."
}

/// What happens to the audio between the decoder and the output, checked once a second, as
/// LastWave's "Signal path" shows it: each stage, then whether the output is bit-perfect.
struct SignalPathView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let player = model.player
            if let report = BitPerfectOutput.shared.report(device: OutputDevices.shared.selectedID, processing: player.processingStages, appVolume: player.appGain) {
                VStack(alignment: .leading, spacing: 6) {
                    row("Source", source(report), info: Explain.source)
                    row("Output", output(report), info: Explain.output)
                    row("Sample rate", rate(report), ok: report.sourceRate == nil ? nil : !report.resampled, info: Explain.sampleRate)
                    row("Processing", report.processing.isEmpty ? "None" : report.processing.joined(separator: ", "), ok: report.processing.isEmpty, info: Explain.processing)
                    row("Volume", volume(report), ok: report.appVolume >= 0.9995, info: Explain.volume)
                    row("Exclusive", exclusive(report.exclusive), ok: { if case .refused = report.exclusive { false } else { nil } }(), info: Explain.exclusiveRow)
                    if let wireless = report.wireless {
                        row("Connection", "\(wireless) re-encodes the audio after it leaves the Mac", ok: false, info: Explain.wireless)
                    }
                    Divider()
                    let problems = report.problems
                    Label(problems.isEmpty ? "Bit-perfect: the decoded audio reaches \(report.deviceName) unchanged" : "Not bit-perfect: " + problems.joined(separator: "; "),
                          systemImage: problems.isEmpty ? "checkmark.seal.fill" : "exclamationmark.circle")
                        .foregroundStyle(problems.isEmpty ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .font(.callout.weight(.medium))
                }
                .font(.callout)
            }
        }
    }

    private func row(_ title: String, _ value: String, ok: Bool? = nil, info: String) -> some View {
        LabeledContent {
            HStack(spacing: 5) {
                Text(value).multilineTextAlignment(.trailing)
                if let ok {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? .green : .orange)
                }
            }
        } label: {
            Text(title).info(info)
        }
    }

    private func source(_ report: BitPerfectOutput.Report) -> String {
        guard let rate = report.sourceRate else { return "Nothing playing yet" }
        var parts = ["Opus"]
        if let id = model.player.currentSong?.id, let record = model.media.records[id], record.bitrate > 0 {
            parts.append("\(record.bitrate / 1000) kb/s")
        }
        parts.append(BitPerfectOutput.Report.kHz(rate))
        if let channels = report.channels { parts.append(channels == 2 ? "stereo" : channels == 1 ? "mono" : "\(channels) channels") }
        return parts.joined(separator: " • ")
    }

    private func output(_ report: BitPerfectOutput.Report) -> String {
        var parts = [report.deviceName]
        if let rate = report.deviceRate { parts.append(BitPerfectOutput.Report.kHz(rate)) }
        if let bits = report.bits { parts.append("\(bits)-bit\(report.isFloat ? " float" : "")") }
        return parts.joined(separator: " • ")
    }

    private func rate(_ report: BitPerfectOutput.Report) -> String {
        guard let source = report.sourceRate, let device = report.deviceRate else { return "—" }
        return report.resampled ? "Resampled \(BitPerfectOutput.Report.kHz(source)) → \(BitPerfectOutput.Report.kHz(device))" : "Matched (\(BitPerfectOutput.Report.kHz(device)))"
    }

    private func volume(_ report: BitPerfectOutput.Report) -> String {
        if report.appVolume >= 0.9995 {
            return model.settings.bitPerfect && report.hardwareVolume ? "The output's own volume" : "Full level in the app"
        }
        return "Set in the app (\(Int((report.appVolume * 100).rounded()))%)"
    }

    private func exclusive(_ state: BitPerfectOutput.Report.Exclusive) -> String {
        switch state {
        case .off: "Shared with other apps"
        case .held: "Metrolist only"
        case .refused(let pid): "Held by another app (\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "process \(pid)"))"
        }
    }
}

struct LyricsSettings: View {
    @ViewState private var order = LyricsPreferences.order
    @ViewState private var disabled = LyricsPreferences.disabled
    @ViewState private var wordSynced = LyricsPreferences.preferWordSynced

    var body: some View {
        Form {
            Section("Sources, in the order they are asked") {
                List {
                    ForEach(order) { source in
                        HStack {
                            Toggle(source.title, isOn: Binding(
                                get: { !disabled.contains(source) },
                                set: { on in
                                    if on { disabled.remove(source) } else { disabled.insert(source) }
                                    LyricsPreferences.disabled = disabled
                                }
                            ))
                            Spacer()
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        }
                    }
                    .onMove { source, destination in
                        order.move(fromOffsets: source, toOffset: destination)
                        LyricsPreferences.order = order
                    }
                }
                .frame(height: 170)
                Text("Drag to reorder. The first source that has timed lyrics wins; plain lyrics are only used when no source has timing. Songs no source knows are asked about again after a week.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Prefer word-synced lyrics", isOn: Binding(get: { wordSynced }, set: { wordSynced = $0; LyricsPreferences.preferWordSynced = $0 }))
                Text("Keeps asking further sources when the first only has line timing. Word timing lets AutoMix hand over between songs more precisely. Search results and edits are chosen from the lyrics menu next to the lyrics.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ContentSettings: View {
    @Bindable private var blocked = BlockedContent.shared

    var body: some View {
        Form {
            Section("AI-generated artists") {
                Toggle("Block AI-generated artists", isOn: $blocked.blockAIArtists)
                if blocked.blockAIArtists {
                    LabeledContent("Blocklist", value: blocked.aiListIsLoaded ? "\(blocked.aiCount) entries" : (blocked.aiRefreshing ? "Downloading…" : "Not downloaded"))
                    if let updated = blocked.aiUpdated { LabeledContent("Updated", value: updated.formatted(date: .abbreviated, time: .shortened)) }
                    if let message = blocked.aiMessage { Text(message).foregroundStyle(.orange) }
                    Button("Update Now") { Task { await blocked.refreshAIList(force: true) } }.disabled(blocked.aiRefreshing)
                }
                Text("Uses the community AiSList (github.com/Override92/AiSList), downloaded over HTTPS and refreshed weekly. Nothing about you is sent. Blocked artists are kept out of Autoplay, search and Home; songs you saved yourself are not touched.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Hidden artists") {
                if blocked.artists.isEmpty {
                    Text("None. Use “Hide This Artist” in a song's or artist's context menu.").foregroundStyle(.secondary)
                }
                ForEach(blocked.artists) { artist in
                    HStack {
                        Text(artist.name)
                        Spacer()
                        Button("Unhide") { blocked.unhide(artist) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Where concert listings come from: Ticketmaster (with the listener's free key) and MusicBrainz.
struct ConcertSettings: View {
    @Bindable private var store = ConcertStore.shared
    @ViewState private var editingKey = false

    var body: some View {
        Section("Concerts") {
            LabeledContent {
                Button(store.hasKey ? "Change…" : "Add Key…") { editingKey = true }
            } label: {
                Text("Ticketmaster").info("Official listings with ticket links and line-ups for the UK, Ireland, Europe, North America, Australia and New Zealand. Needs a free key from developer.ticketmaster.com (no payment details); it allows 5,000 lookups a day.")
                Text(store.hasKey ? "Key saved in the Keychain" : "No key: Concerts uses MusicBrainz only")
            }
            Toggle(isOn: $store.useMusicBrainz) {
                Text("Also use MusicBrainz").info("MusicBrainz is an open music encyclopaedia kept by volunteers. It needs no key and covers every country, Japan included, but many concerts are missing from it. It is asked about your 40 most listened-to artists, one request a second.")
            }
            Text("Concerts are looked for near a place you type on the Concerts page; your Mac's location is never read. Only the country is sent to Ticketmaster, and only artist names to MusicBrainz.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $editingKey) { TicketmasterKeySheet() }
    }
}

struct IntegrationsSettings: View {
    @Environment(AppModel.self) private var model
    @Bindable private var scrobbler = Scrobbler.shared
    @ViewState private var apiKey = ""
    @ViewState private var secret = ""
    @ViewState private var token = ""
    @AppStorage("discordApplicationId") private var discordApplicationId = ""

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            ConcertSettings()
            Section("Discord") {
                Toggle("Show what I'm listening to on Discord", isOn: $settings.discordPresence)
                if settings.discordPresence {
                    LabeledContent("Status", value: DiscordPresence.shared.status)
                    TextField("Application ID (optional)", text: $discordApplicationId, prompt: Text(DiscordPresence.defaultApplicationId))
                }
                Text("Uses the Discord app on this Mac, which must be open; nothing is sent anywhere else and no Discord sign-in is needed. Discord shows the song, artist, artwork and a link to it on YouTube Music. The activity is labelled with Metrolist's Discord application unless you enter your own (create one at discord.com/developers).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Last.fm") {
                if scrobbler.isLastFmSignedIn {
                    LabeledContent("Signed in as", value: scrobbler.lastFmUser ?? "")
                    Toggle("Scrobble to Last.fm", isOn: $scrobbler.lastFmEnabled)
                    if scrobbler.needsSignIn.contains("lastfm") { Text("Last.fm no longer accepts this sign-in.").foregroundStyle(.red) }
                    Button("Sign Out") { scrobbler.signOutLastFm() }
                } else {
                    if !scrobbler.hasLastFmKeys {
                        SecureField("API key", text: $apiKey)
                        SecureField("Shared secret", text: $secret)
                        Button("Save Keys") { scrobbler.saveLastFmKeys(key: apiKey, secret: secret); apiKey = ""; secret = "" }
                            .disabled(apiKey.isEmpty || secret.isEmpty)
                        Text("Last.fm needs an API account for each app. Create one for free at last.fm/api/account/create, then paste its key and shared secret here. They are kept in your Keychain.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if scrobbler.pendingToken == nil {
                        Button("Sign In…") {
                            Task { if let url = await scrobbler.beginLastFmSignIn() { NSWorkspace.shared.open(url) } }
                        }
                    } else {
                        Text("Approve Metrolist in your browser, then come back and press Finish.").font(.callout)
                        Button("Finish Signing In") { Task { await scrobbler.finishLastFmSignIn() } }
                    }
                }
            }
            Section("ListenBrainz") {
                if scrobbler.isListenBrainzSignedIn {
                    LabeledContent("Signed in as", value: scrobbler.listenBrainzUser ?? "")
                    Toggle("Scrobble to ListenBrainz", isOn: $scrobbler.listenBrainzEnabled)
                    if scrobbler.needsSignIn.contains("listenbrainz") { Text("ListenBrainz no longer accepts this token.").foregroundStyle(.red) }
                    Button("Sign Out") { scrobbler.signOutListenBrainz() }
                } else {
                    SecureField("User token", text: $token)
                    Button("Sign In") { Task { await scrobbler.signInListenBrainz(token: token); token = "" } }
                        .disabled(token.isEmpty)
                    Text("Copy your user token from listenbrainz.org/settings. It is kept in your Keychain.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Waiting to be sent") {
                LabeledContent("Listens queued", value: "\(scrobbler.queued)")
                HStack {
                    Button("Send Now") { scrobbler.flush() }.disabled(scrobbler.queued == 0)
                    Button("Clear Queue", role: .destructive) { scrobbler.clearQueue() }.disabled(scrobbler.queued == 0)
                }
                Text("A song counts as played after half of it, or four minutes. With AutoMix on, \u{201C}now playing\u{201D} is sent at the hand-over, half-way through the transition. Listens made offline are sent when the connection returns. Only the title, artist, album and length are sent.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message = scrobbler.message { Text(message).foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
    }
}

/// Songs and music videos are shown, counted and cleared apart, as the sidebar lists them
/// (Downloads and Music Videos). A music video's sound is stored like a song's, beside its
/// picture, but it belongs to the video here.
struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var clearing: ClearTarget?

    private enum ClearTarget: Identifiable {
        case songs, musicVideos
        var id: Self { self }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func count(_ number: Int, _ one: String, _ many: String) -> String {
        "\(number) \(number == 1 ? one : many)"
    }

    var body: some View {
        @Bindable var settings = model.settings
        let split = model.media.storage
        let videos = VideoDownloads.shared
        let videoCount = Set(model.media.downloadedIds.filter { model.media.isVideoDownload($0) }).union(videos.records.keys).count
        Form {
            Section("Songs") {
                LabeledContent("Downloaded", value: "\(count(split.downloadedSongs.count, "song", "songs")) • \(size(split.downloadedSongs.bytes))")
                LabeledContent("Cached", value: size(split.cachedSongs.bytes))
                HStack {
                    Button("Clear Song Cache…") { clearing = .songs }
                        .disabled(split.cachedSongs.count == 0)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.media]) }
                }
            }
            Section("Music Videos") {
                LabeledContent("Downloaded", value: "\(count(videoCount, "video", "videos")) • \(size(videos.bytes + split.downloadedVideoSound.bytes))")
                LabeledContent("Pictures", value: size(videos.bytes))
                    .foregroundStyle(.secondary)
                LabeledContent("Sound", value: size(split.downloadedVideoSound.bytes))
                    .foregroundStyle(.secondary)
                LabeledContent("Cached sound", value: size(split.cachedVideoSound.bytes))
                HStack {
                    Button("Clear Music Video Cache…") { clearing = .musicVideos }
                        .disabled(split.cachedVideoSound.count == 0)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.videos]) }
                }
            }
            Section("Cache") {
                Picker("Maximum size", selection: $settings.maxCacheGB) {
                    Text("500 MB").tag(0.5)
                    Text("1 GB").tag(1.0)
                    Text("2 GB").tag(2.0)
                    Text("5 GB").tag(5.0)
                    Text("10 GB").tag(10.0)
                }
                Text("Songs you play, and the sound of music videos you watch, are kept so they replay instantly and work offline until space is needed. The picture of a music video is only kept when you download it. Downloads are never removed automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.maxCacheGB) { model.media.evictIfNeeded() }
        .confirmationDialog(clearing == .musicVideos ? "Clear the music video cache?" : "Clear the song cache?", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), presenting: clearing) { target in
            Button("Clear Cache", role: .destructive) { model.media.clearCache(musicVideos: target == .musicVideos) }
        } message: { target in
            Text(target == .musicVideos ? "The cached sound of music videos you've watched will be removed. Downloaded music videos are kept." : "Cached songs will be removed. Your downloads are kept.")
        }
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var signingIn = false

    var body: some View {
        Form {
            if model.account.isSignedIn {
                HStack(spacing: 12) {
                    ArtworkView(url: model.account.account?.thumbnail, size: 44, circular: true)
                    VStack(alignment: .leading) {
                        Text(model.account.account?.name ?? "Signed in")
                            .font(.headline)
                        if let email = model.account.account?.email {
                            Text(email).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Sign Out") { model.account.signOut() }
                }
                HStack {
                    Text(model.account.isSyncing ? "Syncing your YouTube Music library…" : "Your YouTube Music library is merged into Liked Songs, Albums, Artists and Playlists.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync Now") { Task { await model.account.refresh() } }
                        .disabled(model.account.isSyncing)
                }
                Toggle("Play through my account when YouTube blocks anonymous playback", isOn: Bindable(model.settings).accountPlayback)
                Text("Normally songs are streamed anonymously and your account is only used for your library and history. If YouTube asks this connection to prove it isn't a bot, Metrolist can ask for the stream as you instead. That is the only thing that works on a blocked connection, but it ties the playback requests to your account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sign in to YouTube Music")
                        .font(.headline)
                    Text("Optional. Signing in personalises Home and merges your YouTube Music liked songs, albums, artists and playlists into the library. Playback and downloads work without an account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Sign In…") { signingIn = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $signingIn) {
            SignInSheet { cookie in
                model.account.signIn(cookie: cookie)
                signingIn = false
            } onCancel: {
                signingIn = false
            }
        }
    }
}

/// Google's own sign-in page in a web view; the session cookie is read once sign-in completes.
private struct SignInSheet: View {
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in with Google").font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
            }
            .padding(12)
            Divider()
            SignInWebView(onComplete: onComplete)
        }
        .frame(width: 520, height: 680)
    }
}

private struct SignInWebView: NSViewRepresentable {
    let onComplete: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onComplete: (String) -> Void
        private var finished = false

        init(onComplete: @escaping (String) -> Void) {
            self.onComplete = onComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished, webView.url?.host == "music.youtube.com" else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.finished else { return }
                let relevant = cookies.filter { $0.domain.hasSuffix("youtube.com") }
                guard relevant.contains(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }) else { return }
                self.finished = true
                let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                DispatchQueue.main.async { self.onComplete(header) }
            }
        }
    }
}
