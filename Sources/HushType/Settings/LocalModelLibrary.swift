import AudioCommon
import Combine
import Foundation
import os

private let modelLibraryLog = Logger(
    subsystem: "com.felix.hushtype",
    category: "model-library"
)

struct LocalModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
    let titleFallback: String
    let detailKey: String
    let detailFallback: String
    let weightBytes: Int64?

    var title: String { L10n.string(titleKey, fallback: titleFallback) }
    var detail: String { L10n.string(detailKey, fallback: detailFallback) }
}

enum LocalModelCatalog {
    private struct InstallReceipt: Codable {
        let modelID: String
        let fileSizes: [String: Int64]
    }

    static let models: [LocalModelDescriptor] = [
        LocalModelDescriptor(
            id: AppConfig.defaultModelId,
            titleKey: "settings.model.qwen_quality",
            titleFallback: "Qwen3-ASR 1.7B 8-bit (quality)",
            detailKey: "settings.model.library.quality_detail",
            detailFallback: "Higher Chinese accuracy · about 2.46 GB",
            weightBytes: QwenModelDownloadSizing.defaultWeightBytes
        ),
        LocalModelDescriptor(
            id: AppConfig.balancedModelId,
            titleKey: "settings.model.balanced",
            titleFallback: "Qwen3-ASR 1.7B 4-bit (balanced)",
            detailKey: "settings.model.library.balanced_detail",
            detailFallback: "Quality and memory balance · about 2.23 GB",
            weightBytes: QwenModelDownloadSizing.balancedWeightBytes
        ),
        LocalModelDescriptor(
            id: AppConfig.powerSavingModelId,
            titleKey: "settings.model.power_saving",
            titleFallback: "Qwen3-ASR 0.6B 4-bit (power saving)",
            detailKey: "settings.model.library.power_saving_detail",
            detailFallback: "Lower memory and power use · about 708 MB",
            weightBytes: QwenModelDownloadSizing.powerSavingWeightBytes
        ),
    ]

    private static let requiredFiles = [
        "config.json",
        "vocab.json",
        "merges.txt",
        "tokenizer_config.json",
    ]

    static func descriptor(for modelID: String) -> LocalModelDescriptor? {
        models.first { $0.id == modelID }
    }

    static func isInstalled(_ model: LocalModelDescriptor) -> Bool {
        cacheDirectories(for: model.id).contains { isComplete(model, at: $0) }
    }

    static func cacheDirectoryForDownload(modelID: String) throws -> URL {
        return try HuggingFaceDownloader.getCacheDirectory(for: modelID)
    }

    /// Clears only snapshots that have already reached an explicit
    /// "download finished but files are incomplete" failure. A normal stop
    /// remains resumable; the failed-state retry deliberately starts clean so
    /// Hub metadata cannot immediately reproduce the same incomplete result.
    @discardableResult
    static func moveIncompleteCachesToTrash(for model: LocalModelDescriptor) throws -> Int {
        let fileManager = FileManager.default
        let base = modelCacheBaseDirectory().standardizedFileURL
        let allowedPrefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        var removed = 0

        for location in cacheDirectories(for: model.id)
        where fileManager.fileExists(atPath: location.path) && !isComplete(model, at: location) {
            guard location.standardizedFileURL.path.hasPrefix(allowedPrefix) else { continue }
            var trashedURL: NSURL?
            try fileManager.trashItem(at: location, resultingItemURL: &trashedURL)
            removed += 1
        }
        return removed
    }

    static func writeInstallReceipt(for model: LocalModelDescriptor, directory: URL) throws {
        let fileSizes = try modelFileSizes(at: directory)
        let receipt = InstallReceipt(modelID: model.id, fileSizes: fileSizes)
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: directory.appendingPathComponent(".hushtype-install.json"), options: .atomic)
    }

    static func moveCachesToTrash(modelID: String) throws {
        let fileManager = FileManager.default
        let base = modelCacheBaseDirectory().standardizedFileURL
        let allowedPrefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let locations = cacheDirectories(for: modelID)
        for location in locations where fileManager.fileExists(atPath: location.path) {
            guard location.standardizedFileURL.path.hasPrefix(allowedPrefix) else { continue }
            var trashedURL: NSURL?
            try fileManager.trashItem(at: location, resultingItemURL: &trashedURL)
        }
    }

    private static func isComplete(_ model: LocalModelDescriptor, at directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard requiredFiles.allSatisfy({ fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
            return false
        }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        let weightFiles = contents.filter { $0.pathExtension == "safetensors" }
        guard !weightFiles.isEmpty else { return false }

        if let receiptData = try? Data(contentsOf: directory.appendingPathComponent(".hushtype-install.json")),
           let receipt = try? JSONDecoder().decode(InstallReceipt.self, from: receiptData),
           receipt.modelID == model.id,
           let currentSizes = try? modelFileSizes(at: directory) {
            return receipt.fileSizes == currentSizes
        }

        let metadataDirectory = directory
            .appendingPathComponent(".cache/huggingface/download", isDirectory: true)
        let modelFiles = requiredFiles + weightFiles.map(\.lastPathComponent)
        let hasSnapshotMetadata = modelFiles.allSatisfy { fileName in
            fileManager.fileExists(
                atPath: metadataDirectory.appendingPathComponent(fileName + ".metadata").path
            )
        }
        if hasSnapshotMetadata { return true }

        // Backward compatibility for the old flat cache layout, which predates
        // Hub metadata. The exact known weight size is used only for migration.
        guard let expectedBytes = model.weightBytes else { return false }
        let actualBytes = weightFiles.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
        return actualBytes == expectedBytes
    }

    private static func modelFileSizes(at directory: URL) throws -> [String: Int64] {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let relevant = contents.filter {
            requiredFiles.contains($0.lastPathComponent) || $0.pathExtension == "safetensors"
        }
        return try Dictionary(uniqueKeysWithValues: relevant.map { url in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return (url.lastPathComponent, Int64(size))
        })
    }

    private static func cacheDirectories(for modelID: String) -> [URL] {
        let base = modelCacheBaseDirectory()
        let components = modelID.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return [] }
        return [
            base.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(components[0], isDirectory: true)
                .appendingPathComponent(components[1], isDirectory: true),
            base.appendingPathComponent(HuggingFaceDownloader.sanitizedCacheKey(for: modelID), isDirectory: true),
        ]
    }

    private static func modelCacheBaseDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["QWEN3_CACHE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("qwen3-speech", isDirectory: true)
        }
        if let override = environment["QWEN3_ASR_CACHE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("qwen3-speech", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qwen3-speech", isDirectory: true)
    }

}

enum LocalModelInstallState: Equatable {
    case notInstalled
    /// Checking reusable files before an install. This is not a network
    /// transfer, so it must never offer a misleading "Stop Download" action.
    case preparing
    case downloading(ModelLoadProgress)
    case verifying
    case installed
    case deleting
    case failed(String)
}

@MainActor
final class LocalModelLibrary: ObservableObject {
    @Published private(set) var states: [String: LocalModelInstallState] = [:]
    @Published private(set) var activeInstallModelID: String?
    @Published private(set) var engineLoadingModelID: String?
    @Published private(set) var isEngineLoading = false

    private var installTask: Task<Void, Never>?
    private var downloadMonitor: ModelDownloadMonitor?

    init() {
        refresh()
    }

    var installedModels: [LocalModelDescriptor] {
        LocalModelCatalog.models.filter { states[$0.id] == .installed }
    }

    func state(for model: LocalModelDescriptor) -> LocalModelInstallState {
        states[model.id] ?? .notInstalled
    }

    func refresh() {
        for model in LocalModelCatalog.models
        where model.id != activeInstallModelID && model.id != engineLoadingModelID {
            states[model.id] = LocalModelCatalog.isInstalled(model) ? .installed : .notInstalled
        }
    }

    func updateEngineState(
        _ appState: StatusBarController.State,
        loadingModelID: String?,
        loadedModelID: String?
    ) {
        switch appState {
        case .loading, .loadingDetailed:
            isEngineLoading = true
        default:
            isEngineLoading = false
        }
        let previousLoadingModelID = engineLoadingModelID
        engineLoadingModelID = loadingModelID

        if let previousLoadingModelID, previousLoadingModelID != loadingModelID,
           previousLoadingModelID != activeInstallModelID,
           let descriptor = LocalModelCatalog.descriptor(for: previousLoadingModelID) {
            states[previousLoadingModelID] = LocalModelCatalog.isInstalled(descriptor) ? .installed : .notInstalled
        }

        guard let loadingModelID,
              loadingModelID != activeInstallModelID,
              LocalModelCatalog.descriptor(for: loadingModelID) != nil else {
            if let loadedModelID,
               LocalModelCatalog.descriptor(for: loadedModelID) != nil {
                states[loadedModelID] = .installed
            }
            return
        }

        switch appState {
        case .loading:
            // Legacy cumulative progress is not evidence of a network
            // transfer. ModelDownloadMonitor is the sole download signal.
            states[loadingModelID] = .preparing
        case let .loadingDetailed(progress):
            switch progress.phase {
            case .checkingLocalModel:
                // The picker only permits installed models. Keep it installed
                // while the engine verifies and maps it into memory instead of
                // presenting the model-library download UI.
                if let descriptor = LocalModelCatalog.descriptor(for: loadingModelID) {
                    states[loadingModelID] = LocalModelCatalog.isInstalled(descriptor) ? .installed : .preparing
                }
            case .downloading:
                states[loadingModelID] = .downloading(progress)
            case .verifying, .loadingTokenizer, .loadingAudio, .loadingText, .ready:
                if let descriptor = LocalModelCatalog.descriptor(for: loadingModelID) {
                    states[loadingModelID] = LocalModelCatalog.isInstalled(descriptor) ? .installed : .verifying
                }
            }
        default:
            break
        }
    }

    func install(_ model: LocalModelDescriptor) {
        guard activeInstallModelID == nil,
              !isEngineLoading,
              state(for: model) != .installed else { return }
        let isRetryingIncompleteInstall: Bool
        if case .failed = state(for: model) {
            isRetryingIncompleteInstall = true
        } else {
            isRetryingIncompleteInstall = false
        }
        activeInstallModelID = model.id
        states[model.id] = .preparing
        modelLibraryLog.info(
            "Install requested model=\(model.id, privacy: .public) cleanRetry=\(isRetryingIncompleteInstall, privacy: .public)"
        )

        let monitor = ModelDownloadMonitor(totalBytes: model.weightBytes) { [weak self] progress in
            Task { @MainActor in
                guard let self, self.activeInstallModelID == model.id else { return }
                self.states[model.id] = .downloading(progress)
            }
        }
        downloadMonitor = monitor
        monitor.start()

        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                if isRetryingIncompleteInstall {
                    let removed = try LocalModelCatalog.moveIncompleteCachesToTrash(for: model)
                    modelLibraryLog.info(
                        "Prepared clean retry model=\(model.id, privacy: .public) trashedIncompleteCaches=\(removed, privacy: .public)"
                    )
                }
                let directory = try LocalModelCatalog.cacheDirectoryForDownload(modelID: model.id)
                try await HuggingFaceDownloader.downloadWeights(
                    modelId: model.id,
                    to: directory,
                    additionalFiles: ["vocab.json", "merges.txt", "tokenizer_config.json"],
                    progressHandler: { _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.activeInstallModelID == model.id else { return }
                            // The dependency reports a cumulative fraction
                            // while it may simply reuse its cache. The temp
                            // file monitor above is the authoritative signal
                            // for a real network download and is the only path
                            // that exposes a stop-download action.
                            if case .downloading = self.states[model.id] { return }
                            self.states[model.id] = .preparing
                        }
                    }
                )
                try Task.checkCancellation()
                monitor.stop()
                downloadMonitor = nil
                states[model.id] = .verifying
                guard LocalModelCatalog.isInstalled(model) else {
                    throw LocalModelLibraryError.incompleteInstall
                }
                try LocalModelCatalog.writeInstallReceipt(for: model, directory: directory)
                states[model.id] = .installed
                modelLibraryLog.info("Install completed model=\(model.id, privacy: .public)")
            } catch {
                monitor.stop()
                downloadMonitor = nil
                if Task.isCancelled {
                    states[model.id] = .notInstalled
                    modelLibraryLog.info("Install stopped model=\(model.id, privacy: .public)")
                } else {
                    states[model.id] = .failed(error.localizedDescription)
                    modelLibraryLog.error(
                        "Install failed model=\(model.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            activeInstallModelID = nil
            installTask = nil
        }
    }

    func stopInstall(_ model: LocalModelDescriptor) {
        guard activeInstallModelID == model.id else { return }
        installTask?.cancel()
        downloadMonitor?.stop()
    }

    func delete(_ model: LocalModelDescriptor, loadedModelID: String?) {
        guard model.id != loadedModelID, activeInstallModelID != model.id else { return }
        states[model.id] = .deleting
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try LocalModelCatalog.moveCachesToTrash(modelID: model.id)
                }.value
                states[model.id] = .notInstalled
            } catch {
                states[model.id] = .failed(error.localizedDescription)
            }
        }
    }
}

private enum LocalModelLibraryError: LocalizedError {
    case incompleteInstall

    var errorDescription: String? {
        L10n.string(
            "settings.model.library.incomplete_error",
            fallback: "The download finished, but the model files are incomplete. Try installing again."
        )
    }
}
