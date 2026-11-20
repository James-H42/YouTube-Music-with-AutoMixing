import SwiftUI

enum FilterCount {
    /// "3 of 120 songs".
    static func text(shown: Int, total: Int, noun: String) -> String {
        "\(shown) of \(total) \(noun)\(total == 1 ? "" : "s")"
    }
}

/// A filter box for a list, with the number of matches beside it while text is typed
/// ("3 of 120 songs"). `loading` adds a spinner while the rest of a long list is fetched.
struct FilterField: View {
    @Binding var text: String
    let shown: Int
    let total: Int
    var noun = "song"
    var loading = false

    var body: some View {
        HStack(spacing: 10) {
            TextField("Filter", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            if !text.isEmpty {
                Text(FilterCount.text(shown: shown, total: total, noun: noun) + (loading ? "…" : ""))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: shown)
                if loading { ProgressView().controlSize(.small) }
            }
        }
    }
}

extension Song {
    /// Whether a filter typed over a list of songs matches this one: its title or artists.
    func matchesFilter(_ text: String) -> Bool {
        text.isEmpty || title.localizedCaseInsensitiveContains(text) || artistText.localizedCaseInsensitiveContains(text)
    }
}
