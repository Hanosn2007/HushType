import Foundation
import Qwen3ASR
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "transcription")

// MARK: - Protocol

protocol TranscriptionEngine: AnyObject {
    var isLoaded: Bool { get }
    var maxSampleCount: Int? { get }
    func load(progressHandler: ((Double, String) -> Void)?) async throws
    func transcribe(audio: [Float], language: String?) async throws -> String
}

extension TranscriptionEngine {
    var maxSampleCount: Int? { nil }
}

/// The app-owned model-loading state. Qwen3's public loader only exposes a
/// cumulative fraction and a human-readable description, so the app keeps a
/// richer state alongside that legacy callback for the status-bar UI.
struct ModelLoadProgress: Equatable, Sendable {
    enum Phase: String, Sendable {
        /// The loader is checking the app-owned cache and preparing a load.
        /// This deliberately makes no network claim: a cached model reaches
        /// the next phases without downloading anything.
        case checkingLocalModel
        case downloading
        case verifying
        case loadingTokenizer
        case loadingAudio
        case loadingText
        case ready
    }

    let phase: Phase
    /// Phase progress. For `.downloading`, this is the current attempt's
    /// bytes / total bytes, never a retry-accumulated fraction.
    let fraction: Double
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    let bytesPerSecond: Double?
    let eta: TimeInterval?

    init(
        phase: Phase,
        fraction: Double,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        bytesPerSecond: Double? = nil,
        eta: TimeInterval? = nil
    ) {
        self.phase = phase
        self.fraction = min(max(fraction, 0), 1)
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.eta = eta
    }
}

/// Sizes of the model weight files observed from the Hugging Face HEAD
/// metadata for the model choices shipped by HushType. The Hub progress
/// object is file-weighted rather than byte-weighted, so these values are
/// needed to make the visible download percentage and ETA meaningful.
enum QwenModelDownloadSizing {
    static let powerSavingWeightBytes: Int64 = 708_236_945
    static let balancedWeightBytes: Int64 = 2_225_411_512
    static let defaultWeightBytes: Int64 = 2_463_307_541

    static func weightBytes(for modelID: String) -> Int64? {
        let lowercased = modelID.lowercased()
        if lowercased.contains("0.6b") { return powerSavingWeightBytes }
        if lowercased.contains("1.7b") && lowercased.contains("4bit") { return balancedWeightBytes }
        if lowercased.contains("1.7b") { return defaultWeightBytes }
        return nil
    }
}

/// Observes Foundation's temporary download file without taking ownership of
/// the speech-swift downloader. The Hub API moves the completed file out of
/// `/tmp`, so the monitor deliberately reports the current temp-file attempt;
/// when a retry swaps paths, the byte/rate sample is reset instead of adding
/// the new attempt to the old one.
final class ModelDownloadMonitor: @unchecked Sendable {
    private struct Candidate {
        let url: URL
        let bytes: Int64
        let modifiedAt: Date
    }

    private let totalBytes: Int64?
    private let startedAt: Date
    private let handler: (ModelLoadProgress) -> Void
    private let lifecycleLock = NSLock()
    private var task: Task<Void, Never>?
    private var stopped = false
    private var currentPath: String?
    private var previousBytes: Int64 = 0
    private var previousSampleAt = Date()
    private var latestSpeed: Double?
    private var latestBytes: Int64 = 0
    private var sawDownload = false
    private var emittedVerification = false

    init(
        totalBytes: Int64?,
        startedAt: Date = Date(),
        handler: @escaping (ModelLoadProgress) -> Void
    ) {
        self.totalBytes = totalBytes
        self.startedAt = startedAt
        self.handler = handler
    }

    func start() {
        lifecycleLock.lock()
        guard task == nil, !stopped else {
            lifecycleLock.unlock()
            return
        }
        let newTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.sample()
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    break
                }
            }
        }
        task = newTask
        lifecycleLock.unlock()
    }

    func stop() {
        lifecycleLock.lock()
        stopped = true
        let runningTask = task
        task = nil
        lifecycleLock.unlock()
        runningTask?.cancel()
    }

    private func sample() {
        let candidate = newestCandidate()
        guard let candidate else {
            // The Hub moves a completed URLSession temp file into its cache.
            // Do not infer verification from a transient retry gap; only a
            // nearly complete attempt is a genuine download-to-verification
            // boundary.
            if sawDownload,
               !emittedVerification,
               let totalBytes,
               latestBytes >= Int64(Double(totalBytes) * 0.99) {
                emittedVerification = true
                handler(ModelLoadProgress(
                    phase: .verifying,
                    fraction: 1,
                    downloadedBytes: totalBytes,
                    totalBytes: totalBytes,
                    bytesPerSecond: latestSpeed,
                    eta: nil
                ))
            }
            return
        }

        sawDownload = true
        let now = Date()
        if currentPath != candidate.url.path {
            // A retry creates a different CFNetwork temp file. Resetting the
            // sample avoids both a false speed spike and cumulative progress.
            currentPath = candidate.url.path
            previousBytes = candidate.bytes
            previousSampleAt = now
            latestSpeed = nil
        } else {
            let elapsed = now.timeIntervalSince(previousSampleAt)
            let delta = candidate.bytes - previousBytes
            if delta >= 0, elapsed > 0, delta > 0 {
                latestSpeed = Double(delta) / elapsed
            }
            previousBytes = candidate.bytes
            previousSampleAt = now
        }

        latestBytes = max(0, candidate.bytes)
        let fraction: Double
        let eta: TimeInterval?
        if let totalBytes, totalBytes > 0 {
            fraction = min(Double(latestBytes) / Double(totalBytes), 1)
            if let latestSpeed, latestSpeed > 0 {
                eta = Double(max(0, totalBytes - latestBytes)) / latestSpeed
            } else {
                eta = nil
            }
        } else {
            fraction = 0
            eta = nil
        }

        handler(ModelLoadProgress(
            phase: .downloading,
            fraction: fraction,
            downloadedBytes: latestBytes,
            totalBytes: totalBytes,
            bytesPerSecond: latestSpeed,
            eta: eta
        ))
    }

    private func newestCandidate() -> Candidate? {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates: [Candidate] = urls.compactMap { url in
            guard url.lastPathComponent.hasPrefix("CFNetworkDownload_") else { return nil }
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
            ]), values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0 else { return nil }

            let modifiedAt = values.contentModificationDate ?? values.creationDate ?? .distantPast
            // Avoid adopting an unrelated stale temporary file from a prior
            // app operation while allowing a small filesystem clock skew.
            guard modifiedAt >= startedAt.addingTimeInterval(-5) else { return nil }
            return Candidate(url: url, bytes: Int64(size), modifiedAt: modifiedAt)
        }

        return candidates.max {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
            return $0.url.path < $1.url.path
        }
    }
}

enum TranscriptionError: Error, Equatable, Sendable {
    case noKey
    case auth
    case permissionDenied(provider: String)
    case rateLimited(provider: String)
    case network
    case timeout
    case payloadTooLarge
    case malformedResponse
    case safetyBlocked
}

// MARK: - Qwen3 Implementation

final class Qwen3TranscriptionEngine: TranscriptionEngine {
    private let loadLock = NSLock()
    private var model: Qwen3ASRModel?
    private var loadedModelIdentifier: String?
    private var inFlightLoad: Task<Qwen3ASRModel, Error>?
    private var inFlightModelIdentifier: String?
    private var inFlightGeneration: UInt = 0
    private var loadGeneration: UInt = 0
    private var progressHandlers: [UUID: (Double, String) -> Void] = [:]
    private var latestProgress: (Double, String)?
    private var detailProgressHandlers: [UUID: (ModelLoadProgress) -> Void] = [:]
    private var latestDetailProgress: ModelLoadProgress?
    private var downloadMonitor: ModelDownloadMonitor?

    private struct PreparedLoad {
        let task: Task<Qwen3ASRModel, Error>
        let generation: UInt
        let modelIdentifier: String
        let replayProgress: (Double, String)?
        let replayDetailProgress: ModelLoadProgress?
    }

    var isLoaded: Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        return model != nil
    }

    /// Read-only handle for the live-caption pipeline. Returns the loaded
    /// model instance so `LiveCaptionManager` can call `transcribe()` directly
    /// without going through the dictation post-processing chain.
    var loadedModel: Qwen3ASRModel? {
        loadLock.lock()
        defer { loadLock.unlock() }
        return model
    }

    /// The model actually resident in memory. This intentionally does not
    /// mirror the model preference, which can change before the next load.
    var loadedModelID: String? {
        loadLock.lock()
        defer { loadLock.unlock() }
        return loadedModelIdentifier
    }

    var loadingModelID: String? {
        loadLock.lock()
        defer { loadLock.unlock() }
        return inFlightModelIdentifier
    }

    func load(progressHandler: ((Double, String) -> Void)? = nil) async throws {
        try await load(
            progressHandler: progressHandler,
            detailProgressHandler: nil
        )
    }

    /// Rich progress surface for the app status bar. The protocol-compatible
    /// callback above remains available to caption and legacy call sites.
    func load(detailProgressHandler: ((ModelLoadProgress) -> Void)? = nil) async throws {
        try await load(
            progressHandler: nil,
            detailProgressHandler: detailProgressHandler
        )
    }

    private func load(
        progressHandler: ((Double, String) -> Void)?,
        detailProgressHandler: ((ModelLoadProgress) -> Void)?
    ) async throws {
        let handlerID = progressHandler.map { _ in UUID() }
        let detailHandlerID = detailProgressHandler.map { _ in UUID() }
        guard let prepared = prepareLoad(
            handlerID: handlerID,
            progressHandler: progressHandler,
            detailHandlerID: detailHandlerID,
            detailProgressHandler: detailProgressHandler
        ) else { return }

        if let replayProgress = prepared.replayProgress, let progressHandler {
            progressHandler(replayProgress.0, replayProgress.1)
        }
        if let replayDetailProgress = prepared.replayDetailProgress, let detailProgressHandler {
            detailProgressHandler(replayDetailProgress)
        }

        do {
            let loadedModel = try await prepared.task.value
            guard commitLoadedModel(
                loadedModel,
                generation: prepared.generation,
                modelIdentifier: prepared.modelIdentifier,
                handlerID: handlerID,
                detailHandlerID: detailHandlerID
            ) else {
                throw CancellationError()
            }
            log.info("Model loaded successfully")
        } catch {
            finishFailedLoad(
                generation: prepared.generation,
                handlerID: handlerID,
                detailHandlerID: detailHandlerID
            )
            throw error
        }
    }

    /// Keep NSLock acquisition in a synchronous helper. Swift warns against
    /// directly holding even a short-lived mutex in an async function because
    /// suspension while locked would deadlock; this helper cannot suspend.
    private func prepareLoad(
        handlerID: UUID?,
        progressHandler: ((Double, String) -> Void)?,
        detailHandlerID: UUID?,
        detailProgressHandler: ((ModelLoadProgress) -> Void)?
    ) -> PreparedLoad? {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard model == nil else { return nil }

        if let handlerID, let progressHandler {
            progressHandlers[handlerID] = progressHandler
        }
        if let detailHandlerID, let detailProgressHandler {
            detailProgressHandlers[detailHandlerID] = detailProgressHandler
        }
        let replayProgress = latestProgress
        let replayDetailProgress = latestDetailProgress

        if let existing = inFlightLoad {
            guard let inFlightModelIdentifier else { return nil }
            return PreparedLoad(
                task: existing,
                generation: inFlightGeneration,
                modelIdentifier: inFlightModelIdentifier,
                replayProgress: replayProgress,
                replayDetailProgress: replayDetailProgress
            )
        }

        let modelId = AppConfig.shared.modelId
        let generation = loadGeneration
        inFlightGeneration = generation
        inFlightModelIdentifier = modelId
        let initialDetailProgress = ModelLoadProgress(
            phase: .checkingLocalModel,
            fraction: 0,
            totalBytes: QwenModelDownloadSizing.weightBytes(for: modelId)
        )
        latestProgress = (0, "Connecting to model repository...")
        latestDetailProgress = initialDetailProgress
        let monitor = ModelDownloadMonitor(
            totalBytes: initialDetailProgress.totalBytes,
            handler: { [weak self] progress in
                self?.publishDetailedProgress(progress, generation: generation)
            }
        )
        downloadMonitor = monitor
        log.info("Loading model: \(modelId)")
        let task = Task { [weak self, monitor] in
            monitor.start()
            defer { monitor.stop() }
            return try await Qwen3ASRModel.fromPretrained(
                modelId: modelId,
                progressHandler: { progress, description in
                    self?.publishLoadProgress(
                        progress,
                        description: description,
                        generation: generation
                    )
                }
            )
        }
        inFlightLoad = task
        return PreparedLoad(
            task: task,
            generation: generation,
            modelIdentifier: modelId,
            replayProgress: replayProgress,
            replayDetailProgress: replayDetailProgress ?? initialDetailProgress
        )
    }

    private func commitLoadedModel(
        _ loadedModel: Qwen3ASRModel,
        generation: UInt,
        modelIdentifier: String,
        handlerID: UUID?,
        detailHandlerID: UUID?
    ) -> Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard generation == loadGeneration else {
            if let handlerID { progressHandlers.removeValue(forKey: handlerID) }
            if let detailHandlerID { detailProgressHandlers.removeValue(forKey: detailHandlerID) }
            return false
        }
        model = loadedModel
        loadedModelIdentifier = modelIdentifier
        if inFlightLoad != nil && inFlightGeneration == generation {
            inFlightLoad = nil
            inFlightModelIdentifier = nil
            progressHandlers.removeAll()
            detailProgressHandlers.removeAll()
            latestProgress = nil
            latestDetailProgress = nil
            downloadMonitor = nil
        } else if let handlerID {
            progressHandlers.removeValue(forKey: handlerID)
            if let detailHandlerID { detailProgressHandlers.removeValue(forKey: detailHandlerID) }
        }
        return true
    }

    private func finishFailedLoad(
        generation: UInt,
        handlerID: UUID?,
        detailHandlerID: UUID?
    ) {
        loadLock.lock()
        defer { loadLock.unlock() }
        if inFlightLoad != nil && inFlightGeneration == generation {
            inFlightLoad = nil
            inFlightModelIdentifier = nil
            progressHandlers.removeAll()
            detailProgressHandlers.removeAll()
            latestProgress = nil
            latestDetailProgress = nil
            downloadMonitor = nil
        } else if let handlerID {
            progressHandlers.removeValue(forKey: handlerID)
            if let detailHandlerID { detailProgressHandlers.removeValue(forKey: detailHandlerID) }
        }
    }

    private func publishLoadProgress(
        _ progress: Double,
        description: String,
        generation: UInt
    ) {
        loadLock.lock()
        guard inFlightLoad != nil && inFlightGeneration == generation else {
            loadLock.unlock()
            return
        }
        latestProgress = (progress, description)
        let mapped = mapDetailProgress(progress: progress, description: description)
        if mapped.phase != .checkingLocalModel && mapped.phase != .downloading {
            downloadMonitor?.stop()
        }
        var detailEvents: [ModelLoadProgress] = []
        if mapped.phase == .loadingTokenizer,
           latestDetailProgress?.phase == .downloading {
            let verification = ModelLoadProgress(
                phase: .verifying,
                fraction: 1,
                downloadedBytes: latestDetailProgress?.downloadedBytes,
                totalBytes: latestDetailProgress?.totalBytes,
                bytesPerSecond: latestDetailProgress?.bytesPerSecond
            )
            detailEvents.append(verification)
        }
        latestDetailProgress = mapped
        detailEvents.append(mapped)
        let handlers = Array(progressHandlers.values)
        let detailHandlers = Array(detailProgressHandlers.values)
        loadLock.unlock()
        for handler in handlers {
            handler(progress, description)
        }
        for detail in detailEvents {
            for handler in detailHandlers {
                handler(detail)
            }
        }
    }

    private func publishDetailedProgress(
        _ progress: ModelLoadProgress,
        generation: UInt
    ) {
        loadLock.lock()
        guard inFlightLoad != nil && inFlightGeneration == generation else {
            loadLock.unlock()
            return
        }
        latestDetailProgress = progress
        let detailHandlers = Array(detailProgressHandlers.values)
        let legacyHandlers = Array(progressHandlers.values)
        loadLock.unlock()

        // Keep the legacy callback useful for Live Caption while the richer
        // callback drives the status bar with byte-accurate values.
        let legacyDescription = legacyDescription(for: progress.phase)
        for handler in legacyHandlers {
            handler(progress.fraction, legacyDescription)
        }
        for handler in detailHandlers {
            handler(progress)
        }
    }

    private func mapDetailProgress(
        progress: Double,
        description: String
    ) -> ModelLoadProgress {
        let lowercased = description.lowercased()
        if lowercased.contains("tokenizer") {
            return ModelLoadProgress(phase: .loadingTokenizer, fraction: 0.80)
        }
        if lowercased.contains("audio encoder") {
            return ModelLoadProgress(phase: .loadingAudio, fraction: 0.85)
        }
        if lowercased.contains("text decoder") {
            return ModelLoadProgress(phase: .loadingText, fraction: 0.92)
        }
        if lowercased.contains("ready") {
            return ModelLoadProgress(phase: .ready, fraction: 1)
        }
        if lowercased.contains("downloading weights") {
            if let latestDetailProgress,
               latestDetailProgress.phase == .downloading {
                return latestDetailProgress
            }
            // The public loader uses this text both when it reuses its cache
            // and when it fetches weights. Only our temporary-file monitor
            // proves that bytes are actually arriving from the network, so do
            // not turn this into a cancellable download prematurely.
            return ModelLoadProgress(
                phase: .checkingLocalModel,
                fraction: 0,
                totalBytes: QwenModelDownloadSizing.weightBytes(for: AppConfig.shared.modelId)
            )
        }
        return ModelLoadProgress(
            phase: .checkingLocalModel,
            fraction: 0,
            totalBytes: QwenModelDownloadSizing.weightBytes(for: AppConfig.shared.modelId)
        )
    }

    private func legacyDescription(for phase: ModelLoadProgress.Phase) -> String {
        switch phase {
        case .checkingLocalModel: return "Checking local model files..."
        case .downloading: return "Downloading weights..."
        case .verifying: return "Verifying downloaded model..."
        case .loadingTokenizer: return "Loading tokenizer..."
        case .loadingAudio: return "Loading audio encoder weights..."
        case .loadingText: return "Loading text decoder weights..."
        case .ready: return "Ready"
        }
    }

    func transcribe(audio: [Float], language: String?) async throws -> String {
        guard let model = loadedModel else {
            log.error("Model not loaded")
            return ""
        }

        guard !audio.isEmpty else {
            log.warning("Empty audio buffer")
            return ""
        }

        let duration = Double(audio.count) / 16000.0
        log.info("Transcribing \(String(format: "%.1f", duration))s of audio...")

        let startTime = CFAbsoluteTimeGetCurrent()

        let rawText = model.transcribe(
            audio: audio,
            sampleRate: 16000,
            language: language
        )

        let asrElapsed = CFAbsoluteTimeGetCurrent() - startTime
        log.info("Raw transcription (\(String(format: "%.2f", asrElapsed))s): \(rawText)")

        let finalText = DictationPostProcessor.apply(rawText)

        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
        let inCh = rawText.count
        let outCh = finalText.count
        let asrMs = Int(asrElapsed * 1000)
        let totalMs = Int(totalElapsed * 1000)

        log.info("timings asr=\(asrMs, privacy: .public)ms total=\(totalMs, privacy: .public)ms in=\(inCh, privacy: .public)ch out=\(outCh, privacy: .public)ch")

        return finalText
    }

    func unload() {
        loadLock.lock()
        loadGeneration &+= 1
        inFlightLoad?.cancel()
        inFlightLoad = nil
        inFlightModelIdentifier = nil
        progressHandlers.removeAll()
        detailProgressHandlers.removeAll()
        latestProgress = nil
        latestDetailProgress = nil
        let monitor = downloadMonitor
        downloadMonitor = nil
        model = nil
        loadedModelIdentifier = nil
        loadLock.unlock()
        monitor?.stop()
        log.info("Model unloaded")
    }
}
