import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "text-polisher")

enum PolishResult {
    case success(polished: String, changed: Bool)
    case failure(PolishError)
}

enum PolishError: LocalizedError {
    case disabled
    case unavailable(String)
    case emptySelection
    case codeDetected
    case generationFailed(String)
    case emptyOutput
    case lengthGuard
    case scriptGuard
    case mixGuard
    case refusalGuard

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Text Polish is turned off."
        case .unavailable(let reason):
            return "Text Polish requires macOS 26 + Apple Intelligence.\n\n\(reason)"
        case .emptySelection:
            return "No text was selected."
        case .codeDetected:
            return "Selection looks like code — not polished."
        case .generationFailed(let reason):
            return reason
        case .emptyOutput:
            return "Apple Intelligence returned an empty result."
        case .lengthGuard:
            return "The result changed the selection length too much. The original text was left untouched."
        case .scriptGuard:
            return "The result changed the selection's dominant writing system. The original text was left untouched."
        case .mixGuard:
            return "The result dropped one of the selection's languages. The original text was left untouched."
        case .refusalGuard:
            return "Apple Intelligence returned a refusal instead of proofreading the selection."
        }
    }
}

enum TextPolisher {
    enum ValidationResult {
        case ok
        case unavailable(reason: String)
    }

    /// Tap handling reads this stored value only. It is refreshed at launch,
    /// app activation, and after toggle validation—never on a key event.
    private(set) static var isAvailableCached = false
    private(set) static var unavailableReasonCached = "Apple Intelligence is unavailable."

    @MainActor
    static func refreshAvailabilityCache() {
        guard #available(macOS 26.0, *) else {
            isAvailableCached = false
            unavailableReasonCached = "This Mac is running an earlier version of macOS."
            return
        }

        if let reason = FoundationModelsPolisher.availabilityReason() {
            isAvailableCached = false
            unavailableReasonCached = reason
        } else {
            isAvailableCached = true
            unavailableReasonCached = ""
        }
        log.info("Availability cache refreshed: \(self.isAvailableCached, privacy: .public)")
    }

    @MainActor
    static func validate() async -> ValidationResult {
        guard #available(macOS 26.0, *) else {
            refreshAvailabilityCache()
            return .unavailable(reason: unavailableReasonCached)
        }

        let result = await FoundationModelsPolisher.validate()
        switch result {
        case .ok:
            isAvailableCached = true
            unavailableReasonCached = ""
            return .ok
        case .unavailable(let reason):
            isAvailableCached = false
            unavailableReasonCached = reason
            return .unavailable(reason: reason)
        }
    }

    static func polish(_ text: String) async -> PolishResult {
        guard AppConfig.shared.textPolishEnabled else {
            return .failure(.disabled)
        }

        let trimmedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return .failure(.emptySelection)
        }
        guard !looksLikeCode(text) else {
            return .failure(.codeDetected)
        }
        guard isAvailableCached else {
            return .failure(.unavailable(unavailableReasonCached))
        }
        guard #available(macOS 26.0, *) else {
            return .failure(.unavailable("This Mac is running an earlier version of macOS."))
        }

        // Race the FM call against a wall-clock deadline: a hung generation
        // would otherwise wedge state at .polishing and the idle guards on all
        // three tap sites would drop every hotkey press until relaunch. The
        // abandoned task ends on its own; only the state machine is protected.
        let modelResult = await withDeadline(seconds: 30) {
            if #available(macOS 26.0, *) {
                return await FoundationModelsPolisher.polish(text)
            }
            return .failure(PolishError.unavailable("This Mac is running an earlier version of macOS."))
        }
        guard let modelResult else {
            return .failure(.generationFailed("Apple Intelligence timed out after 30 seconds."))
        }
        switch modelResult {
        case .failure(let error):
            return .failure(.generationFailed(error.localizedDescription))
        case .success(let polished):
            return validateOutput(polished, input: text)
        }
    }

    private static func withDeadline<T: Sendable>(
        seconds: UInt64,
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func validateOutput(_ output: String, input: String) -> PolishResult {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return .failure(.emptyOutput) }

        let inputLength = trimmedInput.count
        let outputLength = trimmedOutput.count
        if inputLength >= 20 {
            let ratio = Double(outputLength) / Double(inputLength)
            guard (0.5...2.0).contains(ratio) else { return .failure(.lengthGuard) }
        } else {
            guard abs(outputLength - inputLength) <= 10 else { return .failure(.lengthGuard) }
        }

        guard dominantScriptBucket(trimmedInput) == dominantScriptBucket(trimmedOutput) else {
            return .failure(.scriptGuard)
        }
        // Wholesale translation of a mixed-language selection can pass the
        // dominant-bucket check when the minority script is small, so a real
        // mix must keep at least one character of each side.
        let inputHan = hanCount(trimmedInput)
        let inputLatin = latinLetterCount(trimmedInput)
        if inputHan >= 2 && inputLatin >= 2 {
            guard hanCount(trimmedOutput) >= 1 && latinLetterCount(trimmedOutput) >= 1 else {
                return .failure(.mixGuard)
            }
        }
        guard !isNovelRefusal(output: trimmedOutput, input: trimmedInput) else {
            return .failure(.refusalGuard)
        }

        // Return the trimmed text so what gets pasted matches what `changed`
        // compared — FM occasionally pads leading/trailing whitespace.
        return .success(polished: trimmedOutput, changed: trimmedOutput != trimmedInput)
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        if text.contains("```") || text.contains("~~~") { return true }

        let tokenPattern = #"\b(?:[a-z]+[A-Z][A-Za-z0-9]*|[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+)\b"#
        if let regex = try? NSRegularExpression(pattern: tokenPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.numberOfMatches(in: text, range: range) >= 3 { return true }
        }

        // Bare parentheses/angle brackets appear constantly in ordinary prose
        // ("use (A) then (B)"), so density alone false-positives; require at
        // least one statement-shaped symbol before the density test can trip.
        let statementSymbols = text.filter { "{};".contains($0) }.count
        let symbols = text.filter { "{};()=><".contains($0) }.count
        return statementSymbols >= 1 && symbols >= 4
            && Double(symbols) / Double(max(text.count, 1)) >= 0.12
    }

    private static func hanCount(_ text: String) -> Int {
        text.unicodeScalars.lazy.filter { ScriptDetector.isHan($0.value) }.count
    }

    private static func latinLetterCount(_ text: String) -> Int {
        text.unicodeScalars.lazy.filter {
            (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
        }.count
    }

    private enum ScriptBucket: CaseIterable {
        case han
        case kana
        case hangul
        case other
    }

    private static func dominantScriptBucket(_ text: String) -> ScriptBucket {
        var counts = Dictionary(uniqueKeysWithValues: ScriptBucket.allCases.map { ($0, 0) })
        for scalar in text.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            let value = scalar.value
            let bucket: ScriptBucket
            if ScriptDetector.isHan(value) {
                bucket = .han
            } else if (0x3040...0x30FA).contains(value)
                        || (0x30FC...0x30FF).contains(value)
                        || (0xFF66...0xFF9F).contains(value) {
                bucket = .kana
            } else if (0xAC00...0xD7A3).contains(value) {
                bucket = .hangul
            } else {
                bucket = .other
            }
            counts[bucket, default: 0] += 1
        }
        return ScriptBucket.allCases.max { counts[$0, default: 0] < counts[$1, default: 0] } ?? .other
    }

    private static func isNovelRefusal(output: String, input: String) -> Bool {
        let wordCount = output.split { $0.isWhitespace }.count
        guard wordCount < 15 else { return false }

        let templates = [
            "I can't help", "I cannot", "I'm sorry but I can't", "Sorry I can't",
            "抱歉，我", "很抱歉", "對不起，我無法",
        ]
        let normalizedOutput = normalizedPrefix(output)
        let normalizedInput = normalizedPrefix(input)
        guard let matched = templates.first(where: { normalizedOutput.hasPrefix(normalizedPrefix($0)) }) else {
            return false
        }
        return !normalizedInput.hasPrefix(normalizedPrefix(matched))
    }

    private static func normalizedPrefix(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
