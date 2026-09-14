import Foundation
import XCTest
@testable import HushType

@MainActor
final class DictionaryLibraryTests: XCTestCase {
    func testDefaultLibraryUsesLegacyFileWithoutChangingIt() throws {
        let fixture = try DictionaryLibraryFixture()
        defer { fixture.finish() }
        let original = Data("legacy -> retained\n".utf8)
        try original.write(to: fixture.legacyURL)

        let store = fixture.makeStore()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.libraries.map(\.id), [DictionaryLibraryStore.defaultID])
        XCTAssertEqual(store.fileURL(for: DictionaryLibraryStore.defaultID), fixture.legacyURL)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.libraryDirectory.path))
    }

    func testCreateRenameAndOrderPersistAcrossStoreInstances() throws {
        let fixture = try DictionaryLibraryFixture()
        defer { fixture.finish() }
        let store = fixture.makeStore()

        let first = try XCTUnwrap(store.create(name: "  Names  "))
        let second = try XCTUnwrap(store.create(name: "Terms"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: first.id).path))
        XCTAssertTrue(store.rename(id: first.id, name: "People"))

        let reloaded = fixture.makeStore()
        XCTAssertEqual(reloaded.libraries.map(\.id), [DictionaryLibraryStore.defaultID, first.id, second.id])
        XCTAssertEqual(reloaded.library(id: first.id)?.name, "People")
        XCTAssertEqual(reloaded.fileURL(for: second.id).lastPathComponent, second.id.uuidString + ".txt")
    }

    func testDefaultAndLastLibraryCanBeDeletedWithoutLegacyResurrection() throws {
        let fixture = try DictionaryLibraryFixture()
        defer { fixture.finish() }
        try Data("legacy -> saved\n".utf8).write(to: fixture.legacyURL)
        let store = fixture.makeStore()

        XCTAssertTrue(store.delete(id: DictionaryLibraryStore.defaultID))
        XCTAssertTrue(store.libraries.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: fixture.trashDirectory.appendingPathComponent("dictionary.txt")),
            Data("legacy -> saved\n".utf8)
        )
        // Even a stale file appearing at the historical path cannot resurrect
        // the default after an explicit empty metadata array was saved.
        try Data("stale -> legacy\n".utf8).write(to: fixture.legacyURL)
        XCTAssertTrue(fixture.makeStore().libraries.isEmpty)

        let extra = try XCTUnwrap(store.create(name: "Temporary"))
        try Data("alpha -> beta\n".utf8).write(to: store.fileURL(for: extra.id))

        XCTAssertTrue(store.delete(id: extra.id))
        XCTAssertTrue(store.libraries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: extra.id).path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.trashDirectory.appendingPathComponent(extra.id.uuidString + ".txt")),
            Data("alpha -> beta\n".utf8)
        )
        XCTAssertTrue(fixture.makeStore().libraries.isEmpty)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [DictionaryLibrary].self,
                from: Data(contentsOf: fixture.libraryDirectory.appendingPathComponent("libraries.json"))
            ),
            []
        )
    }

    func testDuplicateAppendsIndependentFileAndPreservesRules() throws {
        let fixture = try DictionaryLibraryFixture()
        defer { fixture.finish() }
        let store = fixture.makeStore()
        let source = try XCTUnwrap(store.create(name: "Names"))
        let contents = Data("heard -> intended\n".utf8)
        try contents.write(to: store.fileURL(for: source.id))

        let copy = try XCTUnwrap(store.duplicate(id: source.id))

        XCTAssertEqual(store.libraries.map(\.id), [DictionaryLibraryStore.defaultID, source.id, copy.id])
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: copy.id)), contents)
        try Data("changed -> copy\n".utf8).write(to: store.fileURL(for: copy.id))
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: source.id)), contents)
    }

    func testInvalidMetadataIsVisibleAndNeverOverwrittenByMutation() throws {
        let fixture = try DictionaryLibraryFixture()
        defer { fixture.finish() }
        try FileManager.default.createDirectory(at: fixture.libraryDirectory, withIntermediateDirectories: true)
        let metadata = fixture.libraryDirectory.appendingPathComponent("libraries.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: metadata)

        let store = fixture.makeStore()

        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.libraries.map(\.id), [DictionaryLibraryStore.defaultID])
        XCTAssertNil(store.create(name: "Must not overwrite"))
        XCTAssertEqual(try Data(contentsOf: metadata), corrupt)
    }

    func testExternalMetadataEditIsNotOverwritten() throws {
        let fixture = try DictionaryLibraryFixture()
        defer { fixture.finish() }
        let store = fixture.makeStore()
        let extra = try XCTUnwrap(store.create(name: "Original"))
        let metadata = fixture.libraryDirectory.appendingPathComponent("libraries.json")
        var externallyEdited = try JSONDecoder().decode(
            [DictionaryLibrary].self,
            from: Data(contentsOf: metadata)
        )
        externallyEdited[1].name = "External"
        let externalData = try JSONEncoder().encode(externallyEdited)
        try externalData.write(to: metadata, options: .atomic)

        XCTAssertFalse(store.rename(id: extra.id, name: "Local"))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: metadata), externalData)
        XCTAssertEqual(store.library(id: extra.id)?.name, "Original")
    }
}

@MainActor
private final class DictionaryLibraryFixture {
    let root: URL
    let legacyURL: URL
    let libraryDirectory: URL
    let trashDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HushType.DictionaryLibraries." + UUID().uuidString, isDirectory: true)
        legacyURL = root.appendingPathComponent("dictionary.txt")
        libraryDirectory = root.appendingPathComponent("dictionaries", isDirectory: true)
        trashDirectory = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeStore() -> DictionaryLibraryStore {
        DictionaryLibraryStore(
            directory: libraryDirectory,
            legacyDictionaryURL: legacyURL,
            trash: { file in
                try FileManager.default.createDirectory(
                    at: self.trashDirectory,
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(
                    at: file,
                    to: self.trashDirectory.appendingPathComponent(file.lastPathComponent)
                )
            }
        )
    }

    func finish() {
        try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }
}
