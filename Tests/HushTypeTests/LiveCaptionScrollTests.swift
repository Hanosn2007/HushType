import AppKit
import Foundation
import XCTest
@testable import HushType

@MainActor
final class LiveCaptionScrollTests: XCTestCase {
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private func pumpMainRunLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    private func isAtBottom(_ scrollView: NSScrollView) throws -> Bool {
        let documentView = try XCTUnwrap(scrollView.documentView)
        let clipBounds = scrollView.contentView.bounds
        if documentView.isFlipped {
            return clipBounds.maxY >= documentView.bounds.maxY - 1
        }
        return clipBounds.minY <= documentView.bounds.minY + 1
    }

    private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(descendantScrollViews)
    }

    private func topOrigin(for scrollView: NSScrollView) throws -> NSPoint {
        let documentView = try XCTUnwrap(scrollView.documentView)
        let clipBounds = scrollView.contentView.bounds
        let y = documentView.isFlipped
            ? documentView.bounds.minY
            : max(documentView.bounds.minY, documentView.bounds.maxY - clipBounds.height)
        return NSPoint(x: clipBounds.minX, y: y)
    }

    /// Uses the native accessibility tree rather than a ScrollView offset: a
    /// short document has a zero offset whether it is visibly pinned to the
    /// bottom or incorrectly starts under the header.
    private func accessibilityElements(
        below root: NSObject
    ) -> [NSObject] {
        var result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()

        func collect(_ element: NSObject) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            result.append(element)
            for child in accessibilityAttribute("accessibilityChildren", of: element) as? [NSObject] ?? [] {
                collect(child)
            }
            if let view = element as? NSView {
                view.subviews.forEach(collect)
            }
        }

        collect(root)
        return result
    }

    private func accessibilityAttribute(_ name: String, of element: NSObject) -> Any? {
        guard element.responds(to: NSSelectorFromString(name)) else { return nil }
        return element.value(forKey: name)
    }

    private func textFrame(
        _ text: String,
        in panel: NSPanel
    ) throws -> NSRect {
        let root = try XCTUnwrap(panel.contentView)
        let elements = accessibilityElements(below: root)
        let matches = elements.compactMap { element -> NSRect? in
            let rawValue = accessibilityAttribute("accessibilityValue", of: element)
            let value = (rawValue as? String)
                ?? (rawValue as? NSAttributedString)?.string
                ?? (accessibilityAttribute("accessibilityLabel", of: element) as? String)
            guard value == text else { return nil }
            guard let frame = (accessibilityAttribute("accessibilityFrame", of: element) as? NSValue)?.rectValue else { return nil }
            return frame.isEmpty ? nil : frame
        }
        return try XCTUnwrap(matches.min { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }, "Missing native frame for: \(text). Elements: \(elements.map { String(describing: type(of: $0)) })")
    }

    private func resizeAsUser(_ panel: LiveCaptionWindow, to size: NSSize) {
        let notification = Notification(name: .init("LiveCaptionScrollTests.resize"))
        panel.windowWillStartLiveResize(notification)
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: true, animate: false)
        panel.windowDidResize(notification)
        panel.windowDidEndLiveResize(notification)
        panel.contentView?.layoutSubtreeIfNeeded()
        pumpMainRunLoop(for: 0.20)
    }

    private func assertCaptionIsAtPanelBottom(
        _ captionFrame: NSRect,
        panel: NSPanel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // The caption's lower edge belongs in the panel's 32pt bottom band,
        // and its upper edge must never overlap the 32pt header region.
        XCTAssertGreaterThanOrEqual(captionFrame.minY, panel.frame.minY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(captionFrame.minY, panel.frame.minY + 32, file: file, line: line)
        XCTAssertLessThanOrEqual(captionFrame.maxY, panel.frame.maxY - 32 + 1, file: file, line: line)
    }

    func testLiveFollowSurvivesContentAndPanelResizeButUserScrollSuspendsIt() throws {
        _ = NSApplication.shared

        let rowHeight: CGFloat = 32
        let documentView = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 420, height: rowHeight * 40)
        )
        for index in 0..<40 {
            let row = NSTextField(labelWithString: "Segment \(index + 1)")
            row.frame = NSRect(x: 12, y: CGFloat(index) * rowHeight, width: 360, height: rowHeight)
            documentView.addSubview(row)
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = documentView

        let panel = NSPanel(
            contentRect: NSRect(x: 80, y: 80, width: 420, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = scrollView
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        let controller = LiveCaptionScrollFollowController()
        controller.attach(to: scrollView)
        controller.scheduleScrollToBottomAfterLayout()
        pumpMainRunLoop(for: 0.12)
        XCTAssertTrue(controller.followsLiveEdge)
        XCTAssertTrue(try isAtBottom(scrollView))

        // Commit a forty-first segment and expand the panel while its parent
        // window is animating. Both are programmatic layout events and must
        // retain live-follow through the final clip position.
        let newRow = NSTextField(labelWithString: "Segment 41")
        newRow.frame = NSRect(x: 12, y: rowHeight * 40, width: 360, height: rowHeight)
        documentView.addSubview(newRow)
        documentView.setFrameSize(NSSize(width: 420, height: rowHeight * 41))
        panel.setContentSize(NSSize(width: 460, height: 210))
        controller.scheduleScrollToBottomAfterLayout()
        pumpMainRunLoop(for: 0.12)
        XCTAssertTrue(controller.followsLiveEdge)
        XCTAssertTrue(try isAtBottom(scrollView))

        // Model a real user live-scroll back to the top. Later content must
        // not issue a programmatic scroll that steals this history position.
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: documentView.bounds.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        let historyOffset = scrollView.contentView.bounds.origin.y
        XCTAssertFalse(controller.followsLiveEdge)

        let laterRow = NSTextField(labelWithString: "Segment 42")
        laterRow.frame = NSRect(x: 12, y: rowHeight * 41, width: 360, height: rowHeight)
        documentView.addSubview(laterRow)
        documentView.setFrameSize(NSSize(width: 420, height: rowHeight * 42))
        controller.scheduleScrollToBottomAfterLayout()
        pumpMainRunLoop(for: 0.12)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, historyOffset, accuracy: 0.5)
        XCTAssertFalse(try isAtBottom(scrollView))
    }

    func testLiveCaptionWindowScrollViewFollowsLazyTranscriptAndHonorsUserHistoryScroll() throws {
        _ = NSApplication.shared
        let model = LiveCaptionViewModel()
        model.segments = (0..<40).map { index in
            let words = String(repeating: "segment \(index + 1) ", count: 1 + index % 7)
            return LiveCaptionViewModel.SegmentEntry(text: words)
        }
        let panel = LiveCaptionWindow(viewModel: model, tuning: .init(), onStop: {})
        defer {
            panel.hide()
            pumpMainRunLoop(for: 0.25)
            panel.orderOut(nil)
        }

        panel.show()
        panel.contentView?.layoutSubtreeIfNeeded()
        pumpMainRunLoop(for: 0.40)
        let scrollView = try XCTUnwrap(
            descendantScrollViews(in: try XCTUnwrap(panel.contentView)).first {
                $0.documentView != nil && $0.contentView.bounds.height > 0
            }
        )
        scrollView.documentView?.layoutSubtreeIfNeeded()
        pumpMainRunLoop(for: 0.12)

        // The native controller must materialize and reach the last lazy row
        // when a new committed sentence arrives while the panel also resizes.
        model.segments.append(LiveCaptionViewModel.SegmentEntry(
            text: String(repeating: "newly appended caption ", count: 12)
        ))
        let resizedFrame = NSRect(
            x: panel.frame.minX,
            y: panel.frame.minY,
            width: panel.frame.width,
            height: min(panel.maxSize.height, panel.frame.height + 70)
        )
        panel.setFrame(resizedFrame, display: true, animate: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        pumpMainRunLoop(for: 0.40)
        XCTAssertTrue(try isAtBottom(scrollView))

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        scrollView.contentView.scroll(to: try topOrigin(for: scrollView))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        let historyOffset = scrollView.contentView.bounds.origin.y

        model.segments.append(LiveCaptionViewModel.SegmentEntry(
            text: String(repeating: "history must stay put ", count: 12)
        ))
        panel.contentView?.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        pumpMainRunLoop(for: 0.40)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, historyOffset, accuracy: 0.5)
        XCTAssertFalse(try isAtBottom(scrollView))
    }

    func testShortCaptionGeometryStaysAtBottomBelowHeaderAfterManualResize() throws {
        _ = NSApplication.shared
        let model = LiveCaptionViewModel()
        let panel = LiveCaptionWindow(viewModel: model, tuning: .init(), onStop: {})
        defer {
            panel.hide()
            pumpMainRunLoop(for: 0.25)
            panel.orderOut(nil)
        }

        panel.show()
        panel.contentView?.layoutSubtreeIfNeeded()
        pumpMainRunLoop(for: 0.25)

        // Establish the actual empty-listening state before any transcript
        // arrives; this is the path where the captured regression begins.
        XCTAssertTrue(model.segments.isEmpty)
        XCTAssertTrue(descendantScrollViews(in: try XCTUnwrap(panel.contentView)).isEmpty)

        resizeAsUser(panel, to: NSSize(width: 420, height: 180))
        let firstSentence = "A short caption."
        model.segments = [.init(text: firstSentence)]
        panel.contentView?.layoutSubtreeIfNeeded()
        pumpMainRunLoop(for: 0.35)

        assertCaptionIsAtPanelBottom(try textFrame(firstSentence, in: panel), panel: panel)
    }

    func testTwoShortCaptionsAndLaterLongCaptionKeepNativeTextAtLiveBottom() throws {
        _ = NSApplication.shared
        let model = LiveCaptionViewModel()
        let panel = LiveCaptionWindow(viewModel: model, tuning: .init(), onStop: {})
        defer {
            panel.hide()
            pumpMainRunLoop(for: 0.25)
            panel.orderOut(nil)
        }

        panel.show()
        resizeAsUser(panel, to: NSSize(width: 420, height: 180))

        let firstSentence = "First short sentence."
        let secondSentence = "Second short sentence."
        model.segments = [.init(text: firstSentence)]
        pumpMainRunLoop(for: 0.30)
        let initialFirstFrame = try textFrame(firstSentence, in: panel)
        model.segments.append(.init(text: secondSentence))
        panel.contentView?.layoutSubtreeIfNeeded()
        pumpMainRunLoop(for: 0.35)

        let firstFrame = try textFrame(firstSentence, in: panel)
        let secondFrame = try textFrame(secondSentence, in: panel)
        assertCaptionIsAtPanelBottom(secondFrame, panel: panel)
        XCTAssertEqual(secondFrame.minY, initialFirstFrame.minY, accuracy: 1)
        XCTAssertGreaterThan(firstFrame.minY, initialFirstFrame.minY + 10)
        XCTAssertLessThanOrEqual(firstFrame.maxY, panel.frame.minY + 72)
        XCTAssertLessThan(secondFrame.midY, firstFrame.midY)
        XCTAssertLessThanOrEqual(firstFrame.maxY, panel.frame.maxY - 32 + 1)

        let longSentence = String(repeating: "A later caption grows beyond the short panel width. ", count: 18)
        model.segments.append(.init(text: longSentence))
        panel.contentView?.layoutSubtreeIfNeeded()
        pumpMainRunLoop(for: 0.40)

        let scrollView = try XCTUnwrap(
            descendantScrollViews(in: try XCTUnwrap(panel.contentView)).first {
                $0.documentView != nil && $0.contentView.bounds.height > 0
            }
        )
        let longFrame = try textFrame(longSentence, in: panel)
        XCTAssertTrue(try isAtBottom(scrollView))
        XCTAssertGreaterThanOrEqual(longFrame.minY, panel.frame.minY - 1)
        XCTAssertLessThanOrEqual(longFrame.minY, panel.frame.minY + 32)
    }
}
