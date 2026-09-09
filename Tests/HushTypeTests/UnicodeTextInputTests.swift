import AppKit
import XCTest
@testable import HushType

@MainActor
final class UnicodeTextInputTests: XCTestCase {
    func testDefaultsAndPreferencesAreNormalized() throws {
        let suite = "HushType.input-config.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TextInsertionConfiguration.load(defaults: defaults), .init())
        defaults.set("unicode", forKey: TextInsertionConfiguration.methodKey)
        defaults.set(50, forKey: TextInsertionConfiguration.batchSizeKey)
        defaults.set(0, forKey: TextInsertionConfiguration.intervalKey)
        defaults.set(1000, forKey: TextInsertionConfiguration.restoreDelayKey)
        defaults.set(false, forKey: TextInsertionConfiguration.markersKey)
        XCTAssertEqual(TextInsertionConfiguration.load(defaults: defaults),
            .init(method: .unicode, unicodeBatchSize: 50, unicodeIntervalMilliseconds: 0,
                  clipboardRestoreMilliseconds: 1000, temporaryMarkers: false))
        defaults.set("unknown", forKey: TextInsertionConfiguration.methodKey)
        defaults.set(-1, forKey: TextInsertionConfiguration.batchSizeKey)
        defaults.set(Int.max, forKey: TextInsertionConfiguration.intervalKey)
        defaults.set(0, forKey: TextInsertionConfiguration.restoreDelayKey)
        let invalid = TextInsertionConfiguration.load(defaults: defaults)
        XCTAssertEqual(invalid.method, .clipboard)
        XCTAssertEqual(invalid.unicodeBatchSize, 100)
        XCTAssertEqual(invalid.unicodeIntervalMilliseconds, 1)
        XCTAssertEqual(invalid.clipboardRestoreMilliseconds, 500)
    }

    func testChunksPreserveUnicodeAndGraphemesAtEverySupportedSize() {
        let text = String(repeating: "中文👨‍👩‍👧‍👦🇨🇳e\u{301}\n", count: 200)
        for size in TextInsertionConfiguration.batchSizes {
            let chunks = UnicodeTextInput.chunks(text, batchSize: size)
            XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
            let decoded = chunks.map { String(decoding: $0, as: UTF16.self) }
            XCTAssertEqual(decoded.flatMap(Array.init), Array(text))
            XCTAssertTrue(chunks.allSatisfy { $0.count <= size || String(decoding: $0, as: UTF16.self).count == 1 })
        }
        XCTAssertTrue(UnicodeTextInput.chunks("", batchSize: 100).isEmpty)
    }

    func testFiveThousandCharactersUse100And1WithoutTouchingClipboard() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original PPT content", forType: .string)
        let originalCount = board.changeCount
        let text = String(repeating: "中", count: 5000)
        var batches: [[UniChar]] = []
        var waits: [Int] = []
        let failure = await TextInserter.insert(text, pasteboard: board,
            configuration: .init(method: .unicode), hasPostEventAccess: { true },
            postPaste: { XCTFail("Must not paste"); return false },
            postUnicode: { batches.append($0); return true }, isUnicodeTargetFocused: { true },
            waitBetweenBatches: { waits.append($0) })
        XCTAssertNil(failure)
        XCTAssertEqual(batches.count, 50)
        XCTAssertEqual(batches.flatMap { $0 }, Array(text.utf16))
        XCTAssertEqual(waits, Array(repeating: 1, count: 49))
        XCTAssertEqual(board.changeCount, originalCount)
        XCTAssertEqual(board.string(forType: .string), "original PPT content")
    }

    func testPassedParametersOverrideDefaults() async {
        var batches: [[UniChar]] = []
        var waits: [Int] = []
        let failure = await TextInserter.insert("123456789", configuration:
            .init(method: .unicode, unicodeBatchSize: 8, unicodeIntervalMilliseconds: 5),
            hasPostEventAccess: { true }, postUnicode: { batches.append($0); return true },
            isUnicodeTargetFocused: { true }, waitBetweenBatches: { waits.append($0) })
        XCTAssertNil(failure)
        XCTAssertEqual(batches.map(\.count), [8, 1])
        XCTAssertEqual(waits, [5])
    }

    func testFocusChangeStopsPartialInputWithoutFallback() async {
        var batches = 0
        let failure = await TextInserter.insert(String(repeating: "x", count: 250),
            configuration: .init(method: .unicode), hasPostEventAccess: { true },
            postPaste: { XCTFail("Must not fall back"); return false },
            postUnicode: { _ in batches += 1; return true },
            isUnicodeTargetFocused: { batches == 0 }, waitBetweenBatches: { _ in })
        XCTAssertEqual(failure, .insertionFailed)
        XCTAssertEqual(batches, 1)
    }

    func testDispatchFailureAndCancellationDoNotRetry() async {
        for failsDuringWait in [false, true] {
            var attempts = 0
            let failure = await TextInserter.insert(String(repeating: "x", count: 250),
                configuration: .init(method: .unicode), hasPostEventAccess: { true },
                postPaste: { XCTFail("Must not fall back"); return false },
                postUnicode: { _ in attempts += 1; return failsDuringWait },
                isUnicodeTargetFocused: { true }, waitBetweenBatches: { _ in throw CancellationError() })
            XCTAssertEqual(failure, .insertionFailed)
            XCTAssertEqual(attempts, 1)
        }
    }
}
