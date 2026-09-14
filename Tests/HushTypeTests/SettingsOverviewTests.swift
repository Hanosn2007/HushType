import XCTest
import AppKit
import SwiftUI
@testable import HushType

@MainActor
final class SettingsOverviewTests: XCTestCase {
    func testRenderOverviewStatesWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HUSHTYPE_OVERVIEW_RENDER_DIR"] else {
            throw XCTSkip("Set HUSHTYPE_OVERVIEW_RENDER_DIR to render the native overview")
        }
        _ = NSApplication.shared
        let suite = "HushType.OverviewRender.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HushTypeSettingsModel()
        model.configure(actions: .init(loadedModelID: { AppConfig.defaultModelId }))
        model.updateAppState(.recording)
        model.updateCaptionState(mode: nil, source: nil)
        let view = NSHostingView(rootView: SettingsOverviewView(model: model)
            .defaultAppStorage(defaults).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for name in ["running", "finishing", "developer", "stopped"] {
            if name != "running" {
                model.updateAppState(.transcribing)
                model.updateCaptionState(mode: nil, source: nil, isFinishing: true)
            }
            defaults.set(name == "developer", forKey: OverviewPreferences.developerModeKey)
            if name == "stopped" {
                model.updateAppState(.idle)
                model.updateCaptionState(mode: nil, source: nil)
            }
            try await Task.sleep(for: .milliseconds(500))
            view.layoutSubtreeIfNeeded()
            // SwiftUI's composited text is absent from NSView.cacheDisplay.
            // Capture this exact test window instead of accepting a partial bitmap.
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                 URL(fileURLWithPath: directory).appendingPathComponent(name + "-window.png").path]
            try capture.run()
            capture.waitUntilExit()
            guard capture.terminationStatus == 0 else {
                throw XCTSkip("Native window capture is unavailable; visual acceptance remains manual")
            }
        }
    }

    func testOverviewStopUsesNormalToggleAndNeverCancellation() {
        let model = HushTypeSettingsModel()
        var toggles = 0, cancellations = 0
        model.configure(actions: .init(cancelRecording: { cancellations += 1 }, toggleDictation: { toggles += 1 }))
        model.updateAppState(.recording)
        model.toggleDictation()
        XCTAssertEqual(toggles, 1)
        XCTAssertEqual(cancellations, 0)
        model.updateAppState(.transcribing)
        XCTAssertEqual(model.dictationTaskState, .finishing)
        model.toggleDictation()
        XCTAssertEqual(toggles, 1)
        model.updateAppState(.idle)
        XCTAssertEqual(model.dictationTaskState, .stopped)
    }

    func testIndependentTextWorkDoesNotAppearAsDictation() {
        let model = HushTypeSettingsModel()
        model.updateAppState(.polishing)
        XCTAssertEqual(model.dictationTaskState, .stopped)
        model.updateCaptionState(mode: .local, source: .mic)
        XCTAssertEqual(model.captionTaskState, .running)
        model.updateAppState(.recording)
        model.updateAppState(.error("failed"))
        XCTAssertEqual(model.dictationTaskState, .stopped)
        XCTAssertEqual(model.captionTaskState, .running)
    }

    func testCaptionDrainBlocksRestartUntilCompletion() {
        let model = HushTypeSettingsModel()
        var starts = 0, stops = 0
        model.configure(actions: .init(startCaptions: { starts += 1 }, stopCaptions: { stops += 1 }))
        model.updateAppState(.idle)
        model.updateCaptionState(mode: .local, source: .mic)
        model.toggleCaptions()
        XCTAssertEqual(stops, 1)
        model.updateCaptionState(mode: nil, source: nil, isFinishing: true)
        XCTAssertEqual(model.captionTaskState, .finishing)
        XCTAssertFalse(model.canStartCaptions)
        model.toggleCaptions()
        XCTAssertEqual(starts, 0)
        model.updateCaptionState(mode: nil, source: nil)
        model.toggleCaptions()
        XCTAssertEqual(starts, 1)
    }
}
