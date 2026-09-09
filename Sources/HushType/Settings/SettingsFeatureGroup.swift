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
    }
}
