import AppKit
import SwiftUI
import XCTest
@testable import HushType

@MainActor
final class SettingsDetailInsetTests: XCTestCase {
    func testStableBuildUsesOfficialSidebarWithoutLegacyBackdrop() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("System sidebar requires macOS 26") }
        XCTAssertFalse(SettingsScrollBlurConfiguration.defaultIsPreview)
        let content = SettingsWindowShell(toggleLabel: "Sidebar", expandedLabel: "Expanded", collapsedLabel: "Collapsed") {
            Text("Stable release sidebar").frame(maxWidth: .infinity, maxHeight: .infinity)
        } sidebar: {
            SettingsDrawnSidebar(sections: HushTypeSettingsSection.allCases, selection: .constant(.profiles))
        } header: {
            HStack {
                SettingsNavigationButtons(backDisabled: false, forwardDisabled: true,
                    backLabel: "Back", forwardLabel: "Forward", back: {}, forward: {})
                Text("处理配置").font(.headline)
                Spacer()
            }
        }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "StableOfficialSidebar")
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let customBackdrops = descendants(host).filter {
            String(reflecting: type(of: $0)).contains("SettingsNativeTopBackdrop.BackdropView")
        }
        XCTAssertEqual(customBackdrops.count, 1, "Only the detail pane should own the custom backdrop; the sidebar must use the system edge")
        if let path = ProcessInfo.processInfo.environment["HUSHTYPE_STABLE_SIDEBAR_CAPTURE"] {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try capture.run(); capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
    }

    func testListAndFormFirstRowClearTheMeasuredHeader() async throws {
        for useList in [true, false] {
            var firstRow: NSView?
            let row = Text("First row").frame(height: 32)
                .background(InsetProbe { firstRow = $0 })
            let content: AnyView = useList
                ? AnyView(List { row }.listStyle(.inset).settingsDetailScrollInset())
                : AnyView(Form { row }.formStyle(.grouped).settingsDetailScrollInset())
            let host = NSHostingView(rootView: content
                .environment(\.settingsTopBarHeight, 96)
                .ignoresSafeArea(.container, edges: .top))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(180))
            host.layoutSubtreeIfNeeded()
            let view = try XCTUnwrap(firstRow)
            let rowRect = view.convert(view.bounds, to: nil)
            let rootRect = host.convert(host.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(rootRect.maxY - rowRect.maxY, 95,
                                        useList ? "List overlaps header" : "Form overlaps header")
        }
    }

    func testChromeClearanceFollowsMeasuredBottomAndHasSafeInitialValue() {
        XCTAssertGreaterThan(SettingsWindowChromeMetrics().detailContentTop, 52)
        let measured = SettingsWindowChromeMetrics(minimumToggleX: 100, titlebarCenterY: 60, titlebarBottomY: 90)
        XCTAssertGreaterThan(measured.detailContentTop, 90)
        let invalid = SettingsWindowChromeMetrics(minimumToggleX: 100, titlebarCenterY: .nan, titlebarBottomY: .nan)
        XCTAssertTrue(invalid.detailContentTop.isFinite)
        XCTAssertEqual(invalid.detailContentTop, SettingsWindowChromeMetrics().detailContentTop)
    }
}

private struct InsetProbe: NSViewRepresentable {
    let report: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        report(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { report(view) }
}
