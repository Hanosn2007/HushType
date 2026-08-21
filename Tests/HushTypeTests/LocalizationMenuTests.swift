import XCTest
import AppKit
@testable import HushType

/// Gate C Slice 2 — semantic menu behavior and lifecycle-safety checks.
final class LocalizationMenuTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        super.tearDown()
    }

    func testAppliedNextLaunchOnlyWhenPreferenceDiffersFromLaunchSnapshot() {
        XCTAssertFalse(StatusBarController.shouldShowAppliedNextLaunch(
            persisted: .system,
            launch: .system
        ))
        XCTAssertFalse(StatusBarController.shouldShowAppliedNextLaunch(
            persisted: .traditionalChineseTaiwan,
            launch: .traditionalChineseTaiwan
        ))
        XCTAssertTrue(StatusBarController.shouldShowAppliedNextLaunch(
            persisted: .traditionalChineseTaiwan,
            launch: .english
        ))
        XCTAssertTrue(StatusBarController.shouldShowAppliedNextLaunch(
            persisted: .english,
            launch: .system
        ))
    }

    func testLanguageSavedAlertHasExactlyOneLocalizedOKButton() {
        AppConfig.shared.interfaceLanguage = .english
        L10n.resetLaunchStateForTests()

        let alert = StatusBarController.makeLanguageSavedAlert()
        XCTAssertEqual(alert.messageText, "Language Saved")
        XCTAssertEqual(alert.buttons.count, 1)
        XCTAssertEqual(alert.buttons.first?.title, "OK")
        XCTAssertEqual(alert.alertStyle, .informational)
    }

    func testCaptionRoleIsSemanticAndLocalized() {
        AppConfig.shared.interfaceLanguage = .english
        L10n.resetLaunchStateForTests()
        XCTAssertEqual(CaptionLineRole.source.label, "SOURCE")
        XCTAssertEqual(CaptionLineRole.translated.accessibilityLabel, "Translated")

        AppConfig.shared.interfaceLanguage = .traditionalChineseTaiwan
        L10n.resetLaunchStateForTests()
        XCTAssertEqual(CaptionLineRole.source.label, "原文")
        XCTAssertEqual(CaptionLineRole.translated.label, "翻譯")
        XCTAssertEqual(CaptionLineRole.source.accessibilityLabel, "原文語言")
    }

    func testModelMenuActionIsTyped() {
        let unload: StatusBarController.ModelMenuAction = .unload
        let reload: StatusBarController.ModelMenuAction = .reload
        XCTAssertNotEqual(unload, reload)
    }

    func testLanguageSelectionHandlerHasNoLifecycleAuthorityAndStrictNoOpGuard() throws {
        let body = try sourceSlice(
            from: "@objc private func interfaceLanguageSelected",
            until: "static func makeLanguageSavedAlert"
        )
        XCTAssertTrue(body.contains("selected != AppConfig.shared.interfaceLanguage"))
        for forbidden in ["restart", "terminate", "NSApp", "AppDelegate", ".cancel", ".stop", "quitClicked"] {
            XCTAssertFalse(body.localizedCaseInsensitiveContains(forbidden), "Forbidden lifecycle call in language handler: \(forbidden)")
        }
    }

    func testModelActionHandlerDoesNotInspectRenderedTitle() throws {
        let body = try sourceSlice(
            from: "@objc private func unloadOrReloadModel",
            until: "func setModelUnloaded"
        )
        XCTAssertTrue(body.contains("switch modelMenuAction"))
        XCTAssertFalse(body.contains(".title"))
        XCTAssertFalse(body.contains("attributedTitle"))
        XCTAssertFalse(body.contains("contains("))
    }

    func testCaptionBehaviorDoesNotCompareRenderedSourceLabel() throws {
        let source = try String(contentsOf: sourceURL(named: "LiveCaptionView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("enum CaptionLineRole"))
        XCTAssertFalse(source.contains("roleLabel == \"SOURCE\""))
        XCTAssertFalse(source.contains("role.label =="))
    }

    private func sourceSlice(from startMarker: String, until endMarker: String) throws -> String {
        let source = try String(contentsOf: sourceURL(named: "StatusBarController.swift"), encoding: .utf8)
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound else {
            XCTFail("Could not locate source slice markers")
            return ""
        }
        return String(source[start..<end])
    }

    private func sourceURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HushType")
            .appendingPathComponent(name)
    }
}
