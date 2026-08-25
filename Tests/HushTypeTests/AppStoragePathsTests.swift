import Foundation
import XCTest
@testable import HushType

final class AppStoragePathsTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("HushType-AppStoragePathsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? fileManager.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testMigratesOnlySupportedASRLayoutsAndDoesNotOverwriteExistingDestination() throws {
        let source = temporaryDirectory.appendingPathComponent("legacy", isDirectory: true)
        let destination = temporaryDirectory.appendingPathComponent("app-owned", isDirectory: true)

        let defaultHub = hubEntry(for: AppConfig.defaultModelId, under: source)
        let balancedHub = hubEntry(for: AppConfig.balancedModelId, under: source)
        let powerSavingFlat = flatEntry(for: AppConfig.powerSavingModelId, under: source)
        let unrelatedHub = source.appendingPathComponent("models/aufklarer/Qwen3-TTS-0.6B-MLX-4bit", isDirectory: true)
        let unrelatedFlat = source.appendingPathComponent("aufklarer_Qwen3.5-0.8B-Chat-MLX", isDirectory: true)
        let existingDefaultDestination = hubEntry(for: AppConfig.defaultModelId, under: destination)

        try writeMarker("legacy default", at: defaultHub)
        try writeMarker("legacy balanced", at: balancedHub)
        try writeMarker("legacy power saving", at: powerSavingFlat)
        try writeMarker("unrelated hub", at: unrelatedHub)
        try writeMarker("unrelated flat", at: unrelatedFlat)
        try writeMarker("app-owned default", at: existingDefaultDestination)

        XCTAssertEqual(try AppStoragePaths.migrateSupportedASRCacheEntries(from: source, to: destination), 2)

        XCTAssertTrue(fileManager.fileExists(atPath: defaultHub.path))
        XCTAssertEqual(
            try String(contentsOf: existingDefaultDestination.appendingPathComponent("marker"), encoding: .utf8),
            "app-owned default"
        )
        XCTAssertFalse(fileManager.fileExists(atPath: balancedHub.path))
        XCTAssertFalse(fileManager.fileExists(atPath: powerSavingFlat.path))
        XCTAssertEqual(
            try String(contentsOf: hubEntry(for: AppConfig.balancedModelId, under: destination).appendingPathComponent("marker"), encoding: .utf8),
            "legacy balanced"
        )
        XCTAssertEqual(
            try String(contentsOf: flatEntry(for: AppConfig.powerSavingModelId, under: destination).appendingPathComponent("marker"), encoding: .utf8),
            "legacy power saving"
        )
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedHub.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedFlat.path))
    }

    func testRemovesOnlyEmptyLegacyParentsAfterMovingEntry() throws {
        let source = temporaryDirectory.appendingPathComponent("legacy", isDirectory: true)
        let destination = temporaryDirectory.appendingPathComponent("app-owned", isDirectory: true)
        let sourceEntry = hubEntry(for: AppConfig.balancedModelId, under: source)

        try writeMarker("legacy balanced", at: sourceEntry)

        XCTAssertEqual(try AppStoragePaths.migrateSupportedASRCacheEntries(from: source, to: destination), 1)

        XCTAssertFalse(fileManager.fileExists(atPath: source.path))
        XCTAssertTrue(fileManager.fileExists(atPath: hubEntry(for: AppConfig.balancedModelId, under: destination).path))
    }

    private func hubEntry(for modelID: String, under root: URL) -> URL {
        let parts = modelID.split(separator: "/", maxSplits: 1)
        return root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(String(parts[0]), isDirectory: true)
            .appendingPathComponent(String(parts[1]), isDirectory: true)
    }

    private func flatEntry(for modelID: String, under root: URL) -> URL {
        root.appendingPathComponent(modelID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    private func writeMarker(_ marker: String, at directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try marker.write(to: directory.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
    }
}
