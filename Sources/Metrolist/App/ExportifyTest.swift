import AppKit
import WebKit

/// `--exportifytest`: the Exportify window without signing in to Spotify.
///  1. exportify.app loads in it.
///  2. A CSV made in an exportify.app page the way Exportify's file saver makes it (a blob
///     link with a download name, clicked) is caught, read as a playlist, and its tracks match.
///  3. The same download from another site is ignored.
///  4. A link away from Exportify and Spotify's sign-in is not followed in the window.
@MainActor
enum ExportifyTest {
    static func run() async {
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
            if !passed { failures += 1 }
        }
        func wait(_ seconds: Double, until done: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !done() { try? await Task.sleep(for: .milliseconds(100)) }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        var received: URL?, notes: [String] = [], opened: [URL] = []
        let coordinator = ExportifyCoordinator(onCSV: { received = $0 }, onNote: { notes.append($0) })
        coordinator.openExternally = { opened.append($0) }
        let webView = ExportifyCoordinator.makeWebView(coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView

        webView.load(URLRequest(url: ExportifyWebView.start))
        var text = ""
        await wait(20) {
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in text = value as? String ?? "" }
            return text.localizedCaseInsensitiveContains("spotify")
        }
        check("exportify.app loads in the window", webView.url?.host == "exportify.app" && text.localizedCaseInsensitiveContains("spotify"), String(text.prefix(80)).replacingOccurrences(of: "\n", with: " "))

        let csv = "\"Track URI\",\"Track Name\",\"Artist URI(s)\",\"Artist Name(s)\",\"Album Name\",\"Track Duration (ms)\"\n\"spotify:track:1\",\"Green Light\",\"spotify:artist:c\",\"Lorde\",\"Melodrama\",\"234000\"\n"
        func page(_ name: String) -> String {
            """
            <html><body><script>
            setTimeout(function () {
              var blob = new Blob([\(String(decoding: (try? JSONSerialization.data(withJSONObject: [csv])) ?? Data(), as: UTF8.self))[0]], { type: "text/csv;charset=utf-8" });
              var a = document.createElement("a");
              a.href = URL.createObjectURL(blob);
              a.download = "\(name)";
              a.rel = "noopener";
              a.dispatchEvent(new MouseEvent("click"));
            }, 300);
            </script></body></html>
            """
        }
        webView.loadHTMLString(page("Flat 3A.csv"), baseURL: URL(string: "https://exportify.app/")!)
        await wait(10) { received != nil }
        if let url = received {
            let playlist = try? PlaylistImporter.load(file: url)
            check("a CSV made the way Exportify makes it is caught and read", playlist?.name == "Flat 3A" && playlist?.tracks.first?.title == "Green Light" && playlist?.tracks.first?.duration == 234,
                  "\(playlist?.name ?? "-"): \(playlist?.tracks.map(\.title) ?? [])")
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        } else {
            check("a CSV made the way Exportify makes it is caught and read", false, "notes: \(notes)")
        }

        received = nil
        // A page the window does show (Spotify's sign-in), but that isn't Exportify.
        webView.loadHTMLString(page("other.csv"), baseURL: URL(string: "https://accounts.spotify.com/")!)
        await wait(4) { received != nil || notes.contains { $0.contains("other than Exportify") } }
        check("a download made by any page but Exportify's is ignored", received == nil && notes.contains { $0.contains("other than Exportify") }, "\(notes)")
        webView.loadHTMLString("<p>elsewhere</p>", baseURL: URL(string: "https://example.com/")!)
        await wait(3) { !opened.isEmpty }
        check("a site that isn't Exportify or a sign-in page isn't shown in the window", opened.first?.host == "example.com" && webView.url?.host != "example.com")
        opened = []

        webView.loadHTMLString(page("Everything.zip"), baseURL: URL(string: "https://exportify.app/")!)
        await wait(4) { notes.contains { $0.contains("single playlist") } }
        check("Export All (a zip) is turned down with a hint", received == nil && notes.contains { $0.contains("single playlist") }, "\(notes)")

        try? await Task.sleep(for: .seconds(1))
        webView.loadHTMLString("<a id='l' href='https://github.com/watsonbox/exportify'>x</a><script>setTimeout(function(){document.getElementById('l').click()},500)</script>", baseURL: URL(string: "https://exportify.app/link")!)
        await wait(6) { !opened.isEmpty }
        check("a link to another site isn't followed in the window", opened.first?.host == "github.com" && webView.url?.host != "github.com", "\(opened)")
        print(failures == 0 ? "all Exportify checks passed" : "\(failures) Exportify checks FAILED")
    }
}
