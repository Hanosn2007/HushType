import AppKit
import CoreText
import SwiftUI

/// A reusable AppKit history table. SwiftUI owns filtering, grouping and
/// destructive-action confirmation; this view only owns row reuse and layout.
struct SettingsNativeHistoryList: NSViewRepresentable {
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case dayHeader(String)
            case entry(
                RecognitionHistoryEntry,
                number: Int,
                time: String,
                isFirstInDay: Bool,
                isLastInDay: Bool,
                isExpanded: Bool
            )
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
            isLastInDay: Bool,
            isExpanded: Bool = false
        ) -> Self {
            Self(
                id: "entry-\(entry.id.uuidString)",
                kind: .entry(
                    entry,
                    number: number,
                    time: time,
                    isFirstInDay: isFirstInDay,
                    isLastInDay: isLastInDay,
                    isExpanded: isExpanded
                )
            )
        }
    }

    let header: AnyView
    let rows: [Row]
    let topInset: CGFloat
    let sidebarIsResizing: Bool
    let onDelete: (RecognitionHistoryEntry) -> Void
    let onToggleExpansion: (RecognitionHistoryEntry) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            header: header,
            rows: rows,
            onDelete: onDelete,
            onToggleExpansion: onToggleExpansion
        )
    }

    func makeNSView(context: Context) -> SettingsNativeHistoryScrollView {
        let scroll = SettingsNativeHistoryScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 18, right: 0)

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
        scroll.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 18, right: 0)
        // On drag start, freeze before SwiftUI refreshes the hosted controls.
        // On release, refresh while still frozen, then commit all row geometry
        // together through the coordinator's final-width path.
        if sidebarIsResizing {
            coordinator.setSidebarResizing(true, width: scroll.contentSize.width)
            coordinator.update(
                header: header,
                rows: rows,
                onDelete: onDelete,
                onToggleExpansion: onToggleExpansion
            )
        } else {
            coordinator.update(
                header: header,
                rows: rows,
                onDelete: onDelete,
                onToggleExpansion: onToggleExpansion
            )
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
        private var onToggleExpansion: (RecognitionHistoryEntry) -> Void
        private let headerMeasurementView = SettingsNativeHistoryControlsView()
        private let measurementQueue = DispatchQueue(
            label: "com.felix.hushtype.history-height-preparation",
            qos: .userInitiated
        )
        weak private var table: NSTableView?
        weak private var scroll: SettingsNativeHistoryScrollView?

        private var isResizing: Bool { windowResizing || sidebarResizing }

        init(
            header: AnyView,
            rows: [Row],
            onDelete: @escaping (RecognitionHistoryEntry) -> Void,
            onToggleExpansion: @escaping (RecognitionHistoryEntry) -> Void = { _ in }
        ) {
            self.header = header
            self.rows = rows
            self.rowHeights = [1] + rows.map { Self.defaultHeight(for: $0) }
            self.onDelete = onDelete
            self.onToggleExpansion = onToggleExpansion
        }

        func install(table: NSTableView, scroll: SettingsNativeHistoryScrollView) {
            self.table = table
            self.scroll = scroll
            table.reloadData()
            prepareHeights(for: scroll.contentSize.width)
        }

        func update(
            header: AnyView,
            rows: [Row],
            onDelete: @escaping (RecognitionHistoryEntry) -> Void,
            onToggleExpansion: @escaping (RecognitionHistoryEntry) -> Void
        ) {
            self.onDelete = onDelete
            self.onToggleExpansion = onToggleExpansion
            self.header = header
            guard self.rows != rows else {
                needsHeaderRefresh = true
                if !isResizing { reloadHeader() }
                return
            }
            // A fold/unfold changes only an entry's height. Keep the same
            // stable row at the same clipped offset while AppKit receives the
            // replacement row model and the measured height animation starts.
            let contentAnchor = hasPreparedInitialHeights ? captureTopAnchor() : nil
            self.rows = rows
            rowHeights = [rowHeights.first ?? 1] + rows.map { Self.defaultHeight(for: $0) }
            measuredTextWidth = 0
            generation += 1
            if resizeAnchor == nil { resizeAnchor = contentAnchor }
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
            case let .entry(entry, number, time, isFirstInDay, isLastInDay, isExpanded):
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
                    isExpanded: isExpanded,
                    onDelete: onDelete,
                    onToggleExpansion: onToggleExpansion
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
                    case let .entry(entry, _, _, _, _, isExpanded):
                        SettingsHistoryTextLayout.rowHeight(
                            for: entry.text,
                            textWidth: textWidth,
                            isExpanded: isExpanded
                        )
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
    static let collapsedLineLimit = 3

    static func textWidth(for availableWidth: CGFloat) -> CGFloat {
        let contentWidth = max(0, min(736, availableWidth - 32))
        // 14 left padding + number 24 + gap 8 + time 58 + gap 8 +
        // action area 58 + 14 right padding, plus the NSTextFieldCell's
        // four-point internal horizontal inset. The expand chevron uses the
        // existing action gutter, so it does not change accepted line wraps.
        return max(32, contentWidth - 186)
    }

    static func rowHeight(for text: String, textWidth: CGFloat, isExpanded: Bool = true) -> CGFloat {
        let textHeight = measuredTextHeight(for: text, textWidth: textWidth)
        let visibleTextHeight = isExpanded
            ? textHeight
            : min(textHeight, collapsedTextHeight)
        // Eight points above and below match SettingsNativeHistoryEntryView.
        return max(36, ceil(visibleTextHeight) + 16)
    }

    static func requiresExpansion(for text: String, textWidth: CGFloat) -> Bool {
        measuredTextHeight(for: text, textWidth: textWidth) > collapsedTextHeight + 0.5
    }

    private static var collapsedTextHeight: CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 13)) * CGFloat(collapsedLineLimit))
    }

    private static func measuredTextHeight(for text: String, textWidth: CGFloat) -> CGFloat {
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
        return ceil(size.height)
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
    private let kindIndicator = NSImageView()
    private let numberLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let textField = NSTextField(wrappingLabelWithString: "")
    private let expandButton = NSButton()
    private let copyButton = NSButton()
    private let deleteButton = NSButton()
    private var isFirstInDay = false
    private var isLastInDay = false
    private var entry: RecognitionHistoryEntry?
    private var onDelete: ((RecognitionHistoryEntry) -> Void)?
    private var onToggleExpansion: ((RecognitionHistoryEntry) -> Void)?
    private var isExpanded = false

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

        expandButton.isBordered = false
        expandButton.contentTintColor = .secondaryLabelColor
        expandButton.target = self
        expandButton.action = #selector(toggleExpansion)

        configure(button: copyButton, symbol: "doc.on.doc", label: L10n.string("settings.history.copy", fallback: "Copy"))
        configure(button: deleteButton, symbol: "trash", label: L10n.string("settings.history.delete", fallback: "Delete"))
        copyButton.target = self
        copyButton.action = #selector(copyText)
        deleteButton.target = self
        deleteButton.action = #selector(deleteText)

        [kindIndicator, numberLabel, timeLabel, textField, expandButton, copyButton, deleteButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(
        entry: RecognitionHistoryEntry,
        number: Int,
        time: String,
        isFirstInDay: Bool,
        isLastInDay: Bool,
        isExpanded: Bool,
        onDelete: @escaping (RecognitionHistoryEntry) -> Void,
        onToggleExpansion: @escaping (RecognitionHistoryEntry) -> Void
    ) {
        self.entry = entry
        self.onDelete = onDelete
        self.onToggleExpansion = onToggleExpansion
        self.isFirstInDay = isFirstInDay
        self.isLastInDay = isLastInDay
        self.isExpanded = isExpanded
        configureKindIndicator(for: entry)
        numberLabel.stringValue = String(number)
        timeLabel.stringValue = time
        textField.stringValue = entry.text
        updateExpansionControl()
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
        kindIndicator.frame = NSRect(x: left + 2, y: 12, width: 10, height: 12)
        numberLabel.frame = NSRect(x: left + 14, y: 9, width: 24, height: 18)
        timeLabel.frame = NSRect(x: left + 46, y: 9, width: 58, height: 18)
        updateExpansionControl()
        textField.frame = NSRect(
            x: left + 112,
            y: 8,
            width: max(36, width - 182),
            height: max(20, bounds.height - 16)
        )
        expandButton.frame = NSRect(x: left + width - 92, y: 8, width: 18, height: 20)
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

    @objc private func toggleExpansion() {
        guard let entry, !expandButton.isHidden else { return }
        onToggleExpansion?(entry)
    }

    private func updateExpansionControl() {
        let width = max(0, bounds.width)
        let isExpandable = SettingsHistoryTextLayout.requiresExpansion(
            for: textField.stringValue,
            textWidth: SettingsHistoryTextLayout.textWidth(for: width)
        )
        expandButton.isHidden = !isExpandable
        let label = L10n.string(
            isExpanded ? "settings.history.collapse" : "settings.history.expand",
            fallback: isExpanded ? "Less" : "More"
        )
        expandButton.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: label
        )
        expandButton.toolTip = label
        textField.maximumNumberOfLines = isExpandable && !isExpanded
            ? SettingsHistoryTextLayout.collapsedLineLimit
            : 0
        textField.lineBreakMode = isExpandable && !isExpanded ? .byTruncatingTail : .byWordWrapping
    }

    private func configureKindIndicator(for entry: RecognitionHistoryEntry) {
        let description = historyKindDescription(for: entry)
        let symbol: String
        switch entry.kind {
        case .dictation:
            symbol = "mic.fill"
            kindIndicator.contentTintColor = .secondaryLabelColor
        case .caption:
            symbol = "captions.bubble.fill"
            kindIndicator.contentTintColor = .controlAccentColor
        }
        kindIndicator.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        kindIndicator.toolTip = description
        kindIndicator.setAccessibilityLabel(description)
    }

    private func historyKindDescription(for entry: RecognitionHistoryEntry) -> String {
        switch entry.kind {
        case .dictation:
            return L10n.string("settings.history.kind.dictation", fallback: "Dictation")
        case .caption:
            let caption = L10n.string("settings.history.kind.caption", fallback: "Caption session")
            guard let metadata = entry.captionMetadata else { return caption }
            let started = metadata.startedAt.formatted(date: .omitted, time: .shortened)
            let ended = metadata.endedAt.formatted(date: .omitted, time: .shortened)
            if let source = metadata.sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
                return L10n.format(
                    "settings.history.caption.session_details",
                    "%1$@ from %2$@, started %3$@, ended %4$@.",
                    arguments: [caption, source, started, ended]
                )
            }
            return L10n.format(
                "settings.history.caption.session_details.no_source",
                "%1$@, started %2$@, ended %3$@.",
                arguments: [caption, started, ended]
            )
        }
    }

    private func configure(button: NSButton, symbol: String, label: String) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
    }
}
