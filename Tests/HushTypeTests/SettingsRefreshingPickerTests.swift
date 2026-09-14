import AppKit
import XCTest
@testable import HushType

@MainActor
final class SettingsRefreshingPickerTests: XCTestCase {
    func testEachMenuOpeningRefreshesTheInventoryAndKeepsMissingSelection() {
        var calls = 0
        var items = [SettingsRefreshingPicker.Item(id: "old", title: "Original")]
        let picker = SettingsRefreshingPicker(selection: "old", selectedTitle: "Original", options: {
            calls += 1
            return items
        }, changed: { _ in })
        let coordinator = SettingsRefreshingPicker.Coordinator(picker)
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        coordinator.button = button
        coordinator.menuNeedsUpdate(button.menu!)
        XCTAssertEqual(calls, 1)
        items = [.init(id: "new", title: "New device")]
        coordinator.menuNeedsUpdate(button.menu!)
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(button.itemArray.contains { $0.representedObject as? String == "new" })
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "old")
        XCTAssertNotEqual(button.title, "Original")
    }
}
