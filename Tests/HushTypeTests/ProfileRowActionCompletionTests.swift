import AppKit
import SwiftUI
import XCTest
@testable import HushType

@MainActor
final class ProfileRowActionCompletionTests: XCTestCase {
    func testReporterFindsTheRealListTableWithoutARowOverlay() async throws {
        let completion = ProfileRowActionCompletion()
        let host = NSHostingView(rootView: List {
            Text("Configuration").swipeActions { Button("Rename") {} }
        }.background(ProfileListTableReporter(completion: completion)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(completion.table)
    }

    func testRequestsNativeClosureBeforeActionAndCancellationStillWorks() async throws {
        let table = TrackingTable()
        let completion = ProfileRowActionCompletion()
        completion.table = table
        var performed = false
        completion.perform(for: UUID()) {
            XCTAssertTrue(table.receivedClose)
            performed = true
        }
        XCTAssertFalse(performed, "The native handler must return before presentation")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(performed)
        performed = false
        completion.perform(for: UUID()) { performed = true }
        completion.cancel()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(performed)
    }

    private final class TrackingTable: NSTableView {
        var receivedClose = false
        override var rowActionsVisible: Bool {
            get { !receivedClose }
            set { if !newValue { receivedClose = true } }
        }
    }
}
