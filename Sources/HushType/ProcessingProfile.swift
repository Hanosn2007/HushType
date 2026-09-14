import Foundation

struct ProcessingProfile: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    var name: String
    var input = Input()
    var modelID = AppConfig.defaultModelId
    var language = "auto"
    var rules = Rules()
    var llm = LLM()

    struct Input: Codable, Equatable, Hashable, Sendable {
        enum Kind: String, Codable, CaseIterable, Sendable { case microphone, application }
        var kind: Kind = .microphone
        var device = AudioInputSelection.followSystem
        var bundleID = ""
        var applicationName = ""

        /// Application audio may deliberately have no selected application.
        /// That is a valid saved configuration, but it has no capture source
        /// until the user selects one. Microphone configurations always have
        /// a source because their device selection can fall back to the system.
        var hasCaptureSource: Bool {
            kind == .microphone
                || !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    struct Rules: Codable, Equatable, Sendable {
        var numbers = true
        var traditionalChinese = false
        var dictionaryIDs = [DictionaryLibraryStore.defaultID]
        var punctuation = "soft"

        /// Source compatibility for the first Profiles UI and tests. New JSON
        /// stores the selected library identities instead of this Boolean.
        var dictionary: Bool {
            get { !dictionaryIDs.isEmpty }
            set {
                if newValue {
                    if dictionaryIDs.isEmpty {
                        dictionaryIDs = [DictionaryLibraryStore.defaultID]
                    }
                } else {
                    dictionaryIDs = []
                }
            }
        }

        init() {}

        private enum CodingKeys: String, CodingKey {
            case numbers
            case traditionalChinese
            case dictionaryIDs
            case dictionary
            case punctuation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            numbers = try container.decodeIfPresent(Bool.self, forKey: .numbers) ?? true
            traditionalChinese = try container.decodeIfPresent(Bool.self, forKey: .traditionalChinese) ?? false
            punctuation = try container.decodeIfPresent(String.self, forKey: .punctuation) ?? "soft"

            if let ids = try container.decodeIfPresent([UUID].self, forKey: .dictionaryIDs) {
                var seen: Set<UUID> = []
                dictionaryIDs = ids.filter { seen.insert($0).inserted }
            } else {
                let enabled = try container.decodeIfPresent(Bool.self, forKey: .dictionary) ?? true
                dictionaryIDs = enabled ? [DictionaryLibraryStore.defaultID] : []
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(numbers, forKey: .numbers)
            try container.encode(traditionalChinese, forKey: .traditionalChinese)
            try container.encode(dictionaryIDs, forKey: .dictionaryIDs)
            try container.encode(punctuation, forKey: .punctuation)
        }
    }

    enum Correction: String, Codable, CaseIterable, Sendable {
        case light, standard, fluent
        var title: String { L10n.string("profiles.correction." + rawValue, fallback: rawValue.capitalized) }
        var instruction: String {
            switch self {
            case .light: "Make minimal changes: fix only clear transcription mistakes. Retain the speaker's wording and sentence structure."
            case .standard: "Correct recognition mistakes, grammar, and punctuation while retaining the speaker's wording wherever possible."
            case .fluent: "Also remove verbal repetitions and improve sentence flow, without adding, omitting, or changing any information."
            }
        }
    }

    struct LLM: Codable, Equatable, Sendable {
        var polish = false
        var polishBackend = "qwen"
        var correction: Correction = .standard
        var translate = false
        var translationBackend = "qwen"
        var target = LocalTextLanguage.simplifiedChinese.rawValue
    }

    func validated() throws -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.input.bundleID = input.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.input.bundleID.isEmpty {
            copy.input.applicationName = ""
        }
        guard schemaVersion == 1, !copy.name.isEmpty, copy.name.count <= 100,
              [AppConfig.defaultModelId, AppConfig.balancedModelId, AppConfig.powerSavingModelId].contains(modelID),
              ["auto", "english", "chinese", "japanese"].contains(language),
              PunctuationMode(rawValue: rules.punctuation) != nil,
              llm.polishBackend == "qwen", llm.translationBackend == "qwen",
              LocalTextLanguage(rawValue: llm.target) != nil else {
            throw ProfileError.invalid
        }
        return copy
    }

    static func legacy(captions: Bool) -> Self {
        let config = AppConfig.shared
        var profile = Self(name: L10n.string(captions ? "profiles.initial_caption" : "profiles.initial_dictation",
                                            fallback: captions ? "Configuration 2" : "Default configuration"))
        profile.input.device = config.audioInputSelection
        if captions, !config.lastStartedCaptionUsesMicSource {
            let bundleID = LiveCaptionTuning.load().systemAudioBundleID
            if !bundleID.isEmpty { profile.input.kind = .application; profile.input.bundleID = bundleID }
        }
        profile.modelID = config.modelId
        profile.language = config.language ?? "auto"
        profile.rules.numbers = captions ? false : config.numberConversionEnabled
        profile.rules.traditionalChinese = config.chineseConversionEnabled
        profile.rules.punctuation = config.punctuationMode.rawValue
        profile.llm.translate = captions && LocalTextPreferences.translatesCaptions
        profile.llm.target = LocalTextPreferences.captionTarget.rawValue
        return profile
    }
}

enum ProfileError: LocalizedError {
    case invalid, changedOnDisk, unsaved, modelBusy
    case modelUnavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalid: L10n.string("profiles.error.invalid", fallback: "Check the name, audio source, model, and processing options.")
        case .changedOnDisk: L10n.string("profiles.error.conflict", fallback: "This configuration changed on disk. Cancel editing and reopen it before saving.")
        case .unsaved: L10n.string("profiles.error.unsaved", fallback: "Save or cancel the current changes first.")
        case .modelBusy: L10n.string("profiles.error.model_busy", fallback: "Another task is using a different speech model. Finish that task before switching models.")
        case .modelUnavailable(let name): L10n.format("profiles.error.model_unavailable", "%1$@ is unavailable.", arguments: [name])
        }
    }
}

/// Value captured once per task. Saved profile or dictionary edits cannot change it.
struct ProcessingProfileSnapshot: Sendable {
    let profile: ProcessingProfile
    let dictionaryRules: [DictionaryRule]

    init(
        profile: ProcessingProfile,
        dictionaryURL: URL = AppConfig.dictionaryFileURL,
        dictionaryLibraryDirectory: URL? = nil
    ) {
        var resolved = profile
        if profile.input.kind == .microphone, profile.input.device != AudioInputSelection.automatic,
           let uid = AudioInputDeviceManager.captureDevice(rawValue: profile.input.device)?.captureDevice.uniqueID {
            resolved.input.device = AudioInputSelection.device(uid)
        }
        self.profile = resolved
        let storage = DictionaryLibraryStorage(
            directory: dictionaryLibraryDirectory ?? dictionaryURL.deletingLastPathComponent()
                .appendingPathComponent("dictionaries", isDirectory: true),
            legacyDictionaryURL: dictionaryURL
        )
        dictionaryRules = storage.selectedFileURLs(for: profile.rules.dictionaryIDs).flatMap { url in
            (try? String(contentsOf: url, encoding: .utf8))
                .map { DictionaryDocument(contents: $0).rules } ?? []
        }
    }

    func applyRules(_ text: String) -> String {
        let rules = profile.rules
        let chinese = ScriptDetector.detect(text) == .zh
        var result = ChineseConverter.convert(text, enabled: rules.traditionalChinese)
        if chinese, rules.numbers { result = NumberNormalizer.normalize(result).text }
        if !dictionaryRules.isEmpty { result = DictionaryReplacer.apply(result, rules: dictionaryRules) }
        if chinese { result = PunctuationNormalizer.apply(result, mode: PunctuationMode(rawValue: rules.punctuation) ?? .soft) }
        return result
    }

    func polish(_ text: String,
                transform: @escaping @Sendable (LocalTextRequest) async throws -> String = { try await LocalTextResources.transform($0) }) async throws -> String {
        guard profile.llm.polish, !text.isEmpty else { return text }
        return try await transform(.polish(text, level: profile.llm.correction))
    }

    func process(_ raw: String,
                 transform: @escaping @Sendable (LocalTextRequest) async throws -> String = { try await LocalTextResources.transform($0) }) async throws -> String {
        let text = try await polish(applyRules(raw), transform: transform)
        guard profile.llm.translate, !text.isEmpty else { return text }
        return try await transform(.translate(text,
            target: LocalTextLanguage(rawValue: profile.llm.target) ?? .simplifiedChinese))
    }
}
