import XCTest
@testable import HushType

final class SettingsRecordingCancellationTests: XCTestCase {
    @MainActor
    func testRecordingStateEnablesAndForwardsCancellation() {
        var cancellationCalls = 0

        XCTAssertTrue(HushTypeSettingsModel.canCancelRecording(for: .recording))
        HushTypeSettingsModel.forwardRecordingCancellation(for: .recording) {
            cancellationCalls += 1
        }

        XCTAssertEqual(cancellationCalls, 1)
    }

    @MainActor
    func testNonRecordingStatesDoNotExposeOrForwardCancellation() {
        var cancellationCalls = 0

        for state in [StatusBarController.State.connecting, .idle, .transcribing] {
            XCTAssertFalse(HushTypeSettingsModel.canCancelRecording(for: state))
            HushTypeSettingsModel.forwardRecordingCancellation(for: state) {
                cancellationCalls += 1
            }
        }

        XCTAssertEqual(cancellationCalls, 0)
    }
}
