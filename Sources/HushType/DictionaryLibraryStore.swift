import Combine
import Foundation

struct DictionaryLibrary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
}

/// The non-actor storage description can be copied into a processing task and
/// read without reaching back into the settings store. The metadata array is
/// also the canonical precedence order for equal-length rules.
struct DictionaryLibraryStorage: Sendable {
    let directory: URL
    let legacyDictionaryURL: URL

    var metadataURL: URL {
        directory.appendingPathComponent("libraries.json")
    }

    func fileURL(for id: UUID) -> URL {
        if id == DictionaryLibraryStore.defaultID {
            return legacyDictionaryURL
        }
        return directory.appendingPathComponent(id.uuidString + ".txt")
    }

    func loadLibraries() throws -> [DictionaryLibrary] {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return [Self.defaultLibrary]
        }

        let decoded = try JSONDecoder().decode(
            [DictionaryLibrary].self,
            from: Data(contentsOf: metadataURL)
        )
        return try Self.validated(decoded)
    }

    /// Invalid or unavailable metadata must not make task startup fail. In
    /// that case only the historical default dictionary remains resolvable.
    func selectedFileURLs(for ids: [UUID]) -> [URL] {
        let selected = Set(ids)
        let ordered = (try? loadLibraries()) ?? [Self.defaultLibrary]
        return ordered
            .filter { selected.contains($0.id) }
            .map { fileURL(for: $0.id) }
    }

    static let defaultLibrary = DictionaryLibrary(
        id: DictionaryLibraryStore.defaultID,
        name: L10n.string("dictionary.default_name", fallback: "Default")
    )

    static func validated(_ libraries: [DictionaryLibrary]) throws -> [DictionaryLibrary] {
        var seen: Set<UUID> = []
        var result: [DictionaryLibrary] = []

        for library in libraries {
            let name = library.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 100, seen.insert(library.id).inserted else {
                throw DictionaryLibraryError.invalidMetadata
            }
            result.append(DictionaryLibrary(id: library.id, name: name))
        }

        return result
    }
}

@MainActor
final class DictionaryLibraryStore: ObservableObject {
    /// This identity is permanent: profiles migrated from the historical
    /// Boolean dictionary setting always resolve it back to dictionary.txt.
    nonisolated static let defaultID = UUID(uuidString: "8B76F0C5-D3E2-4D9B-9D34-B1A2A70A09A1")!

    static var defaultDirectory: URL {
        AppConfig.dictionaryFileURL.deletingLastPathComponent()
            .appendingPathComponent("dictionaries", isDirectory: true)
    }

    static let shared = DictionaryLibraryStore()

    @Published private(set) var libraries: [DictionaryLibrary] = []
    @Published private(set) var errorMessage: String?

    let storage: DictionaryLibraryStorage

    private enum MetadataSnapshot: Equatable {
        case missing
        case data(Data)
    }

    private let fileManager: FileManager
    private let trash: (URL) throws -> Void
    private var metadataIsValid = true
    private var loadedMetadata: MetadataSnapshot = .missing

    init(
        directory: URL? = nil,
        legacyDictionaryURL: URL = AppConfig.dictionaryFileURL,
        fileManager: FileManager = .default,
        trash: @escaping (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) {
        storage = DictionaryLibraryStorage(
            directory: directory ?? Self.defaultDirectory,
            legacyDictionaryURL: legacyDictionaryURL
        )
        self.fileManager = fileManager
        self.trash = trash

        do {
            loadedMetadata = try readMetadataSnapshot()
            switch loadedMetadata {
            case .missing:
                libraries = [DictionaryLibraryStorage.defaultLibrary]
            case .data(let data):
                libraries = try DictionaryLibraryStorage.validated(
                    JSONDecoder().decode([DictionaryLibrary].self, from: data)
                )
            }
        } catch {
            libraries = [DictionaryLibraryStorage.defaultLibrary]
            metadataIsValid = false
            errorMessage = error.localizedDescription
        }
    }

    func library(id: UUID) -> DictionaryLibrary? {
        libraries.first { $0.id == id }
    }

    func fileURL(for id: UUID) -> URL {
        storage.fileURL(for: id)
    }

    @discardableResult
    func create(name: String) -> DictionaryLibrary? {
        do {
            try requireValidMetadata()
            try requireUnchangedMetadata()
            let normalizedName = try validatedName(name)
            try fileManager.createDirectory(at: storage.directory, withIntermediateDirectories: true)

            var id = UUID()
            while libraries.contains(where: { $0.id == id }) ||
                    fileManager.fileExists(atPath: storage.fileURL(for: id).path) {
                id = UUID()
            }

            let library = DictionaryLibrary(id: id, name: normalizedName)
            let file = storage.fileURL(for: id)
            guard fileManager.createFile(atPath: file.path, contents: Data()) else {
                throw DictionaryLibraryError.cannotCreateFile
            }

            do {
                try writeMetadata(libraries + [library])
            } catch {
                try? trash(file)
                throw error
            }

            libraries.append(library)
            errorMessage = nil
            return library
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func rename(id: UUID, name: String) -> Bool {
        do {
            try requireValidMetadata()
            try requireUnchangedMetadata()
            guard let index = libraries.firstIndex(where: { $0.id == id }) else {
                throw DictionaryLibraryError.notFound
            }
            var updated = libraries
            updated[index].name = try validatedName(name)
            try writeMetadata(updated)
            libraries = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func duplicate(id: UUID) -> DictionaryLibrary? {
        do {
            try requireValidMetadata()
            try requireUnchangedMetadata()
            guard let source = libraries.first(where: { $0.id == id }) else {
                throw DictionaryLibraryError.notFound
            }

            var newID = UUID()
            while libraries.contains(where: { $0.id == newID }) ||
                    fileManager.fileExists(atPath: storage.fileURL(for: newID).path) {
                newID = UUID()
            }
            let suffix = " " + L10n.string("profiles.copy_suffix", fallback: "Copy")
            let copy = DictionaryLibrary(
                id: newID,
                name: String(source.name.prefix(max(0, 100 - suffix.count))) + suffix
            )
            let sourceFile = storage.fileURL(for: id)
            let contents = fileManager.fileExists(atPath: sourceFile.path)
                ? try Data(contentsOf: sourceFile)
                : Data()
            let copyFile = storage.fileURL(for: newID)
            try fileManager.createDirectory(at: storage.directory, withIntermediateDirectories: true)
            guard fileManager.createFile(atPath: copyFile.path, contents: contents) else {
                throw DictionaryLibraryError.cannotCreateFile
            }

            do {
                try writeMetadata(libraries + [copy])
            } catch {
                try? trash(copyFile)
                throw error
            }
            libraries.append(copy)
            errorMessage = nil
            return copy
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Every library is removable, including the historical default. An
    /// explicit empty metadata array records that zero libraries is intentional.
    @discardableResult
    func delete(id: UUID) -> Bool {
        do {
            try requireValidMetadata()
            try requireUnchangedMetadata()
            guard libraries.contains(where: { $0.id == id }) else {
                throw DictionaryLibraryError.notFound
            }

            let previous = libraries
            let updated = libraries.filter { $0.id != id }
            try writeMetadata(updated)

            let file = storage.fileURL(for: id)
            if fileManager.fileExists(atPath: file.path) {
                do {
                    try trash(file)
                } catch {
                    try? writeMetadata(previous)
                    throw error
                }
            }

            libraries = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func validatedName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 100 else {
            throw DictionaryLibraryError.invalidName
        }
        return normalized
    }

    private func requireValidMetadata() throws {
        guard metadataIsValid else {
            throw DictionaryLibraryError.invalidMetadata
        }
    }

    private func requireUnchangedMetadata() throws {
        guard try readMetadataSnapshot() == loadedMetadata else {
            throw DictionaryLibraryError.changedOnDisk
        }
    }

    private func readMetadataSnapshot() throws -> MetadataSnapshot {
        guard fileManager.fileExists(atPath: storage.metadataURL.path) else {
            return .missing
        }
        return .data(try Data(contentsOf: storage.metadataURL))
    }

    private func writeMetadata(_ value: [DictionaryLibrary]) throws {
        let validated = try DictionaryLibraryStorage.validated(value)
        try fileManager.createDirectory(at: storage.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(validated)
        try data.write(to: storage.metadataURL, options: .atomic)
        loadedMetadata = .data(data)
    }
}

private enum DictionaryLibraryError: LocalizedError {
    case invalidName
    case invalidMetadata
    case changedOnDisk
    case notFound
    case cannotCreateFile

    var errorDescription: String? {
        switch self {
        case .invalidName:
            L10n.string(
                "dictionary.error.invalid_name",
                fallback: "Dictionary names must contain 1 to 100 characters."
            )
        case .invalidMetadata:
            L10n.string(
                "dictionary.error.invalid_metadata",
                fallback: "The dictionary library list is invalid."
            )
        case .changedOnDisk:
            L10n.string(
                "dictionary.error.changed_on_disk",
                fallback: "The dictionary library list changed outside HushType. Restart HushType before making changes."
            )
        case .notFound:
            L10n.string(
                "dictionary.error.not_found",
                fallback: "The dictionary library no longer exists."
            )
        case .cannotCreateFile:
            L10n.string(
                "dictionary.error.create_file",
                fallback: "The dictionary file could not be created."
            )
        }
    }
}
