import Foundation
import XCTest
@testable import HushType

@MainActor
final class SharedMicrophoneCaptureTests: XCTestCase {
    func testDictationFirstSharesCaptureFansOutPCMAndStopsAfterLastLease() async throws {
        let driver = FakeMicrophoneCaptureDriver()
        let service = AudioCaptureService(driver: driver)
        let continuousSamples = LockedBox<[Float]>([])
        let recordingResults = LockedBox<[Result<Void, Error>]>([])
        let stoppedRecording = LockedBox<[Float]?>(nil)
        let unexpectedErrors = LockedBox<[NSError]>([])
        service.onSamples = { samples in continuousSamples.withValue { $0.append(contentsOf: samples) } }

        service.startRecording(onUnexpectedStop: { error in
            unexpectedErrors.withValue { $0.append(error as NSError) }
        }, completion: { result in
            recordingResults.withValue { $0.append(result) }
        })
        await assertEventually { driver.startCount == 1 }

        let captions = Task { try await service.startContinuousCapture() }
        XCTAssertEqual(driver.startCount, 1, "caption lease must reuse the dictation capture")
        driver.completeStart(at: 0, result: .success(()))
        // A real microphone continues delivering frames while the second
        // consumer registers. Zero-valued priming frames are excluded from
        // the explicit payload assertions below.
        let captionResult = await boundedResult(of: captions) {
            driver.emitSamples(at: 0, [0])
        }
        XCTAssertTrue(isSuccess(captionResult))
        driver.emitSamples(at: 0, [0.1, 0.2])

        await assertEventually { recordingResults.withValue { $0.count } == 1 }
        XCTAssertTrue(isSuccess(recordingResults.withValue { $0.first }))
        XCTAssertTrue(unexpectedErrors.withValue { $0.isEmpty })
        await assertEventually { continuousSamples.withValue { $0.filter { $0 != 0 } } == [0.1, 0.2] }

        service.stopRecording { samples in stoppedRecording.withValue { $0 = samples } }
        await assertEventually { stoppedRecording.withValue { $0 != nil } }
        XCTAssertEqual(stoppedRecording.withValue { $0?.filter { $0 != 0 } }, [0.1, 0.2])
        XCTAssertEqual(driver.stopCount, 0, "caption lease keeps the physical microphone active")

        driver.emitSamples(at: 0, [0.3])
        await assertEventually { continuousSamples.withValue { $0.filter { $0 != 0 } } == [0.1, 0.2, 0.3] }

        service.stopContinuousCapture()
        await assertEventually { driver.stopCount == 1 }
        driver.finishStop(at: 0)
    }

    func testCaptionsFirstKeepsCaptureAliveAfterCaptionLeaseStops() async throws {
        let driver = FakeMicrophoneCaptureDriver()
        let service = AudioCaptureService(driver: driver)
        let recordingResults = LockedBox<[Result<Void, Error>]>([])
        let stoppedRecording = LockedBox<[Float]?>(nil)
        let unexpectedErrors = LockedBox<[NSError]>([])

        let captions = Task { try await service.startContinuousCapture() }
        await assertEventually { driver.startCount == 1 }
        service.startRecording(onUnexpectedStop: { error in
            unexpectedErrors.withValue { $0.append(error as NSError) }
        }, completion: { result in
            recordingResults.withValue { $0.append(result) }
        })
        XCTAssertEqual(driver.startCount, 1, "dictation lease must reuse the caption capture")

        driver.completeStart(at: 0, result: .success(()))
        driver.emitSamples(at: 0, [1])
        let captionResult = await boundedResult(of: captions)
        XCTAssertTrue(isSuccess(captionResult))
        await assertEventually { recordingResults.withValue { $0.count } == 1 }
        XCTAssertTrue(unexpectedErrors.withValue { $0.isEmpty })

        service.stopContinuousCapture()
        XCTAssertEqual(driver.stopCount, 0, "dictation lease keeps the physical microphone active")
        driver.emitSamples(at: 0, [2])
        service.stopRecording { samples in stoppedRecording.withValue { $0 = samples } }

        await assertEventually { stoppedRecording.withValue { $0 != nil } }
        XCTAssertEqual(stoppedRecording.withValue { $0 }, [1, 2])
        await assertEventually { driver.stopCount == 1 }
        driver.finishStop(at: 0)
    }

    func testCancelledCaptionStartRestartsAfterPhysicalStopAndIgnoresOldGeneration() async throws {
        let driver = FakeMicrophoneCaptureDriver()
        let service = AudioCaptureService(driver: driver)
        let dictationResults = LockedBox<[Result<Void, Error>]>([])
        let unexpectedErrors = LockedBox<[NSError]>([])
        let stoppedRecording = LockedBox<[Float]?>(nil)

        let captions = Task { try await service.startContinuousCapture() }
        await assertEventually { driver.startCount == 1 }
        captions.cancel()
        let cancellationResult = await boundedResult(of: captions)
        XCTAssertTrue(isCancellation(cancellationResult))
        await assertEventually { driver.stopCount == 1 }

        service.startRecording(onUnexpectedStop: { error in
            unexpectedErrors.withValue { $0.append(error as NSError) }
        }, completion: { result in
            dictationResults.withValue { $0.append(result) }
        })
        XCTAssertEqual(driver.startCount, 1, "restart waits for the active physical stop")

        driver.finishStop(at: 0)
        await assertEventually { driver.startCount == 2 }

        let staleError = NSError(domain: "SharedMicrophoneCaptureTests", code: 91)
        driver.completeStart(at: 0, result: .success(()))
        driver.emitSamples(at: 0, [99])
        driver.emitUnexpectedStop(at: 0, error: staleError)

        driver.completeStart(at: 1, result: .success(()))
        driver.emitSamples(at: 1, [2])
        await assertEventually { dictationResults.withValue { $0.count } == 1 }
        XCTAssertTrue(isSuccess(dictationResults.withValue { $0.first }))
        XCTAssertTrue(unexpectedErrors.withValue { $0.isEmpty })

        service.stopRecording { samples in stoppedRecording.withValue { $0 = samples } }
        await assertEventually { stoppedRecording.withValue { $0 != nil } }
        XCTAssertEqual(stoppedRecording.withValue { $0 }, [2])
    }

    func testPhysicalErrorNotifiesBothActiveConsumers() async throws {
        let driver = FakeMicrophoneCaptureDriver()
        let service = AudioCaptureService(driver: driver)
        let dictationErrors = LockedBox<[NSError]>([])
        let captionErrors = LockedBox<[NSError]>([])
        let dictationResults = LockedBox<[Result<Void, Error>]>([])
        service.onError = { error in captionErrors.withValue { $0.append(error as NSError) } }

        service.startRecording(onUnexpectedStop: { error in
            dictationErrors.withValue { $0.append(error as NSError) }
        }, completion: { result in
            dictationResults.withValue { $0.append(result) }
        })
        let captions = Task { try await service.startContinuousCapture() }
        await assertEventually { driver.startCount == 1 }
        driver.completeStart(at: 0, result: .success(()))
        driver.emitSamples(at: 0, [0.5])
        await assertEventually { dictationResults.withValue { $0.count } == 1 }
        let captionResult = await boundedResult(of: captions) {
            driver.emitSamples(at: 0, [0])
        }
        XCTAssertTrue(isSuccess(captionResult))

        let failure = NSError(domain: "SharedMicrophoneCaptureTests", code: 42)
        driver.emitUnexpectedStop(at: 0, error: failure)

        await assertEventually { dictationErrors.withValue { $0.count } == 1 }
        await assertEventually { captionErrors.withValue { $0.count } == 1 }
        XCTAssertEqual(dictationErrors.withValue { $0.first?.code }, 42)
        XCTAssertEqual(captionErrors.withValue { $0.first?.code }, 42)
    }

    private func boundedResult(
        of task: Task<Void, Error>,
        whileWaiting: (() -> Void)? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Result<Void, Error> {
        let result = LockedBox<Result<Void, Error>?>(nil)
        let observer = Task {
            let value = await task.result
            result.withValue { $0 = value }
        }
        let finished = await eventually {
            if result.withValue({ $0 != nil }) { return true }
            whileWaiting?()
            return false
        }
        guard finished, let value = result.withValue({ $0 }) else {
            task.cancel()
            observer.cancel()
            XCTFail("Capture startup did not finish after controlled PCM delivery", file: file, line: line)
            return .failure(NSError(domain: "SharedMicrophoneCaptureTests.Timeout", code: 1))
        }
        return value
    }

    private func eventually(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func assertEventually(
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let didSucceed = await eventually(timeout: timeout, condition: condition)
        XCTAssertTrue(didSucceed, file: file, line: line)
    }

    private func isSuccess(_ result: Result<Void, Error>?) -> Bool {
        if case .success? = result { return true }
        return false
    }

    private func isCancellation(_ result: Result<Void, Error>) -> Bool {
        guard case let .failure(error) = result else { return false }
        return error is CancellationError
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class FakeMicrophoneCaptureDriver: MicrophoneCaptureDriverProtocol, @unchecked Sendable {
    private struct StartRequest {
        let onSamples: (([Float]) -> Void)?
        let onRMSLevel: ((Float) -> Void)?
        let onUnexpectedStop: (Error) -> Void
        let completion: (Result<Void, Error>) -> Void
    }

    private let lock = NSLock()
    private var startRequests: [StartRequest] = []
    private var stopCompletions: [([Float]) -> Void] = []
    private var storedSamples: (([Float]) -> Void)?
    private var storedRMSLevel: ((Float) -> Void)?
    private var storedRetainsRecordedSamples = true

    var retainsRecordedSamples: Bool {
        get { withLock { storedRetainsRecordedSamples } }
        set { withLock { storedRetainsRecordedSamples = newValue } }
    }

    var onSamples: (([Float]) -> Void)? {
        get { withLock { storedSamples } }
        set { withLock { storedSamples = newValue } }
    }

    var onRMSLevel: ((Float) -> Void)? {
        get { withLock { storedRMSLevel } }
        set { withLock { storedRMSLevel = newValue } }
    }

    var startCount: Int { withLock { startRequests.count } }
    var stopCount: Int { withLock { stopCompletions.count } }

    func startRecording(
        onUnexpectedStop: @escaping (Error) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        withLock {
            startRequests.append(StartRequest(
                onSamples: storedSamples,
                onRMSLevel: storedRMSLevel,
                onUnexpectedStop: onUnexpectedStop,
                completion: completion
            ))
        }
    }

    func stopRecording(completion: @escaping ([Float]) -> Void) {
        withLock { stopCompletions.append(completion) }
    }

    func completeStart(at index: Int, result: Result<Void, Error>) {
        startRequest(at: index)?.completion(result)
    }

    func emitSamples(at index: Int, _ samples: [Float]) {
        startRequest(at: index)?.onSamples?(samples)
    }

    func emitUnexpectedStop(at index: Int, error: Error) {
        startRequest(at: index)?.onUnexpectedStop(error)
    }

    func finishStop(at index: Int, samples: [Float] = []) {
        stopCompletion(at: index)?(samples)
    }

    private func startRequest(at index: Int) -> StartRequest? {
        withLock { startRequests.indices.contains(index) ? startRequests[index] : nil }
    }

    private func stopCompletion(at index: Int) -> (([Float]) -> Void)? {
        withLock { stopCompletions.indices.contains(index) ? stopCompletions[index] : nil }
    }

    @discardableResult
    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
