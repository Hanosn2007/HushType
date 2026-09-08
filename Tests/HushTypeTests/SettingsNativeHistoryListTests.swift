import AppKit
import SwiftUI
import XCTest
@testable import HushType

final class SettingsNativeHistoryListTests: XCTestCase {
    @MainActor
    func testHeightReservesCompleteTextIncludingBlankLines() {
        let text = "第一行。\n\n第三行包含一段需要在窄列中自动换行的识别结果。\n最后一行。"
        let availableWidth: CGFloat = 320
        let textWidth = SettingsHistoryTextLayout.textWidth(for: availableWidth)
        let rowHeight = SettingsHistoryTextLayout.rowHeight(for: text, textWidth: textWidth)

        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 13)
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.usesSingleLineMode = false
        field.cell?.isScrollable = false
        let needed = field.cell!.cellSize(forBounds: NSRect(
            x: 0,
            y: 0,
            width: textWidth + 4,
            height: 100_000
        )).height

        XCTAssertGreaterThanOrEqual(rowHeight - 16, ceil(needed))
    }

    func testNarrowMeasurementAccountsForTextFieldInset() {
        XCTAssertEqual(SettingsHistoryTextLayout.textWidth(for: 320), 102)
        XCTAssertEqual(SettingsHistoryTextLayout.textWidth(for: 180), 32)
    }

    @MainActor
    func testNativeTableKeepsAMiddlePartialRowAnchoredAcrossReflow() async throws {
        let now = Date()
        let rows = (0..<650).map { index in
            let entry = RecognitionHistoryEntry(
                id: UUID(),
                createdAt: now.addingTimeInterval(-Double(index)),
                text: "第 \(index) 条记录包含足够长的内容，以便在窄窗口中换成多行。\n\n保留这一空行和末尾文字。"
            )
            return SettingsNativeHistoryList.Row.entry(
                entry,
                number: 650 - index,
                time: "10:00",
                isFirstInDay: index == 0,
                isLastInDay: index == 649
            )
        }
        let coordinator = SettingsNativeHistoryList.Coordinator(
            header: AnyView(Text("历史控制项").padding()),
            rows: rows,
            onDelete: { _ in }
        )
        let scroll = SettingsNativeHistoryScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 480))
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 82, left: 0, bottom: 18, right: 0)
        let table = NSTableView()
        table.headerView = nil
        table.usesAutomaticRowHeights = false
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history")))
        table.delegate = coordinator
        table.dataSource = coordinator
        scroll.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.close() }

        coordinator.install(table: table, scroll: scroll)
        scroll.layoutSubtreeIfNeeded()
        coordinator.prepareHeights(for: scroll.contentSize.width)
        try await Task.sleep(for: .milliseconds(180))
        table.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(table.rect(ofRow: 0).height, 20)

        let targetRow = 501 // Controls row plus the 500th history entry.
        let start = table.rect(ofRow: targetRow).minY + 7 - scroll.contentInsets.top
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: start))
        let reference = scroll.contentView.bounds.minY + scroll.contentInsets.top
        let expectedRow = table.row(at: NSPoint(x: table.bounds.midX, y: reference))
        let expectedOffset = table.rect(ofRow: expectedRow).minY - reference

        coordinator.setWindowResizing(true, width: scroll.contentSize.width)
        window.setContentSize(NSSize(width: 500, height: 480))
        scroll.layoutSubtreeIfNeeded()
        coordinator.setWindowResizing(false, width: scroll.contentSize.width)
        try await Task.sleep(for: .milliseconds(420))

        let actualReference = scroll.contentView.bounds.minY + scroll.contentInsets.top
        let actualRow = table.row(at: NSPoint(x: table.bounds.midX, y: actualReference))
        let actualOffset = table.rect(ofRow: actualRow).minY - actualReference
        XCTAssertEqual(actualRow, expectedRow)
        XCTAssertEqual(actualOffset, expectedOffset, accuracy: 1)
    }
}
