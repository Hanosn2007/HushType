import Foundation
import XCTest
@testable import HushType

@MainActor
final class ProcessingProfileTransferTests: XCTestCase {
    func testCreateSavedAppendsAndRenameKeepsStableOrderAcrossReload() throws {
        let zebra = ProcessingProfile(name: "Zebra")
        let alpha = ProcessingProfile(name: "Alpha")
        let fixture = try TransferFixture(seedProfiles: [zebra, alpha])
        defer { fixture.finish() }
        XCTAssertEqual(fixture.store.profiles.map(\.id), [alpha.id, zebra.id])
        let selections = (fixture.store.dictationID, fixture.store.captionsID)

        let created = try XCTUnwrap(fixture.store.createSaved())

        XCTAssertEqual(fixture.store.profiles.map(\.id), [alpha.id, zebra.id, created.id])
        XCTAssertEqual(
            created.name,
            L10n.string("profiles.new_name", fallback: "New configuration")
        )
        XCTAssertNil(fixture.store.draft)
        XCTAssertEqual(fixture.store.dictationID, selections.0)
        XCTAssertEqual(fixture.store.captionsID, selections.1)

        XCTAssertTrue(fixture.store.rename(profileID: created.id, name: "A renamed tail"))
        XCTAssertEqual(fixture.store.profiles.map(\.id), [alpha.id, zebra.id, created.id])

        let reloaded = ProcessingProfileStore(
            directory: fixture.profileDirectory,
            defaults: fixture.defaults
        )
        XCTAssertEqual(reloaded.profiles.map(\.id), [alpha.id, zebra.id, created.id])
        XCTAssertEqual(reloaded.profiles.last?.name, "A renamed tail")
        XCTAssertEqual(reloaded.dictationID, selections.0)
        XCTAssertEqual(reloaded.captionsID, selections.1)
    }

    func testExportUsesSavedProfileAndPreservesLibraryReferences() throws {
        let libraryID = UUID()
        var profile = ProcessingProfile(name: "Exported")
        profile.rules.dictionaryIDs = [DictionaryLibraryStore.defaultID, libraryID]
        profile.llm.polish = true
        let fixture = try TransferFixture(seedProfiles: [profile, ProcessingProfile(name: "Second")])
        defer { fixture.finish() }
        let saved = try XCTUnwrap(fixture.store.profiles.first { $0.id == profile.id })
        fixture.store.edit(saved)
        fixture.store.draft?.name = "Unsaved draft"
        let destination = fixture.transferDirectory.appendingPathComponent("exported.json")

        XCTAssertTrue(fixture.store.exportProfile(id: profile.id, to: destination))
        let exported = try JSONDecoder().decode(
            ProcessingProfile.self,
            from: Data(contentsOf: destination)
        )
        XCTAssertEqual(exported.name, "Exported")
        XCTAssertEqual(exported.rules.dictionaryIDs, [DictionaryLibraryStore.defaultID, libraryID])
        XCTAssertTrue(exported.llm.polish)
        XCTAssertEqual(fixture.store.draft?.name, "Unsaved draft")
    }

    func testImportCreatesNewSavedProfileWithoutChangingSelections() throws {
        let libraryID = UUID()
        let fixture = try TransferFixture()
        defer { fixture.finish() }
        var sourceProfile = ProcessingProfile(name: "Imported")
        sourceProfile.rules.dictionaryIDs = [libraryID]
        sourceProfile.language = "japanese"
        let source = fixture.transferDirectory.appendingPathComponent("source.json")
        try ProcessingProfileTransfer.export(sourceProfile, to: source)
        let selections = (fixture.store.dictationID, fixture.store.captionsID)

        let imported = try XCTUnwrap(fixture.store.importProfile(
            from: source,
            availableLibraryIDs: [libraryID]
        ))

        XCTAssertNotEqual(imported.id, sourceProfile.id)
        XCTAssertEqual(imported.name, sourceProfile.name)
        XCTAssertEqual(imported.rules.dictionaryIDs, [libraryID])
        XCTAssertEqual(imported.language, "japanese")
        XCTAssertEqual(fixture.store.dictationID, selections.0)
        XCTAssertEqual(fixture.store.captionsID, selections.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file(imported.id).path))

        let reloaded = ProcessingProfileStore(directory: fixture.profileDirectory, defaults: fixture.defaults)
        XCTAssertEqual(reloaded.profiles.first { $0.id == imported.id }, imported)
    }

    func testImportRejectsUnavailableLibraryWithoutWritingOrChangingSelections() throws {
        let fixture = try TransferFixture()
        defer { fixture.finish() }
        var sourceProfile = ProcessingProfile(name: "Foreign")
        sourceProfile.rules.dictionaryIDs = [UUID()]
        let source = fixture.transferDirectory.appendingPathComponent("foreign.json")
        try ProcessingProfileTransfer.export(sourceProfile, to: source)
        let originalIDs = Set(fixture.store.profiles.map(\.id))
        let selections = (fixture.store.dictationID, fixture.store.captionsID)

        XCTAssertNil(fixture.store.importProfile(from: source, availableLibraryIDs: []))
        XCTAssertNotNil(fixture.store.errorMessage)
        XCTAssertEqual(Set(fixture.store.profiles.map(\.id)), originalIDs)
        XCTAssertEqual(fixture.store.dictationID, selections.0)
        XCTAssertEqual(fixture.store.captionsID, selections.1)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(
                at: fixture.profileDirectory,
                includingPropertiesForKeys: nil
            ).map { $0.deletingPathExtension().lastPathComponent }),
            Set(originalIDs.map(\.uuidString))
        )
    }

    func testImportRejectsInvalidProfileOptions() throws {
        let fixture = try TransferFixture()
        defer { fixture.finish() }
        var invalid = ProcessingProfile(name: "Invalid")
        invalid.modelID = "unknown-model"
        let source = fixture.transferDirectory.appendingPathComponent("invalid.json")
        try JSONEncoder().encode(invalid).write(to: source)
        let originalIDs = Set(fixture.store.profiles.map(\.id))

        XCTAssertNil(fixture.store.importProfile(from: source, availableLibraryIDs: []))
        XCTAssertNotNil(fixture.store.errorMessage)
        XCTAssertEqual(Set(fixture.store.profiles.map(\.id)), originalIDs)
    }

    func testRenameAndDuplicatePersistWithoutOpeningEditorOrChangingSnapshot() throws {
        var first = ProcessingProfile(name: "First")
        first.language = "chinese"
        first.llm.translate = true
        let fixture = try TransferFixture(seedProfiles: [first, ProcessingProfile(name: "Second")])
        defer { fixture.finish() }
        let snapshot = ProcessingProfileSnapshot(
            profile: try XCTUnwrap(fixture.store.profiles.first { $0.id == first.id }),
            dictionaryURL: fixture.root.appendingPathComponent("dictionary.txt")
        )
        let selections = (fixture.store.dictationID, fixture.store.captionsID)

        XCTAssertTrue(fixture.store.rename(profileID: first.id, name: "Renamed"))
        let duplicate = try XCTUnwrap(fixture.store.duplicate(profileID: first.id))

        XCTAssertNil(fixture.store.draft)
        XCTAssertEqual(snapshot.profile.name, "First")
        XCTAssertEqual(fixture.store.profiles.first { $0.id == first.id }?.name, "Renamed")
        XCTAssertNotEqual(duplicate.id, first.id)
        XCTAssertEqual(
            duplicate.name,
            "Renamed " + L10n.string("profiles.copy_suffix", fallback: "Copy")
        )
        XCTAssertEqual(duplicate.language, "chinese")
        XCTAssertTrue(duplicate.llm.translate)
        XCTAssertEqual(fixture.store.dictationID, selections.0)
        XCTAssertEqual(fixture.store.captionsID, selections.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file(duplicate.id).path))
    }

    func testRenameDoesNotOverwriteExternalDiskChange() throws {
        let fixture = try TransferFixture()
        defer { fixture.finish() }
        let profile = try XCTUnwrap(fixture.store.profiles.first)
        var external = profile
        external.name = "External"
        let externalData = try JSONEncoder().encode(external)
        try externalData.write(to: fixture.file(profile.id), options: .atomic)

        XCTAssertFalse(fixture.store.rename(profileID: profile.id, name: "Local"))
        XCTAssertNotNil(fixture.store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: fixture.file(profile.id)), externalData)
        XCTAssertEqual(fixture.store.profiles.first { $0.id == profile.id }?.name, profile.name)
    }

    func testAdditionalRuntimeUseProtectsDeleteSilently() throws {
        let third = ProcessingProfile(name: "Runtime")
        let fixture = try TransferFixture(seedProfiles: [
            ProcessingProfile(name: "First"),
            ProcessingProfile(name: "Second"),
            third,
        ])
        defer { fixture.finish() }

        XCTAssertTrue(fixture.store.isInUse(third.id, additionalInUseIDs: [third.id]))
        XCTAssertFalse(fixture.store.delete(third, additionalInUseIDs: [third.id]))
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file(third.id).path))
        XCTAssertTrue(fixture.store.delete(third))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file(third.id).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.trashDirectory.appendingPathComponent(third.id.uuidString + ".json").path
        ))
    }
}

@MainActor
private final class TransferFixture {
    let root: URL
    let profileDirectory: URL
    let transferDirectory: URL
    let trashDirectory: URL
    let defaults: UserDefaults
    let suite = "HushType.ProfileTransferTests." + UUID().uuidString
    let store: ProcessingProfileStore

    init(seedProfiles: [ProcessingProfile]? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HushType.ProfileTransfers." + UUID().uuidString, isDirectory: true)
        profileDirectory = root.appendingPathComponent("profiles", isDirectory: true)
        transferDirectory = root.appendingPathComponent("transfer", isDirectory: true)
        trashDirectory = root.appendingPathComponent("trash", isDirectory: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
        let seeds = seedProfiles ?? [ProcessingProfile(name: "First"), ProcessingProfile(name: "Second")]
        let trashDirectory = self.trashDirectory
        store = ProcessingProfileStore(
            directory: profileDirectory,
            defaults: defaults,
            seedProfiles: seeds,
            trash: { file in
                try FileManager.default.createDirectory(
                    at: trashDirectory,
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(
                    at: file,
                    to: trashDirectory.appendingPathComponent(file.lastPathComponent)
                )
            }
        )
        XCTAssertNil(store.errorMessage)
    }

    func file(_ id: UUID) -> URL {
        profileDirectory.appendingPathComponent(id.uuidString + ".json")
    }

    func finish() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }
}
