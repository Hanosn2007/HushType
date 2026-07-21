import SwiftUI

struct PolishCardView: View {
    let originalText: String
    let polishedText: String
    let changed: Bool

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

            Text("Original")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(originalText)
                .font(.system(size: 16))
                .lineSpacing(4)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            Text("Polished")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(polishedText)
                    .font(.system(size: 22, weight: .regular))
                    .lineSpacing(6)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 380)

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
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }
}
