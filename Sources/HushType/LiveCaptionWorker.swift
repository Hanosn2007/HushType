import Foundation
import AudioCommon
import SpeechVAD
import os

extension VADConfig {
    /// Build a config from Silero defaults but with onset/offset/duration
    /// overrides from the user-editable `LiveCaptionTuning` file.
    static func fromTuning(_ t: LiveCaptionTuning) -> VADConfig {
        VADConfig(
            onset: t.vadOnset,
            offset: t.vadOffset,
            minSpeechDuration: t.vadMinSpeechSeconds,
            minSilenceDuration: t.vadMinSilenceSeconds,
            windowDuration: VADConfig.sileroDefault.windowDuration,
            stepRatio: VADConfig.sileroDefault.stepRatio
        )
    }
}

private let log = Logger(subsystem: "com.felix.hushtype", category: "liveCaptionWorker")

/// Result of an ASR transcription emitted by `LiveCaptionWorker`.
struct LiveCaptionSegment: Sendable {
    let text: String
    /// Wall-clock time when the worker emitted this segment.
    let emittedAt: Date
    /// Speech duration in seconds.
    let duration: Float
}

/// Confines mutable VAD/buffer state to one actor. Qwen itself is shared with
/// dictation only through `QwenASRInferenceCoordinator`.
///
/// Mirrors `speech-swift`'s `StreamingASR.swift` for the audio-accumulation
/// contract: `VADEvent.speechEnded` carries `SpeechSegment` start/end times
/// in seconds, and the audio buffer to transcribe is sliced from a rolling
/// outer `samplesBuffer` whose index 0 corresponds to absolute sample
/// `sliceBaseSample`.
actor LiveCaptionWorker {
    private let engine: Qwen3TranscriptionEngine
    private let vadProcessor: StreamingVADProcessor
    private let segmentContinuation: AsyncStream<LiveCaptionSegment>.Continuation
    private let language: String?
    private let maxTokens: Int

    /// Rolling buffer of all live samples received since the most recent
    /// segment emission. `samplesBuffer[i]` corresponds to absolute sample
    /// index `sliceBaseSample + i`.
    private var samplesBuffer: [Float] = []
    private var sliceBaseSample: Int = 0
    private var currentSpeechStartTime: Date?
    private var currentSpeechStartSample: Int?
    private var vadProcessedSamples: Int64 = 0
    private var vadProcessingMilliseconds: Double = 0
    private var vadSpeechStartedCount = 0
    private var vadSpeechEndedCount = 0
    private var nextVADMetricsSample: Int64 = 5 * 16_000
    private let forceSplitSamples: Int
    private var lifecycleGeneration: UInt64 = 0

    private static let sampleRate: Int = 16000

    init(
        engine: Qwen3TranscriptionEngine,
        vadModel: SileroVADModel,
        segmentContinuation: AsyncStream<LiveCaptionSegment>.Continuation,
        language: String?,
        tuning: LiveCaptionTuning
    ) {
        self.engine = engine
        self.vadProcessor = StreamingVADProcessor(
            model: vadModel,
            config: .fromTuning(tuning)
        )
        self.segmentContinuation = segmentContinuation
        self.language = language
        self.maxTokens = tuning.maxTokens
        self.forceSplitSamples = max(1, Int(tuning.forceSplitSeconds * Double(Self.sampleRate)))
    }

    /// Feed a buffer of 16kHz mono samples. Appends to the rolling buffer,
    /// runs VAD, and emits a segment per `.speechEnded` event.
    func feed(_ samples: [Float]) async {
        let generation = lifecycleGeneration
        samplesBuffer.append(contentsOf: samples)
        let vadStartedAt = ProcessInfo.processInfo.systemUptime
        let events = vadProcessor.process(samples: samples)
        vadProcessingMilliseconds += (ProcessInfo.processInfo.systemUptime - vadStartedAt) * 1_000
        vadProcessedSamples += Int64(samples.count)
        for event in events {
            guard lifecycleGeneration == generation, !Task.isCancelled else { return }
            switch event {
            case .speechStarted(let time):
                vadSpeechStartedCount += 1
                currentSpeechStartTime = Date()
                currentSpeechStartSample = Int(time * Float(Self.sampleRate))
            case .speechEnded(let segment):
                vadSpeechEndedCount += 1
                await emitSegment(segment, generation: generation)
            }
        }
        guard lifecycleGeneration == generation, !Task.isCancelled else { return }
        if vadProcessedSamples >= nextVADMetricsSample {
            log.info(
                "VAD metrics processedSamples=\(self.vadProcessedSamples, privacy: .public) audioSeconds=\(Double(self.vadProcessedSamples) / Double(Self.sampleRate), privacy: .public) processingMs=\(self.vadProcessingMilliseconds, privacy: .public) speechStarted=\(self.vadSpeechStartedCount, privacy: .public) speechEnded=\(self.vadSpeechEndedCount, privacy: .public)"
            )
            repeat {
                nextVADMetricsSample += Int64(5 * Self.sampleRate)
            } while vadProcessedSamples >= nextVADMetricsSample
        }
        await forceSplitForProcessedAudioIfNeeded()
        guard lifecycleGeneration == generation, !Task.isCancelled else { return }
        await trimBufferIfNeeded(generation: generation)
    }

    /// Bound the rolling sample buffer so a long silent stretch (with no
    /// `.speechEnded` events to drain it) doesn't grow without bound.
    ///
    /// - When VAD is in confirmed silence (`currentSpeechStartTime == nil`),
    ///   trim to a small lookback window. The lookback must cover the
    ///   `pendingSpeech` window (`minSpeechDuration = 0.25s` at sileroDefault)
    ///   so a not-yet-confirmed speech start retains its leading audio.
    ///   `LookbackSeconds = 2` is safely larger than that.
    /// - When VAD is mid-speech (`currentSpeechStartTime != nil`), tolerate
    ///   growth up to the §10 force-split watermark (2× the 10s window) so
    ///   the force-split timer can still grab the full active utterance.
    ///   If the buffer crosses the hard cap before force-split fires, we
    ///   force-split immediately to drain.
    private func trimBufferIfNeeded(generation: UInt64) async {
        let lookbackSamples = 2 * Self.sampleRate           // 2 s
        let hardCapSamples  = 32 * Self.sampleRate          // 32 s

        if currentSpeechStartTime == nil {
            if samplesBuffer.count > lookbackSamples * 2 {
                let drop = samplesBuffer.count - lookbackSamples
                samplesBuffer.removeFirst(drop)
                sliceBaseSample += drop
            }
            return
        }

        if samplesBuffer.count > hardCapSamples {
            log.warning("samplesBuffer exceeded hard cap (\(self.samplesBuffer.count, privacy: .public) samples) — force-splitting")
            await forceSplit(generation: generation)
        }
    }

    /// Force-split a long monologue: §10 algorithm. Transcribe whatever's in
    /// `samplesBuffer` corresponding to the active speech, emit, trim,
    /// re-anchor the timer, but DO NOT reset VAD — hysteresis state continues
    /// across the split.
    func forceSplit() async {
        await forceSplit(generation: lifecycleGeneration)
    }

    private func forceSplit(generation: UInt64) async {
        guard generation == lifecycleGeneration, !Task.isCancelled else { return }
        // Only force-split if there is in-flight speech (timer was anchored).
        guard currentSpeechStartTime != nil else { return }
        guard !samplesBuffer.isEmpty else { return }

        let duration = Float(samplesBuffer.count) / Float(Self.sampleRate)
        let audioSlice = samplesBuffer
        // Advance every mutable segmentation field before awaiting the shared
        // model. Actor re-entrancy may admit reset()/forceSplit() while this
        // request waits in the coordinator queue.
        sliceBaseSample += samplesBuffer.count
        samplesBuffer.removeAll(keepingCapacity: true)
        currentSpeechStartTime = Date()  // re-anchor for next force-split window
        currentSpeechStartSample = Int(vadProcessor.currentTime * Float(Self.sampleRate))

        guard let text = await transcribeWithMetrics(audioSlice, reason: "forceSplit"),
              generation == lifecycleGeneration,
              !Task.isCancelled else { return }
        log.info("forceSplit emitted segment, duration=\(duration, privacy: .public)s, chars=\(text.count, privacy: .public)")
        segmentContinuation.yield(LiveCaptionSegment(text: text, emittedAt: Date(), duration: duration))
    }

    /// Wall-clock time of the currently-active speech segment, if any. Used
    /// by `LiveCaptionManager` to decide whether the 10s force-split timer
    /// should fire.
    func activeSpeechStartedAt() -> Date? {
        currentSpeechStartTime
    }

    /// Commit the last speech buffer and close the stream only after its result.
    func finish() async {
        await forceSplit()
        segmentContinuation.finish()
    }

    /// Tear down all worker state. Called from `LiveCaptionManager.stop()`.
    func reset() {
        lifecycleGeneration &+= 1
        samplesBuffer.removeAll(keepingCapacity: false)
        sliceBaseSample = 0
        currentSpeechStartTime = nil
        currentSpeechStartSample = nil
        vadProcessor.reset()
        vadProcessedSamples = 0
        vadProcessingMilliseconds = 0
        vadSpeechStartedCount = 0
        vadSpeechEndedCount = 0
        nextVADMetricsSample = Int64(5 * Self.sampleRate)
    }

    // MARK: - Private

    private func emitSegment(_ segment: SpeechSegment, generation: UInt64) async {
        guard generation == lifecycleGeneration, !Task.isCancelled else { return }
        let startSampleAbs = Int(segment.startTime * Float(Self.sampleRate))
        let endSampleAbs   = Int(segment.endTime   * Float(Self.sampleRate))

        let startIdx = max(0, startSampleAbs - sliceBaseSample)
        let endIdx   = min(samplesBuffer.count, endSampleAbs - sliceBaseSample)

        guard endIdx > startIdx else {
            log.warning("emitSegment: empty slice (startIdx=\(startIdx) endIdx=\(endIdx) baseSample=\(self.sliceBaseSample) bufLen=\(self.samplesBuffer.count))")
            currentSpeechStartTime = nil
            currentSpeechStartSample = nil
            return
        }

        let audioSlice = Array(samplesBuffer[startIdx..<endIdx])
        let duration = Float(audioSlice.count) / Float(Self.sampleRate)

        // Trim consumed samples and clear the segment before awaiting Qwen.
        // This keeps a re-entrant reset or timer call coherent while inference
        // is queued behind dictation.
        samplesBuffer.removeFirst(endIdx)
        sliceBaseSample += endIdx
        currentSpeechStartTime = nil
        currentSpeechStartSample = nil

        guard let text = await transcribeWithMetrics(audioSlice, reason: "speechEnded"),
              generation == lifecycleGeneration,
              !Task.isCancelled else { return }
        log.info("emitSegment duration=\(duration, privacy: .public)s chars=\(text.count, privacy: .public)")
        segmentContinuation.yield(LiveCaptionSegment(text: text, emittedAt: Date(), duration: duration))
    }

    /// During backlog catch-up, many seconds of audio can pass through the VAD
    /// faster than wall time. Split against VAD's processed-audio clock as well
    /// as the manager's wall-clock timer so Qwen never receives a catch-up
    /// monologue far beyond the configured segment window.
    private func forceSplitForProcessedAudioIfNeeded() async {
        guard let currentSpeechStartSample else { return }
        let processedSample = Int(vadProcessor.currentTime * Float(Self.sampleRate))
        guard processedSample - currentSpeechStartSample >= forceSplitSamples else { return }
        log.info(
            "Force-split triggered by processed audio duration samples=\(processedSample - currentSpeechStartSample, privacy: .public)"
        )
        await forceSplit(generation: lifecycleGeneration)
    }

    private func transcribeWithMetrics(_ audio: [Float], reason: String) async -> String? {
        let audioSeconds = Double(audio.count) / Double(Self.sampleRate)
        log.info(
            "ASR started reason=\(reason, privacy: .public) samples=\(audio.count, privacy: .public) audioSeconds=\(audioSeconds, privacy: .public)"
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        let text: String
        do {
            text = try await engine.transcribeRaw(
                audio: audio,
                language: language,
                maxTokens: maxTokens,
                client: .liveCaption
            )
        } catch is CancellationError {
            log.info("ASR cancelled reason=\(reason, privacy: .public)")
            return nil
        } catch {
            log.error("ASR failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        log.info(
            "ASR completed reason=\(reason, privacy: .public) samples=\(audio.count, privacy: .public) audioSeconds=\(audioSeconds, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public) outputCharacters=\(text.count, privacy: .public)"
        )
        return text
    }
}
