import XCTest
@testable import HushType

@MainActor
final class SystemAudioPermissionFlowTests: XCTestCase {
    func testGrantedPermissionRunsReadySynchronouslyWithoutOpeningSettings() {
        var ready = false
        var presented = false

        SystemAudioPermissionFlow.routePermission(
            then: { ready = true },
            preflight: { true },
            presentPermissions: { presented = true }
        )

        XCTAssertTrue(ready)
        XCTAssertFalse(presented)
    }

    func testMissingPermissionOpensUnifiedPageWithoutRunningReady() {
        var ready = false
        var presented = false

        SystemAudioPermissionFlow.routePermission(
            then: { ready = true },
            preflight: { false },
            presentPermissions: { presented = true }
        )

        XCTAssertFalse(ready)
        XCTAssertTrue(presented)
    }
}
