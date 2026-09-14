import XCTest
@testable import HushType

final class LocalTextModelCatalogTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "LocalTextModelCatalogTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory, fileManager.fileExists(atPath: temporaryDirectory.path) {
            try fileManager.trashItem(at: temporaryDirectory, resultingItemURL: nil)
        }
        temporaryDirectory = nil
    }

    func testDefaultModelUsesPinnedRevisionAndFixedAppStorageOwner() throws {
        let catalog = try LocalTextModelCatalog(
            applicationSupportDirectory: temporaryDirectory
        )

        XCTAssertEqual(
            catalog.model.revision,
            "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
        )
        XCTAssertEqual(
            catalog.rootDirectory,
            temporaryDirectory
                .appendingPathComponent("com.felix.hushtype", isDirectory: true)
                .appendingPathComponent("text-models", isDirectory: true)
        )
    }

    func testMissingRepositoryIsNotInstalled() throws {
        let catalog = try makeCatalog()
        XCTAssertEqual(catalog.installation(), .notInstalled)
    }

    func testIncompleteSnapshotReportsMissingRequiredFiles() throws {
        let catalog = try makeCatalog()
        let snapshot = try makeSnapshot(for: catalog)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))

        guard case .incomplete(let missingFiles) = catalog.installation() else {
            return XCTFail("Expected an incomplete snapshot")
        }
        XCTAssertTrue(missingFiles.contains("model.safetensors"))
        XCTAssertTrue(missingFiles.contains("tokenizer.json"))
    }

    func testCompletePinnedSnapshotIsInstalled() throws {
        let catalog = try makeCatalog()
        let snapshot = try makeSnapshot(for: catalog)
        try writeCompleteSnapshot(at: snapshot, indexedWeightFilename: "model.safetensors")

        XCTAssertEqual(catalog.installation(), .installed(modelDirectory: snapshot))
    }

    func testIndexReferencingMissingShardIsIncomplete() throws {
        let catalog = try makeCatalog()
        let snapshot = try makeSnapshot(for: catalog)
        try writeCompleteSnapshot(at: snapshot, indexedWeightFilename: "missing-shard.safetensors")

        XCTAssertEqual(
            catalog.installation(),
            .incomplete(missingFiles: ["missing-shard.safetensors"])
        )
    }

    private func makeCatalog() throws -> LocalTextModelCatalog {
        try LocalTextModelCatalog(
            applicationSupportDirectory: temporaryDirectory,
            bundleIdentifier: "catalog-tests"
        )
    }

    private func makeSnapshot(for catalog: LocalTextModelCatalog) throws -> URL {
        let repository = catalog.hubCacheDirectory
            .appendingPathComponent(
                "models--mlx-community--Qwen3-4B-Instruct-2507-4bit",
                isDirectory: true
            )
        let snapshot = repository
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(catalog.model.revision, isDirectory: true)
        try fileManager.createDirectory(at: snapshot, withIntermediateDirectories: true)
        return snapshot
    }

    private func writeCompleteSnapshot(
        at snapshot: URL,
        indexedWeightFilename: String
    ) throws {
        let ordinaryFiles = [
            "added_tokens.json",
            "chat_template.jinja",
            "config.json",
            "generation_config.json",
            "model.safetensors",
            "special_tokens_map.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "vocab.json",
        ]
        for filename in ordinaryFiles {
            try Data("x".utf8).write(to: snapshot.appendingPathComponent(filename))
        }

        let index = """
            {"weight_map":{"model.layers.0.weight":"\(indexedWeightFilename)"}}
            """
        try Data(index.utf8).write(
            to: snapshot.appendingPathComponent("model.safetensors.index.json")
        )
    }
}
