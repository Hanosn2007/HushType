import XCTest
@testable import HushType

final class ProcessingProfileAvailabilityTests: XCTestCase {
    func testMissingSpeechModelDoesNotChangeTheConfiguration() {
        let profile = ProcessingProfile(name: "Kept")
        let id = profile.modelID
        var checkedText = false
        XCTAssertThrowsError(try profile.requireAvailableModels(speechAvailable: { _ in false },
            textAvailable: { checkedText = true; return true }))
        XCTAssertEqual(profile.modelID, id)
        XCTAssertFalse(checkedText)
    }
    func testTextModelOnlyRequiredWhenProfileUsesIt() throws {
        var profile = ProcessingProfile(name: "Rules only")
        try profile.requireAvailableModels(speechAvailable: { _ in true }, textAvailable: { false })
        profile.llm.polish = true
        XCTAssertThrowsError(try profile.requireAvailableModels(speechAvailable: { _ in true }, textAvailable: { false }))
    }
}
