import XCTest
@testable import HushType

final class UpdateRelaunchIntentTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "UpdateRelaunchIntentTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMatchingBuildConsumesUpdateRelaunchIntentOnce() {
        UpdateRelaunchIntent.markForRelaunch(targetBuild: "42", systemUptime: 100, defaults: defaults)

        XCTAssertTrue(UpdateRelaunchIntent.consumeIfMatching(
            currentBuild: "42", isLoginItemLaunch: false, systemUptime: 101, defaults: defaults
        ))
        XCTAssertFalse(UpdateRelaunchIntent.consumeIfMatching(
            currentBuild: "42", isLoginItemLaunch: false, systemUptime: 101, defaults: defaults
        ))
    }

    func testSilentUpdateConsumesIntentWithoutOpeningSettingsLater() {
        UpdateRelaunchIntent.markForRelaunch(targetBuild: "42", systemUptime: 100, defaults: defaults)
        XCTAssertFalse(UpdateRelaunchIntent.consumeIfMatching(
            currentBuild: "42", isLoginItemLaunch: false, silentRelaunch: true,
            systemUptime: 101, defaults: defaults
        ))
        XCTAssertFalse(UpdateRelaunchIntent.consumeIfMatching(
            currentBuild: "42", isLoginItemLaunch: false, silentRelaunch: false,
            systemUptime: 102, defaults: defaults
        ))
    }

    func testMismatchedBuildClearsStaleIntentWithoutOpeningSettings() {
        UpdateRelaunchIntent.markForRelaunch(targetBuild: "42", systemUptime: 100, defaults: defaults)

        XCTAssertFalse(UpdateRelaunchIntent.consumeIfMatching(
            currentBuild: "41", isLoginItemLaunch: false, systemUptime: 101, defaults: defaults
        ))
        XCTAssertFalse(UpdateRelaunchIntent.consumeIfMatching(
            currentBuild: "42", isLoginItemLaunch: false, systemUptime: 101, defaults: defaults
        ))
    }

    func testExpiredIntentIsConsumedWithoutOpeningSettings() {
        UpdateRelaunchIntent.markForRelaunch(targetBuild: "42", systemUptime: 100, defaults: defaults)

        XCTAssertFalse(UpdateRelaunchIntent.consumeIfMatching(
            currentBuild: "42",
            isLoginItemLaunch: false,
            systemUptime: 100 + UpdateRelaunchIntent.maximumAge + 1,
            defaults: defaults
        ))
        XCTAssertFalse(UpdateRelaunchIntent.consumeIfMatching(
            currentBuild: "42", isLoginItemLaunch: false, systemUptime: 101, defaults: defaults
        ))
    }

    func testLoginItemLaunchConsumesMatchingIntentWithoutOpeningSettings() {
        UpdateRelaunchIntent.markForRelaunch(targetBuild: "42", systemUptime: 100, defaults: defaults)

        XCTAssertFalse(UpdateRelaunchIntent.consumeIfMatching(
            currentBuild: "42", isLoginItemLaunch: true, systemUptime: 101, defaults: defaults
        ))
        XCTAssertFalse(UpdateRelaunchIntent.consumeIfMatching(
            currentBuild: "42", isLoginItemLaunch: false, systemUptime: 101, defaults: defaults
        ))
    }

    func testUptimeGoingBackwardAfterRebootExpiresIntent() {
        UpdateRelaunchIntent.markForRelaunch(targetBuild: "42", systemUptime: 100, defaults: defaults)

        XCTAssertFalse(UpdateRelaunchIntent.consumeIfMatching(
            currentBuild: "42", isLoginItemLaunch: false, systemUptime: 1, defaults: defaults
        ))
    }

    func testLoginItemAppleEventIsRecognizedByItsPublicParameter() {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.felix.hushtype.tests")
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(boolean: true),
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        )

        XCTAssertTrue(AppLaunchReason.isLoginItemLaunch(event))
    }
}
