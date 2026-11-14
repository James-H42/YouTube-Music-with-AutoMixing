import SwiftUI

/// The glyph used for AutoMix throughout the app: two streams joining.
struct AutoMixGlyph: View {
    var animating = false

    var body: some View {
        Image(systemName: "arrow.trianglehead.merge")
            .symbolEffect(.pulse, options: .repeating, isActive: animating)
    }
}

/// One-click AutoMix switch for the player controls. Click to turn AutoMix on or off; hold or
/// right-click for the transition editor and mixing options. It is not shown while an album
/// plays in order, where AutoMix does not apply (unless albums were enabled in Settings).
struct AutoMixButton: View {
    var size: CGFloat = 14
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let player = model.player
        let isOn = model.settings.autoMix
        if player.autoMixAvailable {
            Menu {
                options
            } label: {
                AutoMixGlyph(animating: player.mixActivity != nil)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .allowsHitTesting(false)
                    .frame(minWidth: max(30, size + 6), minHeight: max(30, size + 6))
                    .contentShape(.rect)
            } primaryAction: {
                model.settings.autoMix.toggle()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .contextMenu { options }
            .help(isOn ? "AutoMix: On. Click to turn off; hold for the transition editor." : "AutoMix: Off. Click to mix between songs like a DJ.")
            .accessibilityLabel("AutoMix")
            .accessibilityValue(isOn ? "On" : "Off")
        }
    }

    @ViewBuilder
    private var options: some View {
        @Bindable var settings = model.settings
        Toggle("AutoMix", isOn: $settings.autoMix)
        Button("Edit Transition…", systemImage: "waveform.path") {
            settings.autoMix = true
            openWindow(id: "main")
            model.showMixEditor = true
        }
        Divider()
        Picker("Style", selection: $settings.mixStyle) {
            ForEach(MixStyle.allCases) { Text($0.title).tag($0) }
        }
        Picker("Length", selection: $settings.mixLength) {
            ForEach(MixLength.allCases) { Text($0.title).tag($0) }
        }
    }
}

/// Row of playback-mode toggles above the queue: Shuffle, Repeat, Autoplay and AutoMix.
struct QueueModeBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let player = model.player
        HStack(spacing: 8) {
            mode("Shuffle", isOn: player.shuffle) { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
            }
            mode(player.repeatMode == .one ? "Repeat One" : "Repeat", isOn: player.repeatMode != .off) { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
            }
            mode("Autoplay", isOn: settings.autoplay) { settings.autoplay.toggle() } label: {
                Image(systemName: "infinity")
            }
            if player.autoMixAvailable {
                mode("AutoMix", isOn: settings.autoMix) { settings.autoMix.toggle() } label: {
                    AutoMixGlyph(animating: player.mixActivity != nil)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func mode<Label: View>(_ title: String, isOn: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        let content = label()
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 22)
        Group {
            if isOn {
                Button(action: action) { content }.buttonStyle(.glassProminent)
            } else {
                Button(action: action) { content }.buttonStyle(.glass)
            }
        }
        .buttonBorderShape(.capsule)
        .help(isOn ? "\(title): On" : "\(title): Off")
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Shown in the queue between the playing track and the next: how AutoMix will join them.
struct TransitionRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if model.settings.autoMix, player.nextSong != nil {
            HStack(spacing: 10) {
                AutoMixGlyph(animating: player.mixActivity != nil)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                if let activity = player.mixActivity {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mixing now").font(.caption.weight(.semibold))
                        ProgressView(value: activity.progress).controlSize(.small)
                    }
                } else if let plan = player.nextMixPlan {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plan.summary).font(.caption.weight(.semibold))
                        let line = [plan.note, plan.detail].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !line.isEmpty {
                            Text(line).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                        }
                    }
                } else if player.isPreparingMix {
                    Text("Analysing the next track…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Plays straight through (same album)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if player.mixPair != nil {
                    Button("Edit") { model.showMixEditor = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Choose where and how these two songs are mixed")
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(.tint.opacity(0.08), in: .rect(cornerRadius: 8))
        }
    }
}

/// Under the full-screen player's controls: what AutoMix will do next. Click to edit it.
struct NextMixChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if player.autoMixActive, player.mixActivity == nil, let pair = player.mixPair {
            Button {
                model.showMixEditor = true
            } label: {
                HStack(spacing: 6) {
                    AutoMixGlyph()
                    if let plan = player.nextMixPlan {
                        Text(plan.summary).fontWeight(.semibold)
                        Text("into \(pair.next.title)").foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("Preparing the mix into \(pair.next.title)…").foregroundStyle(.secondary).lineLimit(1)
                    }
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: true, vertical: false)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .help("Edit this transition")
        }
    }
}

/// Small capsule that appears on the player while two tracks are being blended.
struct MixingBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let activity = model.player.mixActivity {
            HStack(spacing: 6) {
                AutoMixGlyph(animating: true)
                Text("AutoMix")
                Text(activity.plan.summary)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
