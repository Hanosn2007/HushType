import Foundation
import XCTest
@testable import HushType

@MainActor
final class RecognitionHistoryEnhancementTests: XCTestCase {
    private struct LegacyEntry: Codable {
        let id: UUID
        let createdAt: Date
        let text: String
    }

    private let fileManager = FileManager.default
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "HushType-RecognitionHistoryEnhancementTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory, fileManager.fileExists(atPath: temporaryDirectory.path) {
            var trashedURL: NSURL?
            try fileManager.trashItem(at: temporaryDirectory, resultingItemURL: &trashedURL)
        }
        temporaryDirectory = nil
    }

    func testHistorySavingPreferenceDefaultsToEnabledAndCanBeDisabled() throws {
        let suiteName = "HushType-RecognitionHistoryEnhancementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(RecognitionHistoryPreferences.isSavingEnabled(defaults: defaults))
        defaults.set(false, forKey: RecognitionHistoryPreferences.savingEnabledKey)
        XCTAssertFalse(RecognitionHistoryPreferences.isSavingEnabled(defaults: defaults))
    }

    func testSavingDisabledPreservesExistingDictationAndCaptionHistory() throws {
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let enabledStore = makeStore(now: now, savingEnabled: true)
        try enabledStore.append("existing dictation")
        let savedData = try Data(contentsOf: historyURL)

        let disabledStore = makeStore(now: now.addingTimeInterval(60), savingEnabled: false)
        try disabledStore.append("discarded dictation")
        try disabledStore.appendCaption(
            "discarded caption",
            startedAt: now,
            endedAt: now.addingTimeInterval(60),
            sourceLabel: "Microphone"
        )

        XCTAssertEqual(disabledStore.entries.map(\.text), ["existing dictation"])
        XCTAssertEqual(try Data(contentsOf: historyURL), savedData)
    }

    func testCaptionSessionStoresOneEntryWithSessionMetadata() throws {
        let startedAt = Date(timeIntervalSinceReferenceDate: 30_000)
        let endedAt = startedAt.addingTimeInterval(95)
        let store = makeStore(now: endedAt, savingEnabled: true)

        try store.appendCaption(
            "Full caption session transcript.",
            startedAt: startedAt,
            endedAt: endedAt,
            sourceLabel: "Example App"
        )

        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.kind, .caption)
        XCTAssertEqual(entry.createdAt, endedAt)
        XCTAssertEqual(
            entry.captionMetadata,
            RecognitionHistoryCaptionMetadata(
                startedAt: startedAt,
                endedAt: endedAt,
                sourceLabel: "Example App"
            )
        )
        XCTAssertEqual(makeStore(now: endedAt, savingEnabled: true).entries, store.entries)
    }

    func testLegacyHistoryDecodesAsDictationWithoutRewritingFile() throws {
        let legacy = LegacyEntry(
            id: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 40_000),
            text: "History from an earlier HushType version"
        )
        let legacyData = try JSONEncoder().encode([legacy])
        try legacyData.write(to: historyURL, options: .atomic)

        let store = makeStore(now: legacy.createdAt, savingEnabled: true)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].kind, .dictation)
        XCTAssertNil(store.entries[0].captionMetadata)
        XCTAssertEqual(try Data(contentsOf: historyURL), legacyData)
    }

    func testCustomDateRangeUsesInclusiveLocalCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try date(2026, 9, 8, 0, 0, calendar: calendar)
        let end = try date(2026, 9, 10, 0, 0, calendar: calendar)
        let range = RecognitionHistoryDateRange(startDate: start, endDate: end)

        XCTAssertTrue(range.contains(try date(2026, 9, 8, 0, 0, calendar: calendar), calendar: calendar))
        XCTAssertTrue(range.contains(try date(2026, 9, 10, 23, 59, calendar: calendar), calendar: calendar))
        XCTAssertFalse(range.contains(try date(2026, 9, 7, 23, 59, calendar: calendar), calendar: calendar))
        XCTAssertFalse(range.contains(try date(2026, 9, 11, 0, 0, calendar: calendar), calendar: calendar))
    }

    func testCollapsedHistoryLayoutUsesThreeLineCeilingForLongText() {
        let text = String(repeating: "A long history row that wraps. ", count: 24)
        let textWidth: CGFloat = 180

        XCTAssertTrue(SettingsHistoryTextLayout.requiresExpansion(for: text, textWidth: textWidth))
        XCTAssertLessThan(
            SettingsHistoryTextLayout.rowHeight(for: text, textWidth: textWidth, isExpanded: false),
            SettingsHistoryTextLayout.rowHeight(for: text, textWidth: textWidth, isExpanded: true)
        )
    }

    private var historyURL: URL {
        temporaryDirectory.appendingPathComponent("recognition-history.json")
    }

    private func makeStore(now: Date, savingEnabled: Bool) -> RecognitionHistoryStore {
        RecognitionHistoryStore(
            fileURL: historyURL,
            retentionPolicy: .init(maximumEntries: 500, retentionDays: nil),
            now: { now },
            isSavingEnabled: { savingEnabled }
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }
}
