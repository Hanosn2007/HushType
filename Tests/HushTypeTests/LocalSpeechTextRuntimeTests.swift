import AudioCommon
import Foundation
import MLX
import XCTest
@testable import HushType

/// Opt-in cached-model smoke for the app's real ASR/text global-gate mix.
/// It opens no microphone and never invokes either model's download API.
final class LocalSpeechTextRuntimeTests: XCTestCase {
    private final class EngineBox: @unchecked Sendable {
        let engine: Qwen3TranscriptionEngine
        init(_ engine: Qwen3TranscriptionEngine) { self.engine = engine }
    }

    private struct TimedOutput {
        let text: String
        let seconds: Double
    }

    func testConcurrentASRAndTextRequestsShareGlobalGateAndDrain() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HUSHTYPE_LOCAL_MIX_RUNTIME"] == "1" else {
            throw XCTSkip("Set HUSHTYPE_LOCAL_MIX_RUNTIME=1 to run the local mixed-model smoke")
        }
        guard let wavPath = environment["HUSHTYPE_CAPTION_TEST_WAV"], !wavPath.isEmpty else {
            throw XCTSkip("Set HUSHTYPE_CAPTION_TEST_WAV to a known spoken WAV fixture")
        }

        let asrModelID = AppConfig.shared.modelId
        guard let asrDescriptor = LocalModelCatalog.descriptor(for: asrModelID),
              LocalModelCatalog.isInstalled(asrDescriptor) else {
            throw XCTSkip("The selected Qwen ASR model must already be completely cached")
        }
        let textCatalog = try LocalTextModelCatalog()
        guard case .installed = textCatalog.installation() else {
            throw XCTSkip("The pinned local text model must already be completely cached")
        }

        let (loaded, rate) = try AudioFileLoader.loadWAV(url: URL(fileURLWithPath: wavPath))
        let shortAudio = rate == 16_000
            ? loaded
            : AudioFileLoader.resample(loaded, from: rate, to: 16_000)
        guard !shortAudio.isEmpty else {
            XCTFail("The benchmark WAV must contain audio samples")
            return
        }
        let longAudio = Array(repeating: shortAudio, count: 4).flatMap { $0 }
        let textInput = "HushType uses 32GB of memory at 10:30."

        let previousCacheLimit = MLX.Memory.cacheLimit
        MLX.Memory.cacheLimit = 1_024 * 1_024 * 1_024
        defer { MLX.Memory.cacheLimit = previousCacheLimit }

        let engine = Qwen3TranscriptionEngine()
        let engineBox = EngineBox(engine)
        let textService = LocalTextModelService(catalog: textCatalog)
        var footprintSampler: Task<Int, Never>?
        defer { footprintSampler?.cancel() }
        var runtimeError: Error?
        do {
            try await engine.load(progressHandler: nil)
            try await textService.load()
            _ = try await engine.transcribeRaw(
                audio: shortAudio, language: "English", maxTokens: 128, client: .liveCaption
            )
            _ = try await textService.translate(textInput, to: .simplifiedChinese)

            MLX.GPU.resetPeakMemory()
            footprintSampler = Task { () -> Int in
                var peak = MemoryUtils.physFootprintMB()
                while !Task.isCancelled {
                    peak = max(peak, MemoryUtils.physFootprintMB())
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return max(peak, MemoryUtils.physFootprintMB())
            }
            let totalStart = ContinuousClock.now
            async let caption = Self.measure {
                try await engineBox.engine.transcribeRaw(
                    audio: shortAudio,
                    language: "English",
                    maxTokens: 128,
                    client: .liveCaption
                )
            }
            async let dictation = Self.measure {
                try await engineBox.engine.transcribeRaw(
                    audio: longAudio,
                    language: "English",
                    maxTokens: 128,
                    client: .dictation
                )
            }
            async let translation = Self.measure {
                try await textService.translate(textInput, to: .simplifiedChinese)
            }
            let outputs = try await (caption, dictation, translation)
            let totalSeconds = Self.seconds(since: totalStart)
            let peakFootprintMB: Int
            if let sampler = footprintSampler {
                sampler.cancel()
                peakFootprintMB = await sampler.value
            } else {
                peakFootprintMB = MemoryUtils.physFootprintMB()
            }
            footprintSampler = nil

            XCTAssertFalse(outputs.0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(outputs.1.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(outputs.2.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            for preserved in ["HushType", "32GB", "10:30"] {
                XCTAssertTrue(outputs.2.text.localizedCaseInsensitiveContains(preserved), outputs.2.text)
            }

            let memory = MLX.Memory.snapshot()
            emitJSON([
                "record_type": "local_speech_text_runtime",
                "asr_model_id": asrModelID,
                "text_model_id": textCatalog.model.repositoryID,
                "caption_seconds": outputs.0.seconds,
                "dictation_seconds": outputs.1.seconds,
                "translation_seconds": outputs.2.seconds,
                "total_seconds": totalSeconds,
                "caption_output": outputs.0.text,
                "dictation_output": outputs.1.text,
                "translation_output": outputs.2.text,
                "mlx_active_bytes": memory.activeMemory,
                "mlx_cache_bytes": memory.cacheMemory,
                "mlx_peak_bytes": memory.peakMemory,
                "mlx_cache_limit_bytes": MLX.Memory.cacheLimit,
                "phys_footprint_mb": MemoryUtils.physFootprintMB(),
                "phys_footprint_peak_mb": peakFootprintMB,
            ])
        } catch {
            footprintSampler?.cancel()
            if let footprintSampler { _ = await footprintSampler.value }
            runtimeError = error
        }

        await textService.unload()
        await engine.unloadAndWait()
        if let runtimeError { throw runtimeError }
    }

    private static func measure(
        _ operation: @escaping @Sendable () async throws -> String
    ) async throws -> TimedOutput {
        let start = ContinuousClock.now
        return TimedOutput(text: try await operation(), seconds: seconds(since: start))
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func emitJSON(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            XCTFail("Could not serialize mixed local-model runtime record")
            return
        }
        print(json)
    }
}
