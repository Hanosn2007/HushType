import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "dictionary")

/// User-editable customized dictionary applied as the final post-processing
/// step in the transcription pipeline. The on-disk format is one `source ->
/// target` rule per line; comments and unknown lines are ignored by runtime
/// replacement and preserved by the native editor.
///
/// Matching semantics:
/// - ASCII `->` is preferred over Unicode `→` when a legacy line has both.
/// - Sources match case-insensitively and targets are emitted literally.
/// - The longest source wins. Equal-length sources retain their file order.
/// - A single left-to-right pass prevents replacement chains.
/// - An empty target removes the matched source.
enum DictionaryReplacer {

    private struct Entry {
        let source: String
        let target: String
        let fileOrder: Int
    }

    private static let lock = NSLock()

    /// Cached, already ordered entries from the current on-disk file.
    private static var entries: [Entry] = []
    private static var lastModified: Date?
    private static var fileExisted = false

    // MARK: - Public API

    /// Reload entries from disk if the file changed. This stays cheap enough
    /// for the transcription path: it starts with a single `stat` lookup.
    static func reloadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        let url = AppConfig.dictionaryFileURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            if fileExisted {
                entries = []
                lastModified = nil
                fileExisted = false
                log.info("Dictionary file removed — entries cleared")
            }
            return
        }

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let modificationDate = attributes?[.modificationDate] as? Date
        guard !fileExisted || modificationDate != lastModified else { return }
        load(from: url, modificationDate: modificationDate)
    }

    /// Applies the currently saved dictionary. Safe from any thread.
    static func apply(_ text: String) -> String {
        reloadIfNeeded()

        lock.lock()
        let currentEntries = entries
        lock.unlock()

        let output = apply(text, entries: currentEntries)
        if output != text {
            log.debug("Dictionary applied: \(text) → \(output)")
        }
        return output
    }

    /// Applies an in-memory rule set with exactly the same parser-independent
    /// matching path as saved transcription. Used by the editor preview so a
    /// draft never needs to touch the user's real dictionary file.
    static func apply(_ text: String, rules: [DictionaryRule]) -> String {
        apply(text, entries: orderedEntries(from: rules))
    }

    /// Number of valid, currently saved entries.
    static var entryCount: Int {
        reloadIfNeeded()
        lock.lock()
        let count = entries.count
        lock.unlock()
        return count
    }

    static var fileExists: Bool {
        FileManager.default.fileExists(atPath: AppConfig.dictionaryFileURL.path)
    }

    /// Allows a successful native-editor save to be visible to the next
    /// dictation even on a filesystem with coarse modification timestamps.
    static func invalidateCache() {
        lock.lock()
        entries = []
        lastModified = nil
        fileExisted = false
        lock.unlock()
    }

    /// Create the historical starter file when it is explicitly requested by
    /// a legacy call site. The native settings editor itself starts with an
    /// empty draft and only creates a file after the user saves.
    @discardableResult
    static func createTemplateIfMissing() -> Bool {
        let url = AppConfig.dictionaryFileURL
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: url.path) {
            return false
        }

        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.error("Failed to create dictionary directory: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let template = L10n.string(
            "template.dictionary.starter_document",
            table: "Templates",
            fallback: "# HushType Customized Dictionary\n# =============================\n#\n# One rule per line, in this format:\n#\n#     what you say  ->  what gets typed\n#\n# Use this to fix recurring transcription errors — proper nouns the\n# speech model always mishears, acronyms that come out spelled out,\n# technical terms with non-standard phonetics, etc.\n#\n# Rules:\n#   • Lines starting with #  are comments (ignored)\n#   • Blank lines are ignored\n#   • Source is CASE-INSENSITIVE: \"cloud code\", \"Cloud Code\", and\n#     \"CLOUD CODE\" all match the same rule. The target is inserted\n#     literally, so the output always matches what you wrote.\n#   • Plain string match only — no regex, no wildcards\n#   • Longest match wins when rules overlap\n#   • Changes take effect on the next transcription (no restart)\n#\n# ---------------------------------------------------------------\n# Examples (delete the # at the start of a line to activate it)\n# ---------------------------------------------------------------\n\n# Proper nouns the model mis-transcribes:\n# 拍粉       -> Python\n# Cloud code -> Claude Code\n# Enfropic   -> Anthropic\n\n# Acronym normalization:\n# U I U X    -> UI/UX\n\n# Technical jargon:\n# J.S.O.N    -> JSON\n\n# ---------------------------------------------------------------\n# Your entries below:\n# ---------------------------------------------------------------\n"
        )

        do {
            try template.write(to: url, atomically: true, encoding: .utf8)
            invalidateCache()
            log.info("Created dictionary template at \(url.path, privacy: .public)")
            return true
        } catch {
            log.error("Failed to write dictionary template: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Private

    private static func load(from url: URL, modificationDate: Date?) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            log.warning("Failed to read dictionary file at \(url.path, privacy: .public)")
            entries = []
            lastModified = nil
            fileExisted = false
            return
        }

        entries = orderedEntries(from: DictionaryDocument(contents: contents).rules)
        lastModified = modificationDate
        fileExisted = true
        log.info("Loaded \(entries.count) dictionary entries")
    }

    private static func orderedEntries(from rules: [DictionaryRule]) -> [Entry] {
        rules.enumerated()
            .compactMap { offset, rule in
                guard !rule.source.isEmpty else { return nil }
                return Entry(source: rule.source, target: rule.target, fileOrder: offset)
            }
            .sorted { left, right in
                if left.source.count != right.source.count {
                    return left.source.count > right.source.count
                }
                return left.fileOrder < right.fileOrder
            }
    }

    private static func apply(_ text: String, entries: [Entry]) -> String {
        guard !entries.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.count)

        var index = text.startIndex
        let end = text.endIndex
        while index < end {
            var didMatch = false

            for entry in entries {
                guard let sourceEnd = text.index(
                    index,
                    offsetBy: entry.source.count,
                    limitedBy: end
                ) else {
                    continue
                }

                let candidate = text[index..<sourceEnd]
                guard candidate.caseInsensitiveCompare(entry.source) == .orderedSame else {
                    continue
                }

                result.append(entry.target)
                index = sourceEnd
                didMatch = true
                break
            }

            if !didMatch {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }
}
