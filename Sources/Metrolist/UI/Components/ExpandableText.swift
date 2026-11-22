import SwiftUI

/// A few lines of a long text (an artist's biography) with a "More" button when there is
/// more to read. As in Apple Music, More opens the whole text in a sheet.
struct ExpandableText: View {
    let text: String
    /// Heading of the sheet, such as "About The Beatles".
    let title: String
    var lineLimit = 3

    @ViewState private var limitedHeight: CGFloat = 0
    @ViewState private var fullHeight: CGFloat = 0
    @ViewState private var showAll = false

    private var truncated: Bool { fullHeight > limitedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .lineLimit(lineLimit)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { limitedHeight = $0 }
                // The same text without a limit, measured but not shown, says whether
                // anything was cut off.
                .background(alignment: .topLeading) {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
            if truncated {
                Button("More") { showAll = true }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .sheet(isPresented: $showAll) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title).font(.title2.bold())
                    Spacer()
                    Button("Done") { showAll = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(20)
                Divider()
                ScrollView {
                    Text(text)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
            .frame(width: 560, height: 520)
        }
    }
}
