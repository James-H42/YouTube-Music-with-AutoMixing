import SwiftUI
import WebKit

/// Spotify playlists that can't be read from their address (private, collaborative, long ones)
/// are exported by Exportify (exportify.app, MIT-licensed, github.com/watsonbox/exportify), shown here
/// in a web view so nobody has to leave the app.
///
/// Why Exportify's site and not Spotify's Web API directly: since 2025 a new Spotify app is
/// limited to five hand-added users, only organisations can apply for more, and since
/// February 2026 such an app needs Premium and only gets the items of playlists the user owns.
/// Exportify's approved app has none of these limits.
///
/// The web view keeps nothing (non-persistent store). It only goes to Exportify, Spotify's
/// sign-in pages and the sign-in providers Spotify offers; anything else opens in the
/// browser. The only thing taken from it is the CSV file Exportify generates, size-limited,
/// which is read like any chosen file and then deleted.
struct ExportifySheet: View {
    let onCSV: (URL) -> Void
    let onCancel: () -> Void
    @ViewState private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export from Spotify").font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
            }
            .padding(12)
            Text("Sign in to Spotify on Exportify's page below, then press Export next to the playlist. The app reads the file it makes. Nothing is kept after this window closes.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 8)
            if let note { Text(note).foregroundStyle(.orange).padding(.bottom, 6) }
            Divider()
            ExportifyWebView(onCSV: onCSV, onNote: { note = $0 })
        }
        .frame(width: 760, height: 640)
    }
}

struct ExportifyWebView: NSViewRepresentable {
    static let start = URL(string: "https://exportify.app/")!
    let onCSV: (URL) -> Void
    let onNote: (String) -> Void

    func makeCoordinator() -> ExportifyCoordinator { ExportifyCoordinator(onCSV: onCSV, onNote: onNote) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = ExportifyCoordinator.makeWebView(context.coordinator)
        webView.load(URLRequest(url: Self.start))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

final class ExportifyCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let maxBytes = 8 * 1024 * 1024
    /// Hosts the window may show: Exportify, Spotify's sign-in, and the providers Spotify offers.
    static let allowedHosts = ["exportify.app", "accounts.spotify.com", "challenge.spotify.com", "www.spotify.com", "spotify.com",
                               "accounts.google.com", "appleid.apple.com", "www.facebook.com", "m.facebook.com"]

    let onCSV: (URL) -> Void
    let onNote: (String) -> Void
    private var destinations: [ObjectIdentifier: URL] = [:]
    /// Where links that leave Exportify and Spotify's sign-in go (tests replace it).
    var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(onCSV: @escaping (URL) -> Void, onNote: @escaping (String) -> Void) {
        self.onCSV = onCSV
        self.onNote = onNote
    }

    static func makeWebView(_ coordinator: ExportifyCoordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // A Safari user agent: Exportify's file saver treats an unnamed macOS web view
        // differently (it opens the file instead of downloading it).
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        return webView
    }

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme == "blob" || url.scheme == "about" { return true }
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { return decisionHandler(.download) }
        guard action.targetFrame?.isMainFrame != false else { return decisionHandler(.allow) }
        if Self.isAllowed(action.request.url) { return decisionHandler(.allow) }
        // Links elsewhere (GitHub, Spotify's own site) go to the browser, not this window.
        if let url = action.request.url, url.scheme == "https" { openExternally(url) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    /// A sign-in that opens a new window is shown in this one instead, if it is allowed.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if Self.isAllowed(action.request.url) { webView.load(action.request) }
        return nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        // Only a file Exportify made in its own page.
        let source = download.originalRequest?.url
        let fromExportify = source?.absoluteString.hasPrefix("blob:https://exportify.app/") == true || source?.host == "exportify.app"
        let name = (suggestedFilename as NSString).lastPathComponent
        guard fromExportify else { onNote("A download from somewhere other than Exportify was ignored."); return nil }
        guard name.lowercased().hasSuffix(".csv") else {
            onNote(name.lowercased().hasSuffix(".zip") ? "That's every playlist at once. Press Export next to a single playlist instead." : "Only a CSV file from Exportify can be read.")
            return nil
        }
        guard response.expectedContentLength <= Int64(Self.maxBytes) else { onNote("That file is too large to import."); return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("exportify-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name.isEmpty ? "Spotify playlist.csv" : name)
        destinations[ObjectIdentifier(download)] = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        guard size <= Self.maxBytes else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            return onNote("That file is too large to import.")
        }
        DispatchQueue.main.async { self.onCSV(url) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        onNote("The export didn't finish: \(error.localizedDescription)")
    }
}
