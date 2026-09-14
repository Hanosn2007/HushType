import AppKit
import SwiftUI
import XCTest
@testable import HushType

@MainActor
final class SettingsInspectorPresentationTests: XCTestCase {
    func testDockButtonHitTestingUsesSuperviewCoordinatesAndMeasuredAnchor() async throws {
        let outer = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let pane = SettingsInspectorPresentation<Text>.PaneView(frame: NSRect(x: 37, y: 29, width: 900, height: 600))
        let slot = SettingsInspectorDockAnchorReader.Reader(frame: NSRect(x: 885, y: 583, width: 36, height: 36))
        let anchor = SettingsInspectorDockAnchor()
        anchor.register(slot)
        outer.addSubview(slot); outer.addSubview(pane)
        let window = NSWindow(contentRect: outer.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = outer
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        var clicks = 0
        pane.setToggle(visible: true, centerY: 28, rightInset: 16, presented: false, dockAnchor: anchor, action: { clicks += 1 })
        pane.configure(width: 420, presented: false, animated: false)
        pane.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        pane.layoutSubtreeIfNeeded()
        let dockedRect = pane.toggleHost.convert(pane.toggleHost.bounds, to: pane)
        XCTAssertEqual(dockedRect.midY, 28, accuracy: 0.5)
        XCTAssertEqual(dockedRect.midX, 866, accuracy: 0.5)
        let point = pane.convert(CGPoint(x: 866, y: 28), to: pane.superview)
        XCTAssertNil(pane.hitTest(point)) // closed overlay yields to the real toolbar
        let hit = try XCTUnwrap(outer.hitTest(point))
        XCTAssertTrue(hit.isDescendant(of: pane.toggleHost))
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            return view.subviews.compactMap { button(in: $0) }.first
        }
        let control = try XCTUnwrap(button(in: pane.toggleHost))
        control.performClick(nil)
        XCTAssertEqual(clicks, 1)
        pane.setToggle(visible: true, centerY: 28, rightInset: 16, presented: false, dockAnchor: anchor, action: { clicks += 10 })
        XCTAssertTrue(button(in: pane.toggleHost) === control)
        control.performClick(nil)
        XCTAssertEqual(clicks, 11)
    }

    func testDockFollowsRealToolbarAcrossWindowResizeAndSearchChanges() async throws {
        let anchor = SettingsInspectorDockAnchor()
        let host = NSHostingView(rootView: DockToolbarHarness(anchor: anchor, history: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "DockToolbarCutoutRegression")
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        var retainedButton: NSView?
        for (width, history) in [(1000, false), (1250, true), (880, false), (1100, true), (950, false)] {
            host.rootView = DockToolbarHarness(anchor: anchor, history: history)
            window.setContentSize(NSSize(width: width, height: 700))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let slot = try XCTUnwrap(anchor.slot)
            let button = try XCTUnwrap(slot.subviews.first)
            if let retainedButton { XCTAssertTrue(button === retainedButton) }
            retainedButton = button
            let rect = slot.convert(slot.bounds, to: host)
            let topGap = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
            XCTAssertEqual(CGFloat(width) - rect.maxX, topGap, accuracy: 1)
            let buttonRect = button.convert(button.bounds, to: slot)
            XCTAssertEqual(buttonRect.midX, slot.bounds.midX, accuracy: 0.5)
            XCTAssertEqual(buttonRect.midY, slot.bounds.midY, accuracy: 0.5)
            if history {
                let search = try XCTUnwrap(anchor.cutoutRegistry?.registrations(in: window).first { $0.id == "search" })
                let searchRect = search.view.convert(search.view.bounds, to: host)
                XCTAssertEqual(rect.minX - searchRect.maxX, topGap, accuracy: 1)
                XCTAssertEqual(rect.midY, searchRect.midY, accuracy: 1)
            }
            // Verify the actual mask consumer, not just registration or frames.
            let snapshot = SettingsAdaptiveCutoutDiagnostics.snapshot(in: window)
            let opening = try XCTUnwrap(snapshot.entries.first { $0.id == "inspector-toggle" })
            let slotWindow = slot.convert(slot.bounds, to: nil)
            XCTAssertEqual(opening.sourceWindowRect.midY, slotWindow.midY, accuracy: 1)
            XCTAssertEqual(opening.appliedWindowRect.midX, slotWindow.midX, accuracy: 1)
            XCTAssertEqual(opening.appliedWindowRect.midY, slotWindow.midY, accuracy: 1)
            XCTAssertEqual(opening.appliedWindowRect.width, 36, accuracy: 1)
            XCTAssertEqual(opening.opacity, 1)
        }
        for open in [true, false] {
            host.rootView = DockToolbarHarness(anchor: anchor, history: true, presented: open)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            let registered = try XCTUnwrap(anchor.cutoutRegistry?.registrations(in: window)
                .first { $0.id == "inspector-toggle" })
            let source = registered.view.convert(registered.view.bounds, to: nil)
            let applied = try XCTUnwrap(SettingsAdaptiveCutoutDiagnostics.snapshot(in: window).entries
                .first { $0.id == "inspector-toggle" })
            XCTAssertEqual(applied.appliedWindowRect.midX, source.midX, accuracy: 1)
            XCTAssertEqual(applied.appliedWindowRect.midY, source.midY, accuracy: 1)
            XCTAssertEqual(applied.appliedWindowRect.width, 36, accuracy: 1)
        }
    }

    func testDockReparentsAfterAnimationAndRapidReversal() async throws {
        let outer = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let toolbar = NSView(frame: NSRect(x: 200, y: 540, width: 684, height: 36))
        let slot = SettingsInspectorDockAnchorReader.Reader(frame: NSRect(x: 648, y: 0, width: 36, height: 36))
        toolbar.addSubview(slot); outer.addSubview(toolbar)
        let anchor = SettingsInspectorDockAnchor(); anchor.register(slot)
        let pane = SettingsInspectorPresentation<Text>.PaneView(frame: outer.bounds)
        outer.addSubview(pane)
        let window = NSWindow(contentRect: outer.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = outer; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        pane.setToggle(visible: true, centerY: 28, rightInset: 16, presented: false, dockAnchor: anchor, action: {})
        pane.configure(width: 420, presented: false, animated: false)
        let button = pane.toggleHost
        XCTAssertTrue(button.superview === slot)
        // Only an ancestor moves; no slot report, SwiftUI update, or pane resize.
        toolbar.setFrameOrigin(NSPoint(x: 150, y: 510))
        XCTAssertEqual(button.convert(button.bounds, to: outer).midX, 816, accuracy: 0.5)
        try await Task.sleep(for: .milliseconds(100))
        pane.configure(width: 420, presented: true, animated: true)
        var openingSamples: [CGFloat] = []
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(20))
            openingSamples.append(try XCTUnwrap(button.layer?.presentation()).frame.midX)
        }
        XCTAssertTrue(openingSamples.allSatisfy { $0 >= 513 && $0 <= 817 }, "Opening path: \(openingSamples)")
        XCTAssertGreaterThan(try XCTUnwrap(openingSamples.first), try XCTUnwrap(openingSamples.last))
        try await Task.sleep(for: .milliseconds(100))
        pane.configure(width: 420, presented: false, animated: true)
        try await Task.sleep(for: .milliseconds(400))
        for _ in 0..<3 {
            pane.configure(width: 420, presented: true, animated: true)
            try await Task.sleep(for: .milliseconds(80))
            let beforeReverse = try XCTUnwrap(button.layer?.presentation()).frame.midX
            pane.configure(width: 420, presented: false, animated: true)
            try await Task.sleep(for: .milliseconds(20))
            let afterReverse = try XCTUnwrap(button.layer?.presentation()).frame.midX
            XCTAssertEqual(afterReverse, beforeReverse, accuracy: 25, "Reversal must continue from the visible position")
            XCTAssertTrue((513...817).contains(afterReverse))
        }
        pane.configure(width: 420, presented: true, animated: true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(button.superview === pane)
        XCTAssertEqual(button.frame.midX, 514, accuracy: 0.5)
        pane.configure(width: 420, presented: false, animated: true)
        var closingSamples: [CGFloat] = []
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(20))
            closingSamples.append(try XCTUnwrap(button.layer?.presentation()).frame.midX)
        }
        XCTAssertTrue(closingSamples.allSatisfy { $0 >= 513 && $0 <= 817 }, "Closing path: \(closingSamples)")
        XCTAssertLessThan(try XCTUnwrap(closingSamples.first), try XCTUnwrap(closingSamples.last))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(button.superview === slot)
    }

    private func findView(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        return view.subviews.compactMap { findView(identifier: identifier, in: $0) }.first
    }
    func testNativeScrollHeaderRemainsAtWindowTop() async throws {
        guard #available(macOS 26.0, *) else { return }
        var headerProbe: NSView?
        let pane = SettingsInspectorPresentation<Text>.PaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: pane.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "NativeInspectorScrollHeader")
        window.contentView = pane
        pane.setContent(AnyView(Form {
            ForEach(0..<20) { index in Section { Text("Row \(index)") } }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            .modifier(SettingsInspectorScrollChrome {
                SettingsInspectorHeader(centerY: 28, closeLabel: "Close", close: {}) { Text("Title") }
                    .background(InspectorContentProbe { headerProbe = $0 })
            })))
        pane.configure(width: 420, presented: true, animated: false)
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        pane.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        pane.layoutSubtreeIfNeeded()
        let probe = try XCTUnwrap(headerProbe)
        XCTAssertEqual(probe.convert(probe.bounds, to: pane).minY, 0, accuracy: 1)
    }
    func testDockingControlSurvivesClosingAndReturnsToHeader() async throws {
        let pane = SettingsInspectorPresentation<Text>.PaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: pane.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        pane.setToggle(visible: true, centerY: 28, rightInset: 8, presented: true, action: {})
        pane.configure(width: 420, presented: true, animated: false)
        pane.layoutSubtreeIfNeeded()
        let retained = pane.toggleHost
        XCTAssertEqual(retained.frame.midX, 514, accuracy: 0.5)
        pane.configure(width: 420, presented: false, animated: true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(retained.frame.midX, 874, accuracy: 0.5)
        XCTAssertNotNil(pane.hitTest(pane.convert(CGPoint(x: 874, y: 28), to: pane.superview)))
        pane.configure(width: 420, presented: true, animated: true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(pane.toggleHost === retained)
        XCTAssertEqual(retained.frame.midX, 514, accuracy: 0.5)
        XCTAssertEqual(retained.frame.midY, 28, accuracy: 0.5)
    }
    func testUnifiedTitlebarDoesNotInsetNestedPaneContent() async throws {
        var probe: NSView?
        let pane = SettingsInspectorPresentation<Text>.PaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: pane.frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "InspectorTitlebarRegression")
        window.contentView = pane
        pane.setContent(AnyView(VStack(spacing: 0) {
            SettingsInspectorHeader(centerY: 28, closeLabel: "Close", close: {}) { Text("Profile") }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(InspectorContentProbe { probe = $0 })))
        pane.configure(width: 420, presented: true, animated: false)
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        pane.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        pane.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(probe)
        let rect = content.convert(content.bounds, to: pane)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.5)
        XCTAssertEqual(rect.height, pane.bounds.height, accuracy: 0.5)
        func button(in view: NSView) -> NSButton? {
            if let result = view as? NSButton { return result }
            return view.subviews.compactMap { button(in: $0) }.first
        }
        let close = try XCTUnwrap(button(in: pane.host))
        let buttonRect = close.convert(close.bounds, to: pane)
        XCTAssertEqual(buttonRect.midY, 28, accuracy: 0.5)
        // AppKit includes optical bezel outsets in an NSButton's frame. The
        // layout/alignment rectangle is the 36pt control shared with the left.
        let alignmentRect = close.alignmentRect(forFrame: close.frame)
        XCTAssertEqual(alignmentRect.height, 36, accuracy: 0.5)
    }

    func testSidebarDragRelayoutsContinuously() {
        let window = CGSize(width: 1000, height: 700)
        let start = SettingsChromeFrames(size: window, progress: 1, sidebarWidth: 180)
        for draggedWidth: CGFloat in [190, 220, 260] {
            let dragging = SettingsChromeFrames(size: window, progress: 1,
                sidebarWidth: draggedWidth)
            XCTAssertEqual(dragging.detail.width, start.detail.width - (draggedWidth - 180))
            XCTAssertEqual(dragging.sidebar.width, draggedWidth)
        }
        let released = SettingsChromeFrames(size: window, progress: 1, sidebarWidth: 260)
        XCTAssertEqual(released.detail.width, start.detail.width - 80)
    }
    func testRapidReversalKeepsOneHostAndFixedWidth() async throws {
        let pane = SettingsInspectorPresentation<Text>.PaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: pane.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        pane.configure(width: 420, presented: false, animated: false)
        pane.layoutSubtreeIfNeeded()
        let original = pane.host
        for title in ["A very long application name", "无", "Microphone"] {
            pane.host.rootView = AnyView(Text(title))
            pane.configure(width: 420, presented: true, animated: true)
            try await Task.sleep(for: .milliseconds(30))
            pane.configure(width: 420, presented: false, animated: true)
        }
        pane.configure(width: 420, presented: true, animated: true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(pane.host === original)
        XCTAssertEqual(pane.subviews.count, 2) // one pane and one retained docking control
        XCTAssertEqual(pane.host.frame.width, 420, accuracy: 0.5)
        XCTAssertEqual(pane.host.frame.minX, pane.bounds.width - 420, accuracy: 0.5)
        pane.configure(width: 420, presented: false, animated: false)
        XCTAssertNil(pane.hitTest(pane.convert(CGPoint(x: 850, y: 80), to: pane.superview)))
    }

    func testNativeListDoesNotAddGuttersAroundFormDescription() async throws {
        let completion = ProfileRowActionCompletion()
        let content = List {
            SettingsDescriptionCard("配置说明")
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            Text("Configuration")
        }.listStyle(.plain).contentMargins(.horizontal, 0, for: .scrollContent)
            .background(ProfileListTableReporter(completion: completion))
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(completion.table)
        XCTAssertEqual(table.intercellSpacing.width, 0)
        XCTAssertEqual(table.rect(ofColumn: 0).width, table.bounds.width, accuracy: 1)
    }
}

private struct InspectorContentProbe: NSViewRepresentable {
    let report: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { let view = NSView(); report(view); return view }
    func updateNSView(_ view: NSView, context: Context) { report(view) }
}

private struct DockToolbarHarness: View {
    let anchor: SettingsInspectorDockAnchor
    let history: Bool
    var presented = false
    @State private var chrome = SettingsWindowChromeMetrics()
    var body: some View {
        SettingsWindowShell(toggleLabel: "Sidebar", expandedLabel: "Expanded", collapsedLabel: "Collapsed", showsSearch: history) {
            Text("Content")
        } sidebar: { Text("Sidebar") } header: {
            HStack(spacing: 16) {
                Text("←  →").frame(width: 72)
                Text(history ? "识别历史" : "概览")
                Spacer(minLength: 12)
                SettingsInspectorToolbarControls(anchor: anchor, showsSearch: history,
                    searchText: .constant(""), searchPrompt: "Search")
            }
        }
        .overlay {
            SettingsInspectorPresentation(isPresented: presented, width: 420, reduceMotion: false,
                showsToggle: true, headerCenterY: chrome.titlebarCenterY,
                rightInset: SettingsToolbarGeometry.edgeGap(centerY: chrome.titlebarCenterY), dockAnchor: anchor) { Text("Editor") }
                .ignoresSafeArea(.container, edges: .top)
        }
        .onPreferenceChange(SettingsChromeMetricsKey.self) { chrome = $0 }
    }
}
