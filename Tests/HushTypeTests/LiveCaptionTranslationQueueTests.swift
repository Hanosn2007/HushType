import Foundation
import XCTest
@testable import HushType

@MainActor
final class LiveCaptionTranslationQueueTests: XCTestCase {
    func testNormalFinishWaitsForBothActiveAndQueuedTranslations() async {
        let gate = TranslationGate()
        let queue = LiveCaptionTranslationQueue { try await gate.translate($0) }
        let first = UUID(), second = UUID()
        var delivered: [UUID] = []
        var finished = false
        queue.onResult = { id, _ in delivered.append(id) }
        queue.enqueue(id: first, text: "one")
        queue.enqueue(id: second, text: "two")
        let waiter = Task { await queue.waitUntilFinished(); finished = true }
        let started = await waitUntil { await gate.startedTexts() == ["one"] }
        XCTAssertTrue(started)
        XCTAssertFalse(finished)
        await gate.resumeNext(.success("ONE"))
        let secondStarted = await waitUntil { await gate.startedTexts() == ["one", "two"] }
        XCTAssertTrue(secondStarted)
        XCTAssertFalse(finished)
        await gate.resumeNext(.success("TWO"))
        await waiter.value
        XCTAssertEqual(delivered, [first, second])
        XCTAssertTrue(finished)
    }

    func testQueueRunsOneTranslationAtATimeAndContinuesAfterFailure() async {
        let gate = TranslationGate()
        let queue = LiveCaptionTranslationQueue { text in
            try await gate.translate(text)
        }
        let first = UUID()
        let second = UUID()
        let third = UUID()
        var results: [UUID: String] = [:]
        var pendingCounts: [Int] = []
        queue.onResult = { id, result in
            switch result {
            case .success(let text): results[id] = "success:\(text)"
            case .failure: results[id] = "failure"
            }
        }
        queue.onPendingCountChanged = { pendingCounts.append($0) }

        queue.enqueue(id: first, text: "one")
        queue.enqueue(id: second, text: "two")
        queue.enqueue(id: third, text: "three")

        let firstStarted = await waitUntil { await gate.startedTexts() == ["one"] }
        XCTAssertTrue(firstStarted)
        XCTAssertEqual(pendingCounts, [1, 2, 3])

        await gate.resumeNext(.success("ONE"))
        let secondStarted = await waitUntil {
            let startedTexts = await gate.startedTexts()
            return results[first] == "success:ONE" && startedTexts == ["one", "two"]
        }
        XCTAssertTrue(secondStarted)

        await gate.resumeNext(.failure(TestError.expected))
        let thirdStarted = await waitUntil {
            let startedTexts = await gate.startedTexts()
            return results[second] == "failure" && startedTexts == ["one", "two", "three"]
        }
        XCTAssertTrue(thirdStarted)

        await gate.resumeNext(.success("THREE"))
        let thirdCompleted = await waitUntil { results[third] == "success:THREE" }
        XCTAssertTrue(thirdCompleted)
        XCTAssertEqual(pendingCounts, [1, 2, 3, 2, 1, 0])
    }

    func testCancelDiscardsBacklogAndBlocksAnOldResult() async {
        let gate = TranslationGate()
        let queue = LiveCaptionTranslationQueue { text in
            try await gate.translate(text)
        }
        let activeID = UUID()
        let queuedID = UUID()
        var deliveredIDs: [UUID] = []
        var pendingCounts: [Int] = []
        queue.onResult = { id, _ in deliveredIDs.append(id) }
        queue.onPendingCountChanged = { pendingCounts.append($0) }

        queue.enqueue(id: activeID, text: "active")
        queue.enqueue(id: queuedID, text: "queued")
        let activeStarted = await waitUntil { await gate.startedTexts() == ["active"] }
        XCTAssertTrue(activeStarted)

        queue.cancel()
        XCTAssertEqual(pendingCounts, [1, 2, 0])
        await gate.resumeNext(.success("late"))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(deliveredIDs.isEmpty)
        let startedTexts = await gate.startedTexts()
        XCTAssertEqual(startedTexts, ["active"])
    }

    func testBacklogLimitReportsTheNewSentenceInsteadOfDroppingIt() async {
        let gate = TranslationGate()
        let queue = LiveCaptionTranslationQueue(
            translate: { text in try await gate.translate(text) },
            maximumPending: 2
        )
        let activeID = UUID()
        let firstQueuedID = UUID()
        let secondQueuedID = UUID()
        let overflowID = UUID()
        var overflowError: LiveCaptionTranslationQueueError?

        queue.onResult = { id, result in
            guard id == overflowID,
                  case .failure(let error) = result else { return }
            overflowError = error as? LiveCaptionTranslationQueueError
        }
        queue.enqueue(id: activeID, text: "active")
        queue.enqueue(id: firstQueuedID, text: "first")
        queue.enqueue(id: secondQueuedID, text: "second")
        let activeStarted = await waitUntil { await gate.startedTexts() == ["active"] }
        XCTAssertTrue(activeStarted)

        queue.enqueue(id: overflowID, text: "overflow")
        XCTAssertEqual(overflowError, .backlogFull(limit: 2))
        let startedTexts = await gate.startedTexts()
        XCTAssertEqual(startedTexts, ["active"])

        queue.cancel()
        await gate.resumeNext(.success("ignored"))
    }

    func testSegmentEntryKeepsSourceAndTranslationForHistory() {
        var entry = LiveCaptionViewModel.SegmentEntry(text: "Source")
        XCTAssertEqual(entry.displayText, "Source")
        XCTAssertEqual(entry.historyText, "Source")

        entry.translatedText = "Translation"
        XCTAssertTrue(entry.hasTranslatedText)
        XCTAssertEqual(entry.displayText, "Translation")
        XCTAssertEqual(entry.historyText, "Source\nTranslation")

        entry.translationError = "Translation unavailable"
        XCTAssertEqual(entry.displayText, "Translation")
        XCTAssertEqual(entry.translationError, "Translation unavailable")

        var failedEntry = LiveCaptionViewModel.SegmentEntry(text: "Untranslated source")
        failedEntry.translationError = "Translation unavailable"
        XCTAssertEqual(failedEntry.displayText, "Untranslated source")
        XCTAssertEqual(failedEntry.historyText, "Untranslated source")
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

private enum TestError: Error {
    case expected
}

private actor TranslationGate {
    private var started: [String] = []
    private var waiters: [CheckedContinuation<Result<String, Error>, Never>] = []

    func translate(_ text: String) async throws -> String {
        started.append(text)
        let result = await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        return try result.get()
    }

    func startedTexts() -> [String] {
        started
    }

    func resumeNext(_ result: Result<String, Error>) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: result)
    }
}
