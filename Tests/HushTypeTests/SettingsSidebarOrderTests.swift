import XCTest
import AppKit
@testable import HushType

final class SettingsSidebarOrderTests: XCTestCase {
    @MainActor
    func testIconsVaryAmplitudeDurationAndPhaseWithoutRestarting() throws {
        var amplitudes = Set<Double>(), durations = Set<Double>(), phases = Set<Double>()
        for name in ["mic", "gearshape", "slider.horizontal.3", "clock.arrow.circlepath", "book.closed"] {
            let view = SidebarReorderIcon.WiggleImage(frame: .zero)
            view.symbolName = name
            view.setEditing(true)
            let key = SidebarReorderIcon.WiggleImage.animationKey
            let animation = try XCTUnwrap(view.layer?.animation(forKey: key) as? CAKeyframeAnimation)
            amplitudes.insert(try XCTUnwrap(animation.values?[1] as? Double))
            durations.insert(animation.duration)
            phases.insert(animation.timeOffset)
            view.setEditing(true)
            XCTAssertEqual(view.layer?.animation(forKey: key)?.timeOffset, animation.timeOffset)
            view.setEditing(false)
            XCTAssertNil(view.layer?.animation(forKey: key))
        }
        XCTAssertGreaterThan(amplitudes.count, 3)
        XCTAssertGreaterThan(durations.count, 3)
        XCTAssertGreaterThan(phases.count, 3)
    }
    @MainActor
    func testFinishingRemovesWiggleAnimation() {
        let view = SidebarReorderIcon.WiggleImage(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        view.setEditing(true)
        XCTAssertNotNil(view.layer?.animation(forKey: SidebarReorderIcon.WiggleImage.animationKey))
        view.setEditing(false)
        XCTAssertNil(view.layer?.animation(forKey: SidebarReorderIcon.WiggleImage.animationKey))
    }
    func testRestoresUniqueKnownEntriesAndAppendsNewSections() {
        let result = SettingsSidebarOrder.normalized(["general", "general", "obsolete", "overview"])
        XCTAssertEqual(Array(result.prefix(2)), [.general, .overview])
        XCTAssertEqual(Set(result), Set(HushTypeSettingsSection.allCases))
        XCTAssertEqual(result.count, HushTypeSettingsSection.allCases.count)
    }
    func testOrderIsSavedOnConfirmationAndRoundTrips() {
        let name = "SidebarOrderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let order = SettingsSidebarOrder(defaults: defaults)
        order.move(.general, to: .overview)
        XCTAssertNil(defaults.array(forKey: SettingsSidebarOrder.key))
        order.save()
        XCTAssertEqual(SettingsSidebarOrder(defaults: defaults).items.first, .general)
        XCTAssertEqual(order.items.count, HushTypeSettingsSection.allCases.count)
    }
}
