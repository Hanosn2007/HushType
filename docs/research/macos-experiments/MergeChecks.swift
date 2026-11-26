import Foundation

@main
enum MergeChecks {
    static func main() {
        var d = TwoStageTranscript()
        d.native.apply(RecognitionEvent(elapsed: 1, start: 0, end: 4, text: "旧甲新乙", isFinal: false, spans: [TimedText(start: 0, end: 2, text: "旧甲"), TimedText(start: 2, end: 4, text: "新乙")]))
        var s = StrongSegment(startSample: 0, endSample: 32000, reason: "test", requestedAt: 0)
        s.text = "强甲"; s.status = "replaced"; d.update(s)
        precondition(d.text.contains("强甲") && d.text.contains("新乙") && !d.text.contains("旧甲"))
        d.native.apply(RecognitionEvent(elapsed: 2, start: 0, end: 4, text: "迟甲新丙", isFinal: true, spans: [TimedText(start: 0, end: 2, text: "迟甲"), TimedText(start: 2, end: 4, text: "新丙")]))
        precondition(d.text.contains("强甲") && !d.text.contains("迟甲") && d.text.contains("新丙"))
        s.status = "failed-retain-native"; d.update(s)
        precondition(d.text.contains("迟甲"), "Failure must retain native text")
        s.status = "replaced"; d.update(s)
        d.native = Transcript()
        d.native.apply(RecognitionEvent(elapsed: 3, start: 0, end: 6, text: "整句和新的尾句", isFinal: false, spans: [TimedText(start: 0, end: 6, text: "整句和新的尾句")]))
        precondition(d.unalignedText == "整句和新的尾句" && d.text == "强甲\n", "Coarse timing must not discard an unknown suffix")
        var boundary = TwoStageTranscript()
        boundary.native.apply(RecognitionEvent(elapsed: 1, start: 1.4, end: 4.9, text: "专业", isFinal: true, spans: [TimedText(start: 1.4, end: 1.73, text: "专业")]))
        var replacement = StrongSegment(startSample: 25088, endSample: 75264, reason: "speechEnded", requestedAt: 0)
        replacement.text = "专业课程"; replacement.status = "replaced"; boundary.update(replacement)
        precondition(boundary.text == "专业课程\n", "3ms VAD/Apple midpoint mismatch must not duplicate the boundary word")
        var terminal = TwoStageTranscript()
        var phrase = StrongSegment(startSample: 236032, endSample: 297984, reason: "speechEnded", requestedAt: 0)
        phrase.text = "这是我们的。"; phrase.status = "replaced"; terminal.update(phrase)
        func terminalEvent(_ word: String, start: Double = 18.629625, end: Double = 18.689625, eventStart: Double = 14.759625, final: Bool = true) -> RecognitionEvent {
            RecognitionEvent(elapsed: 19, start: eventStart, end: max(18.759625, end), text: "我们的" + word, isFinal: final, spans: [TimedText(start: 18.2, end: 18.6, text: "我们"), TimedText(start: start, end: end, text: word)])
        }
        terminal.native.apply(terminalEvent("的"))
        precondition(terminal.text == "这是我们的。\n", "Exact duplicated terminal 的 must disappear")
        for e in [terminalEvent("吗"), terminalEvent("的", start: 18.8, end: 18.9), terminalEvent("的", final: false)] {
            terminal.native = Transcript(); terminal.native.apply(e)
            precondition(terminal.pieces.contains { !$0.strong }, "Do not erase unmatched, distant, or still revising native text")
        }
        terminal.native = Transcript()
        terminal.native.apply(RecognitionEvent(elapsed: 20, start: 18.629625, end: 19, text: "的", isFinal: true, spans: [TimedText(start: 18.629625, end: 18.689625, text: "的")]))
        precondition(terminal.pieces.contains { !$0.strong }, "An independent next phrase must not be absorbed")
        print("Merge checks passed")
    }
}
