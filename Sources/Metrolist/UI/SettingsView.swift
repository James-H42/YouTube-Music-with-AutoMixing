import SwiftUI
import WebKit

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Playback", systemImage: "play.circle") { PlaybackSettings() }
            Tab("Storage", systemImage: "internaldrive") { StorageSettings() }
            Tab("Account", systemImage: "person.crop.circle") { AccountSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Toggle("Show player in the menu bar", isOn: $settings.showMenuBarPlayer)
            Toggle("Keep Mini Player on top of other windows", isOn: $settings.miniPlayerOnTop)
            Text("Playback also appears in Control Center's Now Playing and responds to the media keys.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Picker("Audio quality", selection: $settings.audioQuality) {
                ForEach(AudioQuality.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Prefer audio versions over music videos", isOn: $settings.preferAudioVersions)
            Toggle("Normalise loudness", isOn: $settings.normalizeVolume)
            Toggle("Show romanised lyrics for non-Latin scripts", isOn: $settings.showRomanization)
            Toggle("Autoplay similar songs when the queue ends", isOn: $settings.autoplay)
            Section("AutoMix") {
                Toggle("Mix between songs like a DJ", isOn: $settings.autoMix)
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

private struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var confirmingClear = false

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Downloads") {
                LabeledContent("Downloaded songs", value: "\(model.media.downloadedIds.count) • \(size(model.media.downloadedBytes))")
            }
            Section("Song cache") {
                LabeledContent("In use", value: size(model.media.cacheBytes))
                Picker("Maximum size", selection: $settings.maxCacheGB) {
                    Text("500 MB").tag(0.5)
                    Text("1 GB").tag(1.0)
                    Text("2 GB").tag(2.0)
                    Text("5 GB").tag(5.0)
                    Text("10 GB").tag(10.0)
                }
                Text("Songs you play are kept so they replay instantly and work offline until space is needed. Downloads are never removed automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Clear Cache…") { confirmingClear = true }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.media]) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.maxCacheGB) { model.media.evictIfNeeded() }
        .confirmationDialog("Clear the song cache?", isPresented: $confirmingClear) {
            Button("Clear Cache", role: .destructive) { model.media.clearCache() }
        } message: {
            Text("Cached songs will be removed. Your downloads are kept.")
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
