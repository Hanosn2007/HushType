import XCTest
import AudioCommon
import SpeechVAD
import MLX
@testable import HushType

/// Opt-in smoke with the dependency's spoken WAV fixture and cached weights.
/// It never opens a microphone, starts system capture, or changes app settings.
final class LiveCaptionRuntimeTests: XCTestCase {
    func testSpokenAudioProducesCaptionAndBackendCanRestart() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["HUSHTYPE_CAPTION_TEST_WAV"] else {
            throw XCTSkip("Set HUSHTYPE_CAPTION_TEST_WAV to run the local-model audio smoke")
        }
        let (samples, rate) = try AudioFileLoader.loadWAV(url: URL(fileURLWithPath: fixturePath))
        let audio = rate == 16000 ? samples : AudioFileLoader.resample(samples, from: rate, to: 16000)
        let engine = Qwen3TranscriptionEngine()
        try await engine.load(progressHandler: nil)
        let vad = try await SileroVADModel.fromPretrained(engine: .mlx)
        let oldCacheLimit = MLX.Memory.cacheLimit
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
        defer { MLX.Memory.cacheLimit = oldCacheLimit }

        // Reuse the exact loaded models across a full stop/start, as the app
        // does when moving between dictation and local captions.
        for iteration in 1...2 {
            let backend = LocalQwen3Backend(
                engine: engine, vadModel: vad, language: "English", tuning: .init()
            )
            let received = expectation(description: "Spoken caption \(iteration)")
            received.assertForOverFulfill = false
            let consumer = Task { () -> [String] in
                var texts: [String] = []
                for await event in backend.events {
                    if case .segmentComplete(let text) = event {
                        texts.append(text)
                        received.fulfill()
                    }
                }
                return texts
            }
            try await backend.start()
            let generation = UInt64(iteration)
            let ingress = LiveCaptionAudioIngress(generation: generation, consume: { samples in
                await backend.feed(samples: samples)
            })
            // Second pass stops during speech: no trailing silence may trigger VAD.
            let buffered = Array(repeating: Float(0), count: 16000) + audio
                + Array(repeating: Float(0), count: iteration == 1 ? 32000 : 0)
            for offset in stride(from: 0, to: buffered.count, by: 1600) {
                XCTAssertEqual(ingress.append(
                    Array(buffered[offset..<min(offset + 1600, buffered.count)]),
                    generation: generation
                ), .accepted)
            }
            if iteration == 2 {
                ingress.finish()
                await ingress.waitUntilStopped()
                await backend.finish()
            }
            let deadline = Date().addingTimeInterval(45)
            while ingress.snapshot().pendingSamples > 0, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let metrics = ingress.snapshot()
            XCTAssertEqual(metrics.capturedSamples, Int64(buffered.count))
            XCTAssertEqual(metrics.processedSamples, Int64(buffered.count))
            XCTAssertEqual(metrics.discardedSamples, 0)
            ingress.cancel()
            await ingress.waitUntilStopped()
            await fulfillment(of: [received], timeout: 15)
            await backend.stop()
            let texts = await consumer.value
            let text = texts.joined(separator: " ").lowercased()
            print("Caption runtime pass \(iteration): \(text)")
            XCTAssertTrue(text.contains("replacement"), text)
            XCTAssertTrue(text.contains("tomorrow"), text)
        }
        await engine.unloadAndWait()
    }
}
