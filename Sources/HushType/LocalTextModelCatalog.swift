import Foundation

/// The single app-managed text model supported by the first local text backend.
struct LocalTextModelDescriptor: Equatable, Sendable {
    let repositoryID: String
    let revision: String
    let displayName: String
    let approximateDownloadBytes: Int64

    static let qwen3FourBit = LocalTextModelDescriptor(
        repositoryID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
        displayName: "Qwen3 4B Instruct (4-bit)",
        approximateDownloadBytes: 2_280_000_000
    )
}

enum LocalTextModelInstallation: Equatable, Sendable {
    case notInstalled
    case incomplete(missingFiles: [String])
    case installed(modelDirectory: URL)
}

/// Resolves and validates HushType's isolated Hugging Face cache for text models.
///
/// The cache layout is owned by `swift-huggingface`'s `HubCache`. The catalog
/// deliberately performs its own Application Support lookup because
/// `AppStoragePaths.applicationSupportRoot()` is private and its existing model
/// directory is reserved for Qwen3-ASR.
struct LocalTextModelCatalog: Sendable {
    static let fallbackBundleIdentifier = "com.felix.hushtype"
    static let directoryName = "text-models"

    let model: LocalTextModelDescriptor
    let rootDirectory: URL

    var hubCacheDirectory: URL {
        rootDirectory.appendingPathComponent("hub", isDirectory: true)
    }

    init(
        model: LocalTextModelDescriptor = .qwen3FourBit,
        applicationSupportDirectory: URL? = nil,
        bundleIdentifier: String = Self.fallbackBundleIdentifier
    ) throws {
        let applicationSupport: URL
        if let applicationSupportDirectory {
            applicationSupport = applicationSupportDirectory
        } else if let resolved = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            applicationSupport = resolved
        } else {
            throw CocoaError(.fileNoSuchFile)
        }

        self.model = model
        self.rootDirectory = applicationSupport
            .appendingPathComponent(
                bundleIdentifier,
                isDirectory: true
            )
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    func prepareStorage() throws {
        try FileManager.default.createDirectory(
            at: hubCacheDirectory,
            withIntermediateDirectories: true
        )

        var root = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    func installation() -> LocalTextModelInstallation {
        let repositoryDirectory = hubRepositoryDirectory()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: repositoryDirectory.path) else {
            return .notInstalled
        }

        guard let modelDirectory = currentSnapshotDirectory() else {
            return .incomplete(missingFiles: ["refs/\(model.revision)"])
        }

        let missingFiles = Self.requiredFileNames.filter { filename in
            !isNonEmptyFile(modelDirectory.appendingPathComponent(filename))
        }
        guard missingFiles.isEmpty else {
            return .incomplete(missingFiles: missingFiles)
        }

        if let missingShard = missingIndexedWeightShard(in: modelDirectory) {
            return .incomplete(missingFiles: [missingShard])
        }

        return .installed(modelDirectory: modelDirectory)
    }

    func currentSnapshotDirectory() -> URL? {
        let fileManager = FileManager.default
        let commit: String
        if Self.isCommitHash(model.revision) {
            commit = model.revision
        } else {
            let refURL = hubRepositoryDirectory()
                .appendingPathComponent("refs", isDirectory: true)
                .appendingPathComponent(model.revision)
            guard let resolved = try? String(contentsOf: refURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  Self.isSafePathComponent(resolved),
                  !resolved.isEmpty else {
                return nil
            }
            commit = resolved
        }

        let snapshot = hubRepositoryDirectory()
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(commit, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: snapshot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return snapshot
    }

    private func hubRepositoryDirectory() -> URL {
        let escapedRepository = model.repositoryID.replacingOccurrences(of: "/", with: "--")
        return hubCacheDirectory.appendingPathComponent(
            "models--\(escapedRepository)",
            isDirectory: true
        )
    }

    private func missingIndexedWeightShard(in modelDirectory: URL) -> String? {
        let indexURL = modelDirectory.appendingPathComponent("model.safetensors.index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = root["weight_map"] as? [String: String] else {
            return "model.safetensors.index.json"
        }

        for filename in Set(weightMap.values).sorted() {
            if !isNonEmptyFile(modelDirectory.appendingPathComponent(filename)) {
                return filename
            }
        }
        return nil
    }

    private func isNonEmptyFile(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }

    private static func isCommitHash(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
            }
    }

    /// `mlx-swift-lm` 3.31.3 resolves `*.safetensors`, `*.json`, and
    /// `*.jinja`. This fixed list verifies the complete filtered snapshot of
    /// the selected Qwen repository rather than accepting a single weight file.
    private static let requiredFileNames = [
        "added_tokens.json",
        "chat_template.jinja",
        "config.json",
        "generation_config.json",
        "model.safetensors",
        "model.safetensors.index.json",
        "special_tokens_map.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "vocab.json",
    ]
}
