import Foundation

/// Caption interaction preferences are independent from the listening pill.
enum LiveCaptionDragPreferences {
    static let snappingEnabledKey = "hushtype.liveCaption.snappingEnabled"
    static let hapticsEnabledKey = "hushtype.liveCaption.hapticsEnabled"
    static let radiusKey = "hushtype.liveCaption.snapRadius"
    static let fadeExponentKey = "hushtype.liveCaption.fadeExponent"
    static let guideEnabledKey = "hushtype.liveCaption.guideEnabled"
    static let guideOpacityKey = "hushtype.liveCaption.guideOpacity"
    static let defaultRadius: CGFloat = 10

    static var snappingEnabled: Bool { bool(snappingEnabledKey, fallback: true) }
    static var hapticsEnabled: Bool { bool(hapticsEnabledKey, fallback: true) }
    static var snapRadius: CGFloat { number(radiusKey, fallback: 10, range: 2...40) }
    static var fadeExponent: CGFloat { number(fadeExponentKey, fallback: 2, range: 1...4) }
    static var guideEnabled: Bool { bool(guideEnabledKey, fallback: true) }
    static var guideOpacity: CGFloat { number(guideOpacityKey, fallback: 1, range: 0.1...1) }

    private static func bool(_ key: String, fallback: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? fallback
    }

    private static func number(_ key: String, fallback: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber,
              number.doubleValue.isFinite else { return fallback }
        return min(max(CGFloat(number.doubleValue), range.lowerBound), range.upperBound)
    }

    @discardableResult
    static func save(_ radius: CGFloat, defaults: UserDefaults = .standard) -> CGFloat {
        let value = radius.isFinite ? min(max(radius, 2), 40) : defaultRadius
        defaults.set(Double(value), forKey: radiusKey)
        return value
    }
}
