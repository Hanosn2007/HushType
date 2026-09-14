import Combine
import Foundation
import os

private let historyLog = Logger(subsystem: "com.felix.hushtype", category: "recognition-history")

private enum RecognitionHistoryStoreError: LocalizedError {
    case unreadableExistingHistory(String)

    var errorDescription: String? {
        switch self {
        case .unreadableExistingHistory(let reason):
            "The existing recognition history could not be read or preserved: \(reason)"
        }
    }
}

enum RecognitionHistoryKind: String, Codable, CaseIterable, Equatable, Sendable {
    case dictation
    case caption
}

/// Session details are only present for a completed Live Caption session.
/// `createdAt` remains the history ordering and grouping timestamp.
struct RecognitionHistoryCaptionMetadata: Codable, Equatable, Sendable {
    let startedAt: Date
    let endedAt: Date
    let sourceLabel: String?
}

/// The final, user-visible text from one completed recognition or caption
/// session. Legacy history JSON has no `kind`, so it decodes as dictation.
struct RecognitionHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let text: String
    let kind: RecognitionHistoryKind
    let captionMetadata: RecognitionHistoryCaptionMetadata?

    init(
        id: UUID,
        createdAt: Date,
        text: String,
        kind: RecognitionHistoryKind = .dictation,
        captionMetadata: RecognitionHistoryCaptionMetadata? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.kind = kind
        self.captionMetadata = captionMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case text
        case kind
        case captionMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        text = try container.decode(String.self, forKey: .text)
        kind = try container.decodeIfPresent(RecognitionHistoryKind.self, forKey: .kind) ?? .dictation
        captionMetadata = try container.decodeIfPresent(RecognitionHistoryCaptionMetadata.self, forKey: .captionMetadata)
    }
}

/// Retention is intentionally independent from presentation. `nil` days means
/// that count is the only automatic pruning limit.
struct RecognitionHistoryRetentionPolicy: Equatable, Sendable {
    var maximumEntries: Int
    var retentionDays: Int?

    static var standard: Self {
        Self(
            maximumEntries: AppConfig.shared.recognitionHistoryMaximumEntries,
            retentionDays: AppConfig.shared.recognitionHistoryRetentionDays
        )
    }

    var normalized: Self {
        Self(
            maximumEntries: max(0, maximumEntries),
            retentionDays: retentionDays.flatMap { $0 > 0 ? $0 : nil }
        )
    }
}

/// Main-actor isolation makes mutations safe for SwiftUI observation while the
/// JSON file remains a small, durable source of truth across launches.
@MainActor
final class RecognitionHistoryStore: ObservableObject {
    @Published private(set) var entries: [RecognitionHistoryEntry] = []

    private let fileURL: URL
    private let now: () -> Date
    private let isSavingEnabled: () -> Bool
    private var retentionPolicy: RecognitionHistoryRetentionPolicy
    private var persistenceBlock: RecognitionHistoryStoreError?

    init(
        fileURL: URL = AppConfig.recognitionHistoryFileURL,
        retentionPolicy: RecognitionHistoryRetentionPolicy = .standard,
        now: @escaping () -> Date = Date.init,
        isSavingEnabled: @escaping () -> Bool = { RecognitionHistoryPreferences.isSavingEnabled() }
    ) {
        self.fileURL = fileURL
        self.retentionPolicy = retentionPolicy.normalized
        self.now = now
        self.isSavingEnabled = isSavingEnabled
        reload()
    }

    /// Saves a non-empty final transcription before any attempt to insert it
    /// into another application.
    func append(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard isSavingEnabled() else { return }
        try ensurePersistenceAvailable()
        let previousEntries = entries
        entries.insert(
            RecognitionHistoryEntry(id: UUID(), createdAt: now(), text: text, kind: .dictation),
            at: 0
        )
        prune()
        try persistOrRestore(entries: previousEntries)
    }

    /// A caption session becomes one history entry only after it ends. Its
    /// transcript is kept whole for search, copy and the existing retention
    /// policy; source and timing remain available as session metadata.
    func appendCaption(
        _ text: String,
        startedAt: Date,
        endedAt: Date,
        sourceLabel: String?
    ) throws {
        guard !text.isEmpty else { return }
        guard isSavingEnabled() else { return }
        try ensurePersistenceAvailable()
        let previousEntries = entries
        entries.insert(
            RecognitionHistoryEntry(
                id: UUID(),
                createdAt: endedAt,
                text: text,
                kind: .caption,
                captionMetadata: RecognitionHistoryCaptionMetadata(
                    startedAt: startedAt,
                    endedAt: endedAt,
                    sourceLabel: sourceLabel
                )
            ),
            at: 0
        )
        prune()
        try persistOrRestore(entries: previousEntries)
    }

    /// Removes one item permanently. UI is responsible for confirmation.
    func remove(id: UUID) throws {
        try ensurePersistenceAvailable()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let previousEntries = entries
        entries.remove(at: index)
        try persistOrRestore(entries: previousEntries)
    }

    /// Removes all items permanently. The empty JSON file is retained so this
    /// never needs a filesystem deletion operation.
    func removeAll() throws {
        try ensurePersistenceAvailable()
        guard !entries.isEmpty else { return }
        let previousEntries = entries
        entries.removeAll()
        try persistOrRestore(entries: previousEntries)
    }

    /// Applies a changed user preference immediately rather than waiting for
    /// the next recognition.
    func updateRetentionPolicy(_ retentionPolicy: RecognitionHistoryRetentionPolicy) throws {
        try ensurePersistenceAvailable()
        let previousEntries = entries
        let previousPolicy = self.retentionPolicy
        self.retentionPolicy = retentionPolicy.normalized
        prune()
        do {
            try persist()
        } catch {
            entries = previousEntries
            self.retentionPolicy = previousPolicy
            throw error
        }
    }

    func applyCurrentRetentionPolicy() throws {
        try ensurePersistenceAvailable()
        let previousEntries = entries
        prune()
        try persistOrRestore(entries: previousEntries)
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decodedEntries = try JSONDecoder().decode([RecognitionHistoryEntry].self, from: data)
            entries = decodedEntries
            sortAndPruneInMemory()
            persistenceBlock = nil
            // Do not rewrite a valid legacy file merely to materialize the
            // default `.dictation` value used at decode time. We still persist
            // a genuine sort or retention cleanup, as before.
            if entries != decodedEntries {
                do {
                    try persist()
                } catch {
                    historyLog.error("Could not persist recognition history cleanup: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            entries = []
            preserveUnreadableHistory(after: error)
        }
    }

    /// Never let a later append silently overwrite unreadable history. Move the
    /// original aside first; if even that fails, block mutations until a later
    /// reload can read or preserve it.
    private func preserveUnreadableHistory(after readError: Error) {
        let recoveryURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "recognition-history-recovery-\(UUID().uuidString).json"
        )
        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            try FileManager.default.moveItem(at: fileURL, to: recoveryURL)
            persistenceBlock = nil
            historyLog.error(
                "Preserved unreadable recognition history at \(recoveryURL.path, privacy: .public): \(readError.localizedDescription, privacy: .public)"
            )
        } catch {
            let blocked = RecognitionHistoryStoreError.unreadableExistingHistory(error.localizedDescription)
            persistenceBlock = blocked
            historyLog.error("Recognition history writes blocked: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensurePersistenceAvailable() throws {
        if let persistenceBlock { throw persistenceBlock }
    }

    private func prune() {
        sortAndPruneInMemory()
    }

    private func sortAndPruneInMemory() {
        entries.sort { $0.createdAt > $1.createdAt }

        if let retentionDays = retentionPolicy.retentionDays {
            let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
            entries.removeAll { $0.createdAt < cutoff }
        }

        if entries.count > retentionPolicy.maximumEntries {
            entries.removeLast(entries.count - retentionPolicy.maximumEntries)
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    private func persistOrRestore(entries previousEntries: [RecognitionHistoryEntry]) throws {
        do {
            try persist()
        } catch {
            entries = previousEntries
            throw error
        }
    }
}
