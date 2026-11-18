import SwiftUI
import UniformTypeIdentifiers

/// The equaliser window: a response curve with draggable band handles, the band table, and
/// profile management (presets, saved profiles, AutoEQ import).
struct EqualizerView: View {
    @Bindable private var eq = MasterEQ.shared
    @ViewState private var importing = false
    @ViewState private var askingName = false
    @ViewState private var askingURL = false
    @ViewState private var name = ""
    @ViewState private var address = ""
    @ViewState private var notice: String?

    var body: some View {
        VStack(spacing: 14) {
            header
            EQCurve(eq: eq)
                .frame(minHeight: 230)
            HStack {
                Text("Preamp")
                Slider(value: $eq.profile.preamp, in: EQProfile.preampRange)
                Text(String(format: "%+.1f dB", eq.profile.preamp)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            bandTable
            if let notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
            Text("The equaliser sits after AutoMix's mixing, so transitions are unchanged. When it, or the loudness boost, adds gain, a limiter keeps the sum from clipping.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 560)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= AutoEQ.maxBytes, let text = String(data: data, encoding: .utf8),
                  let parsed = AutoEQ.parse(text, name: url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ParametricEQ", with: ""))
            else { notice = "That isn't an AutoEQ ParametricEQ.txt profile."; return }
            adopt(parsed)
        }
        .alert("Save profile", isPresented: $askingName) {
            TextField("Name", text: $name)
            Button("Save") { if !name.trimmingCharacters(in: .whitespaces).isEmpty { eq.saveCurrent(as: name.trimmingCharacters(in: .whitespaces)) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Import from AutoEq", isPresented: $askingURL) {
            TextField("https://raw.githubusercontent.com/…/ParametricEQ.txt", text: $address)
            Button("Import") {
                Task {
                    do { adopt(try await AutoEQ.download(address)) } catch { notice = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste the address of a ParametricEQ.txt file from the AutoEq project.")
        }
    }

    private func adopt(_ parsed: AutoEQ.Result) {
        eq.choose(parsed.profile)
        eq.enabled = true
        notice = parsed.skipped > 0 ? "Imported “\(parsed.profile.name)”; \(parsed.skipped) filter(s) of a kind this equaliser doesn't have were left out." : "Imported “\(parsed.profile.name)”."
    }

    private var header: some View {
        HStack {
            Toggle("Equalizer", isOn: $eq.enabled)
                .toggleStyle(.switch)
                .font(.headline)
            Spacer()
            Text(eq.profile.name).foregroundStyle(.secondary)
            Menu("Profile") {
                ForEach(eq.presets) { preset in Button(preset.name) { eq.choose(preset) } }
                if !eq.saved.isEmpty {
                    Divider()
                    ForEach(eq.saved) { profile in Button(profile.name) { eq.choose(profile) } }
                }
                Divider()
                Button("Import AutoEQ File…") { importing = true }
                Button("Import AutoEQ from Web…") { address = ""; askingURL = true }
                Button("Save Current As…") { name = eq.profile.name; askingName = true }
                if !eq.saved.isEmpty {
                    Menu("Delete Saved Profile") {
                        ForEach(eq.saved) { profile in Button(profile.name, role: .destructive) { eq.deleteSaved(profile.id) } }
                    }
                }
            }
            .fixedSize()
        }
    }

    private var bandTable: some View {
        VStack(spacing: 6) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($eq.profile.bands) { $band in
                        HStack(spacing: 8) {
                            Toggle("On", isOn: $band.enabled).labelsHidden()
                            Picker("Type", selection: $band.kind) {
                                ForEach(EQBand.Kind.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            field(value: $band.frequency, range: EQBand.frequencyRange, unit: "Hz", digits: 0)
                            if band.kind.hasGain { field(value: $band.gain, range: EQBand.gainRange, unit: "dB", digits: 1) } else { Spacer().frame(width: 84) }
                            field(value: $band.q, range: EQBand.qRange, unit: "Q", digits: 2)
                            Button { eq.removeBand(band.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove this band")
                        }
                    }
                }
            }
            .frame(maxHeight: 190)
            HStack {
                Button("Add Band") { eq.addBand() }.disabled(eq.profile.bands.count >= EQProfile.maxBands)
                Button("Reset") { eq.choose(.flat) }.disabled(eq.profile.isFlat)
                Spacer()
            }
        }
    }

    private func field(value: Binding<Double>, range: ClosedRange<Double>, unit: String, digits: Int) -> some View {
        HStack(spacing: 3) {
            TextField("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(0 ... digits)))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 62)
            Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
        }
    }
}

/// The response curve. Dragging a handle moves a band's frequency and gain.
private struct EQCurve: View {
    @Bindable var eq: MasterEQ
    private static let decibels = 15.0
    @ViewState private var dragging: UUID?

    private func x(_ frequency: Double, _ width: CGFloat) -> CGFloat {
        CGFloat(log10(frequency / 20) / log10(1_000)) * width
    }

    private func frequency(_ x: CGFloat, _ width: CGFloat) -> Double {
        20 * pow(1_000, Double(min(max(0, x / width), 1)))
    }

    private func y(_ decibels: Double, _ height: CGFloat) -> CGFloat {
        CGFloat(0.5 - decibels / (2 * Self.decibels)) * height
    }

    private func gain(_ y: CGFloat, _ height: CGFloat) -> Double {
        Double(0.5 - min(max(0, y / height), 1)) * 2 * Self.decibels
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for decibels in stride(from: -12.0, through: 12.0, by: 6.0) {
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: y(decibels, size.height)))
                        line.addLine(to: CGPoint(x: size.width, y: y(decibels, size.height)))
                        context.stroke(line, with: .color(.secondary.opacity(decibels == 0 ? 0.55 : 0.2)), lineWidth: 1)
                        context.draw(Text("\(Int(decibels))").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: 12, y: y(decibels, size.height) - 7))
                    }
                    for frequency in [50.0, 100, 200, 500, 1_000, 2_000, 5_000, 10_000] {
                        var line = Path()
                        line.move(to: CGPoint(x: x(frequency, size.width), y: 0))
                        line.addLine(to: CGPoint(x: x(frequency, size.width), y: size.height))
                        context.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 1)
                        let label = frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
                        context.draw(Text(label).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: x(frequency, size.width) + 10, y: size.height - 8))
                    }
                    var curve = Path()
                    let steps = 240
                    for step in 0 ... steps {
                        let f = 20 * pow(1_000, Double(step) / Double(steps))
                        let point = CGPoint(x: x(f, size.width), y: y(max(-Self.decibels, min(Self.decibels, EQMath.response(eq.profile, at: f))), size.height))
                        step == 0 ? curve.move(to: point) : curve.addLine(to: point)
                    }
                    context.stroke(curve, with: .color(eq.enabled ? .orange : .secondary), lineWidth: 2.5)
                }
                ForEach(eq.profile.bands) { band in
                    Circle()
                        .fill(band.enabled ? Color.orange : Color.secondary)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                        .frame(width: 14, height: 14)
                        .position(x: x(band.frequency, size.width), y: y(band.kind.hasGain ? band.gain : 0, size.height))
                        .help(String(format: "%.0f Hz", band.frequency))
                }
            }
            .coordinateSpace(.named("eqcurve"))
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("eqcurve"))
                    .onChanged { value in
                        if dragging == nil {
                            // Pick up the band nearest to where the drag started.
                            dragging = eq.profile.bands.min { distance($0, to: value.startLocation, size) < distance($1, to: value.startLocation, size) }
                                .flatMap { distance($0, to: value.startLocation, size) < 24 ? $0.id : nil }
                        }
                        guard let id = dragging, let index = eq.profile.bands.firstIndex(where: { $0.id == id }) else { return }
                        eq.profile.bands[index].frequency = min(max(frequency(value.location.x, size.width), 20), 20_000)
                        if eq.profile.bands[index].kind.hasGain {
                            eq.profile.bands[index].gain = (min(max(gain(value.location.y, size.height), -Self.decibels), Self.decibels) * 10).rounded() / 10
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    private func distance(_ band: EQBand, to point: CGPoint, _ size: CGSize) -> CGFloat {
        let center = CGPoint(x: x(band.frequency, size.width), y: y(band.kind.hasGain ? band.gain : 0, size.height))
        return hypot(center.x - point.x, center.y - point.y)
    }
}
