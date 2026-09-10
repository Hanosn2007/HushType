import Foundation

struct FloatingOverlayGlassConfiguration: Equatable {
    let variant: Int
    let blur: CGFloat
    let saturation: CGFloat
    let tint: CGFloat
    let refraction: CGFloat

    func approachingTarget(strength: CGFloat) -> Self {
        let amount = strength.isFinite ? min(max(strength, 0), 1) : 1
        return Self(variant: variant, blur: blur * amount, saturation: saturation,
                    tint: tint * amount, refraction: refraction * amount)
    }
}

enum FloatingOverlayGlassPreferences {
    static let variantKey = "hushtype.overlay.glass.variant"
    static let blurKey = "hushtype.overlay.glass.blur"
    static let saturationKey = "hushtype.overlay.glass.saturation"
    static let tintKey = "hushtype.overlay.glass.tint"
    static let refractionKey = "hushtype.overlay.glass.refraction"

    static func load(defaults: UserDefaults = .standard) -> FloatingOverlayGlassConfiguration {
        func read(_ key: String, fallback: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
            guard let number = defaults.object(forKey: key) as? NSNumber,
                  number.doubleValue.isFinite else { return fallback }
            return min(max(CGFloat(number.doubleValue), range.lowerBound), range.upperBound)
        }
        return FloatingOverlayGlassConfiguration(
            variant: Int(read(variantKey, fallback: 19, range: -1...19).rounded()),
            blur: read(blurKey, fallback: 0, range: 0...40),
            saturation: read(saturationKey, fallback: 1, range: 0...2),
            tint: read(tintKey, fallback: 0, range: 0...1),
            refraction: read(refractionKey, fallback: 1, range: 0...2)
        )
    }
}
