import XCTest
@testable import HushType

final class FloatingOverlayGlassPreferencesTests: XCTestCase {
    func testApproachReducesOpticsWithoutChangingSavedValuesOrShapeVariant() {
        let base = FloatingOverlayGlassConfiguration(variant: 19, blur: 20, saturation: 1, tint: 0.2, refraction: 2)
        let half = base.approachingTarget(strength: 0.5)
        XCTAssertEqual(half.variant, 19)
        XCTAssertEqual(half.blur, 10)
        XCTAssertEqual(half.refraction, 1)
        XCTAssertEqual(half.tint, 0.1)
        XCTAssertEqual(base.blur, 20)
        XCTAssertEqual(base.approachingTarget(strength: 0).refraction, 0)
        XCTAssertEqual(base.approachingTarget(strength: 1), base)
    }

    func testGlassTuningIsBoundedAndDefaultsHaveNoTint() throws {
        let name = "GlassTuningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let initial = FloatingOverlayGlassPreferences.load(defaults: defaults)
        XCTAssertEqual(initial.variant, 19)
        XCTAssertEqual(initial.tint, 0)
        XCTAssertEqual(initial.refraction, 1)
        defaults.set(80, forKey: FloatingOverlayGlassPreferences.variantKey)
        defaults.set(-1, forKey: FloatingOverlayGlassPreferences.blurKey)
        defaults.set(10, forKey: FloatingOverlayGlassPreferences.tintKey)
        defaults.set(10, forKey: FloatingOverlayGlassPreferences.refractionKey)
        let bounded = FloatingOverlayGlassPreferences.load(defaults: defaults)
        XCTAssertEqual(bounded.variant, 19)
        XCTAssertEqual(bounded.blur, 0)
        XCTAssertEqual(bounded.tint, 1)
        XCTAssertEqual(bounded.refraction, 2)
        defaults.set(-1, forKey: FloatingOverlayGlassPreferences.variantKey)
        XCTAssertEqual(FloatingOverlayGlassPreferences.load(defaults: defaults).variant, -1)
    }
}
