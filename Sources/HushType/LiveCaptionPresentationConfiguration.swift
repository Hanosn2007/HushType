import Foundation

/// Presentation limits affect the visible panel, never transcript retention.
struct LiveCaptionPresentationConfiguration: Equatable {
    var maximumAutomaticSentences: Int
    var maximumAutomaticWidth: CGFloat
    var maximumAutomaticHeight: CGFloat

    static let maximumAutomaticSentencesKey = "hushtype.liveCaption.maximumAutomaticSentences"
    static let maximumAutomaticWidthKey = "hushtype.liveCaption.maximumAutomaticWidth"
    static let maximumAutomaticHeightKey = "hushtype.liveCaption.maximumAutomaticHeight"
    static let defaults = Self(
        maximumAutomaticSentences: 6,
        maximumAutomaticWidth: 720,
        maximumAutomaticHeight: 420
    )

    static func load(defaults store: UserDefaults = .standard) -> Self {
        func number(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
            guard let number = store.object(forKey: key) as? NSNumber,
                  number.doubleValue.isFinite else { return fallback }
            return min(max(number.doubleValue, range.lowerBound), range.upperBound)
        }
        return Self(
            maximumAutomaticSentences: Int(number(
                maximumAutomaticSentencesKey,
                fallback: Double(defaults.maximumAutomaticSentences), range: 1...30
            )),
            maximumAutomaticWidth: CGFloat(number(
                maximumAutomaticWidthKey,
                fallback: Double(defaults.maximumAutomaticWidth), range: 280...1600
            )),
            maximumAutomaticHeight: CGFloat(number(
                maximumAutomaticHeightKey,
                fallback: Double(defaults.maximumAutomaticHeight), range: 120...800
            ))
        )
    }
}
