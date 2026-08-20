import XCTest
@testable import HushType

final class CloudDictationPolicyTests: XCTestCase {
    func testProjectionBelowWarningAllowsUpload() {
        let projection = CloudUsageTracker.makeDictationUploadProjection(
            currentDollars: 0.40,
            seconds: 60,
            dollarsPerMinute: 0.05,
            warningThreshold: 0.50
        )

        XCTAssertEqual(projection.projectedDollars, 0.05, accuracy: 0.000_001)
        XCTAssertEqual(projection.projectedTotalDollars, 0.45, accuracy: 0.000_001)
        XCTAssertFalse(projection.shouldBlock)
    }

    func testCrossingUtteranceBlocksAtExactEquality() {
        let projection = CloudUsageTracker.makeDictationUploadProjection(
            currentDollars: 0,
            seconds: 60,
            dollarsPerMinute: 0.50,
            warningThreshold: 0.50
        )

        XCTAssertEqual(projection.projectedTotalDollars, 0.50, accuracy: 0.000_001)
        XCTAssertTrue(projection.shouldBlock)
    }

    func testProjectionAboveWarningBlocksUpload() {
        let projection = CloudUsageTracker.makeDictationUploadProjection(
            currentDollars: 0.49,
            seconds: 60,
            dollarsPerMinute: 0.02,
            warningThreshold: 0.50
        )

        XCTAssertTrue(projection.shouldBlock)
    }

    func testCurrentUsageAlreadyAtWarningBlocksUpload() {
        let projection = CloudUsageTracker.makeDictationUploadProjection(
            currentDollars: 0.50,
            seconds: 1,
            dollarsPerMinute: 0.001,
            warningThreshold: 0.50
        )

        XCTAssertTrue(projection.shouldBlock)
    }

    func testReachedWarningStaysBlockedAfterThresholdIncrease() {
        let projection = CloudUsageTracker.makeDictationUploadProjection(
            currentDollars: 0.50,
            seconds: 1,
            dollarsPerMinute: 0.001,
            warningThreshold: 100,
            warningAlreadyReached: true
        )

        XCTAssertLessThan(projection.projectedTotalDollars, projection.warningThreshold)
        XCTAssertTrue(projection.shouldBlock)
    }

    func testProjectionSanitizesInvalidUsageAndFailsClosedForInvalidThreshold() {
        let projection = CloudUsageTracker.makeDictationUploadProjection(
            currentDollars: -.infinity,
            seconds: -10,
            dollarsPerMinute: .nan,
            warningThreshold: .infinity
        )

        XCTAssertEqual(projection.currentDollars, 0)
        XCTAssertEqual(projection.projectedDollars, 0)
        XCTAssertEqual(projection.warningThreshold, 0)
        XCTAssertTrue(projection.shouldBlock)
    }

    func testProductionTimeoutsAreThreeMinutes() {
        XCTAssertEqual(OpenAITranscribeEngine.requestTimeout, 180)
        XCTAssertEqual(GeminiTranscribeEngine.requestTimeout, 180)
    }

    func testOpenAIHTTPStatusClassification() {
        XCTAssertEqual(OpenAITranscribeEngine.mapHTTPFailure(statusCode: 401), .auth)
        XCTAssertEqual(
            OpenAITranscribeEngine.mapHTTPFailure(statusCode: 403),
            .permissionDenied(provider: "OpenAI")
        )
        XCTAssertEqual(
            OpenAITranscribeEngine.mapHTTPFailure(statusCode: 429),
            .rateLimited(provider: "OpenAI")
        )
        XCTAssertEqual(OpenAITranscribeEngine.mapHTTPFailure(statusCode: 503), .network)
    }

    func testGeminiHTTPStatusClassification() {
        XCTAssertEqual(GeminiTranscribeEngine.mapHTTPFailure(statusCode: 401), .auth)
        XCTAssertEqual(
            GeminiTranscribeEngine.mapHTTPFailure(statusCode: 403),
            .permissionDenied(provider: "Gemini")
        )
        XCTAssertEqual(
            GeminiTranscribeEngine.mapHTTPFailure(statusCode: 429),
            .rateLimited(provider: "Gemini")
        )
        XCTAssertEqual(GeminiTranscribeEngine.mapHTTPFailure(statusCode: 500), .network)
    }
}
