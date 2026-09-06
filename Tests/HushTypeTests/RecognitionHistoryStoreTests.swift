import Foundation
import XCTest
@testable import HushType

@MainActor
final class RecognitionHistoryStoreTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("HushType-RecognitionHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? fileManager.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testAppendPersistsFinalTextAcrossStoreInstances() throws {
        let url = historyURL
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let store = makeStore(url: url, now: now)

        try store.append("最终会输入的文字")

        let reloaded = makeStore(url: url, now: now)
        XCTAssertEqual(reloaded.entries.map(\.text), ["最终会输入的文字"])
        XCTAssertEqual(reloaded.entries.first?.createdAt, now)
    }

    func testAppendOrdersNewestFirstAndIgnoresEmptyText() throws {
        let url = historyURL
        var current = Date(timeIntervalSinceReferenceDate: 10_000)
        let store = RecognitionHistoryStore(fileURL: url, now: { current })

        try store.append("first")
        current.addTimeInterval(1)
        try store.append("")
        try store.append("second")

        XCTAssertEqual(store.entries.map(\.text), ["second", "first"])
    }

    func testPrunesWhenEitherAgeOrCountLimitIsReached() throws {
        let url = historyURL
        let now = Date(timeIntervalSinceReferenceDate: 100 * 86_400)
        let policy = RecognitionHistoryRetentionPolicy(maximumEntries: 2, retentionDays: 30)
        let expired = RecognitionHistoryEntry(id: UUID(), createdAt: now.addingTimeInterval(-31 * 86_400), text: "expired")
        let first = RecognitionHistoryEntry(id: UUID(), createdAt: now.addingTimeInterval(-2), text: "first")
        let second = RecognitionHistoryEntry(id: UUID(), createdAt: now.addingTimeInterval(-1), text: "second")
        try write([expired, first, second], to: url)

        let store = RecognitionHistoryStore(fileURL: url, retentionPolicy: policy, now: { now })
        try store.append("newest")

        XCTAssertEqual(store.entries.map(\.text), ["newest", "second"])
        XCTAssertEqual(makeStore(url: url, policy: policy, now: now).entries.map(\.text), ["newest", "second"])
    }

    func testNilRetentionDaysDoesNotExpireEntries() throws {
        let url = historyURL
        let now = Date(timeIntervalSinceReferenceDate: 100 * 86_400)
        let policy = RecognitionHistoryRetentionPolicy(maximumEntries: 10, retentionDays: nil)
        let old = RecognitionHistoryEntry(id: UUID(), createdAt: now.addingTimeInterval(-365 * 86_400), text: "old")
        try write([old], to: url)

        let store = RecognitionHistoryStore(fileURL: url, retentionPolicy: policy, now: { now })
        try store.append("new")

        XCTAssertEqual(store.entries.map(\.text), ["new", "old"])
    }

    func testUpdateRetentionPolicyPrunesAndPersistsImmediately() throws {
        let url = historyURL
        let now = Date(timeIntervalSinceReferenceDate: 100 * 86_400)
        let unlimited = RecognitionHistoryRetentionPolicy(maximumEntries: 10, retentionDays: nil)
        let old = RecognitionHistoryEntry(id: UUID(), createdAt: now.addingTimeInterval(-31 * 86_400), text: "old")
        let recent = RecognitionHistoryEntry(id: UUID(), createdAt: now.addingTimeInterval(-1), text: "recent")
        try write([old, recent], to: url)
        let store = RecognitionHistoryStore(fileURL: url, retentionPolicy: unlimited, now: { now })

        try store.updateRetentionPolicy(.init(maximumEntries: 1, retentionDays: 30))

        XCTAssertEqual(store.entries.map(\.text), ["recent"])
        XCTAssertEqual(makeStore(url: url, now: now).entries.map(\.text), ["recent"])
    }

    func testRemoveAndRemoveAllPersistPermanentChanges() throws {
        let url = historyURL
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let store = makeStore(url: url, now: now)
        try store.append("first")
        try store.append("second")

        try store.remove(id: store.entries[0].id)
        XCTAssertEqual(makeStore(url: url, now: now).entries.map(\.text), ["first"])

        try store.removeAll()
        XCTAssertTrue(makeStore(url: url, now: now).entries.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: url.path))
    }

    func testAppendRollsBackInMemoryWhenParentPathIsAFile() throws {
        let invalidParent = temporaryDirectory.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: invalidParent)
        let invalidURL = invalidParent.appendingPathComponent("recognition-history.json")
        let store = makeStore(url: invalidURL, now: Date(timeIntervalSinceReferenceDate: 10_000))

        XCTAssertThrowsError(try store.append("must not appear as saved"))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testUnreadableHistoryIsPreservedBeforeNewHistoryIsWritten() throws {
        let url = historyURL
        try Data("not-json".utf8).write(to: url)

        let store = makeStore(url: url, now: Date(timeIntervalSinceReferenceDate: 10_000))
        try store.append("new entry")

        XCTAssertEqual(makeStore(url: url, now: Date(timeIntervalSinceReferenceDate: 10_000)).entries.map(\.text), ["new entry"])
        let recovered = try fileManager.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("recognition-history-recovery-") }
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(try Data(contentsOf: recovered[0]), Data("not-json".utf8))
    }

    func testPeriodicCleanupRemovesExpiredEntriesFromMemoryAndDisk() throws {
        let url = historyURL
        var current = Date(timeIntervalSinceReferenceDate: 100 * 86_400)
        let store = RecognitionHistoryStore(
            fileURL: url,
            retentionPolicy: .init(maximumEntries: 500, retentionDays: 30),
            now: { current }
        )
        try store.append("will expire")
        current.addTimeInterval(31 * 86_400)

        try store.applyCurrentRetentionPolicy()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(makeStore(url: url, now: current).entries.isEmpty)
    }

    private var historyURL: URL {
        temporaryDirectory.appendingPathComponent("recognition-history.json")
    }

    private func makeStore(
        url: URL,
        policy: RecognitionHistoryRetentionPolicy = .init(maximumEntries: 500, retentionDays: 30),
        now: Date
    ) -> RecognitionHistoryStore {
        RecognitionHistoryStore(fileURL: url, retentionPolicy: policy, now: { now })
    }

    private func write(_ entries: [RecognitionHistoryEntry], to url: URL) throws {
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
