import SwiftUI

struct PolishCardView: View {
    let originalText: String
    let polishedText: String
    let changed: Bool

    /// Track-changes rendering; nil when the selection exceeds the diff
    /// token cap, in which case the card shows the polished text plain.
    private let diffText: AttributedString?

    init(originalText: String, polishedText: String, changed: Bool) {
        self.originalText = originalText
        self.polishedText = polishedText
        self.changed = changed
        self.diffText = changed
            ? PolishDiff.attributed(original: originalText, polished: polishedText)
            : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(changed ? "Text Polished" : "No changes needed")
                    .font(.headline)

                Spacer()

                if changed {
                    Label("Copied to clipboard", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Divider()

            if changed {
                HStack {
                    Text("Changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if diffText != nil {
                        legend
                    }
                }
            }

            ScrollView {
                Text(diffText ?? AttributedString(polishedText))
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 420)

            HStack(alignment: .bottom) {
                Text("Click outside to dismiss")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("On-device Apple Intelligence — nothing leaves your Mac.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("removed")
                .strikethrough()
                .foregroundStyle(Color(nsColor: .systemRed))
            Text("·")
                .foregroundStyle(.secondary)
            Text("added")
                .underline()
                .foregroundStyle(Color(nsColor: .systemGreen))
        }
        .font(.caption)
    }
}
