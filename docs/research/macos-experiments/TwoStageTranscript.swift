import Foundation

struct StrongSegment: Codable, Identifiable, Sendable {
    var id: Int { startSample }
    let startSample: Int
    let endSample: Int
    let reason: String
    var text = ""
    var status = "processing"
    let requestedAt: Double
    var completedAt: Double?
    var start: Double { Double(startSample) / 16000 }
    var end: Double { Double(endSample) / 16000 }
}
struct DisplayPiece: Identifiable {
    let id: String
    let start: Double
    let end: Double
    let text: String
    let strong: Bool
}

/// Greatest audio overlap assigns boundary-crossing Apple words to one owned range.
/// Late Apple revisions can update uncovered audio, never overwrite Qwen ranges.
struct TwoStageTranscript {
    var native = Transcript()
    var strong: [StrongSegment] = []
    mutating func update(_ segment: StrongSegment) {
        if let i = strong.firstIndex(where: { $0.id == segment.id }) { strong[i] = segment }
        else { strong.append(segment); strong.sort { $0.startSample < $1.startSample } }
    }
    private func isUnaligned(_ event: RecognitionEvent) -> Bool {
        let coarse = event.spans?.isEmpty != false || (!event.isFinal && (event.spans?.count ?? 0) <= 1)
        let completed = strong.filter { $0.status == "replaced" }
        return coarse && completed.contains { event.start < $0.end && event.end > $0.start }
            && !completed.contains { event.start >= $0.start && event.end <= $0.end }
    }
    var unalignedText: String { native.segments.filter { isUnaligned($0) }.map(\.text).joined(separator: "\n") }
    private func isTextSeparator(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).contains($0)
        }
    }
    /// Apple and VAD can disagree by a few milliseconds at a finalized phrase end.
    /// Absorb only an exact duplicated terminal word, never arbitrary gap text.
    private func isDuplicatedTerminalWord(_ span: TimedText, index: Int, spans: [TimedText], event: RecognitionEvent) -> Bool {
        guard event.isFinal, !isTextSeparator(span.text),
              spans.dropFirst(index + 1).allSatisfy({ isTextSeparator($0.text) }) else { return false }
        let owner = strong.map { ($0, max(0, min(event.end, $0.end) - max(event.start, $0.start))) }
            .filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
        guard let owner, owner.status == "replaced",
              span.start >= owner.end, span.end >= span.start,
              span.end - owner.end <= 0.12 else { return false }
        let trim = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        let word = span.text.trimmingCharacters(in: trim)
        return !word.isEmpty && owner.text.trimmingCharacters(in: trim).hasSuffix(word)
    }
    var pieces: [DisplayPiece] {
        let completed = strong.filter { $0.status == "replaced" }
        var output = completed.map { DisplayPiece(id: "strong-\($0.id)", start: $0.start, end: $0.end, text: $0.text, strong: true) }
        for (i, event) in native.segments.enumerated() {
            if isUnaligned(event) { continue } // Keep visible separately; never invent word timing.
            let hasSpans = event.spans?.isEmpty == false
            let spans = hasSpans ? event.spans! : [TimedText(start: event.start, end: event.end, text: event.text)]
            var priorWordCovered: Bool?
            for (j, span) in spans.enumerated() {
                let midpoint = (span.start + span.end) / 2
                let isPunctuation = isTextSeparator(span.text)
                let owner = strong.map { ($0, max(0, min(span.end, $0.end) - max(span.start, $0.start))) }
                    .filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
                let covered: Bool
                if isPunctuation, let priorWordCovered { covered = priorWordCovered }
                else if hasSpans { covered = owner?.status == "replaced" || (span.start == span.end && completed.contains { midpoint >= $0.start && midpoint < $0.end }) || (owner == nil && isDuplicatedTerminalWord(span, index: j, spans: spans, event: event)) }
                else { covered = completed.contains { span.start >= $0.start && span.end <= $0.end } }
                if !covered { output.append(DisplayPiece(id: "apple-\(i)-\(j)", start: span.start, end: span.end, text: span.text, strong: false)) }
                if !isPunctuation { priorWordCovered = covered }
            }
        }
        return output.sorted { $0.start < $1.start }
    }
    var text: String { pieces.map { $0.text + ($0.strong ? "\n" : "") }.joined() }
}
