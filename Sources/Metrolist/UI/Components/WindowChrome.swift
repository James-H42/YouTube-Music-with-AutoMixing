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
        private var itemsObserver: NSObjectProtocol?
        var immersive = false { didSet { if immersive != oldValue { apply() } } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            if immersive {
                if savedTitle == nil { savedTitle = window.titleVisibility }
                window.titleVisibility = .hidden
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
                if let itemsObserver { NotificationCenter.default.removeObserver(itemsObserver) }
                itemsObserver = nil
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
            }
        }

        private func hideItems(of window: NSWindow) {
            for item in window.toolbar?.items ?? [] where !item.isHidden {
                item.isHidden = true
                hiddenItems.append(item)
            }
        }

        deinit {
            if let itemsObserver { NotificationCenter.default.removeObserver(itemsObserver) }
        }
    }
}
