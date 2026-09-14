import Combine
import Foundation
import SwiftUI

/// Presentation state for the native `dictionary.txt` editor. It deliberately
/// keeps a draft in memory until Save, both for a useful preview and so an
/// external text-editor change cannot be overwritten silently.
@MainActor
final class DictionaryEditorModel: ObservableObject {
    @Published var rules: [DictionaryRule] = [] {
        didSet {
            // Let a corrected edit clear a previous read/write error, while an
            // external-change warning remains until the user explicitly reloads.
            if !externalChangeDetected {
                errorMessage = nil
            }
        }
    }
    @Published var previewInput = ""
    @Published private(set) var errorMessage: String?

    private enum FileSnapshot: Equatable {
        case missing
        case data(Data)
    }

    private let fileURL: URL
    private var document = DictionaryDocument.empty
    private var savedRules: [DictionaryRule] = []
    private var loadedSnapshot: FileSnapshot = .missing
    private var didLoad = false
    private var externalChangeDetected = false

    init(fileURL: URL = AppConfig.dictionaryFileURL) {
        self.fileURL = fileURL
    }

    /// Uses the same single-pass replacement function as dictation, but with
    /// the unsaved in-memory rules.
    var previewOutput: String {
        DictionaryReplacer.apply(previewInput, rules: normalizedRules)
    }

    var hasChanges: Bool {
        rules != savedRules
    }

    /// A duplicate source is an advisory: keeping both rows preserves legacy
    /// file order semantics, so it must not prevent a save.
    var validationMessage: String? {
        serializationValidationMessage ?? duplicateSourceMessage
    }

    var canSave: Bool {
        hasChanges && serializationValidationMessage == nil && !externalChangeDetected
    }

    var preservedLineCount: Int {
        document.preservedLineCount
    }

    /// Initial page activation reads the file once. It never discards a draft
    /// that is already in memory.
    func loadIfNeeded() {
        guard !didLoad else { return }
        reload()
    }

    /// Call when the settings page reappears. A clean editor follows a direct
    /// text-editor change; a dirty editor keeps its draft and asks for Reload.
    func refreshIfUnchanged() {
        guard didLoad else {
            loadIfNeeded()
            return
        }

        do {
            let currentSnapshot = try readSnapshot()
            guard currentSnapshot != loadedSnapshot else { return }

            guard !hasChanges else {
                markExternalChange()
                return
            }
            try adopt(currentSnapshot)
        } catch {
            errorMessage = readErrorMessage(error)
        }
    }

    /// Explicit reload is the only operation allowed to replace a draft.
    func reload() {
        do {
            try adopt(readSnapshot())
        } catch {
            errorMessage = readErrorMessage(error)
        }
    }

    /// Saves valid edits atomically. Before writing, compare the full file
    /// contents captured at load time so external edits cannot be overwritten.
    func save() {
        guard hasChanges else { return }

        if let serializationValidationMessage {
            errorMessage = serializationValidationMessage
            return
        }
        guard !externalChangeDetected else {
            markExternalChange()
            return
        }

        do {
            guard try readSnapshot() == loadedSnapshot else {
                markExternalChange()
                return
            }

            let rulesToSave = normalizedRules
            let contents = document.serialized(with: rulesToSave)
            guard let data = contents.data(using: .utf8) else {
                throw DictionaryEditorError.cannotEncode
            }

            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)

            loadedSnapshot = .data(data)
            rules = rulesToSave
            savedRules = rulesToSave
            externalChangeDetected = false
            errorMessage = nil
            DictionaryReplacer.invalidateCache()
        } catch {
            errorMessage = saveErrorMessage(error)
        }
    }

    @discardableResult
    func addRule() -> UUID {
        let rule = DictionaryRule(source: "", target: "")
        rules.append(rule)
        return rule.id
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    /// Text fields can finish reading or committing after their row is removed.
    /// Resolve the stable ID for every access instead of retaining an array
    /// index; a late commit must neither recreate a rule nor edit its neighbor.
    func textBinding(
        for rule: DictionaryRule,
        field: WritableKeyPath<DictionaryRule, String>
    ) -> Binding<String> {
        Binding(
            get: {
                self.rules.first(where: { $0.id == rule.id })?[keyPath: field]
                    ?? rule[keyPath: field]
            },
            set: { value in
                guard let index = self.rules.firstIndex(where: { $0.id == rule.id }) else { return }
                self.rules[index][keyPath: field] = value
            }
        )
    }

    private var serializationValidationMessage: String? {
        for rule in rules {
            if rule.source.rangeOfCharacter(from: .newlines) != nil ||
                rule.target.rangeOfCharacter(from: .newlines) != nil {
                return L10n.string(
                    "settings.dictionary.editor.validation.newline",
                    fallback: "A dictionary rule cannot contain a line break."
                )
            }

            let normalized = normalized(rule)
            if normalized.source.isEmpty {
                return L10n.string(
                    "settings.dictionary.editor.validation.empty_source",
                    fallback: "Recognized text cannot be empty."
                )
            }

            // Validate the actual legacy grammar rather than maintaining a
            // brittle denylist. For example, `→` in a source is valid when the
            // serialized ASCII separator still unambiguously wins.
            let roundTrip = DictionaryDocument(contents: "\(normalized.source) -> \(normalized.target)").rules
            guard roundTrip.count == 1,
                  roundTrip[0].source == normalized.source,
                  roundTrip[0].target == normalized.target else {
                return L10n.string(
                    "settings.dictionary.editor.validation.unserializable_source",
                    fallback: "Recognized text cannot start with # or contain ->."
                )
            }
        }
        return nil
    }

    private var duplicateSourceMessage: String? {
        for (index, rule) in normalizedRules.enumerated() where !rule.source.isEmpty {
            if rules[..<index].contains(where: {
                normalized($0).source.caseInsensitiveCompare(rule.source) == .orderedSame
            }) {
                return L10n.string(
                    "settings.dictionary.editor.validation.duplicate_source",
                    fallback: "Some recognized text is repeated. The first matching rule in file order is used."
                )
            }
        }
        return nil
    }

    private var normalizedRules: [DictionaryRule] {
        rules.map(normalized)
    }

    private func normalized(_ rule: DictionaryRule) -> DictionaryRule {
        DictionaryRule(
            id: rule.id,
            source: rule.source.trimmingCharacters(in: .whitespacesAndNewlines),
            target: rule.target.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func readSnapshot() throws -> FileSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .missing
        }
        return .data(try Data(contentsOf: fileURL))
    }

    private func adopt(_ snapshot: FileSnapshot) throws {
        let nextDocument: DictionaryDocument
        switch snapshot {
        case .missing:
            nextDocument = .empty
        case .data(let data):
            guard let contents = String(data: data, encoding: .utf8) else {
                throw DictionaryEditorError.invalidEncoding
            }
            nextDocument = DictionaryDocument(contents: contents)
        }

        document = nextDocument
        rules = nextDocument.rules
        savedRules = nextDocument.rules
        loadedSnapshot = snapshot
        didLoad = true
        externalChangeDetected = false
        errorMessage = nil
    }

    private func markExternalChange() {
        externalChangeDetected = true
        errorMessage = L10n.string(
            "settings.dictionary.editor.error.external_change",
            fallback: "The dictionary file changed outside HushType. Reload before saving; your draft is still here."
        )
    }

    private func readErrorMessage(_ error: Error) -> String {
        if case DictionaryEditorError.invalidEncoding = error {
            return L10n.string(
                "settings.dictionary.editor.error.invalid_encoding",
                fallback: "The dictionary is not valid UTF-8. Fix it in a text editor, then reload."
            )
        }
        return L10n.format(
            "settings.dictionary.editor.error.read",
            "Could not read the dictionary: %1$@",
            arguments: [error.localizedDescription]
        )
    }

    private func saveErrorMessage(_ error: Error) -> String {
        return L10n.format(
            "settings.dictionary.editor.error.save",
            "Could not save the dictionary: %1$@",
            arguments: [error.localizedDescription]
        )
    }
}

private enum DictionaryEditorError: LocalizedError {
    case invalidEncoding
    case cannotEncode

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "Dictionary file is not UTF-8."
        case .cannotEncode:
            "Dictionary text could not be encoded as UTF-8."
        }
    }
}
