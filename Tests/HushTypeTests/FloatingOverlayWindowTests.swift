import AppKit
import SwiftUI
import XCTest
@testable import HushType

final class FloatingOverlayWindowTests: XCTestCase {
    @MainActor
    func testConnectingToListeningKeepsSizeAndHorizontalCenter() async throws {
        _ = NSApplication.shared
        let model = OverlayStateModel()
        let window = FloatingOverlayWindow(stateModel: model)
        defer { window.hideImmediately() }

        model.state = .connecting
        window.show()
        try await Task.sleep(for: .milliseconds(100))
        let connectingFrame = window.frame

        model.state = .recording(level: 0, provider: nil)
        window.show()
        try await Task.sleep(for: .milliseconds(100))
        let listeningFrame = window.frame

        XCTAssertEqual(listeningFrame.width, connectingFrame.width, accuracy: 1)
        XCTAssertEqual(listeningFrame.midX, connectingFrame.midX, accuracy: 1)

        model.state = .connectionFailed
        window.showConnectionFailure(onOpenSettings: {})
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(window.frame.width, listeningFrame.width, accuracy: 1)
        XCTAssertEqual(window.frame.midX, listeningFrame.midX, accuracy: 1)
        XCTAssertFalse(window.ignoresMouseEvents)

        model.state = .connectionDisconnected
        window.showConnectionFailure(onOpenSettings: {})
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(window.frame.width, listeningFrame.width, accuracy: 1)
        XCTAssertEqual(window.frame.midX, listeningFrame.midX, accuracy: 1)
        XCTAssertFalse(window.ignoresMouseEvents)

        window.hideImmediately()
        XCTAssertEqual(model.state, .hidden)
    }

    @MainActor
    func testNoticePreservesListeningGeometryWithoutFloatingOrTakingFocus() async throws {
        _ = NSApplication.shared
        let model = OverlayStateModel()
        let window = FloatingOverlayWindow(stateModel: model)
        defer { window.hideImmediately() }

        model.state = .recording(level: 0, provider: nil)
        window.show()
        try await Task.sleep(for: .milliseconds(150))
        let listeningSize = window.frame.size
        XCTAssertEqual(window.level, .screenSaver)
        XCTAssertFalse(window.ignoresMouseEvents)

        for kind in [ModelNoticeKind.unloaded, .loaded] {
            window.showModelNotice(kind, onOpenModels: {})
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(window.frame.size.width, listeningSize.width, accuracy: 1)
            XCTAssertEqual(window.frame.size.height, listeningSize.height, accuracy: 1)
            XCTAssertEqual(window.level, .normal)
            XCTAssertFalse(window.isFloatingPanel)
            XCTAssertFalse(window.canBecomeKey)
            XCTAssertFalse(window.canBecomeMain)
            XCTAssertNil(NSApp.modalWindow)
        }
    }

    @MainActor
    func testOldFadeCannotHideRecordingShownImmediatelyAfterNotice() async throws {
        _ = NSApplication.shared
        let model = OverlayStateModel()
        let window = FloatingOverlayWindow(stateModel: model)
        defer { window.hideImmediately() }

        window.showModelNotice(.unloaded, onOpenModels: {})
        window.hide()
        model.state = .recording(level: 0, provider: nil)
        window.show()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(window.isVisible)
        XCTAssertGreaterThan(window.alphaValue, 0.9)
        XCTAssertEqual(model.state, .recording(level: 0, provider: nil))
        XCTAssertEqual(window.level, .screenSaver)
        XCTAssertFalse(window.ignoresMouseEvents)
    }

    @MainActor
    func testHoverKeepsNoticePastDeadlineAndLeavingStartsFreshLifetime() async throws {
        _ = NSApplication.shared
        let model = OverlayStateModel()
        let window = FloatingOverlayWindow(stateModel: model)
        defer { window.hideImmediately() }

        window.showModelNotice(.unloaded, onOpenModels: {})
        window.setModelNoticeHovered(true)
        try await Task.sleep(for: .milliseconds(3700))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(model.state, .modelNotice(.unloaded))

        window.setModelNoticeHovered(false)
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertTrue(window.isVisible)
        try await Task.sleep(for: .milliseconds(2500))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(model.state, .hidden)
        XCTAssertTrue(window.ignoresMouseEvents)
    }

    @MainActor
    func testReplacementNoticeDoesNotUsePreviousDeadline() async throws {
        _ = NSApplication.shared
        let model = OverlayStateModel()
        let window = FloatingOverlayWindow(stateModel: model)
        defer { window.hideImmediately() }

        window.showModelNotice(.unloaded, onOpenModels: {})
        try await Task.sleep(for: .milliseconds(2700))
        window.showModelNotice(.loaded, onOpenModels: {})
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(model.state, .modelNotice(.loaded))
        XCTAssertGreaterThan(window.alphaValue, 0.9)
        window.hideImmediately()
        try await Task.sleep(for: .milliseconds(2400))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(model.state, .hidden)
    }

    func testDefaultPlacementRetainsTheEstablishedBottomCenterFormula() {
        let visible = NSRect(x: 100, y: 40, width: 1200, height: 800)
        let size = CGSize(width: 280, height: 56)
        let insets = EdgeInsets(top: 32, leading: 36, bottom: 40, trailing: 36)

        let frame = FloatingOverlayPlacement.defaultFrame(
            in: visible,
            size: size,
            shadowInsets: insets
        )

        XCTAssertEqual(frame.origin.x, 560)
        XCTAssertEqual(frame.origin.y, 80)
        XCTAssertEqual(frame.size, size)
    }

    func testCustomPlacementIsBoundedToTheVisibleScreen() {
        let visible = NSRect(x: 100, y: 40, width: 400, height: 300)
        let insets = EdgeInsets(top: 32, leading: 36, bottom: 40, trailing: 36)
        let bounded = FloatingOverlayPlacement.bounded(
            // The host includes 72 points of vertical shadow around a 56-point pill.
            NSRect(x: -80, y: 500, width: 280, height: 128),
            in: visible,
            shadowInsets: insets
        )

        XCTAssertEqual(bounded.origin, CGPoint(x: 64, y: 244))
        XCTAssertEqual(bounded.size, CGSize(width: 280, height: 128))

        let pill = FloatingOverlayPlacement.visiblePillFrame(for: bounded, shadowInsets: insets)
        XCTAssertEqual(pill.minX, visible.minX)
        XCTAssertEqual(pill.maxY, visible.maxY)
        XCTAssertLessThan(bounded.minX, visible.minX) // transparent left shadow may be off-screen
        XCTAssertGreaterThan(bounded.maxY, visible.maxY) // transparent top shadow may be off-screen
    }

    func testSnapUsesReleaseHysteresisAroundBottomCenterTarget() {
        let target = CGPoint(x: 600, y: 80)
        let initiallySnapped = FloatingOverlayPlacement.snappedOrigin(
            for: CGPoint(x: 630, y: 80),
            defaultOrigin: target,
            wasSnapped: false,
            snapRadius: 10
        )
        XCTAssertFalse(initiallySnapped.isSnapped)

        let snap = FloatingOverlayPlacement.snappedOrigin(
            for: CGPoint(x: 625, y: 80),
            defaultOrigin: target,
            wasSnapped: false,
            snapRadius: 30
        )
        XCTAssertTrue(snap.isSnapped)
        XCTAssertEqual(snap.origin, target)

        let held = FloatingOverlayPlacement.snappedOrigin(
            for: CGPoint(x: 638, y: 80),
            defaultOrigin: target,
            wasSnapped: true,
            snapRadius: 34
        )
        XCTAssertTrue(held.isSnapped)
        XCTAssertEqual(held.origin, target)

        let released = FloatingOverlayPlacement.snappedOrigin(
            for: CGPoint(x: 645, y: 80),
            defaultOrigin: target,
            wasSnapped: true,
            snapRadius: 40
        )
        XCTAssertFalse(released.isSnapped)
    }

    func testSnapUsesRadialDistanceAndOnlyACompactReleaseHysteresis() {
        let target = CGPoint(x: 100, y: 100)
        let insideRadius = FloatingOverlayPlacement.snappedOrigin(
            for: CGPoint(x: 106, y: 108),
            defaultOrigin: target,
            wasSnapped: false,
            snapRadius: 10
        )
        XCTAssertTrue(insideRadius.isSnapped) // sqrt(6² + 8²) == 10

        let outsideRadius = FloatingOverlayPlacement.snappedOrigin(
            for: CGPoint(x: 107, y: 8 + 100),
            defaultOrigin: target,
            wasSnapped: false,
            snapRadius: 10
        )
        XCTAssertFalse(outsideRadius.isSnapped)

        let heldInsideHysteresis = FloatingOverlayPlacement.snappedOrigin(
            for: CGPoint(x: 114, y: 100),
            defaultOrigin: target,
            wasSnapped: true,
            snapRadius: 10
        )
        XCTAssertTrue(heldInsideHysteresis.isSnapped)
    }

    func testSnapTargetStaysOpaqueUntilOverlapThenFadesToNothing() {
        let target = NSRect(x: 100, y: 100, width: 200, height: 40)
        XCTAssertEqual(
            FloatingOverlayPlacement.snapTargetOpacity(
                draggedPillFrame: NSRect(x: 320, y: 100, width: 200, height: 40),
                targetPillFrame: target
            ),
            1
        )
        XCTAssertEqual(
            FloatingOverlayPlacement.snapTargetOpacity(
                draggedPillFrame: NSRect(x: 200, y: 100, width: 200, height: 40),
                targetPillFrame: target
            ),
            0.75,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            FloatingOverlayPlacement.snapTargetOpacity(
                draggedPillFrame: target,
                targetPillFrame: target
            ),
            0
        )
    }

    func testFadeAcceleratesNearCenterAndCanBeTunedBackToLinear() {
        let target = NSRect(x: 0, y: 0, width: 200, height: 40)
        func opacity(_ x: CGFloat, _ power: CGFloat) -> CGFloat {
            FloatingOverlayPlacement.snapTargetOpacity(
                draggedPillFrame: target.offsetBy(dx: x, dy: 0),
                targetPillFrame: target, exponent: power)
        }
        XCTAssertEqual(opacity(100, 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(opacity(100, 2), 0.75, accuracy: 0.0001)
        XCTAssertGreaterThan(opacity(50, 2) - opacity(0, 2), opacity(150, 2) - opacity(100, 2))
        XCTAssertGreaterThan(opacity(100, 3), opacity(100, 2))
    }

    @MainActor
    func testPillBodyConsumesDragWhileFailureActionSlotKeepsItsClick() async throws {
        _ = NSApplication.shared
        let model = OverlayStateModel()
        let window = FloatingOverlayWindow(stateModel: model)
        defer { window.hideImmediately() }

        model.state = .connectionFailed
        window.showConnectionFailure(onOpenSettings: {})
        try await Task.sleep(for: .milliseconds(100))

        let bodyDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: window.frame.width / 2, y: window.frame.height / 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertNil(window.handleMouseEvent(bodyDown))

        let bodyUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: bodyDown.locationInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ))
        XCTAssertNil(window.handleMouseEvent(bodyUp))

        let actionX = window.frame.width
            - FloatingOverlayAppearance.shadowInsets.trailing
            - 18
            - 22
        let actionDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: actionX, y: window.frame.height / 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertNotNil(window.handleMouseEvent(actionDown))
    }
}
