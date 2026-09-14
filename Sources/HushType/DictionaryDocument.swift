import Foundation

/// One editable dictionary rule. An empty target deliberately removes a
/// matching source from the final transcription.
struct DictionaryRule: Identifiable, Equatable, Sendable {
    let id: UUID
    var source: String
    var target: String

    init(id: UUID = UUID(), source: String, target: String) {
        self.id = id
        self.source = source
        self.target = target
    }
}

/// Lossless representation of the parts of `dictionary.txt` that the native
/// editor does not change. Each line owns its original terminator, so mixed
/// LF/CRLF files continue to parse and round-trip one line at a time.
struct DictionaryDocument {
    private enum Line {
        case raw(String)
        case rule(raw: String, original: DictionaryRule)
    }

    private struct LineRecord {
        var line: Line
        var terminator: String?
    }

    private let records: [LineRecord]

    static let empty = DictionaryDocument(records: [])

    init(contents: String) {
        self.init(records: Self.records(from: contents))
    }

    var rules: [DictionaryRule] {
        records.compactMap {
            guard case .rule(_, let rule) = $0.line else { return nil }
            return rule
        }
    }

    /// Lines which are intentionally left untouched by the editor.
    var preservedLineCount: Int {
        records.reduce(into: 0) { count, record in
            if case .raw = record.line { count += 1 }
        }
    }

    /// Recreates the document with edits applied. Deleted original-rule rows
    /// become empty lines so neighboring comments and their placement survive.
    func serialized(with currentRules: [DictionaryRule]) -> String {
        var rulesByID: [UUID: DictionaryRule] = [:]
        for rule in currentRules {
            rulesByID[rule.id] = rule
        }

        let originalRuleIDs = Set(rules.map(\.id))
        var rendered = records.map { record -> LineRecord in
            switch record.line {
            case .raw(let raw):
                return LineRecord(line: .raw(raw), terminator: record.terminator)
            case .rule(let raw, let original):
                let body: String
                if let current = rulesByID[original.id] {
                    body = current == original ? raw : Self.serializedLine(for: current)
                } else {
                    body = ""
                }
                return LineRecord(line: .raw(body), terminator: record.terminator)
            }
        }

        let addedRules = currentRules.filter { !originalRuleIDs.contains($0.id) }
        Self.append(addedRules, to: &rendered)

        return rendered.map { record in
            let body: String
            switch record.line {
            case .raw(let raw): body = raw
            case .rule: preconditionFailure("Rendered records cannot contain a rule")
            }
            return body + (record.terminator ?? "")
        }.joined()
    }

    private init(records: [LineRecord]) {
        self.records = records
    }

    private static func records(from contents: String) -> [LineRecord] {
        guard !contents.isEmpty else { return [] }

        let pieces = contents.components(separatedBy: "\n")
        var result: [LineRecord] = []
        for (index, piece) in pieces.enumerated() {
            let isLast = index == pieces.count - 1
            // `components` retains a final empty piece after a trailing LF;
            // that empty piece is not an additional line record.
            if isLast && piece.isEmpty && contents.hasSuffix("\n") {
                continue
            }

            let hasCarriageReturn = !isLast && piece.hasSuffix("\r")
            let raw = hasCarriageReturn ? String(piece.dropLast()) : piece
            result.append(LineRecord(
                line: line(from: raw),
                terminator: isLast ? nil : (hasCarriageReturn ? "\r\n" : "\n")
            ))
        }
        return result
    }

    private static func append(_ addedRules: [DictionaryRule], to records: inout [LineRecord]) {
        guard !addedRules.isEmpty else { return }

        let preferredTerminator = records.reversed().compactMap(\.terminator).first ?? "\n"
        let hadTrailingTerminator = records.last?.terminator != nil

        if !records.isEmpty, records[records.count - 1].terminator == nil {
            records[records.count - 1].terminator = preferredTerminator
        }

        for (index, rule) in addedRules.enumerated() {
            let isLast = index == addedRules.count - 1
            records.append(LineRecord(
                line: .raw(serializedLine(for: rule)),
                terminator: (hadTrailingTerminator || !isLast) ? preferredTerminator : nil
            ))
        }
    }

    private static func line(from raw: String) -> Line {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
            return .raw(raw)
        }

        // Keep the historical grammar: an ASCII arrow wins if a line happens
        // to contain both separators.
        let separatorRange = trimmed.range(of: "->") ?? trimmed.range(of: "→")
        guard let separatorRange else {
            return .raw(raw)
        }

        let source = String(trimmed[..<separatorRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = String(trimmed[separatorRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            return .raw(raw)
        }

        return .rule(
            raw: raw,
            original: DictionaryRule(source: source, target: target)
        )
    }

    private static func serializedLine(for rule: DictionaryRule) -> String {
        "\(rule.source) -> \(rule.target)"
    }
}
