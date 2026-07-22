import SwiftUI

/// Builds a Word-style "track changes" rendering of a polish result:
/// one unified text where deleted runs are red strikethrough and inserted
/// runs are green underline.
enum PolishDiff {
    /// Beyond this many tokens per side the O(n·m) LCS table gets expensive;
    /// polish selections are far below it in practice, and the card falls
    /// back to plain polished text when exceeded. CJK tokenizes per
    /// character (no word boundaries), so the cap must fit a long 繁中
    /// selection — 2500 chars — not just 2500 English words.
    private static let tokenCap = 2500

    enum Segment: Equatable {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    /// Returns nil when either side exceeds the token cap.
    static func segments(original: String, polished: String) -> [Segment]? {
        let a = tokenize(original)
        let b = tokenize(polished)
        guard a.count <= tokenCap && b.count <= tokenCap else { return nil }

        // Longest-common-subsequence table (flat Int32 keeps the worst case
        // ~25 MB transient instead of 4× that), then backtrack into ops.
        let width = b.count + 1
        var table = [Int32](repeating: 0, count: (a.count + 1) * width)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i * width + j] = a[i] == b[j]
                        ? table[(i + 1) * width + j + 1] + 1
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
        }

        var raw: [Segment] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                raw.append(.equal(a[i])); i += 1; j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                raw.append(.delete(a[i])); i += 1
            } else {
                raw.append(.insert(b[j])); j += 1
            }
        }
        while i < a.count { raw.append(.delete(a[i])); i += 1 }
        while j < b.count { raw.append(.insert(b[j])); j += 1 }

        return merged(raw)
    }

    static func attributed(original: String, polished: String) -> AttributedString? {
        guard let segments = segments(original: original, polished: polished) else {
            return nil
        }
        var out = AttributedString()
        for segment in segments {
            switch segment {
            case .equal(let text):
                out += AttributedString(text)
            case .delete(let text):
                var run = AttributedString(text)
                run.foregroundColor = Color(nsColor: .systemRed)
                run.strikethroughStyle = .single
                // The tint keeps whitespace-only deletions visible — a bare
                // struck-through space otherwise reads as a stray red dash.
                run.backgroundColor = Color(nsColor: .systemRed).opacity(0.13)
                out += run
            case .insert(let text):
                var run = AttributedString(text)
                run.foregroundColor = Color(nsColor: .systemGreen)
                run.underlineStyle = .single
                run.backgroundColor = Color(nsColor: .systemGreen).opacity(0.13)
                out += run
            }
        }
        return out
    }

    /// Word-level tokens for alphabetic scripts, character-level for CJK
    /// (no word boundaries to align on), single characters for whitespace
    /// and punctuation so punctuation-only fixes surface precisely.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for character in text {
            if isWordCharacter(character) {
                word.append(character)
            } else {
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(character))
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if ScriptDetector.isHan(scalar.value) { return false }
        // Kana + Hangul diff per character like Han.
        if (0x3040...0x30FF).contains(scalar.value) { return false }
        if (0xAC00...0xD7A3).contains(scalar.value) { return false }
        if character.isLetter || character.isNumber { return true }
        return character == "'" || character == "\u{2019}"
    }

    /// Merge adjacent same-type segments, and order each change cluster as
    /// deletions-then-insertions so replacements read old-strike → new-green.
    private static func merged(_ raw: [Segment]) -> [Segment] {
        var out: [Segment] = []
        var deletions = ""
        var insertions = ""

        func flush() {
            if !deletions.isEmpty { out.append(.delete(deletions)); deletions = "" }
            if !insertions.isEmpty { out.append(.insert(insertions)); insertions = "" }
        }

        for segment in raw {
            switch segment {
            case .equal(let text):
                flush()
                if case .equal(let previous) = out.last {
                    out[out.count - 1] = .equal(previous + text)
                } else {
                    out.append(.equal(text))
                }
            case .delete(let text):
                deletions += text
            case .insert(let text):
                insertions += text
            }
        }
        flush()
        return out
    }
}
