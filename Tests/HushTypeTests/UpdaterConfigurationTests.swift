import Foundation
import XCTest

final class UpdaterConfigurationTests: XCTestCase {
    func testProductionUpdaterConfiguration() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["SUFeedURL"] as? String, "https://hanosn2007.github.io/HushType/appcast.xml")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(plist["SUPublicEDKey"] as? String))?.count, 32)
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(plist["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "15.0")
        XCTAssertNotNil(Int(try XCTUnwrap(plist["CFBundleVersion"] as? String)))
    }
}
