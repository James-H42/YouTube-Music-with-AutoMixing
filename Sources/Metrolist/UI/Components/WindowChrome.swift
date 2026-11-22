import AppKit
import SwiftUI

/// While the full-screen player covers the main window, hides the toolbar's contents (search
/// field, buttons, page title) without hiding the toolbar itself, so the title bar keeps its
/// height and the close, minimise and zoom buttons stay where they are.
///
/// Neither SwiftUI's `.toolbar(.hidden, for: .windowToolbar)` (it hides the traffic lights
/// too) nor `NSToolbar.isVisible = false` is used: changing the title bar's height makes
/// macOS window tiling place a tiled window again, which shrank a window tiled to fill the
/// screen into the top half of it.
struct ImmersiveWindowChrome: NSViewRepresentable {
    let immersive: Bool

    /// The app's presentation options for the player: while it is open in macOS full screen the
    /// toolbar auto-hides; otherwise as macOS set them. Nil: leave them as they are. The toolbar
    /// may only auto-hide in full screen with the menu bar and Dock auto-hiding (as macOS full
    /// screen has them); AppKit raises an exception for any other combination.
    static func presentation(_ options: NSApplication.PresentationOptions, immersive: Bool, windowFullScreen: Bool, leaving: Bool) -> NSApplication.PresentationOptions? {
        let inFullScreen = windowFullScreen && options.contains(.fullScreen) && !leaving
        if immersive, inFullScreen, !options.contains(.autoHideToolbar) {
            guard options.contains(.autoHideMenuBar), options.contains(.autoHideDock) || options.contains(.hideDock) else { return nil }
            return options.union(.autoHideToolbar)
        }
        if !(immersive && inFullScreen), options.contains(.autoHideToolbar) {
            return options.subtracting(.autoHideToolbar)
        }
        return nil
    }

    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.immersive = immersive
        view.rehide()
    }

    final class ChromeView: NSView {
        private var savedTitle: NSWindow.TitleVisibility?
        private var savedTransparent: Bool?
        /// Items this view hid, so only those are shown again.
        private var hiddenItems: [NSToolbarItem] = []
        /// A page's toolbar items show themselves again when the page updates them (the
        /// Concerts page's sort menu and refresh button reappeared over the player once its
        /// list refreshed): these hide them again.
        private var itemObservations: [NSKeyValueObservation] = []
        private var itemsObserver: NSObjectProtocol?
        /// SwiftUI shows the window title again as the page underneath updates (the page's
        /// name then showed over the player): this hides it again while the player is open.
        private var titleObservation: NSKeyValueObservation?
        private var fullScreenObservers: [NSObjectProtocol] = []
        var immersive = false { didSet { if immersive != oldValue { apply() } } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in fullScreenObservers { NotificationCenter.default.removeObserver(observer) }
            fullScreenObservers = []
            if let window {
                // In macOS full screen the toolbar lives in a window of its own above the
                // content, which the transparent title bar doesn't reach.
                for name in [NSWindow.didEnterFullScreenNotification, NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    fullScreenObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                        MainActor.assumeIsolated { self?.updateFullScreenToolbar(leaving: note.name == NSWindow.willExitFullScreenNotification) }
                    })
                }
            }
            apply()
        }

        /// While the player is open in macOS full screen, the toolbar slides away and comes
        /// back when the pointer reaches the top of the screen, as in QuickTime Player; it
        /// covered the top of a music video. Outside full screen nothing changes.
        private func updateFullScreenToolbar(leaving: Bool = false) {
            guard let window else { return }
            if let options = ImmersiveWindowChrome.presentation(NSApp.presentationOptions, immersive: immersive,
                                                                windowFullScreen: window.styleMask.contains(.fullScreen), leaving: leaving) {
                NSApp.presentationOptions = options
            }
        }

        private func apply() {
            guard let window else { return }
            updateFullScreenToolbar()
            if immersive {
                if savedTitle == nil { savedTitle = window.titleVisibility }
                window.titleVisibility = .hidden
                if titleObservation == nil {
                    titleObservation = window.observe(\.titleVisibility, options: [.new]) { [weak self] window, _ in
                        DispatchQueue.main.async {
                            guard let self, self.immersive, window.titleVisibility != .hidden else { return }
                            window.titleVisibility = .hidden
                        }
                    }
                }
                // The page's title bar background (and its scroll edge effect) is drawn above
                // all content, so it showed as a grey band across the top of the player. A
                // transparent title bar draws none and keeps its height.
                if savedTransparent == nil { savedTransparent = window.titlebarAppearsTransparent }
                window.titlebarAppearsTransparent = true
                hideItems(of: window)
                // SwiftUI can add toolbar items while the player is open (the progress
                // indicator, for one); hide those as they arrive.
                if itemsObserver == nil, let toolbar = window.toolbar {
                    itemsObserver = NotificationCenter.default.addObserver(forName: NSToolbar.willAddItemNotification, object: toolbar, queue: .main) { [weak self] _ in
                        // Sent before the item joins `items`: look on the next turn.
                        DispatchQueue.main.async {
                            guard let self, self.immersive, let window = self.window else { return }
                            self.hideItems(of: window)
                        }
                    }
                }
            } else {
                titleObservation = nil
                if let itemsObserver { NotificationCenter.default.removeObserver(itemsObserver) }
                itemsObserver = nil
                itemObservations = []
                for item in hiddenItems { item.isHidden = false }
                hiddenItems = []
                if let savedTitle { window.titleVisibility = savedTitle }
                savedTitle = nil
                if let savedTransparent { window.titlebarAppearsTransparent = savedTransparent }
                savedTransparent = nil
            }
        }

        /// SwiftUI rebuilds toolbar items when the page changes underneath the player.
        func rehide() {
            guard immersive, let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.immersive else { return }
                self.hideItems(of: window)
                if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            }
        }

        private func hideItems(of window: NSWindow) {
            for item in window.toolbar?.items ?? [] where !item.isHidden {
                item.isHidden = true
                guard !hiddenItems.contains(where: { $0 === item }) else { continue }
                hiddenItems.append(item)
                itemObservations.append(item.observe(\.isHidden, options: [.new]) { [weak self] item, _ in
                    DispatchQueue.main.async {
                        guard let self, self.immersive, !item.isHidden else { return }
                        item.isHidden = true
                    }
                })
            }
        }

        deinit {
            if let itemsObserver { NotificationCenter.default.removeObserver(itemsObserver) }
            for observer in fullScreenObservers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
