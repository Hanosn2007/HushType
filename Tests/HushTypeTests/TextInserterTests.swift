import AppKit
import XCTest
@testable import HushType

@MainActor
final class TextInserterTests: XCTestCase {
    func testRestoresMultipleItemsAndRepresentations() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("original", forType: .string)
        let richText = Data("{\\rtf1\\ansi original}".utf8)
        first.setData(richText, forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("https://example.com", forType: .URL)
        XCTAssertTrue(board.writeObjects([first, second]))
        let transaction = try TemporaryClipboardTransaction.begin("中文 👋\n第二行", on: board, marked: true)
        XCTAssertEqual(board.string(forType: .string), "中文 👋\n第二行")
        XCTAssertTrue(board.types!.contains(TemporaryClipboardTransaction.transientType))
        XCTAssertTrue(board.types!.contains(TemporaryClipboardTransaction.generatedType))
        XCTAssertEqual(transaction.finish(), .restored)
        XCTAssertEqual(board.pasteboardItems?.count, 2)
        XCTAssertEqual(board.pasteboardItems?[0].string(forType: .string), "original")
        XCTAssertEqual(board.pasteboardItems?[0].data(forType: .rtf), richText)
        XCTAssertEqual(board.pasteboardItems?[1].string(forType: .URL), "https://example.com")
    }

    func testNewCopyAndEmptyClipboardTakePrecedence() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let transaction = try TemporaryClipboardTransaction.begin("temporary", on: board, marked: true)
        board.clearContents()
        board.setString("user copy", forType: .string)
        XCTAssertEqual(transaction.finish(), .superseded)
        XCTAssertEqual(board.string(forType: .string), "user copy")
        let cleared = try TemporaryClipboardTransaction.begin("temporary", on: board, marked: true)
        board.clearContents()
        XCTAssertEqual(cleared.finish(), .superseded)
        XCTAssertNil(board.string(forType: .string))
    }

    func testRestoresEmptyClipboardAndCanDisableMarkers() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let transaction = try TemporaryClipboardTransaction.begin("temporary", on: board, marked: false)
        XCTAssertFalse(board.types!.contains(TemporaryClipboardTransaction.transientType))
        XCTAssertFalse(board.types!.contains(TemporaryClipboardTransaction.generatedType))
        XCTAssertEqual(transaction.finish(), .restored)
        XCTAssertTrue((board.pasteboardItems ?? []).isEmpty)
        XCTAssertEqual(transaction.finish(), .superseded)
    }

    func testPermissionDenialNeverTouchesClipboardOrPosts() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let before = board.changeCount
        var requested = false
        let failure = await TextInserter.insert("text", pasteboard: board, configuration: .init(),
            hasPostEventAccess: { false }, requestPostEventAccess: { requested = true },
            postPaste: { XCTFail("Must not post"); return false },
            waitForPaste: { XCTFail("Must not wait") })
        XCTAssertEqual(failure, .postEventAccessDenied)
        XCTAssertTrue(requested)
        XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testDispatchFailureRestoresOriginalWithoutWaiting() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let failure = await TextInserter.insert("text", pasteboard: board, configuration: .init(),
            hasPostEventAccess: { true }, postPaste: { false },
            waitForPaste: { XCTFail("No event was sent") })
        XCTAssertEqual(failure, .insertionFailed)
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testSuccessfulDispatchKeepsTextUntilWaitFinishesAndLoadsPreferenceEachTime() async throws {
        let suite = "HushType.input-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        for marked in [true, false, true] {
            if !marked || defaults.object(forKey: TextInserter.temporaryMarkersKey) != nil {
                defaults.set(marked, forKey: TextInserter.temporaryMarkersKey)
            }
            var dispatches = 0
            let failure = await TextInserter.insert("text", pasteboard: board, defaults: defaults,
                hasPostEventAccess: { true }, postPaste: {
                    dispatches += 1
                    XCTAssertEqual(board.string(forType: .string), "text")
                    XCTAssertEqual(board.types!.contains(TemporaryClipboardTransaction.transientType), marked)
                    return true
                }, waitForPaste: {
                    await Task.yield()
                    XCTAssertEqual(board.string(forType: .string), "text")
                })
            XCTAssertNil(failure)
            XCTAssertEqual(dispatches, 1)
            XCTAssertEqual(board.string(forType: .string), "original")
        }
    }

    func testUserCopyDuringWaitIsPreservedAndNoRepeatIsSent() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var dispatches = 0
        let failure = await TextInserter.insert("text", pasteboard: board, configuration: .init(),
            hasPostEventAccess: { true }, postPaste: { dispatches += 1; return true },
            waitForPaste: {
                board.clearContents()
                board.setString("new copy", forType: .string)
            })
        XCTAssertNil(failure)
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(board.string(forType: .string), "new copy")
    }

    func testConcurrentInsertionCannotOverwritePendingPaste() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let failure = await TextInserter.insert("first", pasteboard: board, configuration: .init(),
            hasPostEventAccess: { true }, postPaste: { true }, waitForPaste: {
                let nested = await TextInserter.insert("second", pasteboard: board, configuration: .init(),
                    hasPostEventAccess: { true }, postPaste: { XCTFail("Nested post"); return true },
                    waitForPaste: {})
                XCTAssertEqual(nested, .insertionFailed)
                XCTAssertEqual(board.string(forType: .string), "first")
            })
        XCTAssertNil(failure)
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testCancellationAfterDispatchStillWaitsBeforeRestoring() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var operation: Task<TextInserter.Failure?, Never>!
        var dispatchedAt: Date?
        operation = Task { @MainActor in
            await TextInserter.insert("pending", pasteboard: board, configuration: .init(),
                hasPostEventAccess: { true }, postPaste: {
                    dispatchedAt = Date()
                    operation.cancel()
                    return true
                })
        }
        let failure = await operation.value
        XCTAssertNil(failure)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(dispatchedAt!), 0.45)
        XCTAssertEqual(board.string(forType: .string), "original")
    }
}
