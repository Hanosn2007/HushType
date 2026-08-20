import Foundation
import Qwen3ASR
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "transcription")

// MARK: - Protocol

protocol TranscriptionEngine: AnyObject {
    var isLoaded: Bool { get }
    func load(progressHandler: ((Double, String) -> Void)?) async throws
    func transcribe(audio: [Float], language: String?) async throws -> String
}

enum TranscriptionError: Error {
    case noKey
    case auth
    case rateLimited(provider: String)
    case network
    case timeout
    case payloadTooLarge
    case malformedResponse
    case safetyBlocked
}

// MARK: - Qwen3 Implementation

final class Qwen3TranscriptionEngine: TranscriptionEngine {
    private var model: Qwen3ASRModel?

    var isLoaded: Bool { model != nil }

    /// Read-only handle for the live-caption pipeline. Returns the loaded
    /// model instance so `LiveCaptionManager` can call `transcribe()` directly
    /// without going through the dictation post-processing chain.
    var loadedModel: Qwen3ASRModel? { model }

    func load(progressHandler: ((Double, String) -> Void)? = nil) async throws {
        let modelId = AppConfig.shared.modelId
        log.info("Loading model: \(modelId)")

        model = try await Qwen3ASRModel.fromPretrained(
            modelId: modelId,
            progressHandler: progressHandler
        )

        log.info("Model loaded successfully")
    }

    func transcribe(audio: [Float], language: String?) async throws -> String {
        guard let model else {
            log.error("Model not loaded")
            return ""
        }

        guard !audio.isEmpty else {
            log.warning("Empty audio buffer")
            return ""
        }

        let duration = Double(audio.count) / 16000.0
        log.info("Transcribing \(String(format: "%.1f", duration))s of audio...")

        let startTime = CFAbsoluteTimeGetCurrent()

        let rawText = model.transcribe(
            audio: audio,
            sampleRate: 16000,
            language: language
        )

        let asrElapsed = CFAbsoluteTimeGetCurrent() - startTime
        log.info("Raw transcription (\(String(format: "%.2f", asrElapsed))s): \(rawText)")

        let finalText = DictationPostProcessor.apply(rawText)

        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
        let inCh = rawText.count
        let outCh = finalText.count
        let asrMs = Int(asrElapsed * 1000)
        let totalMs = Int(totalElapsed * 1000)

        log.info("timings asr=\(asrMs, privacy: .public)ms total=\(totalMs, privacy: .public)ms in=\(inCh, privacy: .public)ch out=\(outCh, privacy: .public)ch")

        return finalText
    }

    func unload() {
        model = nil
        log.info("Model unloaded")
    }
}
