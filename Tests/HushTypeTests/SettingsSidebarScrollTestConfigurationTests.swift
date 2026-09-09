import XCTest
@testable import HushType

final class SettingsSidebarScrollTestConfigurationTests: XCTestCase {
    func testFillerRowsAreOffByDefaultAndPreviewOnly() throws {
        let suite = "HushType.sidebar-scroll-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(SettingsSidebarScrollTestConfiguration.isEnabled(defaults: defaults, isPreview: true))
        defaults.set(true, forKey: SettingsSidebarScrollTestConfiguration.enabledKey)
        XCTAssertTrue(SettingsSidebarScrollTestConfiguration.isEnabled(defaults: defaults, isPreview: true))
        XCTAssertFalse(SettingsSidebarScrollTestConfiguration.isEnabled(defaults: defaults, isPreview: false))
        XCTAssertEqual(SettingsSidebarScrollTestConfiguration.itemCount, 100)
    }
}
