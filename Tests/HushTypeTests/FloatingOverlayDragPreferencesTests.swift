import XCTest
@testable import HushType

final class FloatingOverlayDragPreferencesTests: XCTestCase {
    func testRadiusPersistsAndInvalidValuesRemainBounded() throws {
        let suite = "FloatingOverlayDragTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(FloatingOverlayDragPreferences.load(defaults: defaults), 10)
        FloatingOverlayDragPreferences.save(7, defaults: defaults)
        XCTAssertEqual(FloatingOverlayDragPreferences.load(defaults: defaults), 7)
        defaults.set(1000, forKey: FloatingOverlayDragPreferences.radiusKey)
        XCTAssertEqual(FloatingOverlayDragPreferences.load(defaults: defaults), 40)
        defaults.set(-3, forKey: FloatingOverlayDragPreferences.radiusKey)
        XCTAssertEqual(FloatingOverlayDragPreferences.load(defaults: defaults), 2)
        XCTAssertEqual(FloatingOverlayDragPreferences.sanitized(.nan), 10)
        XCTAssertEqual(FloatingOverlayDragPreferences.sanitized(.infinity), 10)
    }
}
