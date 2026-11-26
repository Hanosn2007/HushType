import Foundation

public struct TimedText: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
}

public struct RecognitionEvent: Codable, Sendable {
    public let elapsed: Double
    public let start: Double
    public let end: Double
    public let text: String
    public let isFinal: Bool
    public let spans: [TimedText]?
    public init(elapsed: Double, start: Double, end: Double, text: String, isFinal: Bool, spans: [TimedText]? = nil) {
        self.elapsed = elapsed; self.start = start; self.end = end
        self.text = text; self.isFinal = isFinal
        self.spans = spans
    }
}

/// Only overlapping volatile ranges are replaced. Final text is never appended twice.
public struct Transcript: Sendable {
    public private(set) var segments: [RecognitionEvent] = []
    public init() {}
    public mutating func apply(_ event: RecognitionEvent) {
        segments.removeAll { old in
            if old.isFinal {
                // A zero-duration finalized punctuation mark may share the next phrase's start.
                // Only deduplicate an identical finalized range; preserve neighboring punctuation.
                return event.isFinal && abs(old.start - event.start) < 0.0001 && abs(old.end - event.end) < 0.0001
            }
            return (old.start < event.end && event.start < old.end) || abs(old.start - event.start) < 0.0001
        }
        segments.append(event)
        segments.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }
    public var finalText: String {
        segments.filter(\.isFinal).reduce("") { text, event in
            text + (text.isEmpty || event.start == event.end ? "" : "\n") + event.text
        }
    }
    public var draftText: String { segments.filter { !$0.isFinal }.map(\.text).joined(separator: "\n") }
}
