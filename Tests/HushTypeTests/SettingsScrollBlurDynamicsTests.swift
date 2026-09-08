import CoreGraphics
import XCTest
@testable import HushType

final class SettingsScrollBlurDynamicsTests: XCTestCase {
    func testTargetRadiusIsContinuousMonotonicAndBounded() {
        let minimum: CGFloat = 10.5
        let maximum: CGFloat = 30

        XCTAssertEqual(
            SettingsScrollBlurDynamics.targetRadius(speed: 0, minimumRadius: minimum, maximumRadius: maximum),
            maximum
        )
        XCTAssertEqual(
            SettingsScrollBlurDynamics.targetRadius(
                speed: SettingsScrollBlurDynamics.speedForMinimumRadius,
                minimumRadius: minimum,
                maximumRadius: maximum
            ),
            minimum
        )

        var previous = maximum
        for speed in stride(from: CGFloat(0), through: CGFloat(2_400), by: 12) {
            let radius = SettingsScrollBlurDynamics.targetRadius(
                speed: speed,
                minimumRadius: minimum,
                maximumRadius: maximum
            )
            XCTAssertGreaterThanOrEqual(radius, minimum)
            XCTAssertLessThanOrEqual(radius, maximum)
            XCTAssertLessThanOrEqual(radius, previous)
            previous = radius
        }
    }

    func testExponentialResponseMovesSmoothlyWithoutOvershooting() {
        let current: CGFloat = 30
        let target: CGFloat = 10.5
        let first = SettingsScrollBlurDynamics.exponentiallyApproached(
            current: current,
            target: target,
            elapsed: 1.0 / 60.0,
            timeConstant: SettingsScrollBlurDynamics.liveRadiusResponseTime
        )
        let second = SettingsScrollBlurDynamics.exponentiallyApproached(
            current: first,
            target: target,
            elapsed: 1.0 / 60.0,
            timeConstant: SettingsScrollBlurDynamics.liveRadiusResponseTime
        )

        XCTAssertLessThan(first, current)
        XCTAssertGreaterThan(first, target)
        XCTAssertLessThan(second, first)
        XCTAssertGreaterThan(second, target)
    }

    func testIdleDecayReturnsTowardMaximumGradually() {
        let filteredSpeed = SettingsScrollBlurDynamics.exponentiallyApproached(
            current: 1_200,
            target: 0,
            elapsed: 1.0 / 30.0,
            timeConstant: SettingsScrollBlurDynamics.idleSpeedDecayTime
        )
        XCTAssertGreaterThan(filteredSpeed, 0)
        XCTAssertLessThan(filteredSpeed, 1_200)

        let before = SettingsScrollBlurDynamics.targetRadius(
            speed: 1_200,
            minimumRadius: 10.5,
            maximumRadius: 30
        )
        let after = SettingsScrollBlurDynamics.targetRadius(
            speed: filteredSpeed,
            minimumRadius: 10.5,
            maximumRadius: 30
        )
        XCTAssertGreaterThan(after, before)
        XCTAssertLessThan(after, 30)
    }
}
