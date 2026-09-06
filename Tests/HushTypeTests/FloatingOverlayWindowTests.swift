import AppKit
import XCTest
@testable import HushType

final class FloatingOverlayWindowTests: XCTestCase {
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
        XCTAssertTrue(window.ignoresMouseEvents)

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
        XCTAssertTrue(window.ignoresMouseEvents)
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
}
