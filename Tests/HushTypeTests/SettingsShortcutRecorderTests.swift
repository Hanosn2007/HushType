import AppKit
import XCTest
@testable import HushType

@MainActor
final class SettingsShortcutRecorderTests: XCTestCase {
    func testRecorderConsumesCommandKeyEquivalentDuringCapture() throws {
        let coordinator = HushTypeShortcutRecorder.Coordinator()
        let button = HushTypeShortcutRecorderButton(title: "Record", target: coordinator, action: nil)
        button.coordinator = coordinator
        button.isCapturing = true
        var capturedKeyCode: UInt16?
        coordinator.onCapture = { event in capturedKeyCode = event.keyCode }
        let commandX = try keyEvent(keyCode: 7, characters: "x", modifiers: .command)

        XCTAssertTrue(button.performKeyEquivalent(with: commandX))
        XCTAssertEqual(capturedKeyCode, 7)
    }

    func testRecorderCancelsCaptureForEscape() throws {
        let coordinator = HushTypeShortcutRecorder.Coordinator()
        let button = HushTypeShortcutRecorderButton(title: "Record", target: coordinator, action: nil)
        button.coordinator = coordinator
        button.isCapturing = true
        var cancellations = 0
        coordinator.onCancelCapture = { cancellations += 1 }

        button.keyDown(with: try keyEvent(keyCode: 53, characters: "\u{1B}", modifiers: []))

        XCTAssertEqual(cancellations, 1)
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
