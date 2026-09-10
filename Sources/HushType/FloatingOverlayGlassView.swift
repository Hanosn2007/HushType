import AppKit
import SwiftUI
import SwiftUI_SPI

/// System-owned ControlCenter material for the empty drag destination.
/// Opacity belongs to the panel; do not rewrite the material's internal filters.
@available(macOS 26.0, *)
final class FloatingOverlayGlassView: NSHostingView<FloatingOverlayControlCenterMaterial> {
    convenience init(frame frameRect: NSRect) {
        self.init(rootView: FloatingOverlayControlCenterMaterial())
        frame = frameRect
    }

    required init(rootView: FloatingOverlayControlCenterMaterial) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@available(macOS 26.0, *)
struct FloatingOverlayControlCenterMaterial: View {
    var body: some View {
        RoundedRectangle(
            cornerRadius: FloatingOverlayAppearance.cornerRadius,
            style: .continuous
        )
        .fill(SwiftUI_SPI.Material._glass(.controlCenter))
        .allowsHitTesting(false)
    }
}
