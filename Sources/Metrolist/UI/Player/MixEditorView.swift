import SwiftUI

extension MixLane {
    var color: Color {
        switch self {
        case .volume: Color(red: 0.36, green: 0.74, blue: 1.0)
        case .bass: Color(red: 1.0, green: 0.82, blue: 0.25)
        case .mid: Color(red: 1.0, green: 0.55, blue: 0.85)
        case .high: Color(white: 0.96)
        case .filter: Color(red: 0.45, green: 0.92, blue: 0.55)
        case .echo: Color(red: 0.72, green: 0.58, blue: 1.0)
        }
    }
}

/// Maps between the editor's canvas and positions in the two tracks.
private struct MixGeometry {
    var size: CGSize
    var plan: MixPlan

    static let pad: CGFloat = 14

    /// The transition itself: the part of the canvas where both tracks play.
    var window: CGRect {
        CGRect(x: size.width * 0.13, y: 0, width: size.width * 0.74, height: size.height)
    }

    func half(outgoing: Bool) -> CGRect {
        let height = size.height / 2 - 3
        return CGRect(x: 0, y: outgoing ? 0 : size.height - height, width: size.width, height: height)
    }

    /// Seconds of each track that the transition covers.
    var spans: (outgoing: Double, incoming: Double) { plan.span(glide: true) }

    func progress(at x: CGFloat) -> Double { Double((x - window.minX) / window.width) }

    func x(atProgress progress: Double) -> CGFloat { window.minX + CGFloat(progress) * window.width }

    /// Track time shown at a horizontal position. A looped section repeats.
    func time(at x: CGFloat, outgoing: Bool) -> Double {
        let p = progress(at: x)
        if outgoing {
            let time = plan.outStart + p * spans.outgoing
            if let loop = plan.loop, loop.length > 0.05, time > loop.start + loop.length {
                return loop.start + (time - loop.start).truncatingRemainder(dividingBy: loop.length)
            }
            return time
        }
        return plan.inPoint + p * spans.incoming
    }

    func y(for value: Double, outgoing: Bool) -> CGFloat {
        let rect = half(outgoing: outgoing)
        return rect.minY + Self.pad + CGFloat(1 - value) * (rect.height - Self.pad * 2)
    }

    func value(at y: CGFloat, outgoing: Bool) -> Double {
        let rect = half(outgoing: outgoing)
        return min(1, max(0, 1 - Double((y - rect.minY - Self.pad) / (rect.height - Self.pad * 2))))
    }

    func point(_ point: MixPoint, outgoing: Bool) -> CGPoint {
        CGPoint(x: x(atProgress: point.x), y: y(for: point.y, outgoing: outgoing))
    }
}

/// The two waveforms with the transition's automation drawn across them. Drag a waveform to
/// choose where each song is mixed; drag the points of the selected lane to shape the mix.
private struct MixCanvas: View {
    let plan: MixPlan
    let a: TrackAnalysis
    let b: TrackAnalysis
    let lane: MixLane
    /// Where playback is, as progress through the transition (may be outside 0…1), if nearby.
    let playhead: Double?
    let onChange: (MixPlan) -> Void
    let onCommit: (MixPlan, _ moved: Bool) -> Void

    private enum Drag {
        case point(outgoing: Bool, index: Int)
        case pan(outgoing: Bool, origin: Double)
    }

    @ViewState private var drag: Drag?
    @ViewState private var working: MixPlan?

    var body: some View {
        GeometryReader { proxy in
            let geometry = MixGeometry(size: proxy.size, plan: working ?? plan)
            Canvas { context, size in
                draw(&context, MixGeometry(size: size, plan: working ?? plan))
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragChanged(value, geometry) }
                    .onEnded { _ in dragEnded() }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { value in removePoint(at: value.location, geometry) }
            )
        }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ geometry: MixGeometry) {
        let plan = geometry.plan
        let window = geometry.window
        context.fill(Path(roundedRect: window, cornerRadius: 14), with: .color(.white.opacity(0.07)))

        // Beat grid of the outgoing track across the window; bar lines stand out.
        if plan.sync, plan.beats > 0 {
            for beat in 0 ... plan.beats {
                let x = geometry.x(atProgress: Double(beat) / Double(plan.beats))
                var line = Path()
                line.move(to: CGPoint(x: x, y: 4))
                line.addLine(to: CGPoint(x: x, y: geometry.size.height - 4))
                context.stroke(line, with: .color(.white.opacity(beat % 4 == 0 ? 0.13 : 0.045)), lineWidth: 1)
            }
        }

        waveform(&context, geometry, track: a, outgoing: true)
        waveform(&context, geometry, track: b, outgoing: false)

        if let loop = plan.loop, loop.length > 0.05 {
            let width = CGFloat(loop.length / max(0.1, geometry.spans.outgoing)) * window.width
            let rect = CGRect(x: window.minX, y: 4, width: min(width, window.width), height: geometry.half(outgoing: true).height - 8)
            context.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(.yellow.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }

        for outgoing in [true, false] {
            let lanes = outgoing ? plan.outgoing : plan.incoming
            // Lanes that do something are always visible; the selected one is drawn on top with handles.
            for other in MixLane.allCases where other != lane {
                let curve = lanes[other]
                guard !(curve.isConstant && abs((curve.points.first?.y ?? 0) - other.neutral) < 0.001) else { continue }
                context.stroke(path(curve, geometry, outgoing: outgoing), with: .color(other.color.opacity(0.55)), lineWidth: 1.5)
            }
            let curve = lanes[lane]
            context.stroke(path(curve, geometry, outgoing: outgoing), with: .color(lane.color), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            for point in curve.points {
                let centre = geometry.point(point, outgoing: outgoing)
                let dot = CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: dot), with: .color(.black.opacity(0.75)))
                context.stroke(Path(ellipseIn: dot), with: .color(lane.color), lineWidth: 2)
            }
        }

        if let playhead, playhead > -0.17, playhead < 1.17 {
            let x = geometry.x(atProgress: playhead)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: geometry.size.height))
            context.stroke(line, with: .color(Color(red: 0.3, green: 0.95, blue: 0.45)), lineWidth: 2.5)
        }
    }

    private func path(_ curve: MixCurve, _ geometry: MixGeometry, outgoing: Bool) -> Path {
        var path = Path()
        guard let first = curve.points.first, let last = curve.points.last else { return path }
        path.move(to: CGPoint(x: geometry.window.minX, y: geometry.y(for: first.y, outgoing: outgoing)))
        for point in curve.points { path.addLine(to: geometry.point(point, outgoing: outgoing)) }
        path.addLine(to: CGPoint(x: geometry.window.maxX, y: geometry.y(for: last.y, outgoing: outgoing)))
        return path
    }

    /// Three stacked bands, mirrored about the centre line: bass widest, highs innermost.
    private func waveform(_ context: inout GraphicsContext, _ geometry: MixGeometry, track: TrackAnalysis, outgoing: Bool) {
        let rect = geometry.half(outgoing: outgoing)
        let bands: [(data: Data, scale: CGFloat, color: Color)] = [
            (track.waveLow, 1.0, Color(red: 0.28, green: 0.22, blue: 0.92)),
            (track.waveMid, 0.78, Color(red: 0.88, green: 0.56, blue: 0.24)),
            (track.waveHigh, 0.5, Color(red: 0.99, green: 0.94, blue: 0.84)),
        ]
        guard track.waveRate > 0, !track.waveLow.isEmpty else { return }
        let step: CGFloat = 2
        let columns = Int(geometry.size.width / step)
        let middle = rect.midY
        let reach = rect.height / 2 - 6
        let window = geometry.window
        for band in bands {
            let bytes = [UInt8](band.data)
            var inside = Path()
            var outside = Path()
            for column in 0 ..< columns {
                let x = CGFloat(column) * step
                let start = geometry.time(at: x, outgoing: outgoing)
                let end = geometry.time(at: x + step, outgoing: outgoing)
                guard start >= 0, start < track.duration else { continue }
                let first = max(0, Int(start * track.waveRate))
                let last = min(bytes.count - 1, max(first, Int(end * track.waveRate)))
                guard first < bytes.count else { continue }
                var peak: UInt8 = 0
                for index in first ... last { peak = max(peak, bytes[index]) }
                let height = max(0.5, CGFloat(peak) / 255 * reach * band.scale)
                let bar = CGRect(x: x, y: middle - height, width: step, height: height * 2)
                if x >= window.minX, x < window.maxX { inside.addRect(bar) } else { outside.addRect(bar) }
            }
            context.fill(inside, with: .color(band.color))
            context.fill(outside, with: .color(band.color.opacity(0.3)))
        }
    }

    // MARK: Editing

    private func dragChanged(_ value: DragGesture.Value, _ geometry: MixGeometry) {
        var edited = working ?? plan
        if drag == nil {
            let start = value.startLocation
            let outgoing = start.y < geometry.size.height / 2
            let curve = (outgoing ? edited.outgoing : edited.incoming)[lane]
            if let index = curve.points.firstIndex(where: {
                let centre = geometry.point($0, outgoing: outgoing)
                return hypot(centre.x - start.x, centre.y - start.y) < 11
            }) {
                drag = .point(outgoing: outgoing, index: index)
            } else if geometry.window.contains(start),
                      abs(geometry.y(for: curve.value(at: geometry.progress(at: start.x)), outgoing: outgoing) - start.y) < 8 {
                // A click on the line itself adds a point there.
                var curve = curve
                let new = MixPoint(x: geometry.progress(at: start.x), y: geometry.value(at: start.y, outgoing: outgoing))
                let index = curve.points.firstIndex { $0.x > new.x } ?? curve.points.count
                curve.points.insert(new, at: index)
                if outgoing { edited.outgoing[lane] = curve } else { edited.incoming[lane] = curve }
                drag = .point(outgoing: outgoing, index: index)
            } else {
                drag = .pan(outgoing: outgoing, origin: outgoing ? edited.outStart : edited.inPoint)
            }
        }
        switch drag {
        case .point(let outgoing, let index):
            var curve = (outgoing ? edited.outgoing : edited.incoming)[lane]
            guard curve.points.indices.contains(index) else { return }
            // A point stays between its neighbours.
            let low = index > 0 ? curve.points[index - 1].x : 0
            let high = index + 1 < curve.points.count ? curve.points[index + 1].x : 1
            curve.points[index] = MixPoint(
                x: min(high, max(low, geometry.progress(at: value.location.x))),
                y: geometry.value(at: value.location.y, outgoing: outgoing)
            )
            if outgoing { edited.outgoing[lane] = curve } else { edited.incoming[lane] = curve }
        case .pan(let outgoing, let origin):
            // Dragging the waveform moves the music under the window.
            let spans = geometry.spans
            let shift = Double(value.translation.width / geometry.window.width) * (outgoing ? spans.outgoing : spans.incoming)
            if outgoing {
                edited.outStart = min(max(0, origin - shift), max(0, a.duration - 1))
                if var loop = edited.loop {
                    loop.start = edited.outStart
                    edited.loop = loop
                }
            } else {
                edited.inPoint = min(max(0, origin - shift), max(0, b.duration - 5))
            }
        case nil:
            return
        }
        working = edited
        onChange(edited)
    }

    private func dragEnded() {
        guard var edited = working else {
            drag = nil
            return
        }
        var moved = false
        if case .pan(let outgoing, _) = drag {
            moved = true
            // Land on the beat; on a bar line unless Option is held.
            let fine = NSEvent.modifierFlags.contains(.option)
            if edited.sync {
                if outgoing {
                    edited.outStart = a.beats[fine ? a.beatIndex(nearest: edited.outStart) : a.barIndex(nearest: edited.outStart)]
                } else {
                    edited.inPoint = b.beats[fine ? b.beatIndex(nearest: edited.inPoint) : b.barIndex(nearest: edited.inPoint)]
                }
            }
        }
        drag = nil
        working = nil
        onCommit(edited, moved)
    }

    private func removePoint(at location: CGPoint, _ geometry: MixGeometry) {
        var edited = plan
        let outgoing = location.y < geometry.size.height / 2
        var curve = (outgoing ? edited.outgoing : edited.incoming)[lane]
        guard curve.points.count > 2, let index = curve.points.firstIndex(where: {
            let centre = geometry.point($0, outgoing: outgoing)
            return hypot(centre.x - location.x, centre.y - location.y) < 11
        }) else { return }
        curve.points.remove(at: index)
        if outgoing { edited.outgoing[lane] = curve } else { edited.incoming[lane] = curve }
        onCommit(edited, false)
    }
}

/// Title, artist, tempo and key of one side of a transition.
private struct MixTrackHeader: View {
    let song: Song
    let analysis: TrackAnalysis?
    let caption: String

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: song.thumbnail, size: 46, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.headline).lineLimit(1)
                Text(song.artistText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let analysis {
                    Text(String(format: "%.0f BPM", analysis.bpm)).font(.callout.weight(.semibold)).monospacedDigit()
                    HStack(spacing: 6) {
                        Text(analysis.camelot)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color(hue: Double((Int(analysis.camelot.dropLast()) ?? 1) - 1) / 12, saturation: 0.55, brightness: 0.95), in: .rect(cornerRadius: 4))
                            .foregroundStyle(.black)
                            .help(analysis.keyName)
                        Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }
}

/// Editor for the transition between the playing song and the next: where each song is
/// mixed, for how long, and how volume, EQ, filter and echo move across the overlap.
struct MixEditorView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var lane: MixLane = .volume
    @ViewState private var draft: MixPlan?
    /// Preselected lane, for snapshots.
    var initialLane: MixLane?

    var body: some View {
        let player = model.player
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AutoMixGlyph(animating: player.mixActivity != nil)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Transition").font(.title3.bold())
                Spacer()
                Button("Done") { model.showMixEditor = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if let pair = player.mixPair, let a = player.analyses[pair.current.id], let b = player.analyses[pair.next.id],
               let plan = draft ?? player.nextMixPlan {
                editor(plan, pair.current, pair.next, a, b)
            } else {
                unavailable
            }
        }
        .frame(width: 620)
        .frame(minHeight: 420)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .environment(\.colorScheme, .dark)
        .onAppear { if let initialLane { lane = initialLane } }
        .onChange(of: player.currentSong?.id) { draft = nil }
    }

    @ViewBuilder
    private var unavailable: some View {
        let player = model.player
        VStack(spacing: 14) {
            Spacer()
            if !model.settings.autoMix {
                ContentUnavailableView("AutoMix Is Off", systemImage: "arrow.trianglehead.merge", description: Text("Turn it on to mix between songs and edit how they join."))
                Button("Turn On AutoMix") { model.settings.autoMix = true }.buttonStyle(.glassProminent)
            } else if player.nextSong == nil {
                ContentUnavailableView("Nothing Up Next", systemImage: "list.bullet", description: Text("Add another song to the queue to mix into it."))
            } else if player.mixPair == nil {
                ContentUnavailableView("Plays Straight Through", systemImage: "square.stack", description: Text("These songs follow each other on an album, so they play as sequenced. You can change this in Settings."))
            } else {
                ProgressView().controlSize(.large)
                Text("Listening to both songs…").foregroundStyle(.secondary)
                Text("AutoMix is finding their beats, keys, sections and shared lyrics. The next song has to finish downloading first.")
                    .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .padding(20)
    }

    private func editor(_ plan: MixPlan, _ current: Song, _ next: Song, _ a: TrackAnalysis, _ b: TrackAnalysis) -> some View {
        let player = model.player
        let span = plan.span(glide: true)
        return VStack(spacing: 12) {
            MixTrackHeader(song: current, analysis: a, caption: "out at \(formatDuration(plan.outStart))")
                .padding(.horizontal, 20)

            MixCanvas(
                plan: plan, a: a, b: b, lane: lane, playhead: playhead(plan, span.outgoing),
                onChange: { draft = $0 },
                onCommit: { edited, _ in commit(edited) }
            )
            .frame(height: 330)
            .overlay {
                Button {
                    player.mixActivity == nil ? player.previewMix() : player.pause()
                } label: {
                    Image(systemName: player.mixActivity != nil && player.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 52, height: 38)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 13))
                .help("Hear this transition from a few seconds before it starts")
            }
            .overlay(alignment: .bottom) {
                lengthMenu(plan).offset(y: 14)
            }
            .padding(.bottom, 10)

            MixTrackHeader(song: next, analysis: b, caption: "in at \(formatDuration(plan.inPoint))")
                .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(plan.summary + (plan.detail.isEmpty ? "" : "  ·  " + plan.detail)).font(.callout.weight(.semibold)).monospacedDigit()
                if !plan.note.isEmpty { Text(plan.note).font(.caption).foregroundStyle(.secondary) }
                if let lyrics = player.mixLyricsNote {
                    Label(lyrics, systemImage: "quote.bubble").font(.caption2).foregroundStyle(.tertiary)
                }
                if player.isAuditioningMix {
                    HStack(spacing: 8) {
                        Label("Trying this out. It isn't saved for these songs.", systemImage: "ear")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Keep") { player.keepAuditionedMix() }
                            .help("Always use this transition between these two songs")
                        Button("Discard") { player.endMixAudition() }
                            .help(player.hasSavedMix ? "Go back to the transition saved for these songs" : "Go back to AutoMix's choice")
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                } else if player.hasSavedMix {
                    Label("Saved for these two songs. Choose Auto to remove it.", systemImage: "pin")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)

            Picker("Lane", selection: $lane) {
                ForEach(MixLane.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .help("Choose which curve to edit. Drag its points, click the line to add one, double-click a point to remove it.")

            HStack(spacing: 16) {
                Toggle("Beat-match", isOn: Binding(get: { plan.sync }, set: { setSync($0, plan, a, b) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Stretch the songs to a shared tempo and line their beats up")
                Stepper(value: Binding(get: { plan.outgoingPitch ?? 0 }, set: { value in
                    var edited = plan
                    edited.outgoingPitch = value == 0 ? nil : value
                    // Any older shift of the next song is replaced by this one.
                    edited.pitchShift = 0
                    commit(edited)
                }), in: -8 ... 8, step: 1) {
                    let bend = plan.outgoingPitch ?? 0
                    Text(bend == 0 ? "Pitch drift: none" : String(format: "Pitch drift: %+.0f st", bend))
                        .monospacedDigit()
                }
                .controlSize(.small)
                .help("The playing song's pitch drifts by this much, slowly, before the transition starts, so it meets the next song's key and the next song plays unchanged")
                if MixPlanner.isTempoMatched(plan) {
                    Text(String(format: "Speed → %.0f %%", plan.periodA / plan.periodB * 100)).font(.callout).monospacedDigit()
                        .help("The playing song eases to the next song's tempo before the transition starts")
                }
                Spacer()
                Text("Drag a waveform to move its mix point")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)

            Divider().padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if plan.isCustom, plan.preset == .custom { presetButton(.custom, selected: true) }
                    ForEach(MixPreset.selectable) { preset in
                        presetButton(preset, selected: plan.isCustom ? plan.preset == preset : preset == .auto)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }

            let proposals = player.nextMixCandidates
            if proposals.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AutoMix found").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(proposals.prefix(4)) { proposal in
                        proposalRow(proposal, selected: abs(proposal.outStart - plan.outStart) < 0.05 && abs(proposal.inPoint - plan.inPoint) < 0.05)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 18)
    }

    private func presetButton(_ preset: MixPreset, selected: Bool) -> some View {
        Button {
            draft = nil
            if preset != .custom { model.player.applyMixPreset(preset) }
        } label: {
            Label(preset.title, systemImage: preset.symbol)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Color.black : Color.white)
                .background(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1)), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(preset.help)
    }

    private func proposalRow(_ proposal: MixPlan, selected: Bool) -> some View {
        Button {
            draft = nil
            model.player.chooseMixCandidate(proposal)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                Text(proposal.summary).font(.callout.weight(.medium))
                Text(proposal.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(formatDuration(proposal.outStart)) → \(formatDuration(proposal.inPoint))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Mix out of the first song at \(formatDuration(proposal.outStart)) and into the next at \(formatDuration(proposal.inPoint))")
    }

    private func lengthMenu(_ plan: MixPlan) -> some View {
        Menu {
            if plan.sync {
                ForEach([1, 2, 4, 8, 16, 32], id: \.self) { bars in
                    Button("\(bars) bar\(bars == 1 ? "" : "s")") {
                        var edited = plan
                        edited.beats = bars * 4
                        commit(edited)
                    }
                }
            } else {
                ForEach([1, 2, 4, 7, 11, 16, 24], id: \.self) { seconds in
                    Button("\(seconds) seconds") {
                        var edited = plan
                        edited.seconds = Double(seconds)
                        commit(edited)
                    }
                }
            }
        } label: {
            Text(plan.sync ? "\(plan.beats / 4 >= 1 ? "\(plan.beats / 4) bar\(plan.beats / 4 == 1 ? "" : "s")" : "\(plan.beats) beats")" : "\(Int(plan.seconds.rounded())) s")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .help("Length of the transition")
    }

    /// Progress through the transition at the current playback position, when it is in view.
    private func playhead(_ plan: MixPlan, _ spanA: Double) -> Double? {
        let player = model.player
        if let activity = player.mixActivity { return activity.progress }
        guard spanA > 0 else { return nil }
        return (player.position - plan.outStart) / spanA
    }

    private func commit(_ plan: MixPlan) {
        var edited = plan
        edited.preset = .custom
        edited.reason = .manual
        edited.note = "Edited by you"
        draft = nil
        model.player.setCustomMix(edited)
    }

    private func setSync(_ sync: Bool, _ plan: MixPlan, _ a: TrackAnalysis, _ b: TrackAnalysis) {
        if sync {
            // Whole bars, both ends on bar lines, tempos locked and the key nudged if it helps.
            draft = nil
            model.player.beatMatchMix(plan)
            return
        }
        var edited = plan
        edited.sync = false
        edited.forceSync = nil
        edited.seconds = plan.duration(glide: true)
        edited.loop = nil
        commit(edited)
    }
}
