import SwiftUI

/// A feature's title stays visible while its related controls expand together.
/// Disclosure is presentation state only; it never enables/disables the feature.
struct SettingsFeatureGroup<Content: View>: View {
    let title: String
    let systemImage: String
    private let content: Content
    @State private var isExpanded = false

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disclosureGroupStyle(SettingsFeatureGroupStyle())
    }
}

private struct SettingsFeatureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(configuration.isExpanded
                ? L10n.string("settings.feature_group.expanded", fallback: "Expanded")
                : L10n.string("settings.feature_group.collapsed", fallback: "Collapsed")))

            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, 20)
            }
        }
    }
}
