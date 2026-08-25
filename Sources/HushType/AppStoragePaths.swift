import Foundation
import os

private let storageLog = Logger(subsystem: "com.felix.hushtype", category: "storage")

enum AppStoragePaths {
    private static let fallbackBundleIdentifier = "com.felix.hushtype"
    private static let modelDirectoryName = "qwen3-speech"
    private static let supportedASRModelIDs = [
        AppConfig.defaultModelId,
        AppConfig.balancedModelId,
        AppConfig.powerSavingModelId,
    ]

    /// Selects an app-owned Application Support directory before any model
    /// loader or downloader resolves its cache path. Explicit developer/user
    /// overrides continue to win.
    static func prepareModelStorage() {
        let environment = ProcessInfo.processInfo.environment
        if environment["QWEN3_CACHE_DIR"]?.isEmpty == false
            || environment["QWEN3_ASR_CACHE_DIR"]?.isEmpty == false {
            storageLog.info("Using explicit Qwen model storage override")
            return
        }

        do {
            let root = try applicationSupportRoot()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try migrateLegacyCacheIfNeeded(to: root.appendingPathComponent(modelDirectoryName, isDirectory: true))
            setenv("QWEN3_CACHE_DIR", root.path, 1)

            let modelRoot = root.appendingPathComponent(modelDirectoryName, isDirectory: true)
            if FileManager.default.fileExists(atPath: modelRoot.path) {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutableModelRoot = modelRoot
                try mutableModelRoot.setResourceValues(values)
            }
            storageLog.info("Model storage ready at \(modelRoot.path, privacy: .public)")
        } catch {
            // Keep the previous cache path usable if migration cannot complete.
            storageLog.error("Could not prepare app-owned model storage: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func applicationSupportRoot() throws -> URL {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    private static func migrateLegacyCacheIfNeeded(to destination: URL) throws {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let source = caches.appendingPathComponent(modelDirectoryName, isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path),
              source.standardizedFileURL != destination.standardizedFileURL else { return }

        let moved = try migrateSupportedASRCacheEntries(from: source, to: destination)
        if moved > 0 {
            storageLog.info("Moved \(moved) supported legacy ASR cache entries into Application Support")
        }
    }

    /// Moves only HushType's supported ASR cache entries. Both the current Hub
    /// layout (`models/<org>/<repo>`) and the downloader's legacy flat layout
    /// (`<org>_<repo>`) are retained verbatim. Existing destination entries
    /// are never merged or overwritten.
    @discardableResult
    static func migrateSupportedASRCacheEntries(from source: URL, to destination: URL) throws -> Int {
        let fileManager = FileManager.default
        var moved = 0

        for modelID in supportedASRModelIDs {
            for relativePath in cacheEntryRelativePaths(for: modelID) {
                let legacyEntry = relativePath.reduce(source) {
                    $0.appendingPathComponent($1, isDirectory: true)
                }
                guard fileManager.fileExists(atPath: legacyEntry.path) else { continue }

                let appEntry = relativePath.reduce(destination) {
                    $0.appendingPathComponent($1, isDirectory: true)
                }
                guard !fileManager.fileExists(atPath: appEntry.path) else { continue }

                try fileManager.createDirectory(
                    at: appEntry.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: legacyEntry, to: appEntry)
                removeEmptyAncestors(of: legacyEntry.deletingLastPathComponent(), stoppingAt: source)
                moved += 1
            }
        }

        return moved
    }

    private static func cacheEntryRelativePaths(for modelID: String) -> [[String]] {
        let components = modelID.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return [] }

        return [
            ["models", components[0], components[1]],
            [sanitizedCacheKey(for: modelID)],
        ]
    }

    /// Mirrors `HuggingFaceDownloader.sanitizedCacheKey(for:)` so this
    /// migration recognizes cache entries written by the dependency before
    /// HushType began using app-owned storage.
    private static func sanitizedCacheKey(for modelID: String) -> String {
        let replaced = modelID.replacingOccurrences(of: "/", with: "_")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let filtered = String(String.UnicodeScalarView(replaced.unicodeScalars.map {
            allowed.contains($0) ? $0 : "_"
        }))
        let cleaned = filtered.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "model" : cleaned
    }

    private static func removeEmptyAncestors(of directory: URL, stoppingAt source: URL) {
        let fileManager = FileManager.default
        let root = source.standardizedFileURL
        var candidate = directory.standardizedFileURL

        while candidate == root || candidate.path.hasPrefix(root.path + "/") {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: candidate.path),
                  contents.isEmpty else { return }
            try? fileManager.removeItem(at: candidate)

            if candidate == root { return }
            candidate.deleteLastPathComponent()
        }
    }
}
