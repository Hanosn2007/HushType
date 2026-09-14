import AppKit
import XCTest
@testable import HushType

@MainActor
final class DictationFocusTests: XCTestCase {
    func testKeyboardDictationCanTargetHushTypeItself() {
        let current = NSRunningApplication.current
        let target = AppDelegate.insertionFocus(current: current, previous: nil,
                                                preferPreviousApplication: false)
        XCTAssertEqual(target?.processIdentifier, current.processIdentifier)
    }

    func testOnlyOverviewStopRequestsThePreviousApplication() throws {
        let previous = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let own = NSRunningApplication.current
        // XCTest is not a registered application bundle; AppKit may report -1.
        let ownPID = own.processIdentifier
        XCTAssertEqual(AppDelegate.insertionFocus(current: own, previous: previous,
            preferPreviousApplication: false, ownProcessID: ownPID)?.processIdentifier, ownPID)
        XCTAssertEqual(AppDelegate.insertionFocus(current: own, previous: previous,
            preferPreviousApplication: true, ownProcessID: ownPID)?.processIdentifier, previous.processIdentifier)
        XCTAssertEqual(AppDelegate.insertionFocus(current: previous, previous: own,
            preferPreviousApplication: true, ownProcessID: ownPID)?.processIdentifier, previous.processIdentifier)
    }

    func testSpotlightFocusDoesNotReactivateTheApplicationUnderneath() {
        XCTAssertFalse(AppDelegate.shouldActivateInsertionTarget(targetPID: 42, focusedPID: 42, frontmostPID: 99))
        XCTAssertFalse(AppDelegate.shouldActivateInsertionTarget(targetPID: 99, focusedPID: nil, frontmostPID: 99))
        XCTAssertTrue(AppDelegate.shouldActivateInsertionTarget(targetPID: 42, focusedPID: 99, frontmostPID: 42))
    }
}
