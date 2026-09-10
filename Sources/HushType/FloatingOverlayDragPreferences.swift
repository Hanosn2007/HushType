import Foundation

/// The drag path reads this value on each move so Preview tuning applies live.
enum FloatingOverlayDragPreferences {
    static let radiusKey = "hushtype.overlay.snapRadius"
    static let defaultRadius: CGFloat = 10
    static let allowedRadius: ClosedRange<CGFloat> = 2...40

    static var snapRadius: CGFloat { load() }
    static let fadeExponentKey = "hushtype.overlay.fadeExponent"
    static var fadeExponent: CGFloat { value(fadeExponentKey, fallback: 2, range: 1...4) }

    private static func value(_ key: String, fallback: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber,
              number.doubleValue.isFinite else { return fallback }
        return min(max(CGFloat(number.doubleValue), range.lowerBound), range.upperBound)
    }

    static func load(defaults: UserDefaults = .standard) -> CGFloat {
        guard let number = defaults.object(forKey: radiusKey) as? NSNumber else {
            return defaultRadius
        }
        return sanitized(CGFloat(number.doubleValue))
    }

    @discardableResult
    static func save(_ radius: CGFloat, defaults: UserDefaults = .standard) -> CGFloat {
        let radius = sanitized(radius)
        defaults.set(Double(radius), forKey: radiusKey)
        return radius
    }

    static func sanitized(_ radius: CGFloat) -> CGFloat {
        guard radius.isFinite else { return defaultRadius }
        return min(max(radius, allowedRadius.lowerBound), allowedRadius.upperBound)
    }
}
