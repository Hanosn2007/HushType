import XCTest
@testable import HushType

final class LiveCaptionAudioIngressTests: XCTestCase {
    func testNormalFinishDrainsAcceptedTailAndRejectsNewAudio() async {
        let consumer = SlowFirstConsumer(delayNanoseconds: 100_000_000)
        let ingress = LiveCaptionAudioIngress(generation: 31, maximumBatchSamples: 1) {
            await consumer.consume($0)
        }
        XCTAssertEqual(ingress.append([1], generation: 31), .accepted)
        let started = await waitUntil(timeout: 1) { await consumer.hasStarted() }
        XCTAssertTrue(started)
        XCTAssertEqual(ingress.append([2, 3], generation: 31), .accepted)
        ingress.finish()
        XCTAssertEqual(ingress.append([4], generation: 31), .inactive)
        await ingress.waitUntilStopped()
        let values = await consumer.values()
        XCTAssertEqual(values, [1, 2, 3])
        XCTAssertEqual(ingress.snapshot().processedSamples, 3)
        XCTAssertEqual(ingress.snapshot().discardedSamples, 0)
        XCTAssertEqual(ingress.snapshot().pendingSamples, 0)
    }

    func testSlowConsumerPreservesOrderAndSampleConservationWithoutDrops() async {
        let consumer = SlowFirstConsumer(delayNanoseconds: 2_000_000_000)
        let ingress = LiveCaptionAudioIngress(
            generation: 1,
            consume: { samples in
                await consumer.consume(samples)
            }
        )

        XCTAssertEqual(ingress.append([0], generation: 1), .accepted)
        let slowConsumerStarted = await waitUntil(timeout: 1) {
            await consumer.hasStarted()
        }
        XCTAssertTrue(slowConsumerStarted)

        for value in 1..<200 {
            XCTAssertEqual(
                ingress.append([Float(value)], generation: 1),
                .accepted
            )
            if value.isMultiple(of: 10) {
                await Task.yield()
            }
        }

        let blockedMetrics = ingress.snapshot()
        XCTAssertEqual(blockedMetrics.capturedSamples, 200)
        XCTAssertEqual(blockedMetrics.enqueuedSamples, 200)
        XCTAssertEqual(blockedMetrics.processedSamples, 0)
        XCTAssertEqual(blockedMetrics.pendingSamples, 200)

        let processedSlowInput = await waitUntil(timeout: 5) {
            ingress.snapshot().processedSamples == 200
        }
        XCTAssertTrue(processedSlowInput)
        let values = await consumer.values()
        XCTAssertEqual(values, (0..<200).map(Float.init))

        let metrics = ingress.snapshot()
        XCTAssertEqual(metrics.capturedSamples, 200)
        XCTAssertEqual(metrics.enqueuedSamples, 200)
        XCTAssertEqual(
            metrics.enqueuedSamples,
            metrics.processedSamples + Int64(metrics.pendingSamples)
        )
        XCTAssertEqual(metrics.pendingSamples, 0)
        XCTAssertEqual(metrics.overflowCount, 0)

        ingress.cancel()
        await ingress.waitUntilStopped()
    }

    func testAppendAtEmptyDrainBoundaryNeverStrandsAudio() async {
        let consumer = RecordingConsumer()
        let ingress = LiveCaptionAudioIngress(
            generation: 7,
            consume: { samples in
                await consumer.consume(samples)
            }
        )

        for value in 0..<500 {
            XCTAssertEqual(ingress.append([Float(value)], generation: 7), .accepted)
            if value.isMultiple(of: 3) {
                await Task.yield()
            }
        }

        let processedAllBoundaryInput = await waitUntil(timeout: 3) {
            ingress.snapshot().processedSamples == 500
        }
        XCTAssertTrue(processedAllBoundaryInput)
        let values = await consumer.values()
        XCTAssertEqual(values, (0..<500).map(Float.init))

        ingress.cancel()
        await ingress.waitUntilStopped()
    }

    func testCancelDiscardsPendingTailAndOldGenerationCannotFeedNewSession() async {
        let blockedConsumer = GateConsumer()
        let oldIngress = LiveCaptionAudioIngress(
            generation: 11,
            consume: { samples in
                await blockedConsumer.consume(samples)
            }
        )

        XCTAssertEqual(oldIngress.append([1], generation: 11), .accepted)
        let oldConsumerStarted = await waitUntil(timeout: 1) {
            await blockedConsumer.hasStarted()
        }
        XCTAssertTrue(oldConsumerStarted)
        XCTAssertEqual(oldIngress.append([2], generation: 11), .accepted)

        let stoppedMetrics = oldIngress.cancel()
        XCTAssertEqual(stoppedMetrics.pendingSamples, 0)
        XCTAssertEqual(stoppedMetrics.discardedSamples, 2)
        await blockedConsumer.release()
        await oldIngress.waitUntilStopped()
        let oldValues = await blockedConsumer.values()
        XCTAssertEqual(oldValues, [1])
        XCTAssertEqual(oldIngress.append([3], generation: 11), .inactive)

        let newConsumer = RecordingConsumer()
        let newIngress = LiveCaptionAudioIngress(
            generation: 12,
            consume: { samples in
                await newConsumer.consume(samples)
            }
        )
        XCTAssertEqual(newIngress.append([99], generation: 11), .inactive)
        XCTAssertEqual(newIngress.append([4], generation: 12), .accepted)
        let newInputProcessed = await waitUntil(timeout: 1) {
            newIngress.snapshot().processedSamples == 1
        }
        XCTAssertTrue(newInputProcessed)
        let newValues = await newConsumer.values()
        XCTAssertEqual(newValues, [4])

        newIngress.cancel()
        await newIngress.waitUntilStopped()
    }

    func testOverflowRejectsNewAudioExplicitlyAndStopsFurtherDelivery() async {
        let consumer = GateConsumer()
        let ingress = LiveCaptionAudioIngress(
            generation: 21,
            maximumPendingSamples: 3,
            consume: { samples in
                await consumer.consume(samples)
            }
        )

        XCTAssertEqual(ingress.append([1, 2], generation: 21), .accepted)
        let overflowConsumerStarted = await waitUntil(timeout: 1) {
            await consumer.hasStarted()
        }
        XCTAssertTrue(overflowConsumerStarted)

        guard case .overflow(let metrics) = ingress.append([3, 4], generation: 21) else {
            return XCTFail("Expected an explicit overflow result")
        }
        XCTAssertEqual(metrics.capturedSamples, 4)
        XCTAssertEqual(metrics.enqueuedSamples, 2)
        XCTAssertEqual(metrics.pendingSamples, 2)
        XCTAssertEqual(metrics.pendingLimitSamples, 3)
        XCTAssertEqual(metrics.discardedSamples, 2)
        XCTAssertEqual(metrics.overflowCount, 1)
        XCTAssertEqual(ingress.append([5], generation: 21), .inactive)

        let stoppedMetrics = ingress.cancel()
        XCTAssertEqual(stoppedMetrics.discardedSamples, 4)
        await consumer.release()
        await ingress.waitUntilStopped()
        let values = await consumer.values()
        XCTAssertEqual(values, [1, 2])
        XCTAssertEqual(ingress.snapshot().processedSamples, 0)
    }

    func testDrainCapsEachBackendFeedAtOneSecondWithoutReordering() async {
        let consumer = RecordingConsumer()
        let ingress = LiveCaptionAudioIngress(
            generation: 31,
            consume: { samples in
                await consumer.consume(samples)
            }
        )
        let input = (0..<40_000).map(Float.init)
        XCTAssertEqual(ingress.append(input, generation: 31), .accepted)

        let processed = await waitUntil(timeout: 2) {
            ingress.snapshot().processedSamples == Int64(input.count)
        }
        XCTAssertTrue(processed)
        let values = await consumer.values()
        let batchSizes = await consumer.batchSizes()
        XCTAssertEqual(values, input)
        XCTAssertEqual(batchSizes, [16_000, 16_000, 8_000])
        XCTAssertTrue(batchSizes.allSatisfy { $0 <= LiveCaptionAudioIngress.sampleRate })

        ingress.cancel()
        await ingress.waitUntilStopped()
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

private actor RecordingConsumer {
    private var recorded: [Float] = []
    private var recordedBatchSizes: [Int] = []

    func consume(_ samples: [Float]) {
        recordedBatchSizes.append(samples.count)
        recorded.append(contentsOf: samples)
    }

    func values() -> [Float] {
        recorded
    }

    func batchSizes() -> [Int] {
        recordedBatchSizes
    }
}

private actor SlowFirstConsumer {
    private let delayNanoseconds: UInt64
    private var callCount = 0
    private var recorded: [Float] = []

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func consume(_ samples: [Float]) async {
        callCount += 1
        if callCount == 1 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        recorded.append(contentsOf: samples)
    }

    func hasStarted() -> Bool {
        callCount > 0
    }

    func values() -> [Float] {
        recorded
    }
}

private actor GateConsumer {
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var recorded: [Float] = []

    func consume(_ samples: [Float]) async {
        started = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        recorded.append(contentsOf: samples)
    }

    func hasStarted() -> Bool {
        started
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func values() -> [Float] {
        recorded
    }
}
