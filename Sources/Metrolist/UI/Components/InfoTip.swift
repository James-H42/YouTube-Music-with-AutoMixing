import SwiftUI

/// A small ⓘ next to a setting. Hovering over it (or clicking it) shows a short explanation in
/// a popover; VoiceOver reads the explanation as the button's hint.
struct InfoTip: View {
    let text: String
    @ViewState private var hovering = false
    @ViewState private var pinned = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { pinned.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(hovering || pinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: Binding(get: { hovering || pinned }, set: { if !$0 { hovering = false; pinned = false } }), arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
        .accessibilityLabel("More information")
        .accessibilityHint(text)
    }
}

extension View {
    /// Puts an ⓘ with `text` after this label.
    func info(_ text: String) -> some View {
        HStack(spacing: 6) {
            self
            InfoTip(text)
        }
    }
}
