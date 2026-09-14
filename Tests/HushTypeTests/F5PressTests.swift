import XCTest
@testable import HushType

final class F5PressTests: XCTestCase {
    func testDefaultF5RoutesShortPressToDictationAndHoldToCaptions() {
        var router = HushTypeShortcutPressRouter()

        let shortToken = holdToken(from: router.keyDown(
            keyCode: 96,
            modifiers: [],
            isRepeat: false,
            configuration: .defaults,
            shouldPassThrough: { _ in false }
        ))
        XCTAssertEqual(shortToken, 1)
        XCTAssertEqual(delivery(from: router.keyUp(keyCode: 96))?.action, .dictation)

        let longToken = holdToken(from: router.keyDown(
            keyCode: 96,
            modifiers: [],
            isRepeat: false,
            configuration: .defaults,
            shouldPassThrough: { _ in false }
        ))
        XCTAssertEqual(router.holdDeadlineFired(token: longToken)?.action, .captions)
        XCTAssertEqual(router.keyUp(keyCode: 96), .consume)
    }

    func testMediaModeF5AliasMatchesDefaultBinding() {
        var router = HushTypeShortcutPressRouter()

        XCTAssertEqual(HushTypeShortcutBinding(keyCode: 176).keyCode, 96)
        _ = holdToken(from: router.keyDown(
            keyCode: 176,
            modifiers: [],
            isRepeat: false,
            configuration: .defaults,
            shouldPassThrough: { _ in false }
        ))
        XCTAssertEqual(delivery(from: router.keyUp(keyCode: 176))?.action, .dictation)
    }

    func testNormalKeyWithoutCommandOptionOrControlIsInvalid() {
        let binding = HushTypeShortcutBinding(keyCode: 0, modifiers: [], trigger: .press)
        XCTAssertFalse(binding.isValid)

        let configuration = HushTypeShortcutConfiguration(dictation: binding, captions: nil)
        XCTAssertThrowsError(try configuration.validate())
    }

    func testSameChordAndTriggerConflictsButShortAndHoldMayShareAChord() {
        let conflict = HushTypeShortcutConfiguration(
            dictation: .init(keyCode: 96, trigger: .press),
            captions: .init(keyCode: 176, trigger: .press)
        )
        XCTAssertThrowsError(try conflict.validate())

        let sharedShortAndHold = HushTypeShortcutConfiguration(
            dictation: .init(keyCode: 96, trigger: .press),
            captions: .init(keyCode: 176, trigger: .hold)
        )
        XCTAssertNoThrow(try sharedShortAndHold.validate())
    }

    func testConfigurationChangeAndClearInvalidateQueuedDeliveries() throws {
        var router = HushTypeShortcutPressRouter()
        var configuration = HushTypeShortcutConfiguration.defaults

        _ = holdToken(from: router.keyDown(
            keyCode: 96,
            modifiers: [],
            isRepeat: false,
            configuration: configuration,
            shouldPassThrough: { _ in false }
        ))
        let beforeChange = try XCTUnwrap(delivery(from: router.keyUp(keyCode: 96)))
        XCTAssertEqual(beforeChange.action, .dictation)

        configuration.dictation = .init(keyCode: 120, trigger: .press)
        router.cancel()
        XCTAssertFalse(router.shouldDeliver(beforeChange))

        XCTAssertEqual(router.keyDown(
            keyCode: 120,
            modifiers: [],
            isRepeat: false,
            configuration: configuration,
            shouldPassThrough: { _ in false }
        ), .consume)
        let beforeClear = try XCTUnwrap(delivery(from: router.keyUp(keyCode: 120)))
        XCTAssertEqual(beforeClear.action, .dictation)

        configuration = .init(dictation: nil, captions: nil)
        router.cancel()
        XCTAssertFalse(router.shouldDeliver(beforeClear))
        XCTAssertEqual(router.keyDown(
            keyCode: 120,
            modifiers: [],
            isRepeat: false,
            configuration: configuration,
            shouldPassThrough: { _ in false }
        ), .passThrough)
    }

    func testDifferentKeysCanBeHeldAndReleasedIndependently() {
        var router = HushTypeShortcutPressRouter()
        let configuration = HushTypeShortcutConfiguration(
            dictation: .init(keyCode: 96, trigger: .press),
            captions: .init(keyCode: 97, trigger: .press)
        )

        XCTAssertEqual(router.keyDown(
            keyCode: 96,
            modifiers: [],
            isRepeat: false,
            configuration: configuration,
            shouldPassThrough: { _ in false }
        ), .consume)
        XCTAssertEqual(router.keyDown(
            keyCode: 97,
            modifiers: [],
            isRepeat: false,
            configuration: configuration,
            shouldPassThrough: { _ in false }
        ), .consume)

        XCTAssertEqual(delivery(from: router.keyUp(keyCode: 97))?.action, .captions)
        XCTAssertEqual(delivery(from: router.keyUp(keyCode: 96))?.action, .dictation)
    }

    func testKeyUpUsesBindingCapturedBeforeModifiersChange() {
        var router = HushTypeShortcutPressRouter()
        let configuration = HushTypeShortcutConfiguration(
            dictation: .init(keyCode: 0, modifiers: [.command], trigger: .press),
            captions: nil
        )

        XCTAssertEqual(router.keyDown(
            keyCode: 0,
            modifiers: [.command],
            isRepeat: false,
            configuration: configuration,
            shouldPassThrough: { _ in false }
        ), .consume)
        // keyUp intentionally carries no modifiers: the key-down binding is latched.
        XCTAssertEqual(delivery(from: router.keyUp(keyCode: 0))?.action, .dictation)
    }

    func testAllPressShortcutPassThroughIsLatchedAcrossRepeatAndRelease() {
        var router = HushTypeShortcutPressRouter()
        let configuration = HushTypeShortcutConfiguration(
            dictation: .init(keyCode: 96, trigger: .press),
            captions: nil
        )
        var decisionCount = 0

        XCTAssertEqual(router.keyDown(
            keyCode: 96,
            modifiers: [],
            isRepeat: false,
            configuration: configuration,
            shouldPassThrough: { _ in
                decisionCount += 1
                return true
            }
        ), .passThrough)
        XCTAssertEqual(router.keyDown(
            keyCode: 96,
            modifiers: [],
            isRepeat: true,
            configuration: configuration,
            shouldPassThrough: { _ in
                decisionCount += 1
                return false
            }
        ), .passThrough)
        XCTAssertEqual(router.keyUp(keyCode: 96), .passThrough)
        XCTAssertEqual(decisionCount, 1)
    }

    func testSaveAndLoadUseOnlyTheProvidedUserDefaultsSuite() throws {
        let firstSuite = "HushTypeTests.shortcuts.\(UUID().uuidString)"
        let secondSuite = "HushTypeTests.shortcuts.\(UUID().uuidString)"
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
        }

        let saved = HushTypeShortcutConfiguration(
            dictation: .init(keyCode: 0, modifiers: [.command], trigger: .press),
            captions: .init(keyCode: 96, trigger: .hold),
            translation: .init(keyCode: 97, trigger: .press),
            polish: nil
        )
        try HushTypeShortcutPreferences.save(saved, defaults: firstDefaults)

        XCTAssertEqual(HushTypeShortcutPreferences.load(defaults: firstDefaults), saved)
        XCTAssertEqual(HushTypeShortcutPreferences.load(defaults: secondDefaults), .defaults)
    }

    private func holdToken(from result: HushTypeShortcutPressRouter.Result) -> UInt64 {
        guard case .scheduleHold(let token) = result else {
            XCTFail("Expected a held shortcut to schedule its deadline")
            return 0
        }
        return token
    }

    private func delivery(from result: HushTypeShortcutPressRouter.Result) -> HushTypeShortcutPressRouter.Delivery? {
        guard case .deliver(let delivery) = result else {
            XCTFail("Expected a shortcut action delivery")
            return nil
        }
        return delivery
    }
}
