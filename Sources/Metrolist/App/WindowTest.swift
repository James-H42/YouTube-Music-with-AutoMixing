import AppKit

/// `METROLIST_WINDOWTEST=1`: opens the real main window, shows and hides the full-screen
/// player, and prints whether the window's close, minimise and zoom buttons stay usable.
/// Run it with `METROLIST_HOME` pointing at a throwaway folder.
@MainActor
enum WindowTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["METROLIST_WINDOWTEST"] == "1" }

    static func run() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            // Start from a window filling the screen, as most people use it.
            if let window = mainWindow, let screen = window.screen ?? NSScreen.main {
                window.setFrame(screen.visibleFrame, display: true)
                try? await Task.sleep(for: .seconds(1))
                // macOS window tiling (Window > Move & Resize > Fill), which re-tiles windows
                // whose frame changes: METROLIST_WINDOWTEST_TILE=1.
                if ProcessInfo.processInfo.environment["METROLIST_WINDOWTEST_TILE"] == "1" {
                    window.makeKeyAndOrderFront(nil)
                    @MainActor func find(_ menu: NSMenu?, _ title: String) -> NSMenuItem? {
                        if let menu { menu.delegate?.menuNeedsUpdate?(menu); menu.update() }
                        if ProcessInfo.processInfo.environment["METROLIST_WINDOWTEST_MENUS"] == "1" { print("menu \(menu?.title ?? "-"): \(menu?.items.map(\.title) ?? [])") }
                        for item in menu?.items ?? [] {
                            if item.title == title { return item }
                            if let found = find(item.submenu, title) { return found }
                        }
                        return nil
                    }
                    if let fill = find(NSApp.mainMenu, "Fill"), let menu = fill.menu, let index = Optional(menu.index(of: fill)) {
                        menu.performActionForItem(at: index)
                        print("chose Window > Fill")
                    } else {
                        print("no Fill menu item")
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
            // METROLIST_WINDOWTEST_MIX="idA idB": a real (muted) AutoMix transition in the
            // full-screen player, pictured before, while both covers show, and after the next
            // song takes over.
            if let ids = ProcessInfo.processInfo.environment["METROLIST_WINDOWTEST_MIX"]?.split(separator: " ").map(String.init), ids.count == 2 {
                await mixTransition(ids)
                exit(0)
            }
            // METROLIST_WINDOWTEST_SHOWCASE="idA idB": pictures of the main screens for the README,
            // with a transition from A into B (both cached in the test home).
            if let ids = ProcessInfo.processInfo.environment["METROLIST_WINDOWTEST_SHOWCASE"]?.split(separator: " ").map(String.init), ids.count == 2 {
                await showcase(ids)
                exit(0)
            }
            // METROLIST_WINDOWTEST_PUSH=1: open a page with a back button first (a concert
            // page, which needs no network), to check the button doesn't show over the player.
            if ProcessInfo.processInfo.environment["METROLIST_WINDOWTEST_PUSH"] == "1" {
                AppModel.shared.push(.concert("windowtest"))
                try? await Task.sleep(for: .seconds(1))
            }
            // METROLIST_WINDOWTEST_CONCERTS=1: start from the Concerts page, whose toolbar has a
            // sort menu and a refresh button (they showed over the player on 2026-11-22).
            if ProcessInfo.processInfo.environment["METROLIST_WINDOWTEST_CONCERTS"] == "1" {
                AppModel.shared.sidebar = .concerts
                try? await Task.sleep(for: .seconds(2))
            }
            report("normal")
            AppModel.shared.showExpandedPlayer = true
            try? await Task.sleep(for: .seconds(1.5))
            report("full-screen player")
            try? await Task.sleep(for: .seconds(4))
            report("full-screen player later")
            // METROLIST_WINDOWTEST_FULLSCREEN=1: the open player in macOS's own full screen, where
            // the toolbar moves to a window of its own above the content.
            if ProcessInfo.processInfo.environment["METROLIST_WINDOWTEST_FULLSCREEN"] == "1", let window = mainWindow {
                // Only the active app's window can enter full screen.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))
                window.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(3))
                report("player in macOS full screen")
                window.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(3))
                report("player after full screen")
            }
            AppModel.shared.showExpandedPlayer = false
            try? await Task.sleep(for: .seconds(1.5))
            report("closed again")
            // Metrolist 14.0.1 fixed its Mac app not reopening after being hidden: close the
            // window, then send the event a click on the Dock icon sends.
            NSApp.windows.first { $0.title == "Metrolist+" || $0.identifier?.rawValue.hasPrefix("main") == true }?.close()
            try? await Task.sleep(for: .seconds(1))
            print("after closing: main window visible = \(mainVisible)")
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                               targetDescriptor: NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier),
                                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            _ = try? event.sendEvent(options: [.noReply], timeout: 5)
            try? await Task.sleep(for: .seconds(1.5))
            print("after a Dock click: main window visible = \(mainVisible)")
            exit(0)
        }
    }

    private static func mixTransition(_ ids: [String]) async {
        let model = AppModel.shared, player = model.player
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        model.settings.autoMix = true
        model.settings.autoplay = false
        player.play(ids.map { model.library.song($0) ?? Song(id: $0, title: $0) })
        player.volume = 0
        model.showExpandedPlayer = true
        for _ in 0 ..< 600 where player.nextMixPlan == nil || !player.isPlaying || player.position < 1 { await wait(0.1) }
        guard let plan = player.nextMixPlan else { print("FAIL no transition planned"); return }
        print("planned: \(plan.summary), out at \(String(format: "%.1f", plan.outStart)) s")
        player.seek(to: max(0, plan.outStart - (plan.approach ?? 0) - 5))
        await wait(2)
        func state() -> String {
            "at \(String(format: "%.1f", player.position)) s playing=\(player.isPlaying) current=\(player.currentSong?.title ?? "-") incoming=\(player.mixIncoming?.title ?? "-") progress=\(player.mixActivity.map { String(format: "%.2f", $0.progress) } ?? "-")"
        }
        var lastLog = Date()
        print("before: \(state())")
        capture("mix-1-before")
        var sawPair = false, sawHandOver = false
        let deadline = Date().addingTimeInterval(60 + (plan.approach ?? 0))
        while Date() < deadline {
            await wait(0.1)
            if Date().timeIntervalSince(lastLog) > 2 { print("  \(state())"); lastLog = Date() }
            if !sawPair, player.mixIncoming != nil {
                sawPair = true
                await wait(1.2)
                print("both covers: \(state())")
                capture("mix-2-both")
            }
            if sawPair, !sawHandOver, player.mixIncoming == nil, player.currentIndex == 1 {
                sawHandOver = true
                await wait(1.4)
                print("taken over: \(state())")
                capture("mix-3-taken-over")
            }
            if sawHandOver, player.mixActivity == nil { break }
        }
        await wait(1)
        print("after: \(state())")
        capture("mix-4-after")
        print(sawPair ? "PASS the next cover joined during the transition" : "FAIL no incoming cover was shown")
        print(sawHandOver ? "PASS the next song took over half-way and its cover was centred" : "FAIL no hand-over seen")
        player.pause()
    }

    private static func showcase(_ ids: [String]) async {
        let model = AppModel.shared, player = model.player
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        guard let window = mainWindow else { print("FAIL main window not found"); return }
        if let screen = window.screen ?? NSScreen.main {
            let area = screen.visibleFrame
            let size = CGSize(width: min(1440, area.width), height: min(900, area.height))
            window.setFrame(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        model.settings.autoMix = true
        model.settings.autoplay = false
        model.settings.mixStems = true
        player.volume = 0.7
        player.muteOutputForTesting()
        await wait(10)
        capture("showcase-home")
        model.searchText = "Daft Punk"
        model.submitSearch()
        await wait(8)
        capture("showcase-search")
        model.searchText = ""
        if let album = model.library.song(ids[0])?.album?.id {
            model.push(.album(album))
            await wait(8)
            capture("showcase-album")
        }
        if let artist = model.library.song(ids[0])?.artists.first?.id {
            model.push(.artist(artist))
            await wait(10)
            capture("showcase-artist")
        }
        model.path = []

        // The pair, mixed: the transition editor, then the full-screen player through it.
        player.play(ids.map { model.library.song($0) ?? Song(id: $0, title: $0) })
        player.muteOutputForTesting()
        for _ in 0 ..< 900 where player.nextMixPlan == nil || !player.isPlaying || player.position < 1 { await wait(0.1) }
        // Give a sample lookup time to name the transition.
        for _ in 0 ..< 100 where player.nextMixPlan?.known == nil { await wait(0.1) }
        guard let plan = player.nextMixPlan else { print("FAIL no transition planned"); return }
        print("planned: \(plan.summary) — \(plan.note)")
        capture("showcase-playing")
        model.showMixEditor = true
        await wait(4)
        if let sheet = window.attachedSheet ?? NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) {
            captureWindow(sheet, "showcase-mix-editor")
        }
        model.showMixEditor = false
        await wait(1.5)
        model.showExpandedPlayer = true
        player.seek(to: max(0, plan.outStart - (plan.approach ?? 0) - 30))
        await wait(5)
        capture("showcase-player")
        // Just before the tempo approach (jumping into it leaves the planned transition behind),
        // then film from a moment before the mix point to after the next song takes over.
        player.seek(to: max(0, plan.outStart - (plan.approach ?? 0) - 3))
        var frames: [CGImage] = []
        var tookBoth = false, tookNext = false, handOverAt: Date?
        let deadline = Date().addingTimeInterval(60 + (plan.approach ?? 0))
        while Date() < deadline {
            player.muteOutputForTesting()
            if player.mixActivity == nil, player.currentIndex == 0, player.position < plan.outStart - 1 {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            if let image = composited(window, best: false) { frames.append(image) }
            try? await Task.sleep(for: .milliseconds(30))
            if !tookBoth, player.mixIncoming != nil {
                tookBoth = true
                // Let the covers settle, keep filming meanwhile.
                let settle = Date().addingTimeInterval(1.3)
                while Date() < settle {
                    if let image = composited(window, best: false) { frames.append(image) }
                    try? await Task.sleep(for: .milliseconds(30))
                }
                capture("showcase-transition")
            }
            if tookBoth, handOverAt == nil, player.mixIncoming == nil { handOverAt = Date() }
            if let handOverAt, !tookNext, Date().timeIntervalSince(handOverAt) > 1.5 {
                tookNext = true
                capture("showcase-taken-over")
                break
            }
        }
        let folder = AppPaths.root.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, frame) in frames.enumerated() {
            try? NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent(String(format: "frame-%04d.png", index)))
        }
        print("transition: both covers \(tookBoth), taken over \(tookNext), \(frames.count) frames")
        model.settings.fullScreenLyrics = true
        await wait(6)
        capture("showcase-lyrics")
        model.settings.fullScreenLyrics = false
        model.showExpandedPlayer = false
        await wait(2)
        capture("showcase-bar")

        // A music video, played as a video.
        if let video = try? await YTMusic.search("Daft Punk Instant Crush official video", filter: .videos).sections.flatMap(\.items)
            .compactMap({ if case .song(let song) = $0, song.isMusicVideo { song } else { nil } }).first {
            player.play(song: video)
            player.muteOutputForTesting()
            model.showExpandedPlayer = true
            for _ in 0 ..< 300 where !NowPlayingVideo.shared.isShowing { await wait(0.1) }
            await wait(3)
            player.seek(to: 70)
            await wait(4)
            // Paused, the player keeps its controls on screen.
            player.pause()
            await wait(2)
            capture("showcase-video")
            model.showExpandedPlayer = false
        }
        player.pause()
    }

    /// A picture of the whole window frame, title bar included, in the test home. Also, when
    /// macOS allows it, the window as composited on screen (Liquid Glass and blur included),
    /// which `cacheDisplay` leaves out.
    static func capture(_ label: String) {
        guard let window = mainWindow, let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: AppPaths.root.appendingPathComponent("window-\(label).png"))
        print("window \(window.windowNumber): wrote window-\(label).png")
        captureWindow(window, label, plain: false)
    }

    /// The window as composited on screen, as `screen-<label>.png`.
    private static func captureWindow(_ window: NSWindow, _ label: String, plain: Bool = true) {
        guard let image = composited(window) else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: AppPaths.root.appendingPathComponent("screen-\(label).png"))
        print("window \(window.windowNumber): wrote screen-\(label).png (\(image.width)×\(image.height))")
    }

    /// The app's own window as the window server draws it. `CGWindowListCreateImage` is gone
    /// from the macOS 15 SDK but still answers for a process's own windows; it is looked up at
    /// run time, and nil means it isn't available.
    private static func composited(_ window: NSWindow, best: Bool = true) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming (| kCGWindowImageBestResolution).
        return create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (best ? 1 << 3 : 0))?.takeRetainedValue()
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Metrolist+" }
    }

    private static var mainVisible: Bool {
        NSApp.windows.contains { ($0.title == "Metrolist+" || $0.identifier?.rawValue.hasPrefix("main") == true) && $0.isVisible }
    }

    /// A window button counts as usable when it and every view above it are shown and it
    /// sits inside the window's visible frame.
    private static func report(_ label: String) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Metrolist+" }) else {
            print("\(label): main window not found")
            return
        }
        var parts: [String] = []
        for (name, kind) in [("close", NSWindow.ButtonType.closeButton), ("minimise", .miniaturizeButton), ("zoom", .zoomButton)] {
            guard let button = window.standardWindowButton(kind) else { parts.append("\(name)=missing"); continue }
            var hidden = button.isHiddenOrHasHiddenAncestor
            var alpha = button.alphaValue
            var view: NSView? = button.superview
            while let current = view { alpha *= current.alphaValue; view = current.superview }
            if alpha < 0.05 { hidden = true }
            parts.append("\(name)=\(hidden ? "hidden" : "shown")\(button.isEnabled ? "" : ",disabled")")
        }
        // Buttons drawn in the title bar besides the window's own three (a back button, say).
        var titlebarButtons: [String] = []
        if let frame = window.contentView?.superview {
            func walk(_ view: NSView) {
                if let button = view as? NSButton, !button.isHiddenOrHasHiddenAncestor,
                   ![NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].contains(where: { window.standardWindowButton($0) === button }),
                   button.convert(button.bounds, to: nil).minY > window.frame.height - 60 {
                    var alpha = button.alphaValue
                    var up = button.superview
                    while let current = up { alpha *= current.alphaValue; up = current.superview }
                    if alpha > 0.05 { titlebarButtons.append(button.accessibilityLabel() ?? button.title) }
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(frame)
        }
        print("\(label): titlebar buttons=\(titlebarButtons)")
        // Text the title bar shows (a page's title, say), in the window itself and, in full
        // screen, in the separate window that then holds the toolbar.
        var titlebarText: [String] = []
        for host in NSApp.windows where host === window || String(describing: type(of: host)).contains("FullScreen") {
            guard host.isVisible || host === window, let root = host.contentView?.superview ?? host.contentView else { continue }
            func walk(_ view: NSView) {
                if let field = view as? NSTextField, !field.isHiddenOrHasHiddenAncestor, !field.stringValue.isEmpty {
                    let rect = field.convert(field.bounds, to: nil)
                    var alpha = field.alphaValue
                    var up = field.superview
                    while let current = up { alpha *= current.alphaValue; up = current.superview }
                    if alpha > 0.05, host !== window || rect.minY > window.frame.height - 60 { titlebarText.append(field.stringValue) }
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(root)
        }
        let options = NSApp.presentationOptions
        print("\(label): titlebar text=\(titlebarText) fullScreen=\(window.styleMask.contains(.fullScreen)) autoHideToolbar=\(options.contains(.autoHideToolbar)) contentHeight=\(Int(window.contentLayoutRect.height))")
        print("\(label): \(parts.joined(separator: " ")) frame=\(Int(window.frame.width))x\(Int(window.frame.height))@\(Int(window.frame.minX)),\(Int(window.frame.minY)) resizable=\(window.styleMask.contains(.resizable)) toolbar=\(window.toolbar.map { $0.isVisible ? "visible" : "hidden" } ?? "none") title=\(window.titleVisibility == .hidden ? "hidden" : "shown") items=\((window.toolbar?.items ?? []).map { "\($0.itemIdentifier.rawValue)\($0.isHidden ? "[hidden]" : "")" })")
        // METROLIST_WINDOWTEST_TREE=1: the views of the title bar area that draw something,
        // to find what shows above the full-screen player.
        if ProcessInfo.processInfo.environment["METROLIST_WINDOWTEST_TREE"] == "1", let frame = window.contentView?.superview {
            func dump(_ view: NSView, depth: Int) {
                guard depth < 14 else { return }
                let inTitlebar = view.convert(view.bounds, to: nil).maxY > window.frame.height - 80
                if inTitlebar || depth < 3 {
                    let effect = (view as? NSVisualEffectView).map { " material=\($0.material.rawValue) state=\($0.state.rawValue)" } ?? ""
                    let layer = view.layer.map { " layerBG=\($0.backgroundColor != nil) layerAlpha=\($0.opacity)" } ?? ""
                    print(String(repeating: "  ", count: depth) + "\(type(of: view)) \(Int(view.frame.minX)),\(Int(view.frame.minY)) \(Int(view.frame.width))x\(Int(view.frame.height))\(view.isHidden ? " HIDDEN" : "") alpha=\(view.alphaValue)\(effect)\(layer)")
                }
                for sub in view.subviews { dump(sub, depth: depth + 1) }
            }
            print("— view tree (\(label)) —")
            dump(frame, depth: 0)
        }
        // A picture of the whole window frame, title bar included, for checking by eye.
        if let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            let name = label.replacingOccurrences(of: " ", with: "-")
            try? rep.representation(using: .png, properties: [:])?.write(to: AppPaths.root.appendingPathComponent("window-\(name).png"))
        }
    }
}
