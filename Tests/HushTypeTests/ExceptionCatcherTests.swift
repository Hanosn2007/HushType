import ExceptionCatcher
import Foundation
import XCTest

final class ExceptionCatcherTests: XCTestCase {
    func testObjectiveCExceptionBecomesErrorInsteadOfTerminatingProcess() {
        var error: NSError?
        let succeeded = HTCatchException({
            NSException(name: .internalInconsistencyException, reason: "format mismatch").raise()
        }, &error)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(error?.localizedDescription, "format mismatch")
    }
}
