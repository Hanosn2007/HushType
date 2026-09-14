import XCTest
@testable import HushType

@MainActor
final class SettingsCaptionStateTests: XCTestCase {
    func testCaptionsOnlyStartWhenDictationAndModelAreAvailable() {
        XCTAssertTrue(HushTypeSettingsModel.canStartCaptions(for: .idle))
        XCTAssertTrue(HushTypeSettingsModel.canStartCaptions(for: .unloaded))
        XCTAssertFalse(HushTypeSettingsModel.canStartCaptions(for: .idle, isCaptionStarting: true))

        XCTAssertFalse(HushTypeSettingsModel.canStartCaptions(for: .loading(0.5)))
        XCTAssertFalse(HushTypeSettingsModel.canStartCaptions(for: .connecting))
        XCTAssertFalse(HushTypeSettingsModel.canStartCaptions(for: .recording))
        XCTAssertFalse(HushTypeSettingsModel.canStartCaptions(for: .transcribing))
        XCTAssertFalse(HushTypeSettingsModel.canStartCaptions(for: .polishing))
        XCTAssertFalse(HushTypeSettingsModel.canStartCaptions(for: .error("failed")))
    }

    func testLoadedSharedModelPermitsActiveDictationButNeverModelLoading() {
        XCTAssertTrue(HushTypeSettingsModel.canStartCaptions(
            for: .connecting,
            hasLoadedModel: true
        ))
        XCTAssertTrue(HushTypeSettingsModel.canStartCaptions(
            for: .recording,
            hasLoadedModel: true
        ))
        XCTAssertTrue(HushTypeSettingsModel.canStartCaptions(
            for: .transcribing,
            hasLoadedModel: true
        ))
        XCTAssertFalse(HushTypeSettingsModel.canStartCaptions(
            for: .loading(0.5),
            hasLoadedModel: true
        ))
    }

    func testLegacyExclusivePreferenceCannotDisableConcurrentUse() throws {
        let suite = "HushType.SettingsCaptionStateTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("exclusive", forKey: "hushtype.captions.dictationMode")

        XCTAssertTrue(HushTypeSettingsModel.canStartCaptions(
            for: .recording,
            hasLoadedModel: true
        ))
    }

    @MainActor
    func testCaptionStateTracksActiveSource() {
        let model = HushTypeSettingsModel()

        model.updateCaptionState(mode: .local, source: .mic)
        XCTAssertTrue(model.isCaptionActive)
        XCTAssertEqual(model.captionMode, .local)
        XCTAssertEqual(model.captionSource, .mic)
        XCTAssertFalse(model.isCaptionStarting)

        model.updateCaptionState(mode: nil, source: nil)
        XCTAssertFalse(model.isCaptionActive)
        XCTAssertNil(model.captionMode)
        XCTAssertNil(model.captionSource)
    }
}
