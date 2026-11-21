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
            // METROLIST_WINDOWTEST_PUSH=1: open a page with a back button first (a concert
            // page, which needs no network), to check the button doesn't show over the player.
            if ProcessInfo.processInfo.environment["METROLIST_WINDOWTEST_PUSH"] == "1" {
                AppModel.shared.push(.concert("windowtest"))
                try? await Task.sleep(for: .seconds(1))
            }
            report("normal")
            AppModel.shared.showExpandedPlayer = true
            try? await Task.sleep(for: .seconds(1.5))
            report("full-screen player")
            AppModel.shared.showExpandedPlayer = false
            try? await Task.sleep(for: .seconds(1.5))
            report("closed again")
            // Metrolist 14.0.1 fixed its Mac app not reopening after being hidden: close the
            // window, then send the event a click on the Dock icon sends.
            NSApp.windows.first { $0.title == "Metrolist" || $0.identifier?.rawValue.hasPrefix("main") == true }?.close()
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

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Metrolist" }
    }

    private static var mainVisible: Bool {
        NSApp.windows.contains { ($0.title == "Metrolist" || $0.identifier?.rawValue.hasPrefix("main") == true) && $0.isVisible }
    }

    /// A window button counts as usable when it and every view above it are shown and it
    /// sits inside the window's visible frame.
    private static func report(_ label: String) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Metrolist" }) else {
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
