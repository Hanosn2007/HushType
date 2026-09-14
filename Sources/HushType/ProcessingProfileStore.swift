import Combine
import Foundation

@MainActor
final class ProcessingProfileStore: ObservableObject {
    static let shared = ProcessingProfileStore()
    private static let orderKey = "hushtype.profiles.order"
    enum Use: String { case dictation, captions }
    @Published private(set) var profiles: [ProcessingProfile] = []
    @Published var draft: ProcessingProfile?
    @Published var errorMessage: String?
    @Published private(set) var dictationID: UUID?
    @Published private(set) var captionsID: UUID?
    private var originalDraft: ProcessingProfile?
    private var originalData: Data?
    private let directory: URL
    private let defaults: UserDefaults
    private let trash: (URL) throws -> Void

    init(directory: URL? = nil, defaults: UserDefaults = .standard,
         seedProfiles: [ProcessingProfile]? = nil,
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.felix.hushtype/profiles", isDirectory: true)
        self.defaults = defaults
        self.trash = trash
        dictationID = defaults.string(forKey: "hushtype.profiles.dictation").flatMap(UUID.init(uuidString:))
        captionsID = defaults.string(forKey: "hushtype.profiles.captions").flatMap(UUID.init(uuidString:))
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            for file in files {
                let value = try JSONDecoder().decode(ProcessingProfile.self, from: Data(contentsOf: file)).validated()
                guard file.deletingPathExtension().lastPathComponent == value.id.uuidString else { throw ProfileError.invalid }
                profiles.append(value)
            }
            if files.isEmpty {
                let seeds = seedProfiles ?? [.legacy(captions: false), .legacy(captions: true)]
                for profile in seeds { try write(profile.validated()) }
                profiles = seeds
            }
            if !profiles.contains(where: { $0.id == dictationID }) { dictationID = profiles.first?.id }
            if !profiles.contains(where: { $0.id == captionsID }) { captionsID = profiles.dropFirst().first?.id ?? profiles.first?.id }
            saveSelections()
            restoreOrder()
        } catch { errorMessage = error.localizedDescription }
    }

    var isDirty: Bool { draft != nil && draft != originalDraft }

    func isSelected(_ id: UUID) -> Bool {
        id == dictationID || id == captionsID
    }

    func isInUse(_ id: UUID, additionalInUseIDs: Set<UUID> = []) -> Bool {
        isSelected(id) || additionalInUseIDs.contains(id)
    }

    /// Removes a deleted word-library reference from every saved profile and
    /// the current draft. All disk versions are checked before the first write,
    /// so an external edit is preserved and reported as a conflict.
    @discardableResult
    func removeDictionaryReference(_ libraryID: UUID) -> Bool {
        do {
            var changes: [(index: Int, value: ProcessingProfile, data: Data)] = []
            for profile in profiles where profile.rules.dictionaryIDs.contains(libraryID) {
                let saved = try currentSavedProfile(profile.id)
                var updated = saved.value
                updated.rules.dictionaryIDs.removeAll { $0 == libraryID }
                changes.append((saved.index, try updated.validated(), saved.data))
            }

            for change in changes {
                try replace(change.value, expectedData: change.data)
                profiles[change.index] = change.value
            }

            draft?.rules.dictionaryIDs.removeAll { $0 == libraryID }
            originalDraft?.rules.dictionaryIDs.removeAll { $0 == libraryID }
            if let draftID = draft?.id,
               changes.contains(where: { $0.value.id == draftID }) {
                originalData = try Data(contentsOf: url(draftID))
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func selected(_ use: Use) -> ProcessingProfile? {
        let id = use == .dictation ? dictationID : captionsID
        return profiles.first { $0.id == id }
    }

    func select(_ id: UUID, for use: Use) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        if use == .dictation { dictationID = id } else { captionsID = id }
        saveSelections()
    }

    func edit(_ profile: ProcessingProfile) {
        guard !isDirty else { errorMessage = ProfileError.unsaved.localizedDescription; return }
        do {
            let data = try Data(contentsOf: url(profile.id))
            let current = try JSONDecoder().decode(ProcessingProfile.self, from: data).validated()
            if let index = profiles.firstIndex(where: { $0.id == current.id }) { profiles[index] = current }
            draft = current; originalDraft = current; originalData = data
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func create(copying source: ProcessingProfile? = nil) {
        guard !isDirty else { errorMessage = ProfileError.unsaved.localizedDescription; return }
        var value = source ?? ProcessingProfile(name: L10n.string("profiles.new_name", fallback: "New configuration"))
        value.id = UUID()
        if source != nil { value.name += " " + L10n.string("profiles.copy_suffix", fallback: "Copy") }
        draft = value; originalDraft = nil; originalData = nil; errorMessage = nil
    }

    /// Creates the default configuration as a real saved list item. The UI can
    /// immediately offer rename without opening the full profile editor.
    @discardableResult
    func createSaved(availableLibraryIDs: Set<UUID>? = nil) -> ProcessingProfile? {
        do {
            var value = ProcessingProfile(
                name: L10n.string("profiles.new_name", fallback: "New configuration")
            )
            value.id = uniqueID()
            if let availableLibraryIDs { value.rules.dictionaryIDs.removeAll { !availableLibraryIDs.contains($0) } }
            value = try value.validated()
            try writeNew(value)
            profiles.append(value)
            saveOrder()
            errorMessage = nil
            return value
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Renames the saved value directly, without opening or replacing an edit
    /// draft. A disk change since this store loaded the profile wins.
    @discardableResult
    func rename(profileID: UUID, name: String) -> Bool {
        do {
            let saved = try currentSavedProfile(profileID)
            var renamed = saved.value
            renamed.name = name
            renamed = try renamed.validated()
            try replace(renamed, expectedData: saved.data)
            profiles[saved.index] = renamed
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates and saves a new independent profile immediately. The selected
    /// dictation/caption profiles and any running snapshots remain unchanged.
    @discardableResult
    func duplicate(profileID: UUID) -> ProcessingProfile? {
        do {
            let saved = try currentSavedProfile(profileID)
            var copy = saved.value
            copy.id = uniqueID()
            let suffix = " " + L10n.string("profiles.copy_suffix", fallback: "Copy")
            copy.name = String(copy.name.prefix(max(0, 100 - suffix.count))) + suffix
            copy = try copy.validated()
            try writeNew(copy)
            profiles.append(copy)
            saveOrder()
            errorMessage = nil
            return copy
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func exportProfile(id: UUID, to destination: URL) -> Bool {
        do {
            let saved = try currentSavedProfile(id)
            try ProcessingProfileTransfer.export(saved.value, to: destination)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Imports configuration only. Referenced word libraries must already
    /// exist locally; the imported profile always receives a fresh identity.
    @discardableResult
    func importProfile(
        from source: URL,
        availableLibraryIDs: Set<UUID>? = nil
    ) -> ProcessingProfile? {
        do {
            let available = availableLibraryIDs
                ?? Set(DictionaryLibraryStore.shared.libraries.map(\.id))
            var imported = try ProcessingProfileTransfer.importedProfile(
                from: source,
                availableLibraryIDs: available
            )
            imported.id = uniqueID()
            try writeNew(imported)
            profiles.append(imported)
            saveOrder()
            errorMessage = nil
            return imported
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult func save() -> Bool {
        guard let draft else { return false }
        do {
            let value = try draft.validated()
            let file = url(value.id)
            if originalDraft != nil {
                guard try Data(contentsOf: file) == originalData else { throw ProfileError.changedOnDisk }
            } else if FileManager.default.fileExists(atPath: file.path) { throw ProfileError.changedOnDisk }
            try write(value)
            let isNew = !profiles.contains(where: { $0.id == value.id })
            if let index = profiles.firstIndex(where: { $0.id == value.id }) { profiles[index] = value }
            else { profiles.append(value) }
            self.draft = value; originalDraft = value; originalData = try Data(contentsOf: file)
            if dictationID == nil { dictationID = value.id }
            if captionsID == nil { captionsID = value.id }
            saveSelections()
            if isNew { saveOrder() }
            errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func cancelEditing() { draft = nil; originalDraft = nil; originalData = nil; errorMessage = nil }

    @discardableResult
    func delete(
        _ profile: ProcessingProfile,
        additionalInUseIDs: Set<UUID> = []
    ) -> Bool {
        do {
            guard !isDirty else { throw ProfileError.unsaved }
            guard !isInUse(profile.id, additionalInUseIDs: additionalInUseIDs) else {
                errorMessage = nil
                return false
            }
            try trash(url(profile.id))
            profiles.removeAll { $0.id == profile.id }
            saveOrder()
            if draft?.id == profile.id { cancelEditing() }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    private func currentSavedProfile(_ id: UUID) throws -> (value: ProcessingProfile, data: Data, index: Int) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ProcessingProfileTransferError.notFound
        }
        let data = try Data(contentsOf: url(id))
        let value = try JSONDecoder().decode(ProcessingProfile.self, from: data).validated()
        guard value.id == id, value == profiles[index] else {
            throw ProfileError.changedOnDisk
        }
        return (value, data, index)
    }

    private func uniqueID() -> UUID {
        var id = UUID()
        while profiles.contains(where: { $0.id == id }) || FileManager.default.fileExists(atPath: url(id).path) {
            id = UUID()
        }
        return id
    }

    private func replace(_ profile: ProcessingProfile, expectedData: Data) throws {
        guard try Data(contentsOf: url(profile.id)) == expectedData else {
            throw ProfileError.changedOnDisk
        }
        try write(profile)
    }

    private func writeNew(_ profile: ProcessingProfile) throws {
        guard !FileManager.default.fileExists(atPath: url(profile.id).path) else {
            throw ProfileError.changedOnDisk
        }
        try write(profile)
    }

    private func write(_ profile: ProcessingProfile) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: url(profile.id), options: .atomic)
    }
    /// Existing installations did not persist order, so migrate their current
    /// name ordering once. Afterwards saved IDs are stable and any externally
    /// added files are appended deterministically.
    private func restoreOrder() {
        guard let stored = defaults.stringArray(forKey: Self.orderKey) else {
            profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            saveOrder()
            return
        }

        var positions: [UUID: Int] = [:]
        for (index, rawID) in stored.enumerated() {
            guard let id = UUID(uuidString: rawID), positions[id] == nil else { continue }
            positions[id] = index
        }
        let known = profiles.filter { positions[$0.id] != nil }.sorted {
            positions[$0.id, default: .max] < positions[$1.id, default: .max]
        }
        let unknown = profiles.filter { positions[$0.id] == nil }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        profiles = known + unknown
        if unknown.isEmpty == false || stored.count != profiles.count {
            saveOrder()
        }
    }

    private func saveOrder() {
        defaults.set(profiles.map { $0.id.uuidString }, forKey: Self.orderKey)
    }

    private func saveSelections() {
        defaults.set(dictationID?.uuidString, forKey: "hushtype.profiles.dictation")
        defaults.set(captionsID?.uuidString, forKey: "hushtype.profiles.captions")
    }
}
