import AppKit
import XCTest
@testable import HushType

final class SettingsChromeLayoutTests: XCTestCase {
    @MainActor
    func testClickOnlyButtonConsumesADragThatReturnsToItsStart() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let button = SettingsClickOnlyIconButton.ClickOnlyButton(
            frame: NSRect(x: 0, y: 0, width: 40, height: 36)
        )
        var actionCount = 0
        button.configure(symbolName: "chevron.left", label: "Back") {
            actionCount += 1
        }
        window.contentView = button
        // Give synthetic events a real window number; an unordered window's
        // -1 number is interpreted as screen coordinates by nextEvent.
        window.orderFront(nil)

        let start = NSPoint(x: 20, y: 18)
        try postMouseEvent(.leftMouseDragged, location: NSPoint(x: 28, y: 18), to: window)
        try postMouseEvent(.leftMouseUp, location: start, to: window)
        let mouseDown = try makeMouseEvent(.leftMouseDown, location: start, in: window)
        button.mouseDown(with: mouseDown)

        XCTAssertEqual(actionCount, 0)
    }

    @MainActor
    func testClickOnlyButtonActivatesAStationaryMouseSequence() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let button = SettingsClickOnlyIconButton.ClickOnlyButton(
            frame: NSRect(x: 0, y: 0, width: 40, height: 36)
        )
        var actionCount = 0
        button.configure(symbolName: "sidebar.left", label: "Toggle Sidebar") {
            actionCount += 1
        }
        window.contentView = button
        // Give synthetic events a real window number; an unordered window's
        // -1 number is interpreted as screen coordinates by nextEvent.
        window.orderFront(nil)

        let point = NSPoint(x: 20, y: 18)
        try postMouseEvent(.leftMouseUp, location: point, to: window)
        button.mouseDown(with: try makeMouseEvent(.leftMouseDown, location: point, in: window))

        XCTAssertEqual(actionCount, 1)
    }

    func testClickOnlyControlsRejectDragsAndMouseUpsOutsideTheirBounds() {
        let start = NSPoint(x: 20, y: 18)

        XCTAssertTrue(settingsClickOnlyActionAllowed(start: start, end: start, endsInside: true))
        XCTAssertFalse(settingsClickOnlyActionAllowed(
            start: start, end: NSPoint(x: 23, y: 18), endsInside: true
        ))
        XCTAssertFalse(settingsClickOnlyActionAllowed(
            start: start, end: start, endsInside: false
        ))
    }

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

    func testSidebarWidthIsBoundedByItsRangeAndAvailableDetailSpace() {
        XCTAssertEqual(settingsSidebarWidthRange(windowWidth: 500), 180...180)
        XCTAssertEqual(settingsSidebarWidthRange(windowWidth: 760), 180...240)
        XCTAssertEqual(settingsSidebarWidthRange(windowWidth: 840), 180...320)
        XCTAssertEqual(settingsSidebarWidth(120, windowWidth: 840), 180)
        XCTAssertEqual(settingsSidebarWidth(270, windowWidth: 760), 240)
        XCTAssertEqual(settingsSidebarWidth(400, windowWidth: 840), 320)
    }

    func testResizableSidebarKeepsFramesAndGlassGeometryInSync() {
        let width: CGFloat = 260
        let frame = SettingsChromeFrames(size: size, progress: 1, sidebarWidth: width,
                                         minimumToggleX: 100, detailLayoutProgress: 1)

        XCTAssertEqual(frame.sidebar, CGRect(x: 8, y: 8, width: width, height: size.height - 16))
        XCTAssertEqual(frame.detail, CGRect(x: width + 8, y: 64,
                                            width: size.width - width - 8, height: size.height - 64))
        XCTAssertEqual(frame.toggle.minX, frame.sidebar.maxX - 44, accuracy: 0.001)
        XCTAssertEqual(settingsToggleGlassOpacity(0.3, width, 100), 0, accuracy: 0.001)
        XCTAssertGreaterThan(settingsToggleGlassOpacity(0.3, 180, 100), 0)
    }

    func testNativeScrollEdgePreservesContentOriginAndChromeAcrossAnimation() {
        for centerY: CGFloat in [16, 28, 44] {
            for target: CGFloat in [0, 1] {
                for step in 0...60 {
                    let progress = CGFloat(step) / 60
                    let old = SettingsChromeFrames(size: size, progress: progress,
                                                   titlebarCenterY: centerY, detailLayoutProgress: target)
                    let edge = SettingsChromeFrames(size: size, progress: progress,
                                                    titlebarCenterY: centerY, extendsDetailUnderHeader: true,
                                                    detailLayoutProgress: target)
                    XCTAssertEqual(edge.detail.minY, 0)
                    XCTAssertEqual(edge.detail.maxY, old.detail.maxY)
                    XCTAssertEqual(edge.detail.minX, old.detail.minX)
                    XCTAssertEqual(edge.detail.width, old.detail.width)
                    XCTAssertEqual(edge.detail.minY + max(64, centerY + 28), old.detail.minY)
                    XCTAssertEqual(edge.sidebar, old.sidebar)
                    XCTAssertEqual(edge.toggle, old.toggle)
                    XCTAssertEqual(edge.header, old.header)
                }
            }
        }
    }

    @MainActor
    func testBackdropMaskFadesDownwardAndLeavesGlassOpeningClear() throws {
        let mask = SettingsTopBackdropMask(size: CGSize(width: 200, height: 64),
            panelHeight: 400, sidebar: false,
            holes: [CGRect(x: 30, y: 10, width: 71, height: 36)],
            toggle: .zero, toggleOpacity: 0, origin: .zero)
        let image = try XCTUnwrap(mask.image())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        func alpha(_ x: Int, _ y: Int) -> CGFloat {
            bitmap.colorAt(x: x, y: y)!.alphaComponent
        }
        XCTAssertGreaterThan(alpha(150, 2), 0.3)
        XCTAssertLessThan(alpha(150, 2), 0.4)
        XCTAssertLessThan(alpha(150, 62), 0.05)
        XCTAssertGreaterThan(alpha(150, 20), alpha(150, 40))
        XCTAssertLessThan(alpha(60, 28), 0.01)
        XCTAssertGreaterThan(alpha(110, 28), 0.1)
    }

    @MainActor
    func testSidebarBackdropExcludesRimAndUsesLocalHoleCoordinates() throws {
        let mask = SettingsTopBackdropMask(size: CGSize(width: 180, height: 64),
            panelHeight: 400, sidebar: true, holes: [],
            toggle: CGRect(x: 100, y: 18, width: 44, height: 36),
            toggleOpacity: 1, origin: CGPoint(x: 8, y: 8))
        let image = try XCTUnwrap(mask.image())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        XCTAssertLessThan(bitmap.colorAt(x: 0, y: 28)!.alphaComponent, 0.01)
        XCTAssertLessThan(bitmap.colorAt(x: 110, y: 28)!.alphaComponent, 0.01)
        XCTAssertGreaterThan(bitmap.colorAt(x: 60, y: 28)!.alphaComponent, 0.1)
    }

    @MainActor
    func testInsetOpeningCoversTheOuterPixelWithoutFillingItsCenter() throws {
        let mask = SettingsTopBackdropMask(size: CGSize(width: 200, height: 64),
            openingInset: 1.5, panelHeight: 400, sidebar: false,
            holes: [CGRect(x: 30, y: 10, width: 71, height: 36)],
            toggle: .zero, toggleOpacity: 0, origin: .zero)
        let image = try XCTUnwrap(mask.image())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        XCTAssertGreaterThan(bitmap.colorAt(x: 65, y: 10)!.alphaComponent, 0.3)
        XCTAssertLessThan(bitmap.colorAt(x: 65, y: 20)!.alphaComponent, 0.01)
    }

    @MainActor
    func testScrollerTrackIsExcludedFromBlurAndTint() throws {
        let mask = SettingsTopBackdropMask(size: CGSize(width: 200, height: 52),
            excludedRects: [CGRect(x: 180, y: 0, width: 20, height: 52)],
            panelHeight: 400, sidebar: false, holes: [],
            toggle: .zero, toggleOpacity: 0, origin: .zero)
        for blur in [false, true] {
            let image = try XCTUnwrap(mask.image(blur: blur))
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let pixels = NSBitmapImageRep(cgImage: cg)
            let row = pixels.pixelsHigh / 4
            XCTAssertEqual(pixels.colorAt(x: pixels.pixelsWide * 19 / 20, y: row)!.alphaComponent,
                           0, accuracy: 0.001)
            XCTAssertGreaterThan(pixels.colorAt(x: pixels.pixelsWide / 2, y: row)!.alphaComponent, 0.01)
            XCTAssertEqual(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh - 1)!.alphaComponent,
                           0, accuracy: 0.001)
        }
    }

    func testBlurRadiusIsLinearAndClamped() {
        XCTAssertEqual(settingsTopBlurStrength(0), 0.1, accuracy: 0.00001)
        XCTAssertEqual(settingsTopBlurStrength(1), 0, accuracy: 0.00001)
        XCTAssertEqual(settingsTopBlurStrength(1.1), 0, accuracy: 0.00001)
        XCTAssertEqual(settingsTopBlurStrength(0.99), 0.001, accuracy: 0.00001)
        XCTAssertEqual(settingsTopBlurStrength(0.5), 0.05, accuracy: 0.00001)
        for step in 1...100 {
            XCTAssertLessThanOrEqual(settingsTopBlurStrength(CGFloat(step) / 100),
                                     settingsTopBlurStrength(CGFloat(step - 1) / 100))
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
        XCTAssertEqual(wide.header, CGRect(x: 206, y: 10, width: 884, height: 36))
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

    @MainActor
    private func postMouseEvent(_ type: NSEvent.EventType, location: NSPoint, to window: NSWindow) throws {
        NSApp.postEvent(try makeMouseEvent(type, location: location, in: window), atStart: false)
    }

    @MainActor
    private func makeMouseEvent(_ type: NSEvent.EventType, location: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }
}
