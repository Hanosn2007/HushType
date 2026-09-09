import AppKit
import Foundation

/// Runtime parameters shared by Preview debugging controls and the backdrop.
///
/// This type validates a snapshot and does not write preferences. The
/// backdrop host reads it and applies the result to `CAFilter.inputRadius`.
/// See `docs/SCROLL_BLUR_CONFIGURATION.md` for preference keys and usage.
struct SettingsScrollBlurConfiguration: Equatable {
    /// Whether scroll-driven blur updates are active for this process.
    /// Missing keys enable the probe only in a Preview build.
    let enabled: Bool

    /// Lower bound, in `CAFilter.inputRadius` units, for the scroll-driven radius.
    let minimumRadius: CGFloat

    /// Upper bound, in `CAFilter.inputRadius` units, for the scroll-driven radius.
    /// A disabled host should retain this value as its stationary radius.
    let maximumRadius: CGFloat

    /// Inset, in backing pixels, applied before the backdrop is blurred.
    /// This is a rendering-pixel margin, not a physical panel pixel measurement.
    let edgeInsetPixels: CGFloat

    init(
        enabled: Bool,
        minimumRadius: CGFloat,
        maximumRadius: CGFloat,
        edgeInsetPixels: CGFloat = 2
    ) {
        self.enabled = enabled
        self.minimumRadius = minimumRadius
        self.maximumRadius = maximumRadius
        self.edgeInsetPixels = edgeInsetPixels
    }

    /// UserDefaults keys intentionally use the shipped app's bundle domain.
    static let enabledKey = "hushtype.preview.scrollBlur.enabled"
    static let minimumRadiusKey = "hushtype.preview.scrollBlur.minimumRadius"
    static let maximumRadiusKey = "hushtype.preview.scrollBlur.maximumRadius"
    static let edgeInsetPixelsKey = "hushtype.preview.scrollBlur.edgeInsetPixels"

    /// Defaults preserve the accepted stationary look: maximum radius 30.
    static let defaultMinimumRadius: CGFloat = 10.5
    static let defaultMaximumRadius: CGFloat = 30
    static let allowedRadiusRange: ClosedRange<CGFloat> = 0...60
    static let defaultEdgeInsetPixels: CGFloat = 2
    static let allowedEdgeInsetPixelsRange: ClosedRange<CGFloat> = 0...100

    /// True when the short bundle version marks this process as a Preview build.
    ///
    /// Probe Info.plists can opt into the Preview default by including "preview" in
    /// `CFBundleShortVersionString`; matching is case-insensitive.
    static var defaultIsPreview: Bool {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version?.localizedCaseInsensitiveContains("preview") ?? false
    }

    /// The runtime entry point. The backdrop also reloads this snapshot when
    /// UserDefaults changes so Preview debugging controls take effect immediately.
    static var current: Self {
        load(isPreview: defaultIsPreview)
    }

    /// Reads one validated snapshot without changing UserDefaults.
    ///
    /// - Parameters:
    ///   - defaults: Preference store to inspect; `.standard` reads the app domain.
    ///   - isPreview: Missing `enabled` defaults to this value. By default it is
    ///     inferred from the bundle version, leaving stable builds default-off.
    /// - Returns: A safe configuration: finite radii, clamped to `0...60`, with
    ///   `minimumRadius <= maximumRadius`.
    static func load(
        defaults: UserDefaults = .standard,
        isPreview: Bool = SettingsScrollBlurConfiguration.defaultIsPreview
    ) -> Self {
        let enabled = (defaults.object(forKey: enabledKey) as? Bool) ?? isPreview
        let requestedMinimum = number(forKey: minimumRadiusKey, defaults: defaults) ?? defaultMinimumRadius
        let requestedMaximum = number(forKey: maximumRadiusKey, defaults: defaults) ?? defaultMaximumRadius
        let requestedEdgeInsetPixels = number(forKey: edgeInsetPixelsKey, defaults: defaults)
            ?? defaultEdgeInsetPixels

        let minimum = sanitizedRadius(requestedMinimum, fallback: defaultMinimumRadius)
        let maximum = sanitizedRadius(requestedMaximum, fallback: defaultMaximumRadius)
        return Self(
            enabled: enabled,
            minimumRadius: Swift.min(minimum, maximum),
            maximumRadius: Swift.max(minimum, maximum),
            edgeInsetPixels: sanitizedEdgeInsetPixels(requestedEdgeInsetPixels)
        )
    }

    private static func number(forKey key: String, defaults: UserDefaults) -> CGFloat? {
        guard let value = defaults.object(forKey: key) as? NSNumber else { return nil }
        let radius = CGFloat(value.doubleValue)
        return radius.isFinite ? radius : nil
    }

    private static func sanitizedRadius(_ radius: CGFloat, fallback: CGFloat) -> CGFloat {
        guard radius.isFinite else { return fallback }
        return Swift.min(Swift.max(radius, allowedRadiusRange.lowerBound), allowedRadiusRange.upperBound)
    }

    private static func sanitizedEdgeInsetPixels(_ pixels: CGFloat) -> CGFloat {
        guard pixels.isFinite else { return defaultEdgeInsetPixels }
        return Swift.min(
            Swift.max(pixels, allowedEdgeInsetPixelsRange.lowerBound),
            allowedEdgeInsetPixelsRange.upperBound
        )
    }
}
