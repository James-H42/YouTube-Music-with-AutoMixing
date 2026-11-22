import SwiftUI

/// The covers of the full-screen player, and what they do during an AutoMix transition.
///
/// While a transition brings the next song in (`PlayerController.mixIncoming`, the first half
/// of the overlap), the next song's cover slides in from the right of the screen and the
/// playing song's cover moves left, so the two sit balanced about the centre. When the next
/// song takes over (half-way through, as the title and controls change to it), the old cover
/// slides away to the left and the new one moves into the centre at full size. Outside a
/// transition a change of song crossfades, as it always did.
///
/// The stage keeps the height of one full-size cover, so the title, scrubber and controls
/// below never move.
struct MixCoverStage: View {
    let current: Song?
    /// The song a running transition is bringing in, until it takes over.
    let incoming: Song?
    /// A transition is running: covers that arrive or leave slide rather than fade.
    let mixing: Bool
    let artSize: CGFloat
    /// The width the covers may use (the player's column).
    let width: CGFloat
    let isPlaying: Bool

    private struct Entry: Identifiable, Equatable {
        let song: Song
        let incoming: Bool
        var id: String { song.id }
        static func == (a: Entry, b: Entry) -> Bool { a.id == b.id && a.incoming == b.incoming }
    }

    /// Size, offset and travel for the covers.
    struct Geometry {
        let size: CGFloat
        let shift: CGFloat
        let travel: CGFloat

        init(paired: Bool, artSize: CGFloat, width: CGFloat) {
            let gap = max(24, artSize * 0.08)
            let pairSize = min(artSize * 0.82, max(80, (width - gap * 3) / 2))
            size = paired ? pairSize : artSize
            shift = paired ? (pairSize + gap) / 2 : 0
            // Far enough to start (or end) beyond the edge of the window.
            travel = width / 2 + artSize
        }
    }

    var body: some View {
        let paired = incoming != nil && incoming?.id != current?.id
        let layout = Geometry(paired: paired, artSize: artSize, width: width)
        let entries = [current.map { Entry(song: $0, incoming: false) }, paired ? incoming.map { Entry(song: $0, incoming: true) } : nil].compactMap { $0 }
        ZStack {
            if entries.isEmpty {
                ArtworkView(url: nil, size: artSize, cornerRadius: 16)
            }
            ForEach(entries) { entry in
                ArtworkView(url: entry.song.thumbnail, size: layout.size, cornerRadius: 16, pixelSize: 1000)
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                    .offset(x: entry.incoming ? layout.shift : -layout.shift)
                    .transition(mixing
                        ? .asymmetric(insertion: .offset(x: layout.travel), removal: .offset(x: -layout.travel).combined(with: .opacity))
                        : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: width, height: artSize)
        .scaleEffect(isPlaying ? 1 : 0.92)
        .animation(.spring(duration: 0.5), value: isPlaying)
        .animation(mixing ? .smooth(duration: 0.85) : .easeInOut(duration: 0.9), value: entries)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paired ? "Mixing \(current?.title ?? "") into \(incoming?.title ?? "")" : current?.title ?? "Not Playing")
    }
}

/// The full-screen player's backdrop: the playing song's cover, blurred. During a transition
/// the incoming song's colours fill the right half, blending into the playing song's on the
/// left through the middle; when it takes over, the left half fades over to it too.
struct MixBackdrop: View {
    let current: Song?
    let incoming: Song?
    let size: CGSize

    var body: some View {
        let paired = incoming != nil && incoming?.id != current?.id
        ZStack {
            // Nothing of the page shows through, even before the artwork loads.
            Color.black
            ForEach([current].compactMap { $0 }, id: \.id) { song in
                blurred(song)
                    .transition(.opacity)
            }
            if paired, let incoming {
                blurred(incoming)
                    .mask {
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0.3), .init(color: .black, location: 0.7)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    }
                    .transition(.opacity)
            }
        }
        .overlay(.black.opacity(0.55))
        .frame(width: size.width, height: size.height)
        .clipped()
        .animation(.easeInOut(duration: 1.1), value: current?.id)
        .animation(.easeInOut(duration: 0.9), value: paired)
    }

    private func blurred(_ song: Song) -> some View {
        ArtworkView(url: song.thumbnail, size: max(size.width, size.height), cornerRadius: 0, pixelSize: 240)
            .blur(radius: 90, opaque: true)
            .frame(width: size.width, height: size.height)
    }
}
