import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "insertion")

@MainActor
struct TextInserter {
    static let temporaryMarkersKey = TextInsertionConfiguration.markersKey
    private static var isInserting = false

    enum Failure: Equatable {
        case postEventAccessDenied
        case insertionFailed

        var message: String {
            switch self {
            case .postEventAccessDenied:
                return L10n.string(
                    "status.insertion_permission_denied",
                    fallback: "macOS blocked automatic input. Allow HushType in Accessibility and try again."
                )
            case .insertionFailed:
                return L10n.string(
                    "status.insertion_failed",
                    fallback: "HushType couldn't complete automatic input."
                )
            }
        }
    }

    /// A nil result means the input events were dispatched, not that the target
    /// acknowledged insertion. Never retry an ambiguous delivery automatically.
    static func insert(
        _ text: String,
        pasteboard: NSPasteboard = .general,
        defaults: UserDefaults = .standard,
        configuration: TextInsertionConfiguration? = nil,
        hasPostEventAccess: @MainActor () -> Bool = { CGPreflightPostEventAccess() },
        requestPostEventAccess: @MainActor () -> Void = { _ = CGRequestPostEventAccess() },
        postPaste: @MainActor () -> Bool = { simulatePaste() },
        waitForPaste: (@MainActor () async -> Void)? = nil,
        postUnicode: @MainActor ([UniChar]) -> Bool = { UnicodeTextInput.post($0) },
        isUnicodeTargetFocused: (@MainActor () -> Bool)? = nil,
        waitBetweenBatches: @MainActor (Int) async throws -> Void = {
            if $0 == 0 { await Task.yield() }
            else { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }
        }
    ) async -> Failure? {
        guard !text.isEmpty, !isInserting, !Task.isCancelled else {
            return .insertionFailed
        }
        guard hasPostEventAccess() else {
            requestPostEventAccess()
            return .postEventAccessDenied
        }
        isInserting = true
        defer { isInserting = false }
        let configuration = configuration ?? TextInsertionConfiguration.load(defaults: defaults)
        if configuration.method == .unicode {
            let stillFocused = isUnicodeTargetFocused ?? UnicodeTextInput.captureFocusValidator()
            let chunks = UnicodeTextInput.chunks(text, batchSize: configuration.unicodeBatchSize)
            for (index, chunk) in chunks.enumerated() {
                guard !Task.isCancelled, stillFocused(), postUnicode(chunk) else {
                    log.error("Unicode input stopped; delivery may be partial, no automatic retry")
                    return .insertionFailed
                }
                if index + 1 < chunks.count {
                    do { try await waitBetweenBatches(configuration.unicodeIntervalMilliseconds) }
                    catch { return .insertionFailed }
                }
            }
            log.debug("Unicode input dispatched")
            return nil
        }
        let transaction: TemporaryClipboardTransaction
        do {
            transaction = try TemporaryClipboardTransaction.begin(
                text, on: pasteboard,
                marked: configuration.temporaryMarkers
            )
        } catch {
            log.error("Could not prepare temporary clipboard input")
            return .insertionFailed
        }
        // Always restore on dispatch failure too. A new copy made while awaiting
        // the target's paste takes precedence over our original snapshot.
        var restored = false
        defer {
            if !restored { _ = transaction.finish() }
        }
        guard transaction.stillOwnsClipboard, !Task.isCancelled, postPaste() else {
            return .insertionFailed
        }
        print("[TextInserter] Cmd+V sent")
        if let waitForPaste { await waitForPaste() }
        else { await waitForPasteCompletionWindow(milliseconds: configuration.clipboardRestoreMilliseconds) }
        let result = transaction.finish()
        restored = true
        switch result {
        case .restored:
            log.debug("Original clipboard restored after paste dispatch")
        case .superseded:
            log.debug("Preserving newer clipboard contents")
        case .failed:
            log.error("Could not restore original clipboard")
            return .insertionFailed
        }
        return nil
    }

    static func waitForPasteCompletionWindow(milliseconds: Int = 500) async {
        // Tested demo default. This is a delivery grace period, not an app ACK.
        // Deliberately cancellation-insensitive after dispatch: cancellation must
        // not restore early while the destination is still reading the board.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(milliseconds) / 1000) {
                continuation.resume()
            }
        }
    }

    static func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        // kVK_ANSI_V = 0x09
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            log.error("Failed to create paste CGEvents")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

/// Owns only the temporary clipboard entry, never a clipboard manager's history.
@MainActor
struct TemporaryClipboardTransaction {
    enum PreparationError: Error { case unreadableRepresentation, clipboardChanged, writeFailed }
    enum Restoration: Equatable { case restored, superseded, failed }
    static let ownerType = NSPasteboard.PasteboardType("com.felix.hushtype.temporary-input")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let generatedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    let pasteboard: NSPasteboard
    let original: [[NSPasteboard.PasteboardType: Data]]
    let token: String
    let changeCount: Int

    static func begin(_ text: String, on board: NSPasteboard, marked: Bool) throws -> Self {
        let before = board.changeCount
        var original: [[NSPasteboard.PasteboardType: Data]] = []
        for item in board.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw PreparationError.unreadableRepresentation
                }
                representations[type] = data
            }
            original.append(representations)
        }
        // Lazy representations can take time to materialize. Don't replace a
        // copy that arrived while capturing the original contents.
        guard board.changeCount == before else { throw PreparationError.clipboardChanged }
        let token = UUID().uuidString
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(token, forType: ownerType)
        if marked {
            item.setData(Data(), forType: transientType)
            item.setData(Data(), forType: generatedType)
        }
        let clearedCount = board.clearContents()
        guard board.changeCount == clearedCount else { throw PreparationError.clipboardChanged }
        guard board.writeObjects([item]) else {
            _ = restore(original, to: board, expectedCount: clearedCount)
            throw PreparationError.writeFailed
        }
        return Self(pasteboard: board, original: original, token: token, changeCount: board.changeCount)
    }

    var stillOwnsClipboard: Bool {
        pasteboard.changeCount == changeCount && pasteboard.string(forType: Self.ownerType) == token
    }

    func finish() -> Restoration {
        guard stillOwnsClipboard else { return .superseded }
        return Self.restore(original, to: pasteboard, expectedCount: changeCount, expectedToken: token)
    }

    private static func restore(
        _ original: [[NSPasteboard.PasteboardType: Data]], to board: NSPasteboard,
        expectedCount: Int, expectedToken: String? = nil
    ) -> Restoration {
        let items = original.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        // Construct representations before checking ownership again, so that
        // materializing a large original item doesn't extend the write window.
        guard board.changeCount == expectedCount,
              expectedToken == nil || board.string(forType: ownerType) == expectedToken else {
            return .superseded
        }
        let clearedCount = board.clearContents()
        guard board.changeCount == clearedCount else { return .superseded }
        return items.isEmpty || board.writeObjects(items) ? .restored : .failed
    }
}
