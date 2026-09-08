import XCTest
@testable import HushType

final class SettingsHistoryResizeTests: XCTestCase {
    func testContinuousWindowDragKeepsRowWidthUntilRelease() {
        var state = SettingsHistoryResizeState()
        state.setWindowResizing(true, width: 700)
        for width in stride(from: 690.0, through: 420.0, by: -1) {
            XCTAssertEqual(state.layoutWidth(available: width), 700)
        }
        state.setWindowResizing(false, width: 420)
        XCTAssertEqual(state.layoutWidth(available: 420), 420)
        XCTAssertEqual(state.layoutWidth(available: 500), 500)
    }

    func testOverlappingResizeSourcesDoNotReleaseWidthEarly() {
        var state = SettingsHistoryResizeState()
        state.setSidebarResizing(true, width: 640)
        state.setWindowResizing(true, width: 600)
        state.setSidebarResizing(false, width: 580)
        XCTAssertEqual(state.layoutWidth(available: 580), 640)
        state.setWindowResizing(false, width: 560)
        XCTAssertEqual(state.layoutWidth(available: 560), 560)
        state.setSidebarResizing(true, width: 560)
        XCTAssertEqual(state.layoutWidth(available: 540), 560)
    }
}
