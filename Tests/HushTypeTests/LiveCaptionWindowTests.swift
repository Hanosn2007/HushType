import AppKit
import Foundation
import XCTest
@testable import HushType

final class LiveCaptionWindowTests: XCTestCase {
    @MainActor
    private func pumpMainRunLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    @MainActor
    private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    func testScreenAwareLimitsKeepMinimumAndApplyPreferredCaps() {
        let regularScreen = LiveCaptionWindowSizing.limits(
            in: NSRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        XCTAssertEqual(regularScreen.minimum, NSSize(width: 230, height: 90))
        XCTAssertEqual(regularScreen.maximum, NSSize(width: 720, height: 420))

        let smallerScreen = LiveCaptionWindowSizing.limits(
            in: NSRect(x: 0, y: 0, width: 600, height: 600)
        )
        XCTAssertEqual(smallerScreen.maximum, NSSize(width: 560, height: 420))
    }

    func testAutomaticSizeClampsTextToScreenAwareBounds() {
        let limits = LiveCaptionWindowSizing.limits(
            in: NSRect(x: 0, y: 0, width: 900, height: 800)
        )

        XCTAssertEqual(
            LiveCaptionWindowSizing.automaticSize(
                contentSize: NSSize(width: 12, height: 24),
                limits: limits
            ),
            NSSize(width: 230, height: 90)
        )
        XCTAssertEqual(
            LiveCaptionWindowSizing.automaticSize(
                contentSize: NSSize(width: 900, height: 600),
                limits: limits
            ),
            NSSize(width: 720, height: 420)
        )
    }

    func testConfiguredLimitsRemainInsideScreen() {
        let limits = LiveCaptionWindowSizing.limits(
            in: NSRect(x: 0, y: 0, width: 900, height: 700),
            configuration: .init(maximumAutomaticSentences: 3, maximumAutomaticWidth: 1200, maximumAutomaticHeight: 800)
        )
        XCTAssertEqual(limits.maximum, NSSize(width: 860, height: 660))
    }

    @MainActor
    func testAutomaticSentenceLimitKeepsAllHistoryAndDragGuideCloses() throws {
        _ = NSApplication.shared
        let model = LiveCaptionViewModel()
        var pointer = NSPoint.zero
        let window = LiveCaptionWindow(viewModel: model, tuning: .init(), pointerLocation: { pointer }, onStop: {})
        defer { window.hide(); pumpMainRunLoop(for: 0.25); window.orderOut(nil) }
        window.show()
        model.segments = [.init(text: String(repeating: "A long earlier caption ", count: 60))]
        pumpMainRunLoop(for: 0.35)
        let fullHeight = window.frame.height
        for _ in 0..<LiveCaptionPresentationConfiguration.load().maximumAutomaticSentences {
            model.segments.append(.init(text: "Short sentence."))
        }
        pumpMainRunLoop(for: 0.35)
        XCTAssertEqual(model.segments.count, LiveCaptionPresentationConfiguration.load().maximumAutomaticSentences + 1)
        XCTAssertLessThan(window.frame.height, fullHeight)
        XCTAssertLessThan(window.frame.width, 400)

        let headerPoint = NSPoint(x: 100, y: window.frame.height - 16)
        pointer = window.convertPoint(toScreen: headerPoint)
        XCTAssertTrue(window.handleHeaderDragEvent(try mouseEvent(.leftMouseDown, in: window, at: headerPoint)))
        pointer.x += 220
        pointer.y += 60
        XCTAssertTrue(window.handleHeaderDragEvent(try mouseEvent(.leftMouseDragged, in: window, at: headerPoint)))
        XCTAssertEqual(window.isSnapGuideVisible, LiveCaptionDragPreferences.guideEnabled)
        window.finishUserMove(snap: false)
        XCTAssertFalse(window.isSnapGuideVisible)
    }

    func testHeaderDragRegionUsesCurrentSizeAndExcludesControls() {
        for size in [NSSize(width: 230, height: 90), NSSize(width: 720, height: 420)] {
            let y = size.height - 16
            XCTAssertTrue(LiveCaptionHeaderHitRegion.isDraggable(NSPoint(x: 65, y: y), size: size, showsRestore: true))
            XCTAssertTrue(LiveCaptionHeaderHitRegion.isDraggable(NSPoint(x: size.width - 45, y: y), size: size, showsRestore: true))
            XCTAssertFalse(LiveCaptionHeaderHitRegion.isDraggable(NSPoint(x: 16, y: y), size: size, showsRestore: false))
            XCTAssertFalse(LiveCaptionHeaderHitRegion.isDraggable(NSPoint(x: size.width - 16, y: y), size: size, showsRestore: false))
            XCTAssertFalse(LiveCaptionHeaderHitRegion.isDraggable(NSPoint(x: 44, y: y), size: size, showsRestore: true))
            XCTAssertTrue(LiveCaptionHeaderHitRegion.isDraggable(NSPoint(x: 44, y: y), size: size, showsRestore: false))
            XCTAssertFalse(LiveCaptionHeaderHitRegion.isDraggable(NSPoint(x: 65, y: size.height - 2), size: size, showsRestore: false))
            XCTAssertFalse(LiveCaptionHeaderHitRegion.isDraggable(NSPoint(x: 65, y: size.height - 40), size: size, showsRestore: false))
        }
    }

    @MainActor
    func testDraggingSnapsAndEmitsOneHapticPerEntryBeforeMouseUp() throws {
        _ = NSApplication.shared
        let keys = [LiveCaptionDragPreferences.snappingEnabledKey, LiveCaptionDragPreferences.hapticsEnabledKey, LiveCaptionDragPreferences.radiusKey]
        let previousValues = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previousValues) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.set(true, forKey: keys[0])
        UserDefaults.standard.set(true, forKey: keys[1])
        UserDefaults.standard.set(10.0, forKey: keys[2])

        var pointer = NSPoint.zero
        var hapticCount = 0
        let window = LiveCaptionWindow(
            viewModel: LiveCaptionViewModel(), tuning: .init(),
            pointerLocation: { pointer }, alignmentHaptic: { hapticCount += 1 }, onStop: {}
        )
        defer { window.hide(); pumpMainRunLoop(for: 0.25); window.orderOut(nil) }
        window.show()
        pumpMainRunLoop(for: 0.20)
        let target = window.frame
        window.setFrame(target.offsetBy(dx: 100, dy: 0), display: true)
        let headerPoint = NSPoint(x: 100, y: window.frame.height - 16)
        pointer = window.convertPoint(toScreen: headerPoint)
        let initialPointer = pointer
        XCTAssertTrue(window.handleHeaderDragEvent(try mouseEvent(.leftMouseDown, in: window, at: headerPoint)))

        pointer.x = initialPointer.x - 95
        XCTAssertTrue(window.handleHeaderDragEvent(try mouseEvent(.leftMouseDragged, in: window, at: headerPoint)))
        XCTAssertEqual(window.frame.minX, target.minX, accuracy: 0.5)
        XCTAssertEqual(hapticCount, 1)
        pointer.x -= 3
        window.handleHeaderDragEvent(try mouseEvent(.leftMouseDragged, in: window, at: headerPoint))
        XCTAssertEqual(hapticCount, 1)
        pointer.x = initialPointer.x - 60
        window.handleHeaderDragEvent(try mouseEvent(.leftMouseDragged, in: window, at: headerPoint))
        XCTAssertEqual(hapticCount, 1)
        pointer.x = initialPointer.x - 96
        window.handleHeaderDragEvent(try mouseEvent(.leftMouseDragged, in: window, at: headerPoint))
        XCTAssertEqual(hapticCount, 2)
        window.handleHeaderDragEvent(try mouseEvent(.leftMouseUp, in: window, at: headerPoint))
        XCTAssertEqual(hapticCount, 2)
        XCTAssertFalse(window.isSnapGuideVisible)
    }

    func testManualSizingPersistsUntilRestoreOrNewSession() {
        var state = LiveCaptionSizingState()
        XCTAssertTrue(state.acceptsAutomaticResizing)
        XCTAssertFalse(state.showsRestoreControl)

        XCTAssertTrue(state.userDidResize())
        XCTAssertFalse(state.acceptsAutomaticResizing)
        XCTAssertTrue(state.showsRestoreControl)
        XCTAssertFalse(state.userDidResize())

        XCTAssertTrue(state.restoreAutomaticSizing())
        XCTAssertTrue(state.acceptsAutomaticResizing)
        XCTAssertFalse(state.showsRestoreControl)

        XCTAssertTrue(state.userDidResize())
        state.resetForNewSession()
        XCTAssertTrue(state.acceptsAutomaticResizing)
        XCTAssertFalse(state.showsRestoreControl)
    }

    func testSegmentEntryCapturesItsCommitTimestampByDefault() {
        let before = Date()
        let entry = LiveCaptionViewModel.SegmentEntry(text: "timestamped")
        let after = Date()

        XCTAssertGreaterThanOrEqual(entry.timestamp, before)
        XCTAssertLessThanOrEqual(entry.timestamp, after)
    }

    func testAutomaticFramePreservesBottomCenterAndStaysOnScreen() {
        let visible = NSRect(x: 0, y: 0, width: 800, height: 600)
        let existing = NSRect(x: 290, y: 80, width: 230, height: 90)

        let resized = LiveCaptionWindowSizing.frame(
            size: NSSize(width: 720, height: 270),
            preservingBottomCenterOf: existing,
            in: visible
        )
        XCTAssertEqual(resized, NSRect(x: 45, y: 80, width: 720, height: 270))

        let defaultFrame = LiveCaptionWindowSizing.defaultFrame(
            size: NSSize(width: 720, height: 270),
            in: visible
        )
        XCTAssertEqual(defaultFrame, NSRect(x: 40, y: 80, width: 720, height: 270))
    }

    func testNewShowInvalidatesEarlierHideCompletion() {
        var visibility = LiveCaptionVisibilityState()
        let earlierHide = visibility.beginHide()
        visibility.beginShow()
        XCTAssertFalse(visibility.shouldFinishHide(earlierHide))

        let currentHide = visibility.beginHide()
        XCTAssertTrue(visibility.shouldFinishHide(currentHide))
    }

    @MainActor
    func testPanelAutomaticallyFitsThenHonorsManualResizeAndRestores() throws {
        _ = NSApplication.shared
        let model = LiveCaptionViewModel()
        let window = LiveCaptionWindow(
            viewModel: model,
            tuning: .init(),
            onStop: {}
        )
        defer {
            window.hide()
            pumpMainRunLoop(for: 0.25)
            window.orderOut(nil)
        }

        window.show()
        pumpMainRunLoop(for: 0.20)
        let compactFrame = window.frame

        model.segments = [LiveCaptionViewModel.SegmentEntry(
            text: String(repeating: "A caption row that needs more room ", count: 12)
        )]
        pumpMainRunLoop(for: 0.32)
        let automaticFrame = window.frame
        XCTAssertGreaterThan(automaticFrame.width, compactFrame.width + 20)

        let manualFrame = NSRect(
            x: automaticFrame.minX,
            y: automaticFrame.minY,
            width: 320,
            height: 120
        )
        window.windowWillStartLiveResize(Notification(name: .init("LiveCaptionWindowTests.resize")))
        window.setFrame(manualFrame, display: true, animate: false)
        window.windowDidResize(Notification(name: .init("LiveCaptionWindowTests.resize")))
        window.windowDidEndLiveResize(Notification(name: .init("LiveCaptionWindowTests.resize")))
        XCTAssertFalse(model.sizingState.acceptsAutomaticResizing)

        model.segments.append(LiveCaptionViewModel.SegmentEntry(
            text: String(repeating: "A later caption must not override manual size ", count: 12)
        ))
        pumpMainRunLoop(for: 0.32)
        XCTAssertEqual(window.frame.width, manualFrame.width, accuracy: 0.5)
        XCTAssertEqual(window.frame.height, manualFrame.height, accuracy: 0.5)

        model.restoreAutomaticSizing()
        pumpMainRunLoop(for: 0.32)
        XCTAssertTrue(model.sizingState.acceptsAutomaticResizing)
        XCTAssertGreaterThan(window.frame.width, manualFrame.width + 20)

        // Showing again before the fade completes must invalidate the old
        // completion handler rather than ordering out the new session.
        window.hide()
        window.show()
        pumpMainRunLoop(for: 0.28)
        XCTAssertTrue(window.isVisible)

        window.hide()
        pumpMainRunLoop(for: 0.25)
        XCTAssertFalse(window.isVisible)
    }
}
