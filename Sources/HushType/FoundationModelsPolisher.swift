import Foundation
import FoundationModels
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "fm-polisher")

@available(macOS 26.0, *)
@MainActor
enum FoundationModelsPolisher {
    enum ValidationResult {
        case ok
        case unavailable(reason: String)
    }

    private static var prewarmedPromptFingerprint: Int?

    static func availabilityReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return String(describing: reason)
        @unknown default:
            return "Unknown availability state"
        }
    }

    static func validate() async -> ValidationResult {
        if let reason = availabilityReason() {
            log.info("Validation: framework unavailable — \(reason, privacy: .public)")
            return .unavailable(reason: reason)
        }

        do {
            let session = LanguageModelSession(instructions: PolishPrompt.activePrompt())
            let options = GenerationOptions(temperature: 0.0)
            _ = try await session.respond(
                to: "Input: <selection>This sentence is correct.</selection>\nOutput:",
                options: options
            )
            log.info("Validation: round-trip succeeded")
            return .ok
        } catch {
            let reason = error.localizedDescription
            log.error("Validation: round-trip failed — \(reason, privacy: .public)")
            return .unavailable(reason: reason)
        }
    }

    static func warmup() {
        let prompt = PolishPrompt.activePrompt()
        let session = LanguageModelSession(instructions: prompt)
        session.prewarm()
        prewarmedPromptFingerprint = prompt.hashValue
        log.info("Warmup complete")
    }

    static func releaseSession() {
        prewarmedPromptFingerprint = nil
        log.info("Text Polish warmup state released")
    }

    static func polish(_ text: String, mixRetry: Bool = false) async -> Result<String, Error> {
        let prompt = PolishPrompt.activePrompt()
        let fingerprint = prompt.hashValue
        let session = LanguageModelSession(instructions: prompt)
        let options = GenerationOptions(temperature: 0.0)
        let reminder = mixRetry ? PolishPrompt.mixRetryReminder : ""
        let userPrompt = "Input: <selection>\(text)</selection>\(reminder)\nOutput:"

        do {
            let response = try await session.respond(to: userPrompt, options: options)
            let wasPrewarmed = prewarmedPromptFingerprint == fingerprint
            log.debug("Polish response fingerprint=\(fingerprint, privacy: .public) prewarmed=\(wasPrewarmed, privacy: .public) transcript_entries=\(response.transcriptEntries.count, privacy: .public)")
            return .success(sanitize(response.content, input: text))
        } catch {
            log.error("Polish failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    private static func stripPrefix(_ raw: String) -> String {
        let leadingTrimmed = raw.drop { $0.isWhitespace }
        for prefix in ["Output:", "output:", "輸出：", "输出："] {
            if leadingTrimmed.hasPrefix(prefix) {
                return String(leadingTrimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return raw
    }

    /// The model deterministically echoes the `<selection>` wrapper for some
    /// inputs (observed on trailing-apostrophe selections). Strip it unless the
    /// user's own selection was wrapped the same way.
    static func sanitize(_ raw: String, input: String) -> String {
        var value = stripPrefix(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<selection>"), value.hasSuffix("</selection>"),
           !(trimmedInput.hasPrefix("<selection>") && trimmedInput.hasSuffix("</selection>")) {
            value = String(value.dropFirst("<selection>".count).dropLast("</selection>".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
}
