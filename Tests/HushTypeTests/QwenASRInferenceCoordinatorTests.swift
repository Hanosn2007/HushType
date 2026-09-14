import Foundation
import XCTest
@testable import HushType

final class QwenASRInferenceCoordinatorTests: XCTestCase {
    func testSerializesAllRequestsAcrossBothClients() async throws {
        let fake = FakeTranscriber(delay: 0.01)
        let coordinator = makeCoordinator(fake)

        let tasks = (0..<12).map { index in
            Task {
                try await coordinator.transcribe(
                    audio: [Float(index)],
                    language: nil,
                    maxTokens: 8,
                    client: index.isMultiple(of: 2) ? .dictation : .liveCaption
                )
            }
        }
        for task in tasks {
            _ = try await task.value
        }

        XCTAssertEqual(fake.maximumConcurrentCalls, 1)
        XCTAssertEqual(fake.completedCallCount, tasks.count)
    }

    func testSeparateCoordinatorInstancesDoNotShareAGlobalSerialGate() async throws {
        let probe = ConcurrentCoordinatorProbe()
        let first = QwenASRInferenceCoordinator(
            transcriber: { [probe] _, _, _ in probe.run(marker: 1) },
            computeGate: independentComputeGate
        )
        let second = QwenASRInferenceCoordinator(
            transcriber: { [probe] _, _, _ in probe.run(marker: 2) },
            computeGate: independentComputeGate
        )
        defer { probe.releaseBoth() }

        let firstTask = request(first, marker: 1, client: .dictation)
        let secondTask = request(second, marker: 2, client: .liveCaption)
        XCTAssertTrue(probe.waitUntilBothStart())
        XCTAssertEqual(probe.maximumConcurrentCalls, 2)

        probe.releaseBoth()
        _ = try await firstTask.value
        _ = try await secondTask.value
    }

    func testCancellingWhileWaitingForSharedComputeGateNeverStartsModelCall() async throws {
        let gate = LocalMLXComputeGate()
        let sharedGate: QwenASRInferenceCoordinator.ComputeGate = { operation in
            try await gate.run(operation)
        }
        let holder = FakeTranscriber(blocksFirstCall: true)
        let waiting = FakeTranscriber()
        let first = QwenASRInferenceCoordinator(
            transcriber: { [holder] audio, language, maxTokens in
                holder.transcribe(audio: audio, language: language, maxTokens: maxTokens)
            },
            computeGate: sharedGate
        )
        let second = QwenASRInferenceCoordinator(
            transcriber: { [waiting] audio, language, maxTokens in
                waiting.transcribe(audio: audio, language: language, maxTokens: maxTokens)
            },
            computeGate: sharedGate
        )
        defer { holder.releaseFirstCall() }

        let admitted = request(first, marker: 1, client: .liveCaption)
        XCTAssertTrue(holder.waitUntilFirstCallStarts())
        let blocked = request(second, marker: 2, client: .dictation)
        try await waitUntil { second.snapshot().runningClient == .dictation }
        XCTAssertFalse(waiting.waitUntilFirstCallStarts(timeout: 0.05))

        blocked.cancel()
        assertCancellation(await blocked.result)
        XCTAssertEqual(waiting.completedCallCount, 0)

        holder.releaseFirstCall()
        _ = try await admitted.value
        let retry = request(second, marker: 3, client: .dictation)
        let retryValue = try await retry.value
        XCTAssertEqual(retryValue, "3")
        XCTAssertEqual(waiting.completedMarkers, [3])
    }

    func testAlternatesClientsWhileBothAreWaitingAndPreservesLaneFIFO() async throws {
        let fake = FakeTranscriber(blocksFirstCall: true)
        let coordinator = makeCoordinator(fake)
        defer { fake.releaseFirstCall() }

        let caption1 = request(coordinator, marker: 1, client: .liveCaption)
        XCTAssertTrue(fake.waitUntilFirstCallStarts())

        let caption2 = request(coordinator, marker: 2, client: .liveCaption)
        try await waitUntil { coordinator.snapshot().pendingLiveCaptionRequests == 1 }
        let dictation1 = request(coordinator, marker: 10, client: .dictation)
        try await waitUntil { coordinator.snapshot().pendingDictationRequests == 1 }
        let caption3 = request(coordinator, marker: 3, client: .liveCaption)
        try await waitUntil { coordinator.snapshot().pendingLiveCaptionRequests == 2 }

        fake.releaseFirstCall()
        _ = try await caption1.value
        _ = try await caption2.value
        _ = try await dictation1.value
        _ = try await caption3.value

        XCTAssertEqual(fake.completedMarkers, [1, 10, 2, 3])
    }

    func testCancellingQueuedRequestReturnsBeforeRunningInferenceFinishes() async throws {
        let fake = FakeTranscriber(blocksFirstCall: true)
        let coordinator = makeCoordinator(fake)
        defer { fake.releaseFirstCall() }

        let running = request(coordinator, marker: 1, client: .liveCaption)
        XCTAssertTrue(fake.waitUntilFirstCallStarts())
        let queued = request(coordinator, marker: 10, client: .dictation)
        try await waitUntil { coordinator.snapshot().pendingDictationRequests == 1 }

        queued.cancel()
        let queuedResult = await queued.result
        assertCancellation(queuedResult)
        XCTAssertEqual(fake.completedCallCount, 0)

        fake.releaseFirstCall()
        _ = try await running.value
        XCTAssertEqual(fake.completedMarkers, [1])
    }

    func testCancellingInflightRequestSuppressesResultAfterSynchronousCallReturns() async throws {
        let fake = FakeTranscriber(blocksFirstCall: true)
        let coordinator = makeCoordinator(fake)
        defer { fake.releaseFirstCall() }

        let running = request(coordinator, marker: 1, client: .liveCaption)
        XCTAssertTrue(fake.waitUntilFirstCallStarts())
        running.cancel()
        try await waitUntil { coordinator.snapshot().runningRequestIsCancelled }
        XCTAssertTrue(coordinator.snapshot().hasTranscriber)

        fake.releaseFirstCall()
        assertCancellation(await running.result)
        XCTAssertEqual(fake.completedMarkers, [1])
    }

    func testShutdownCancelsQueueAndWaitsForInflightCallBeforeReleasingModel() async throws {
        let fake = FakeTranscriber(blocksFirstCall: true)
        let coordinator = makeCoordinator(fake)
        defer { fake.releaseFirstCall() }

        let running = request(coordinator, marker: 1, client: .liveCaption)
        XCTAssertTrue(fake.waitUntilFirstCallStarts())
        let queued = request(coordinator, marker: 10, client: .dictation)
        try await waitUntil { coordinator.snapshot().pendingDictationRequests == 1 }

        let shutdown = Task { await coordinator.shutdownAndWait() }
        try await waitUntil { !coordinator.snapshot().isAcceptingRequests }
        assertCancellation(await queued.result)
        XCTAssertTrue(coordinator.snapshot().hasTranscriber)
        XCTAssertTrue(coordinator.snapshot().runningRequestIsCancelled)

        fake.releaseFirstCall()
        await shutdown.value
        assertCancellation(await running.result)
        XCTAssertFalse(coordinator.snapshot().hasTranscriber)
        XCTAssertNil(coordinator.snapshot().runningClient)

        do {
            _ = try await coordinator.transcribe(
                audio: [99], language: nil, maxTokens: 8, client: .dictation
            )
            XCTFail("A shut-down coordinator must reject new work")
        } catch let error as QwenASRInferenceCoordinatorError {
            XCTAssertEqual(error, .shuttingDown)
        }
    }

    private func request(
        _ coordinator: QwenASRInferenceCoordinator,
        marker: Int,
        client: QwenASRInferenceClient
    ) -> Task<String, Error> {
        Task {
            try await coordinator.transcribe(
                audio: [Float(marker)],
                language: nil,
                maxTokens: 8,
                client: client
            )
        }
    }

    private func makeCoordinator(_ fake: FakeTranscriber) -> QwenASRInferenceCoordinator {
        QwenASRInferenceCoordinator(
            transcriber: { [fake] audio, language, maxTokens in
                fake.transcribe(audio: audio, language: language, maxTokens: maxTokens)
            },
            computeGate: independentComputeGate
        )
    }

    private var independentComputeGate: QwenASRInferenceCoordinator.ComputeGate {
        { operation in await operation() }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for coordinator state")
    }

    private func assertCancellation(
        _ result: Result<String, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let value):
            XCTFail("Expected cancellation, got \(value)", file: file, line: line)
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private final class FakeTranscriber: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private let blocksFirstCall: Bool
    private let firstCallStarted = DispatchSemaphore(value: 0)
    private let firstCallRelease = DispatchSemaphore(value: 0)
    private var callCount = 0
    private var activeCalls = 0
    private(set) var maximumConcurrentCalls = 0
    private(set) var completedMarkers: [Int] = []

    init(delay: TimeInterval = 0, blocksFirstCall: Bool = false) {
        self.delay = delay
        self.blocksFirstCall = blocksFirstCall
    }

    var completedCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completedMarkers.count
    }

    func transcribe(audio: [Float], language _: String?, maxTokens _: Int) -> String {
        lock.lock()
        let index = callCount
        callCount += 1
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        lock.unlock()

        if blocksFirstCall, index == 0 {
            firstCallStarted.signal()
            _ = firstCallRelease.wait(timeout: .now() + 5)
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }

        let marker = Int(audio.first ?? -1)
        lock.lock()
        activeCalls -= 1
        completedMarkers.append(marker)
        lock.unlock()
        return String(marker)
    }

    func waitUntilFirstCallStarts(timeout: TimeInterval = 2) -> Bool {
        firstCallStarted.wait(timeout: .now() + timeout) == .success
    }

    func releaseFirstCall() {
        firstCallRelease.signal()
    }
}

private final class ConcurrentCoordinatorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var activeCalls = 0
    private var maximumCalls = 0

    var maximumConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumCalls
    }

    func run(marker: Int) -> String {
        lock.lock()
        activeCalls += 1
        maximumCalls = max(maximumCalls, activeCalls)
        lock.unlock()
        started.signal()
        _ = release.wait(timeout: .now() + 5)
        lock.lock()
        activeCalls -= 1
        lock.unlock()
        return String(marker)
    }

    func waitUntilBothStart(timeout: TimeInterval = 2) -> Bool {
        let deadline = DispatchTime.now() + timeout
        return started.wait(timeout: deadline) == .success
            && started.wait(timeout: deadline) == .success
    }

    func releaseBoth() {
        release.signal()
        release.signal()
    }
}
