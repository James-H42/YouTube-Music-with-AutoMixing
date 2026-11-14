import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        // Space toggles playback unless the user is typing.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            if event.window?.firstResponder is NSText { return event }
            MainActor.assumeIsolated { AppModel.shared.player.togglePlayPause() }
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}

struct MetrolistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model = AppModel.shared

    var body: some Scene {
        Window("Metrolist", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 700, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            PlaybackCommands(model: model)
        }

        Window("Mini Player", id: "mini") {
            MiniPlayerView()
                .environment(model)
        }
        .windowStyle(.plain)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 300, height: 300)
        .windowLevel(model.settings.miniPlayerOnTop ? .floating : .normal)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.topTrailing)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: Bindable(model.settings).showMenuBarPlayer) {
            MenuBarPlayerView()
                .environment(model)
        } label: {
            Image(systemName: model.player.isPlaying ? "music.note" : "music.note")
                .accessibilityLabel("Metrolist")
        }
        .menuBarExtraStyle(.window)
    }
}

struct PlaybackCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Playback") {
            Button(model.player.isPlaying ? "Pause" : "Play") { model.player.togglePlayPause() }
                .disabled(model.player.currentSong == nil)
            Button("Next") { model.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { model.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Increase Volume") { model.player.volume = min(1, model.player.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Decrease Volume") { model.player.volume = max(0, model.player.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button(model.player.volume == 0 ? "Unmute" : "Mute") { model.player.toggleMute() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { model.player.shuffle }, set: { _ in model.player.toggleShuffle() }))
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Cycle Repeat Mode") { model.player.cycleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Toggle("AutoMix", isOn: Bindable(model.settings).autoMix)
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(!model.player.autoMixAvailable)
            Button("Edit Transition…") {
                model.settings.autoMix = true
                model.showMixEditor = true
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(!model.player.autoMixAvailable)
            Divider()
            Menu("Sleep Timer") {
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) Minutes") { model.player.setSleepTimer(minutes: minutes) }
                }
                Divider()
                Button("Off") { model.player.setSleepTimer(minutes: nil) }
            }
        }
        CommandGroup(after: .sidebar) {
            Button("Show Lyrics") { model.toggleInspector(.lyrics) }
                .keyboardShortcut("l", modifiers: .command)
            Button("Show Up Next") { model.toggleInspector(.queue) }
                .keyboardShortcut("u", modifiers: .command)
            Button("Full Screen Player") { model.showExpandedPlayer.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
        }
        CommandGroup(after: .windowArrangement) {
            Button("Switch to Mini Player") {
                openWindow(id: "mini")
                dismissWindow(id: "main")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}
