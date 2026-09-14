import AudioCommon
import Foundation
import MLX
import Qwen3ASR
import XCTest
@testable import HushType

/// Opt-in benchmark for deciding whether a second resident Qwen ASR instance
/// has a measured latency benefit. Run this test by itself: the shared-gate
/// scenarios assume no other local MLX inference is active in this process.
///
/// The test requires an already-complete HushType model cache. It never opens
/// a microphone and does not clear MLX's process-wide cache between scenarios,
/// so every JSON record reports the allocator state that actually carried over.
final class QwenASRDualModelRuntimeTests: XCTestCase {
    private static let sampleRate = 16_000
    private static let language = "English"
    private static let maxTokens = 128
    private static let longInputRepeatCount = 4

    private final class ModelBox: @unchecked Sendable {
        let model: Qwen3ASRModel

        init(_ model: Qwen3ASRModel) {
            self.model = model
        }

        func transcribe(audio: [Float], language: String?, maxTokens: Int) -> String {
            model.transcribe(
                audio: audio,
                sampleRate: QwenASRDualModelRuntimeTests.sampleRate,
                language: language,
                maxTokens: maxTokens
            )
        }
    }

    private struct TimedOutput {
        let text: String
        let seconds: Double
    }

    private struct ScenarioConfiguration {
        let label: String
        let captionCoordinator: QwenASRInferenceCoordinator
        let dictationCoordinator: QwenASRInferenceCoordinator
        let modelInstanceCount: Int
        let gateMode: String
    }

    func testSingleModelSharedGateVersusDualModelSharedAndBypassedGate() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HUSHTYPE_ASR_DUAL_MODEL_RUNTIME"] == "1" else {
            throw XCTSkip("Set HUSHTYPE_ASR_DUAL_MODEL_RUNTIME=1 to run the dual-model benchmark")
        }
        guard let fixturePath = environment["HUSHTYPE_CAPTION_TEST_WAV"], !fixturePath.isEmpty else {
            throw XCTSkip("Set HUSHTYPE_CAPTION_TEST_WAV to a known spoken WAV fixture")
        }
        let previousCacheLimit = MLX.Memory.cacheLimit
        MLX.Memory.cacheLimit = 1024 * 1024 * 1024 // Matches AppDelegate.
        defer { MLX.Memory.cacheLimit = previousCacheLimit }

        let modelID = AppConfig.shared.modelId
        guard let descriptor = LocalModelCatalog.descriptor(for: modelID),
              LocalModelCatalog.isInstalled(descriptor) else {
            throw XCTSkip("The selected Qwen ASR model must be completely cached before this benchmark")
        }

        let (loadedSamples, rate) = try AudioFileLoader.loadWAV(
            url: URL(fileURLWithPath: fixturePath)
        )
        let captionAudio = rate == Self.sampleRate
            ? loadedSamples
            : AudioFileLoader.resample(loadedSamples, from: rate, to: Self.sampleRate)
        guard !captionAudio.isEmpty else {
            XCTFail("The benchmark WAV must contain audio samples")
            return
        }
        let dictationAudio = Array(repeating: captionAudio, count: Self.longInputRepeatCount)
            .flatMap { $0 }

        let firstLoadStart = ContinuousClock.now
        let firstModel = try await Qwen3ASRModel.fromPretrained(modelId: modelID)
        emitLoadRecord(
            label: "after_load_one",
            modelID: modelID,
            residentModelInstances: 1,
            seconds: Self.seconds(since: firstLoadStart)
        )

        let firstBox = ModelBox(firstModel)
        var secondModel: Qwen3ASRModel?
        var benchmarkError: Error?
        do {
            try await warm(firstBox, label: "model_1_warm", modelID: modelID, audio: captionAudio)

            let singleCoordinator = makeCoordinator(firstBox, bypassSharedGate: false)
            try await runScenario(
                ScenarioConfiguration(
                    label: "single_model_shared_gate_two_clients",
                    captionCoordinator: singleCoordinator,
                    dictationCoordinator: singleCoordinator,
                    modelInstanceCount: 1,
                    gateMode: "shared"
                ),
                modelID: modelID,
                captionAudio: captionAudio,
                dictationAudio: dictationAudio
            )

            let secondLoadStart = ContinuousClock.now
            let loadedSecondModel = try await Qwen3ASRModel.fromPretrained(modelId: modelID)
            secondModel = loadedSecondModel
            emitLoadRecord(
                label: "after_load_two",
                modelID: modelID,
                residentModelInstances: 2,
                seconds: Self.seconds(since: secondLoadStart)
            )
            XCTAssertFalse(firstModel === loadedSecondModel)
            let secondBox = ModelBox(loadedSecondModel)
            try await warm(secondBox, label: "model_2_warm", modelID: modelID, audio: captionAudio)

            try await runScenario(
                ScenarioConfiguration(
                    label: "dual_model_shared_gate",
                    captionCoordinator: makeCoordinator(firstBox, bypassSharedGate: false),
                    dictationCoordinator: makeCoordinator(secondBox, bypassSharedGate: false),
                    modelInstanceCount: 2,
                    gateMode: "shared"
                ),
                modelID: modelID,
                captionAudio: captionAudio,
                dictationAudio: dictationAudio
            )

            try await runScenario(
                ScenarioConfiguration(
                    label: "dual_model_bypassed_gate",
                    captionCoordinator: makeCoordinator(firstBox, bypassSharedGate: true),
                    dictationCoordinator: makeCoordinator(secondBox, bypassSharedGate: true),
                    modelInstanceCount: 2,
                    gateMode: "bypass"
                ),
                modelID: modelID,
                captionAudio: captionAudio,
                dictationAudio: dictationAudio
            )
        } catch {
            benchmarkError = error
        }

        // Every scenario drains its coordinators before returning. Releasing
        // model weights is therefore safe here. We deliberately leave MLX's
        // shared allocator cache untouched so the scenario records are honest
        // about order-dependent cache carry-over.
        firstModel.unload()
        secondModel?.unload()

        if let benchmarkError { throw benchmarkError }
    }

    private func warm(
        _ box: ModelBox,
        label: String,
        modelID: String,
        audio: [Float]
    ) async throws {
        let coordinator = makeCoordinator(box, bypassSharedGate: false)
        let start = ContinuousClock.now
        var output: String?
        var warmError: Error?
        do {
            output = try await coordinator.transcribe(
                audio: audio,
                language: Self.language,
                maxTokens: Self.maxTokens,
                client: .liveCaption
            )
        } catch {
            warmError = error
        }
        await coordinator.shutdownAndWait()
        if let warmError { throw warmError }

        let text = output ?? ""
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label)
        emitJSON([
            "record_type": "qwen_asr_dual_model_runtime",
            "stage": "warmup",
            "label": label,
            "model_id": modelID,
            "seconds": Self.seconds(since: start),
            "output": text,
            "phys_footprint_mb": MemoryUtils.physFootprintMB(),
        ])
    }

    private func runScenario(
        _ configuration: ScenarioConfiguration,
        modelID: String,
        captionAudio: [Float],
        dictationAudio: [Float]
    ) async throws {
        MLX.GPU.resetPeakMemory()
        let footprintSampler = Task { () -> Int in
            var peak = MemoryUtils.physFootprintMB()
            while !Task.isCancelled {
                peak = max(peak, MemoryUtils.physFootprintMB())
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return max(peak, MemoryUtils.physFootprintMB())
        }
        let totalStart = ContinuousClock.now
        var outputs: (caption: TimedOutput, dictation: TimedOutput)?
        var scenarioError: Error?
        do {
            async let caption = Self.timedTranscription(
                configuration.captionCoordinator,
                audio: captionAudio,
                client: .liveCaption
            )
            async let dictation = Self.timedTranscription(
                configuration.dictationCoordinator,
                audio: dictationAudio,
                client: .dictation
            )
            outputs = try await (caption, dictation)
        } catch {
            scenarioError = error
        }
        let totalSeconds = Self.seconds(since: totalStart)
        footprintSampler.cancel()
        let peakFootprintMB = await footprintSampler.value

        if configuration.captionCoordinator === configuration.dictationCoordinator {
            await configuration.captionCoordinator.shutdownAndWait()
        } else {
            async let captionShutdown: Void = configuration.captionCoordinator.shutdownAndWait()
            async let dictationShutdown: Void = configuration.dictationCoordinator.shutdownAndWait()
            _ = await (captionShutdown, dictationShutdown)
        }
        if let scenarioError { throw scenarioError }
        guard let outputs else {
            XCTFail("Missing benchmark outputs for \(configuration.label)")
            return
        }

        XCTAssertFalse(
            outputs.caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(configuration.label) caption output"
        )
        XCTAssertFalse(
            outputs.dictation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(configuration.label) dictation output"
        )

        let memory = MLX.Memory.snapshot()
        emitJSON([
            "record_type": "qwen_asr_dual_model_runtime",
            "stage": "scenario",
            "scenario": configuration.label,
            "round": 1,
            "model_id": modelID,
            "model_instances": configuration.modelInstanceCount,
            "gate_mode": configuration.gateMode,
            "language": Self.language,
            "max_tokens": Self.maxTokens,
            "caption_audio_samples": captionAudio.count,
            "dictation_audio_samples": dictationAudio.count,
            "caption_seconds": outputs.caption.seconds,
            "dictation_seconds": outputs.dictation.seconds,
            "total_seconds": totalSeconds,
            "caption_output": outputs.caption.text,
            "dictation_output": outputs.dictation.text,
            "mlx_peak_bytes": memory.peakMemory,
            "mlx_active_bytes": memory.activeMemory,
            "mlx_cache_bytes": memory.cacheMemory,
            "phys_footprint_mb": MemoryUtils.physFootprintMB(),
            "phys_footprint_peak_mb": peakFootprintMB,
            "mlx_cache_cleared_between_scenarios": false,
            "requires_isolated_test_process": true,
        ])
    }

    private static func timedTranscription(
        _ coordinator: QwenASRInferenceCoordinator,
        audio: [Float],
        client: QwenASRInferenceClient
    ) async throws -> TimedOutput {
        let start = ContinuousClock.now
        let text = try await coordinator.transcribe(
            audio: audio,
            language: Self.language,
            maxTokens: Self.maxTokens,
            client: client
        )
        return TimedOutput(text: text, seconds: seconds(since: start))
    }

    private func makeCoordinator(
        _ box: ModelBox,
        bypassSharedGate: Bool
    ) -> QwenASRInferenceCoordinator {
        let transcriber: QwenASRInferenceCoordinator.Transcriber = {
            [box] audio, language, maxTokens in
            box.transcribe(audio: audio, language: language, maxTokens: maxTokens)
        }
        if bypassSharedGate {
            return QwenASRInferenceCoordinator(
                transcriber: transcriber,
                computeGate: { operation in await operation() }
            )
        }
        return QwenASRInferenceCoordinator(transcriber: transcriber)
    }

    private func emitLoadRecord(
        label: String,
        modelID: String,
        residentModelInstances: Int,
        seconds: Double
    ) {
        let memory = MLX.Memory.snapshot()
        emitJSON([
            "record_type": "qwen_asr_dual_model_runtime",
            "stage": "load",
            "label": label,
            "model_id": modelID,
            "resident_model_instances": residentModelInstances,
            "seconds": seconds,
            "mlx_active_bytes": memory.activeMemory,
            "mlx_cache_bytes": memory.cacheMemory,
            "mlx_peak_bytes": memory.peakMemory,
            "phys_footprint_mb": MemoryUtils.physFootprintMB(),
        ])
    }

    private func emitJSON(_ record: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            XCTFail("Could not serialize dual-model runtime record")
            return
        }
        print(json)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
