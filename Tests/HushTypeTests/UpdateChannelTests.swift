import XCTest
@testable import HushType

final class UpdateChannelTests: XCTestCase {
    func testStableChannelAllowsOnlyUntaggedUpdates() {
        XCTAssertEqual(UpdateChannel.stable.allowedSparkleChannels, [])
    }

    func testPreviewChannelOptsIntoPreviewUpdates() {
        XCTAssertEqual(UpdateChannel.preview.allowedSparkleChannels, ["preview"])
    }
}
