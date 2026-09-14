import Foundation

enum ProcessingProfileTransfer {
    static func export(_ profile: ProcessingProfile, to destination: URL) throws {
        let value = try profile.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: destination, options: .atomic)
    }

    static func importedProfile(
        from source: URL,
        availableLibraryIDs: Set<UUID>
    ) throws -> ProcessingProfile {
        let decoded: ProcessingProfile
        do {
            decoded = try JSONDecoder().decode(
                ProcessingProfile.self,
                from: Data(contentsOf: source)
            )
        } catch {
            throw ProcessingProfileTransferError.invalid
        }

        let value: ProcessingProfile
        do {
            value = try decoded.validated()
        } catch {
            throw ProcessingProfileTransferError.invalid
        }

        guard Set(value.rules.dictionaryIDs).isSubset(of: availableLibraryIDs) else {
            throw ProcessingProfileTransferError.missingLibrary
        }

        var imported = value
        imported.id = UUID()
        return imported
    }
}

enum ProcessingProfileTransferError: LocalizedError {
    case invalid
    case missingLibrary
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalid:
            L10n.string(
                "profiles.error.invalid_import",
                fallback: "This file is not a valid HushType processing configuration."
            )
        case .missingLibrary:
            L10n.string(
                "profiles.error.missing_library",
                fallback: "This configuration uses word libraries that are not available on this Mac. Add the same libraries before importing it."
            )
        case .notFound:
            L10n.string(
                "profiles.error.not_found",
                fallback: "This processing configuration no longer exists."
            )
        }
    }
}
