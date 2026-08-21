import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "transcription")

enum DictationPostProcessor {
    static func apply(_ raw: String) -> String {
        let rawText = raw

        // Classify once on the raw ASR text. Gates the Chinese-only stages
        // (OpenCC, ITN, punctuation strip) so they never touch JP/KO/EN.
        let script = ScriptDetector.detect(rawText)

        // Apply Traditional Chinese conversion
        let convertedText = ChineseConverter.convert(rawText)
        if convertedText != rawText {
            log.info("After conversion: \(convertedText)")
        }

        // Apply number conversion (ITN) if enabled. Deterministic regex-based
        // pass that converts Chinese numerals to Arabic digits.
        let itnResult: NumberNormalizer.Result
        if script == .zh && AppConfig.shared.numberConversionEnabled {
            itnResult = NumberNormalizer.normalize(convertedText)
            if itnResult.applied {
                log.info("After ITN: \(itnResult.text, privacy: .public) [\(itnResult.note, privacy: .public)]")
            } else if itnResult.note != "no-op" {
                log.debug("ITN skipped: \(itnResult.note, privacy: .public)")
            }
        } else {
            itnResult = NumberNormalizer.Result(text: convertedText, applied: false, note: "disabled")
        }

        // Apply user customized dictionary as the final post-processing step.
        // No-op if the dictionary file doesn't exist or is empty.
        let dictText = DictionaryReplacer.apply(itnResult.text)
        if dictText != itnResult.text {
            log.info("After dictionary: \(dictText)")
        }

        // Final step: strip the model's over-aggressive Chinese inline
        // punctuation. Chinese only, and last in the chain so nothing downstream
        // can re-introduce it.
        let finalText: String
        if script == .zh {
            finalText = PunctuationNormalizer.apply(dictText, mode: AppConfig.shared.punctuationMode)
            if finalText != dictText {
                log.info("After punctuation: \(finalText)")
            }
        } else {
            finalText = dictText
        }

        return finalText
    }
}
