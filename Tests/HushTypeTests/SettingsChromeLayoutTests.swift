import XCTest
@testable import HushType

final class SettingsChromeLayoutTests: XCTestCase {
    func testHistoryWidthRemainsAtTargetThroughoutSidebarAnimation() {
        for target: CGFloat in [0, 1] {
            for frame in 0...60 {
                let progress = CGFloat(frame) / 60
                let layout = SettingsChromeFrames(size: size, progress: progress, detailLayoutProgress: target)
                XCTAssertEqual(layout.detail.width, size.width - 188 * target, accuracy: 0.001)
                XCTAssertEqual(layout.detail.minX, 188 * progress, accuracy: 0.001)
            }
        }
    }

    func testHistoryAndOrdinaryPagesHaveIdenticalSettledGeometry() {
        for target: CGFloat in [0, 1] {
            let ordinary = SettingsChromeFrames(size: size, progress: target)
            let history = SettingsChromeFrames(size: size, progress: target, detailLayoutProgress: target)
            XCTAssertEqual(history.detail, ordinary.detail)
            XCTAssertEqual(history.toggle, ordinary.toggle)
        }
    }
    private let size = CGSize(width: 950, height: 650)
    private let sidebarWidth: CGFloat = 180

    func testSidebarEndpointsCoverCollapsedAndExpandedProgress() {
        let collapsed = frames(progress: 0)
        let expanded = frames(progress: 1)

        XCTAssertEqual(collapsed.sidebar.maxX, 0, accuracy: 0.000_001)
        XCTAssertEqual(collapsed.sidebar.minX, -sidebarWidth, accuracy: 0.000_001)
        XCTAssertEqual(expanded.sidebar.maxX, sidebarWidth + 8, accuracy: 0.000_001)
        XCTAssertEqual(expanded.sidebar.minX, 8, accuracy: 0.000_001)
    }

    func testToggleUsesTrafficLightsRightPlusSixteenAsItsMinimum() {
        let firstTrafficLightsRight: CGFloat = 64
        let secondTrafficLightsRight: CGFloat = 121

        let first = frames(progress: 0, minimumToggleX: firstTrafficLightsRight + 16)
        let second = frames(progress: 0, minimumToggleX: secondTrafficLightsRight + 16)

        XCTAssertEqual(first.toggle.minX, 80, accuracy: 0.000_001)
        XCTAssertEqual(second.toggle.minX, 137, accuracy: 0.000_001)
        XCTAssertEqual(first.toggle.minX, firstTrafficLightsRight + 16, accuracy: 0.000_001)
        XCTAssertEqual(second.toggle.minX, secondTrafficLightsRight + 16, accuracy: 0.000_001)
    }

    func testToggleIsLimitedAtCollapseAndFollowsSidebarWhenExpanded() {
        let limited = frames(progress: 0.5, minimumToggleX: 100)
        let following = frames(progress: 1, minimumToggleX: 100)

        XCTAssertEqual(limited.sidebar.maxX, 94, accuracy: 0.000_001)
        XCTAssertEqual(limited.toggle.minX, 100, accuracy: 0.000_001)
        XCTAssertEqual(following.sidebar.maxX, 188, accuracy: 0.000_001)
        XCTAssertEqual(following.toggle.minX, following.sidebar.maxX - 44, accuracy: 0.000_001)
    }

    func testCollapseFollowsThenLimitsAndExpansionLimitsThenFollows() {
        let expanded = frames(progress: 1)
        let following = frames(progress: 0.9)
        let limited = frames(progress: 0.7)
        let collapsed = frames(progress: 0)

        XCTAssertEqual(expanded.toggle.minX, expanded.sidebar.maxX - 44, accuracy: 0.000_001)
        XCTAssertEqual(following.toggle.minX, following.sidebar.maxX - 44, accuracy: 0.000_001)
        XCTAssertEqual(limited.toggle.minX, 100, accuracy: 0.000_001)
        XCTAssertEqual(collapsed.toggle.minX, 100, accuracy: 0.000_001)
        XCTAssertGreaterThan(expanded.toggle.minX, following.toggle.minX)
        XCTAssertGreaterThan(following.toggle.minX, limited.toggle.minX)

        let sameProgressFromCollapse = frames(progress: 0.9)
        let sameProgressFromExpansion = frames(progress: 0.9)
        XCTAssertEqual(sameProgressFromCollapse.toggle, sameProgressFromExpansion.toggle)
        XCTAssertEqual(sameProgressFromCollapse.sidebar, sameProgressFromExpansion.sidebar)
    }

    func testFramesAreMonotonicAndContinuousAcrossWholeProgressRange() {
        let progressValues = (0 ... 100).map { CGFloat($0) / 100 }
        let sampledFrames = progressValues.map { frames(progress: $0) }

        for (previous, next) in zip(sampledFrames, sampledFrames.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.sidebar.maxX, previous.sidebar.maxX)
            XCTAssertGreaterThanOrEqual(next.toggle.minX, previous.toggle.minX)
            XCTAssertLessThanOrEqual(next.sidebar.maxX - previous.sidebar.maxX, 1.88 + 0.000_001)
            XCTAssertLessThanOrEqual(next.toggle.minX - previous.toggle.minX, 1.88 + 0.000_001)
        }

        let threshold: CGFloat = 144.0 / 188.0
        let justBefore = frames(progress: threshold - 0.000_1)
        let atThreshold = frames(progress: threshold)
        let justAfter = frames(progress: threshold + 0.000_1)
        XCTAssertEqual(justBefore.toggle.minX, atThreshold.toggle.minX, accuracy: 0.02)
        XCTAssertEqual(atThreshold.toggle.minX, justAfter.toggle.minX, accuracy: 0.02)
    }

    func testWideAndMinimumWindowsKeepDerivedFramesNonnegative() {
        let wide = SettingsChromeFrames(
            size: CGSize(width: 1_100, height: 700), progress: 1, minimumToggleX: 100
        )
        let minimum = SettingsChromeFrames(
            size: CGSize(width: 210, height: 64), progress: 1, minimumToggleX: 100
        )

        XCTAssertEqual(wide.detail, CGRect(x: 188, y: 64, width: 912, height: 636))
        XCTAssertEqual(wide.header, CGRect(x: 206, y: 10, width: 874, height: 36))
        XCTAssertEqual(minimum.detail, CGRect(x: 188, y: 64, width: 22, height: 0))
        XCTAssertEqual(minimum.header, CGRect(x: 206, y: 10, width: 0, height: 36))
        XCTAssertGreaterThanOrEqual(minimum.sidebar.height, 0)
        XCTAssertGreaterThanOrEqual(minimum.detail.width, 0)
        XCTAssertGreaterThanOrEqual(minimum.detail.height, 0)
        XCTAssertGreaterThanOrEqual(minimum.header.width, 0)
    }

    func testProgressIsClampedBeforeComputingFrames() {
        let belowZero = frames(progress: -0.5)
        let atZero = frames(progress: 0)
        let aboveOne = frames(progress: 1.5)
        let atOne = frames(progress: 1)

        XCTAssertEqual(belowZero.sidebar, atZero.sidebar)
        XCTAssertEqual(belowZero.detail, atZero.detail)
        XCTAssertEqual(belowZero.toggle, atZero.toggle)
        XCTAssertEqual(aboveOne.sidebar, atOne.sidebar)
        XCTAssertEqual(aboveOne.detail, atOne.detail)
        XCTAssertEqual(aboveOne.toggle, atOne.toggle)
    }

    func testHeaderAndToggleRespectTheActualTrafficLightCenter() {
        for centerY: CGFloat in [16, 28, 36] {
            let layout = SettingsChromeFrames(size: size, progress: 1, titlebarCenterY: centerY)
            XCTAssertEqual(layout.toggle.midY, centerY)
            XCTAssertEqual(layout.header.midY, centerY)
        }
    }

    private func frames(progress: CGFloat, minimumToggleX: CGFloat = 100) -> SettingsChromeFrames {
        SettingsChromeFrames(
            size: size,
            progress: progress,
            sidebarWidth: sidebarWidth,
            minimumToggleX: minimumToggleX
        )
    }
}
