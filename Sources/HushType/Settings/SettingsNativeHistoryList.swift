import AppKit
import CoreText
import SwiftUI

/// A reusable AppKit history table. SwiftUI owns filtering, grouping and
/// destructive-action confirmation; this view only owns row reuse and layout.
struct SettingsNativeHistoryList: NSViewRepresentable {
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case dayHeader(String)
            case entry(RecognitionHistoryEntry, number: Int, time: String, isFirstInDay: Bool, isLastInDay: Bool)
        }

        let id: String
        let kind: Kind

        static func dayHeader(id: String, title: String) -> Self {
            Self(id: "day-\(id)", kind: .dayHeader(title))
        }

        static func entry(
            _ entry: RecognitionHistoryEntry,
            number: Int,
            time: String,
            isFirstInDay: Bool,
            isLastInDay: Bool
        ) -> Self {
            Self(
                id: "entry-\(entry.id.uuidString)",
                kind: .entry(
                    entry,
                    number: number,
                    time: time,
                    isFirstInDay: isFirstInDay,
                    isLastInDay: isLastInDay
                )
            )
        }
    }

    let header: AnyView
    let rows: [Row]
    let topInset: CGFloat
    let sidebarIsResizing: Bool
    let onDelete: (RecognitionHistoryEntry) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(header: header, rows: rows, onDelete: onDelete)
    }

    func makeNSView(context: Context) -> SettingsNativeHistoryScrollView {
        let scroll = SettingsNativeHistoryScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: topInset + 18, left: 0, bottom: 18, right: 0)

        let table = NSTableView()
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.usesAutomaticRowHeights = false
        table.rowHeight = 40
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recognition-history"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        scroll.documentView = table

        context.coordinator.install(table: table, scroll: scroll)
        scroll.widthChanged = { [weak coordinator = context.coordinator] width in
            coordinator?.prepareHeights(for: width)
        }
        scroll.resizeChanged = { [weak coordinator = context.coordinator] active, width in
            coordinator?.setWindowResizing(active, width: width)
        }
        context.coordinator.setSidebarResizing(sidebarIsResizing, width: scroll.contentSize.width)
        return scroll
    }

    func updateNSView(_ scroll: SettingsNativeHistoryScrollView, context: Context) {
        let coordinator = context.coordinator
        scroll.contentInsets = NSEdgeInsets(top: topInset + 18, left: 0, bottom: 18, right: 0)
        // On drag start, freeze before SwiftUI refreshes the hosted controls.
        // On release, refresh while still frozen, then commit all row geometry
        // together through the coordinator's final-width path.
        if sidebarIsResizing {
            coordinator.setSidebarResizing(true, width: scroll.contentSize.width)
            coordinator.update(header: header, rows: rows, onDelete: onDelete)
        } else {
            coordinator.update(header: header, rows: rows, onDelete: onDelete)
            coordinator.setSidebarResizing(false, width: scroll.contentSize.width)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var header: AnyView
        private var rows: [Row]
        private var rowHeights: [CGFloat]
        private var measuredTextWidth: CGFloat = 0
        private var generation = 0
        private var windowResizing = false
        private var sidebarResizing = false
        private var hasPreparedInitialHeights = false
        private var needsHeaderRefresh = false
        private struct TopAnchor {
            let rowID: String
            let offset: CGFloat
        }
        private var resizeAnchor: TopAnchor?
        private var heightTimer: Timer?
        private var onDelete: (RecognitionHistoryEntry) -> Void
        private let headerMeasurementView = SettingsNativeHistoryControlsView()
        private let measurementQueue = DispatchQueue(
            label: "com.felix.hushtype.history-height-preparation",
            qos: .userInitiated
        )
        weak private var table: NSTableView?
        weak private var scroll: SettingsNativeHistoryScrollView?

        private var isResizing: Bool { windowResizing || sidebarResizing }

        init(header: AnyView, rows: [Row], onDelete: @escaping (RecognitionHistoryEntry) -> Void) {
            self.header = header
            self.rows = rows
            self.rowHeights = [1] + rows.map { Self.defaultHeight(for: $0) }
            self.onDelete = onDelete
        }

        func install(table: NSTableView, scroll: SettingsNativeHistoryScrollView) {
            self.table = table
            self.scroll = scroll
            table.reloadData()
            prepareHeights(for: scroll.contentSize.width)
        }

        func update(header: AnyView, rows: [Row], onDelete: @escaping (RecognitionHistoryEntry) -> Void) {
            self.onDelete = onDelete
            self.header = header
            guard self.rows != rows else {
                needsHeaderRefresh = true
                if !isResizing { reloadHeader() }
                return
            }
            self.rows = rows
            rowHeights = [rowHeights.first ?? 1] + rows.map { Self.defaultHeight(for: $0) }
            measuredTextWidth = 0
            generation += 1
            guard let table else { return }
            table.reloadData()
            prepareHeights(for: scroll?.contentSize.width ?? table.bounds.width)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count + 1 }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rowHeights.indices.contains(row) ? rowHeights[row] : 40
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if row == 0 {
                let id = NSUserInterfaceItemIdentifier("recognition-history-controls")
                let view = tableView.makeView(withIdentifier: id, owner: self) as? SettingsNativeHistoryControlsView
                    ?? SettingsNativeHistoryControlsView()
                view.identifier = id
                view.configure(rootView: header)
                return view
            }
            guard rows.indices.contains(row - 1) else { return nil }
            switch rows[row - 1].kind {
            case let .dayHeader(title):
                let id = NSUserInterfaceItemIdentifier("recognition-history-day-header")
                let view = tableView.makeView(withIdentifier: id, owner: self) as? SettingsNativeHistoryDayHeaderView
                    ?? SettingsNativeHistoryDayHeaderView()
                view.identifier = id
                view.configure(title: title)
                return view
            case let .entry(entry, number, time, isFirstInDay, isLastInDay):
                let id = NSUserInterfaceItemIdentifier("recognition-history-entry")
                let view = tableView.makeView(withIdentifier: id, owner: self) as? SettingsNativeHistoryEntryView
                    ?? SettingsNativeHistoryEntryView()
                view.identifier = id
                view.configure(
                    entry: entry,
                    number: number,
                    time: time,
                    isFirstInDay: isFirstInDay,
                    isLastInDay: isLastInDay,
                    onDelete: onDelete
                )
                return view
            }
        }

        func setWindowResizing(_ active: Bool, width: CGFloat) {
            guard windowResizing != active else { return }
            windowResizing = active
            resizePhaseChanged(width: width)
        }

        func setSidebarResizing(_ active: Bool, width: CGFloat) {
            guard sidebarResizing != active else { return }
            sidebarResizing = active
            resizePhaseChanged(width: width)
        }

        private func resizePhaseChanged(width: CGFloat) {
            if isResizing {
                // Ignore measurements for transient widths. Existing row heights
                // stay in place while AppKit reuses the currently visible cells.
                heightTimer?.invalidate()
                heightTimer = nil
                if resizeAnchor == nil { resizeAnchor = captureTopAnchor() }
                generation += 1
                measuredTextWidth = 0
            } else {
                if needsHeaderRefresh { measuredTextWidth = 0 }
                prepareHeights(for: width)
            }
        }

        func prepareHeights(for availableWidth: CGFloat) {
            guard !isResizing, availableWidth > 0 else { return }
            if needsHeaderRefresh {
                table?.reloadData(forRowIndexes: IndexSet(integer: 0), columnIndexes: IndexSet(integer: 0))
                needsHeaderRefresh = false
            }
            let textWidth = Self.textWidth(for: availableWidth)
            guard abs(textWidth - measuredTextWidth) > 0.5 else { return }
            measuredTextWidth = textWidth
            generation += 1
            let request = generation
            let rows = rows
            let headerHeight = measuredHeaderHeight(for: availableWidth)

            measurementQueue.async { [weak self] in
                let heights = [headerHeight] + rows.map { row in
                    switch row.kind {
                    case .dayHeader:
                        Self.defaultHeight(for: row)
                    case let .entry(entry, _, _, _, _):
                        SettingsHistoryTextLayout.rowHeight(for: entry.text, textWidth: textWidth)
                    }
                }
                DispatchQueue.main.async {
                    guard let self, request == self.generation, !self.isResizing, let table = self.table else { return }
                    let anchor = self.hasPreparedInitialHeights ? (self.resizeAnchor ?? self.captureTopAnchor()) : nil
                    self.resizeAnchor = nil
                    let previousHeights = self.rowHeights
                    let shouldAnimate = self.hasPreparedInitialHeights
                        && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    self.hasPreparedInitialHeights = true
                    self.heightTimer?.invalidate()
                    let apply: (CGFloat) -> Void = { [weak self, weak table] progress in
                        guard let self, let table else { return }
                        self.rowHeights = zip(previousHeights, heights).map { current, target in
                            current + (target - current) * progress
                        }
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = 0
                            context.allowsImplicitAnimation = false
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<heights.count))
                            table.layoutSubtreeIfNeeded()
                        if let anchor,
                           let row = self.rowIndex(for: anchor.rowID),
                           let scroll = table.enclosingScrollView {
                            let clip = scroll.contentView
                            var target = clip.bounds.origin
                            target.y = table.rect(ofRow: row).minY - anchor.offset - scroll.contentInsets.top
                            target = clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin
                            clip.setBoundsOrigin(target)
                            scroll.reflectScrolledClipView(clip)
                        }
                            CATransaction.commit()
                        }
                    }
                    if shouldAnimate {
                        let start = CACurrentMediaTime()
                        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                            guard let self, request == self.generation, !self.isResizing else {
                                timer.invalidate()
                                if let self, self.heightTimer === timer { self.heightTimer = nil }
                                return
                            }
                            let fraction = min(1, (CACurrentMediaTime() - start) / 0.24)
                            apply(CGFloat(fraction * fraction * (3 - 2 * fraction)))
                            if fraction >= 1 {
                                timer.invalidate()
                                if self.heightTimer === timer { self.heightTimer = nil }
                            }
                        }
                        self.heightTimer = timer
                        RunLoop.main.add(timer, forMode: .common)
                    } else {
                        apply(1)
                    }
                }
            }
        }

        private func captureTopAnchor() -> TopAnchor? {
            guard let table, let scroll = table.enclosingScrollView else { return nil }
            let reference = scroll.contentView.bounds.minY + scroll.contentInsets.top
            let row = table.row(at: NSPoint(x: table.bounds.midX, y: reference))
            guard row >= 0, let rowID = rowID(at: row) else { return nil }
            return TopAnchor(rowID: rowID, offset: table.rect(ofRow: row).minY - reference)
        }

        private func rowID(at row: Int) -> String? {
            if row == 0 { return "recognition-history-controls" }
            guard rows.indices.contains(row - 1) else { return nil }
            return rows[row - 1].id
        }

        private func rowIndex(for rowID: String) -> Int? {
            if rowID == "recognition-history-controls" { return 0 }
            return rows.firstIndex(where: { $0.id == rowID }).map { $0 + 1 }
        }

        private func reloadHeader() {
            guard !isResizing, let table else { return }
            table.reloadData(forRowIndexes: IndexSet(integer: 0), columnIndexes: IndexSet(integer: 0))
            let availableWidth = scroll?.contentSize.width ?? table.bounds.width
            guard availableWidth > 0 else { return }
            let height = measuredHeaderHeight(for: availableWidth)
            needsHeaderRefresh = false
            guard abs((rowHeights.first ?? 0) - height) > 0.5 else { return }
            rowHeights[0] = height
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
        }

        private func measuredHeaderHeight(for availableWidth: CGFloat) -> CGFloat {
            headerMeasurementView.configure(rootView: header)
            return headerMeasurementView.fittingHeight(for: availableWidth)
        }

        private static func defaultHeight(for row: Row) -> CGFloat {
            if case .dayHeader = row.kind { return 30 }
            return 36
        }

        private static func textWidth(for availableWidth: CGFloat) -> CGFloat {
            SettingsHistoryTextLayout.textWidth(for: availableWidth)
        }
    }
}

/// Shared measurement helpers are deliberately small and independently
/// testable. The cell and Core Text layout use the same font and wrapping
/// behavior, which keeps line breaks (including explicit blank lines) intact.
enum SettingsHistoryTextLayout {
    static func textWidth(for availableWidth: CGFloat) -> CGFloat {
        let contentWidth = max(0, min(736, availableWidth - 32))
        // 14 left padding + number 24 + gap 8 + time 58 + gap 8 +
        // copy/delete area 58 + 14 right padding, plus the NSTextFieldCell's
        // four-point internal horizontal inset. Measuring a little narrower
        // prevents its drawn text from needing a line the row did not reserve.
        return max(32, contentWidth - 186)
    }

    static func rowHeight(for text: String, textWidth: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: paragraph
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
                CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            nil
        )
        // Eight points above and below match SettingsNativeHistoryEntryView.
        return max(36, ceil(size.height) + 16)
    }
}

private final class SettingsNativeHistoryControlsView: NSView {
    private var hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(rootView: AnyView) {
        hostingView.rootView = rootView
        needsLayout = true
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        hostingView.layoutSubtreeIfNeeded()
        return max(1, ceil(hostingView.fittingSize.height))
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }
}

final class SettingsNativeHistoryScrollView: NSScrollView {
    var widthChanged: ((CGFloat) -> Void)?
    var resizeChanged: ((Bool, CGFloat) -> Void)?

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        resizeChanged?(true, contentSize.width)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        resizeChanged?(false, contentSize.width)
    }

    override func layout() {
        super.layout()
        if let table = documentView as? NSTableView, abs(table.frame.width - contentSize.width) > 0.5 {
            table.setFrameSize(NSSize(width: contentSize.width, height: table.frame.height))
            table.tableColumns.first?.width = contentSize.width
        }
        if !inLiveResize { widthChanged?(contentSize.width) }
    }
}

private final class SettingsNativeHistoryDayHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String) { label.stringValue = title }

    override func layout() {
        super.layout()
        let width = min(736, max(0, bounds.width - 32))
        let left = (bounds.width - width) / 2
        label.frame = NSRect(x: left + 12, y: 7, width: max(0, width - 24), height: 16)
    }
}

private final class SettingsNativeHistoryEntryView: NSView {
    private let numberLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let textField = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton()
    private let deleteButton = NSButton()
    private var isFirstInDay = false
    private var isLastInDay = false
    private var entry: RecognitionHistoryEntry?
    private var onDelete: ((RecognitionHistoryEntry) -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        numberLabel.textColor = .tertiaryLabelColor
        timeLabel.textColor = .secondaryLabelColor

        textField.font = .systemFont(ofSize: 13)
        textField.textColor = .labelColor
        textField.maximumNumberOfLines = 0
        textField.lineBreakMode = .byWordWrapping
        textField.cell?.wraps = true
        textField.cell?.usesSingleLineMode = false
        textField.cell?.isScrollable = false
        textField.isSelectable = true

        configure(button: copyButton, symbol: "doc.on.doc", label: L10n.string("settings.history.copy", fallback: "Copy"))
        configure(button: deleteButton, symbol: "trash", label: L10n.string("settings.history.delete", fallback: "Delete"))
        copyButton.target = self
        copyButton.action = #selector(copyText)
        deleteButton.target = self
        deleteButton.action = #selector(deleteText)

        [numberLabel, timeLabel, textField, copyButton, deleteButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(
        entry: RecognitionHistoryEntry,
        number: Int,
        time: String,
        isFirstInDay: Bool,
        isLastInDay: Bool,
        onDelete: @escaping (RecognitionHistoryEntry) -> Void
    ) {
        self.entry = entry
        self.onDelete = onDelete
        self.isFirstInDay = isFirstInDay
        self.isLastInDay = isLastInDay
        numberLabel.stringValue = String(number)
        timeLabel.stringValue = time
        textField.stringValue = entry.text
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let width = min(736, max(0, bounds.width - 32))
        let left = (bounds.width - width) / 2
        let backgroundRect: NSRect
        if isFirstInDay && !isLastInDay {
            // Extend the lower corners below this row so only the top pair is
            // visible. The final row mirrors this for the bottom pair.
            backgroundRect = NSRect(x: left, y: 0, width: width, height: bounds.height + 10)
        } else if isLastInDay && !isFirstInDay {
            backgroundRect = NSRect(x: left, y: -10, width: width, height: bounds.height + 10)
        } else {
            backgroundRect = NSRect(x: left, y: 0, width: width, height: bounds.height)
        }
        let background = NSBezierPath(
            roundedRect: backgroundRect,
            xRadius: (isFirstInDay || isLastInDay) ? 10 : 0,
            yRadius: (isFirstInDay || isLastInDay) ? 10 : 0
        )
        NSColor.controlBackgroundColor.setFill()
        background.fill()
        if !isLastInDay {
            NSColor.separatorColor.setFill()
            NSBezierPath.fill(NSRect(x: left + 14, y: bounds.height - 1, width: max(0, width - 28), height: 1))
        }
    }

    override func layout() {
        super.layout()
        let width = min(736, max(0, bounds.width - 32))
        let left = (bounds.width - width) / 2
        numberLabel.frame = NSRect(x: left + 14, y: 9, width: 24, height: 18)
        timeLabel.frame = NSRect(x: left + 46, y: 9, width: 58, height: 18)
        textField.frame = NSRect(
            x: left + 112,
            y: 8,
            width: max(36, width - 182),
            height: max(20, bounds.height - 16)
        )
        copyButton.frame = NSRect(x: left + width - 58, y: 8, width: 18, height: 20)
        deleteButton.frame = NSRect(x: left + width - 32, y: 8, width: 18, height: 20)
    }

    @objc private func copyText() {
        guard let entry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    @objc private func deleteText() {
        guard let entry else { return }
        onDelete?(entry)
    }

    private func configure(button: NSButton, symbol: String, label: String) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
    }
}
