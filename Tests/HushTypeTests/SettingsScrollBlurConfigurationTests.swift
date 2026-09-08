import XCTest
@testable import HushType

final class SettingsScrollBlurConfigurationTests: XCTestCase {
    func testPreviewDefaultsAndValidatedOverrides() throws {
        let suite = "HushType.blur-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preview = SettingsScrollBlurConfiguration.load(defaults: defaults, isPreview: true)
        XCTAssertTrue(preview.enabled)
        XCTAssertEqual(preview.minimumRadius, 10.5)
        XCTAssertEqual(preview.maximumRadius, 30)
        XCTAssertFalse(SettingsScrollBlurConfiguration.load(defaults: defaults, isPreview: false).enabled)
        defaults.set(false, forKey: SettingsScrollBlurConfiguration.enabledKey)
        defaults.set(80, forKey: SettingsScrollBlurConfiguration.minimumRadiusKey)
        defaults.set(-1, forKey: SettingsScrollBlurConfiguration.maximumRadiusKey)
        let overridden = SettingsScrollBlurConfiguration.load(defaults: defaults, isPreview: true)
        XCTAssertFalse(overridden.enabled)
        XCTAssertEqual(overridden.minimumRadius, 0)
        XCTAssertEqual(overridden.maximumRadius, 60)
    }

    func testDebugPreferencesNormalizeRangeAndRestorePreviewDefaults() throws {
        let suite = "HushType.debug-preferences-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let saved = SettingsDebugPreferences.saveScrollBlur(
            enabled: false,
            minimumRadius: 48,
            maximumRadius: 12,
            defaults: defaults,
            isPreview: true
        )
        XCTAssertFalse(saved.enabled)
        XCTAssertEqual(saved.minimumRadius, 12)
        XCTAssertEqual(saved.maximumRadius, 48)

        SettingsDebugPreferences.restoreScrollBlurDefaults(defaults: defaults)
        let restored = SettingsScrollBlurConfiguration.load(defaults: defaults, isPreview: true)
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.minimumRadius, SettingsScrollBlurConfiguration.defaultMinimumRadius)
        XCTAssertEqual(restored.maximumRadius, SettingsScrollBlurConfiguration.defaultMaximumRadius)
    }

    func testDebugSectionIsPreviewOnlyAndOnboardingStillWins() {
        XCTAssertTrue(HushTypeSettingsSection.visibleSections(onboardingRequired: false, isPreview: true).contains(.debug))
        XCTAssertFalse(HushTypeSettingsSection.visibleSections(onboardingRequired: false, isPreview: false).contains(.debug))
        XCTAssertEqual(
            HushTypeSettingsSection.visibleSections(onboardingRequired: true, isPreview: true),
            [.permissions]
        )
    }
}
