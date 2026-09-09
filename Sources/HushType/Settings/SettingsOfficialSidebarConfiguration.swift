import Foundation

/// Preview-only parameters for the macOS 26 public sidebar scroll-edge effect.
///
/// These keys are deliberately separate from the private right-side blur
/// configuration so either side can be reset without changing the other.
struct SettingsOfficialSidebarConfiguration: Equatable {
    enum Style: String, CaseIterable {
        case soft
        case hard
        case automatic
    }

    let style: Style
    let barHeight: CGFloat
    let barSpacing: CGFloat

    static let styleKey = "hushtype.preview.sidebarOfficial.style"
    static let barHeightKey = "hushtype.preview.sidebarOfficial.barHeight"
    static let barSpacingKey = "hushtype.preview.sidebarOfficial.barSpacing"

    static let defaultStyle: Style = .soft
    static let defaultBarHeight: CGFloat = 52
    static let defaultBarSpacing: CGFloat = 0
    static let allowedBarHeightRange: ClosedRange<CGFloat> = 24...240
    static let allowedBarSpacingRange: ClosedRange<CGFloat> = 0...80

    static var current: Self {
        load()
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(
            style: Style(rawValue: defaults.string(forKey: styleKey) ?? "") ?? defaultStyle,
            barHeight: sanitized(
                number(forKey: barHeightKey, defaults: defaults),
                range: allowedBarHeightRange,
                fallback: defaultBarHeight
            ),
            barSpacing: sanitized(
                number(forKey: barSpacingKey, defaults: defaults),
                range: allowedBarSpacingRange,
                fallback: defaultBarSpacing
            )
        )
    }

    static func make(styleRawValue: String, barHeight: Double, barSpacing: Double) -> Self {
        Self(
            style: Style(rawValue: styleRawValue) ?? defaultStyle,
            barHeight: sanitized(CGFloat(barHeight), range: allowedBarHeightRange, fallback: defaultBarHeight),
            barSpacing: sanitized(CGFloat(barSpacing), range: allowedBarSpacingRange, fallback: defaultBarSpacing)
        )
    }

    private static func number(forKey key: String, defaults: UserDefaults) -> CGFloat? {
        guard let value = defaults.object(forKey: key) as? NSNumber else { return nil }
        let number = CGFloat(value.doubleValue)
        return number.isFinite ? number : nil
    }

    private static func sanitized(
        _ value: CGFloat?,
        range: ClosedRange<CGFloat>,
        fallback: CGFloat
    ) -> CGFloat {
        guard let value, value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
