import XCTest
@testable import HushType

final class SettingsNavigationHistoryTests: XCTestCase {
    func testBackForwardFollowVisitsNotSidebarOrder() {
        var history = SettingsNavigationHistory()
        history.visit(.permissions)
        history.visit(.profiles)
        XCTAssertEqual(history.back(), .permissions)
        XCTAssertEqual(history.back(), .overview)
        XCTAssertNil(history.back())
        XCTAssertEqual(history.forward(), .permissions)
        history.visit(.dictionary)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.entries, [.overview, .permissions, .dictionary])
        history.visit(.dictionary)
        XCTAssertEqual(history.entries.count, 3)
    }
}
