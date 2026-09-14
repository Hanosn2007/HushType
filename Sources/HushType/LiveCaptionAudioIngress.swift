import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "liveCaptionAudio")

/// A lossless, ordered handoff between the realtime audio callback and the
/// caption backend. One persistent drain task owns all `consume` calls. Audio
/// arriving while Qwen is transcribing is coalesced in FIFO order instead of
/// spawning unordered per-buffer tasks or silently dropping newer speech.
final class LiveCaptionAudioIngress: @unchecked Sendable {
    static let sampleRate = 16_000
    static let defaultMaximumPendingSeconds = 120

    struct Metrics: Equatable, Sendable {
        let capturedSamples: Int64
        let enqueuedSamples: Int64
        let processedSamples: Int64
        let pendingSamples: Int
        let maximumPendingSamples: Int
        let pendingLimitSamples: Int
        let discardedSamples: Int64
        let overflowCount: Int
        let sampleRate: Int

        var pendingSeconds: Double {
            Double(pendingSamples) / Double(sampleRate)
        }

        var maximumPendingSeconds: Double {
            Double(maximumPendingSamples) / Double(sampleRate)
        }

        var pendingLimitSeconds: Double {
            Double(pendingLimitSamples) / Double(sampleRate)
        }
    }

    enum AppendResult: Equatable, Sendable {
        case accepted
        case inactive
        case overflow(Metrics)
    }

    private struct Batch {
        let samples: [Float]
        let generation: UInt64
    }

    private let lock = NSLock()
    private let generation: UInt64
    private let maximumPendingSamples: Int
    private let maximumBatchSamples: Int
    private let consume: @Sendable ([Float]) async -> Void
    private let onOverflow: @Sendable (Metrics) -> Void
    private let signalContinuation: AsyncStream<Void>.Continuation
    private var drainTask: Task<Void, Never>?

    private var active = true
    private var accepting = true
    private var pendingChunks: [[Float]] = []
    private var pendingChunkIndex = 0
    private var pendingChunkOffset = 0
    private var queuedSamples = 0
    private var inFlightSamples = 0
    private var capturedSamples: Int64 = 0
    private var enqueuedSamples: Int64 = 0
    private var processedSamples: Int64 = 0
    private var maximumObservedPendingSamples = 0
    private var discardedSamples: Int64 = 0
    private var overflowCount = 0
    private var nextMetricsLogSample: Int64 = Int64(LiveCaptionAudioIngress.sampleRate * 5)

    init(
        generation: UInt64,
        maximumPendingSamples: Int = LiveCaptionAudioIngress.sampleRate
            * LiveCaptionAudioIngress.defaultMaximumPendingSeconds,
        maximumBatchSamples: Int = LiveCaptionAudioIngress.sampleRate,
        consume: @escaping @Sendable ([Float]) async -> Void,
        onOverflow: @escaping @Sendable (Metrics) -> Void = { _ in }
    ) {
        self.generation = generation
        self.maximumPendingSamples = max(1, maximumPendingSamples)
        self.maximumBatchSamples = max(1, maximumBatchSamples)
        self.consume = consume
        self.onOverflow = onOverflow

        let signal = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        signalContinuation = signal.continuation
        drainTask = Task { [weak self, stream = signal.stream] in
            for await _ in stream {
                guard let self else { return }
                await self.drainAvailableAudio()
            }
        }
    }

    @discardableResult
    func append(_ samples: [Float], generation candidateGeneration: UInt64) -> AppendResult {
        guard !samples.isEmpty else { return .accepted }

        var metricsToLog: Metrics?
        var overflowMetrics: Metrics?

        lock.lock()
        guard active, accepting, candidateGeneration == generation else {
            lock.unlock()
            return .inactive
        }

        capturedSamples += Int64(samples.count)
        let unprocessedSamples = queuedSamples + inFlightSamples
        if samples.count > maximumPendingSamples - min(unprocessedSamples, maximumPendingSamples) {
            overflowCount += 1
            discardedSamples += Int64(samples.count)
            active = false
            overflowMetrics = makeMetricsLocked()
        } else {
            pendingChunks.append(samples)
            queuedSamples += samples.count
            enqueuedSamples += Int64(samples.count)
            maximumObservedPendingSamples = max(
                maximumObservedPendingSamples,
                queuedSamples + inFlightSamples
            )
            if capturedSamples >= nextMetricsLogSample {
                metricsToLog = makeMetricsLocked()
                repeat {
                    nextMetricsLogSample += Int64(Self.sampleRate * 5)
                } while capturedSamples >= nextMetricsLogSample
            }
        }
        lock.unlock()

        if let overflowMetrics {
            signalContinuation.finish()
            drainTask?.cancel()
            log.error(
                "Audio ingress overflow captured=\(overflowMetrics.capturedSamples, privacy: .public) enqueued=\(overflowMetrics.enqueuedSamples, privacy: .public) processed=\(overflowMetrics.processedSamples, privacy: .public) pendingSeconds=\(overflowMetrics.pendingSeconds, privacy: .public) maxPendingSeconds=\(overflowMetrics.maximumPendingSeconds, privacy: .public) limitSeconds=\(overflowMetrics.pendingLimitSeconds, privacy: .public)"
            )
            onOverflow(overflowMetrics)
            return .overflow(overflowMetrics)
        }

        if let metricsToLog {
            logMetrics(metricsToLog, event: "progress")
        }
        signalContinuation.yield(())
        return .accepted
    }

    /// Cancels future delivery and explicitly discards queued or currently
    /// processing tail audio. The backend's synchronous in-flight inference is
    /// still awaited by `waitUntilStopped()` before its model is released.
    @discardableResult
    func cancel() -> Metrics {
        lock.lock()
        active = false
        discardedSamples += Int64(queuedSamples + inFlightSamples)
        pendingChunks.removeAll(keepingCapacity: false)
        pendingChunkIndex = 0
        pendingChunkOffset = 0
        queuedSamples = 0
        inFlightSamples = 0
        let metrics = makeMetricsLocked()
        lock.unlock()

        signalContinuation.finish()
        drainTask?.cancel()
        logMetrics(metrics, event: "cancel")
        return metrics
    }

    /// Seal capture while retaining every already accepted buffer for delivery.
    func finish() {
        lock.lock()
        accepting = false
        lock.unlock()
        signalContinuation.yield(())
        signalContinuation.finish()
    }

    func waitUntilStopped() async {
        await currentDrainTask()?.value
    }

    private func currentDrainTask() -> Task<Void, Never>? {
        lock.lock()
        let task = drainTask
        lock.unlock()
        return task
    }

    func snapshot() -> Metrics {
        lock.lock()
        let metrics = makeMetricsLocked()
        lock.unlock()
        return metrics
    }

    private func drainAvailableAudio() async {
        while !Task.isCancelled, let batch = takeNextBatch() {
            await consume(batch.samples)
            complete(batch)
        }
    }

    private func takeNextBatch() -> Batch? {
        lock.lock()
        defer { lock.unlock() }
        guard active, queuedSamples > 0 else { return nil }

        let requestedCount = min(queuedSamples, maximumBatchSamples)
        var samples: [Float] = []
        samples.reserveCapacity(requestedCount)
        while samples.count < requestedCount, pendingChunkIndex < pendingChunks.count {
            let chunk = pendingChunks[pendingChunkIndex]
            let available = chunk.count - pendingChunkOffset
            let takeCount = min(available, requestedCount - samples.count)
            let endOffset = pendingChunkOffset + takeCount
            samples.append(contentsOf: chunk[pendingChunkOffset..<endOffset])
            pendingChunkOffset = endOffset
            if pendingChunkOffset == chunk.count {
                pendingChunkIndex += 1
                pendingChunkOffset = 0
            }
        }

        if pendingChunkIndex == pendingChunks.count {
            pendingChunks.removeAll(keepingCapacity: true)
            pendingChunkIndex = 0
        } else if pendingChunkIndex >= 128,
                  pendingChunkIndex * 2 >= pendingChunks.count {
            pendingChunks.removeFirst(pendingChunkIndex)
            pendingChunkIndex = 0
        }
        queuedSamples -= samples.count
        inFlightSamples += samples.count
        return Batch(samples: samples, generation: generation)
    }

    private func complete(_ batch: Batch) {
        lock.lock()
        defer { lock.unlock() }
        guard active, batch.generation == generation else { return }
        inFlightSamples = max(0, inFlightSamples - batch.samples.count)
        processedSamples += Int64(batch.samples.count)
    }

    private func makeMetricsLocked() -> Metrics {
        Metrics(
            capturedSamples: capturedSamples,
            enqueuedSamples: enqueuedSamples,
            processedSamples: processedSamples,
            pendingSamples: queuedSamples + inFlightSamples,
            maximumPendingSamples: maximumObservedPendingSamples,
            pendingLimitSamples: maximumPendingSamples,
            discardedSamples: discardedSamples,
            overflowCount: overflowCount,
            sampleRate: Self.sampleRate
        )
    }

    private func logMetrics(_ metrics: Metrics, event: String) {
        log.info(
            "Audio ingress \(event, privacy: .public) captured=\(metrics.capturedSamples, privacy: .public) enqueued=\(metrics.enqueuedSamples, privacy: .public) processed=\(metrics.processedSamples, privacy: .public) pendingSeconds=\(metrics.pendingSeconds, privacy: .public) maxPendingSeconds=\(metrics.maximumPendingSeconds, privacy: .public) limitSeconds=\(metrics.pendingLimitSeconds, privacy: .public) discarded=\(metrics.discardedSamples, privacy: .public)"
        )
    }
}
