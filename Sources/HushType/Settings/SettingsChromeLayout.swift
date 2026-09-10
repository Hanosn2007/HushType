import AppKit
import SwiftUI

/// Shared chrome keeps the isolated preview and the shipping window identical.
struct SettingsToolbarChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .principal) {
                        Color.clear.frame(width: 1, height: 40).accessibilityHidden(true)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) {
                        Color.clear.frame(width: 1, height: 40).accessibilityHidden(true)
                    }
                }
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
    }
}

struct SettingsNavigationButtons: View {
    let backDisabled: Bool
    let forwardDisabled: Bool
    let backLabel: String
    let forwardLabel: String
    let back: () -> Void
    let forward: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SettingsClickOnlyIconButton(
                symbolName: "chevron.left", label: backLabel,
                isEnabled: !backDisabled, action: back
            )
            .frame(width: 35, height: 36)
            Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 18)
            SettingsClickOnlyIconButton(
                symbolName: "chevron.right", label: forwardLabel,
                isEnabled: !forwardDisabled, action: forward
            )
            .frame(width: 35, height: 36)
        }
        .font(.system(size: 18))
        .buttonStyle(.plain)
        .modifier(SettingsLiquidGlass())
        .fixedSize()
        .settingsBackdropCutout(id: "navigation")
        // This AppKit view registers the rendered capsule. The titlebar drag
        // responder reads its live frame on mouse-down, so the separator and
        // glass surrounding both buttons stay non-draggable as the header
        // moves or the window is resized.
        .background(SettingsTitlebarDragExclusionReporter())
    }
}

private struct SettingsTitlebarDragExclusionRegistryKey: EnvironmentKey {
    static let defaultValue: SettingsTitlebarDragExclusionRegistry? = nil
}

private extension EnvironmentValues {
    var settingsTitlebarDragExclusionRegistry: SettingsTitlebarDragExclusionRegistry? {
        get { self[SettingsTitlebarDragExclusionRegistryKey.self] }
        set { self[SettingsTitlebarDragExclusionRegistryKey.self] = newValue }
    }
}

private struct SettingsAdaptiveCutoutRegistryKey: EnvironmentKey {
    static let defaultValue: SettingsAdaptiveCutoutRegistry? = nil
}

private extension EnvironmentValues {
    var settingsAdaptiveCutoutRegistry: SettingsAdaptiveCutoutRegistry? {
        get { self[SettingsAdaptiveCutoutRegistryKey.self] }
        set { self[SettingsAdaptiveCutoutRegistryKey.self] = newValue }
    }
}

/// Runtime evidence for the adaptive top-backdrop openings. Coordinates are in
/// window space except `appliedLocalRect`, which is in the mask image's
/// top-leading coordinate system.
struct SettingsAdaptiveCutoutDiagnosticEntry: Equatable {
    let id: String
    let sourceWindowRect: CGRect
    let presentationWindowRect: CGRect
    let appliedWindowRect: CGRect
    let appliedLocalRect: CGRect
    let opacity: Double
}

struct SettingsAdaptiveCutoutDiagnosticsSnapshot: Equatable {
    let entries: [SettingsAdaptiveCutoutDiagnosticEntry]
    let registeredCount: Int
    let maskUpdateCount: Int
    let trackingActive: Bool
}

enum SettingsAdaptiveCutoutDiagnostics {
    static func snapshot(in window: NSWindow) -> SettingsAdaptiveCutoutDiagnosticsSnapshot {
        SettingsAdaptiveCutoutRegistry.snapshot(in: window)
    }
}

/// Window-local registration for controls which must be cut out of the top
/// backdrop. It only retains the small reporter views weakly; the registry is
/// retained by the SettingsWindowShell that owns that window.
final class SettingsAdaptiveCutoutRegistry {
    private final class Registration {
        weak var view: NSView?
        let id: String
        var fallbackOpacity: Double

        init(view: NSView, id: String, fallbackOpacity: Double) {
            self.view = view
            self.id = id
            self.fallbackOpacity = fallbackOpacity
        }
    }

    private static let registries = NSMapTable<NSWindow, SettingsAdaptiveCutoutRegistry>(
        keyOptions: .weakMemory, valueOptions: .weakMemory
    )
    private var registrations: [String: Registration] = [:]
    private var observers: [UUID: () -> Void] = [:]
    private var diagnosticSampler: ((NSWindow) -> [SettingsAdaptiveCutoutDiagnosticEntry])?
    private var updateCount = 0
    private var isTracking = false

    func register(_ view: NSView, id: String, fallbackOpacity: Double) {
        purgeDeadRegistrations()
        let clampedOpacity = min(1, max(0, fallbackOpacity))
        if let existing = registrations[id], existing.view === view {
            guard existing.fallbackOpacity != clampedOpacity else { return }
            existing.fallbackOpacity = clampedOpacity
        } else {
            registrations[id] = Registration(view: view, id: id, fallbackOpacity: clampedOpacity)
        }
        if let window = view.window { Self.registries.setObject(self, forKey: window) }
        changed()
    }

    func unregister(_ view: NSView, id: String) {
        guard registrations[id]?.view === view else { return }
        registrations[id] = nil
        changed()
    }

    func geometryDidChange(for view: NSView) {
        guard registrations.values.contains(where: { $0.view === view }) else { return }
        changed()
    }

    func registrations(in window: NSWindow) -> [(id: String, view: NSView, fallbackOpacity: Double)] {
        purgeDeadRegistrations()
        return registrations.values.compactMap { entry in
            guard let view = entry.view, view.window === window else { return nil }
            return (entry.id, view, entry.fallbackOpacity)
        }.sorted { $0.id < $1.id }
    }

    func observe(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID?) {
        guard let token else { return }
        observers[token] = nil
    }

    func record(maskDidUpdate: Bool, trackingActive: Bool) {
        if maskDidUpdate { updateCount += 1 }
        isTracking = trackingActive
    }

    func setTrackingActive(_ active: Bool) {
        isTracking = active
    }

    func setDiagnosticSampler(_ sampler: ((NSWindow) -> [SettingsAdaptiveCutoutDiagnosticEntry])?) {
        diagnosticSampler = sampler
    }

    private func changed() {
        for observer in observers.values { observer() }
    }

    private func purgeDeadRegistrations() {
        let dead = registrations.compactMap { $0.value.view == nil ? $0.key : nil }
        for id in dead {
            registrations[id] = nil
        }
    }

    private func diagnosticSnapshot(in window: NSWindow) -> SettingsAdaptiveCutoutDiagnosticsSnapshot {
        guard let diagnosticSampler else {
            return SettingsAdaptiveCutoutDiagnosticsSnapshot(
                entries: [], registeredCount: 0, maskUpdateCount: 0, trackingActive: false
            )
        }
        let registered = registrations(in: window)
        let entries = diagnosticSampler(window)
        return SettingsAdaptiveCutoutDiagnosticsSnapshot(
            entries: entries,
            registeredCount: registered.count,
            maskUpdateCount: updateCount,
            trackingActive: isTracking
        )
    }

    static func snapshot(in window: NSWindow) -> SettingsAdaptiveCutoutDiagnosticsSnapshot {
        registries.object(forKey: window)?.diagnosticSnapshot(in: window)
            ?? SettingsAdaptiveCutoutDiagnosticsSnapshot(
                entries: [], registeredCount: 0, maskUpdateCount: 0, trackingActive: false
            )
    }
}

/// Registers the bounds SwiftUI actually rendered. The reporter is transparent
/// and never joins hit testing, layout state or the SwiftUI animation graph.
private struct SettingsAdaptiveCutoutReporter: NSViewRepresentable {
    let id: String
    let opacity: Double
    @Environment(\.settingsAdaptiveCutoutRegistry) private var registry

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.configure(id: id, opacity: opacity, registry: registry)
        return view
    }

    func updateNSView(_ view: ReporterView, context: Context) {
        view.configure(id: id, opacity: opacity, registry: registry)
    }

    final class ReporterView: NSView {
        private var id = ""
        private var opacity = 1.0
        private weak var registry: SettingsAdaptiveCutoutRegistry?

        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

        func configure(id: String, opacity: Double, registry: SettingsAdaptiveCutoutRegistry?) {
            if self.id != id || self.registry !== registry {
                self.registry?.unregister(self, id: self.id)
                self.id = id
                self.registry = registry
            }
            self.opacity = opacity
            refreshRegistration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshRegistration()
        }

        override func layout() {
            super.layout()
            refreshRegistration()
            registry?.geometryDidChange(for: self)
        }

        private func refreshRegistration() {
            guard !id.isEmpty else { return }
            guard window != nil else {
                registry?.unregister(self, id: id)
                return
            }
            registry?.register(self, id: id, fallbackOpacity: opacity)
        }

        deinit { registry?.unregister(self, id: id) }
    }
}

extension View {
    /// Attach this to any capsule (including test-only controls) to give the
    /// top backdrop its rendered bounds instead of a guessed frame.
    func settingsBackdropCutout(id: String, opacity: Double = 1) -> some View {
        background(SettingsAdaptiveCutoutReporter(id: id, opacity: opacity))
    }
}

/// A window-local, weak registry of rendered controls that titlebar dragging
/// must avoid. Frames are resolved only for the mouse-down event, so layout
/// animation does not feed state changes back through the whole SwiftUI shell.
final class SettingsTitlebarDragExclusionRegistry {
    private final class WeakView {
        weak var value: NSView?

        init(_ value: NSView) {
            self.value = value
        }
    }

    private var registeredViews: [WeakView] = []

    func register(_ view: NSView) {
        registeredViews.removeAll { $0.value == nil }
        guard !registeredViews.contains(where: { $0.value === view }) else { return }
        registeredViews.append(WeakView(view))
    }

    func contains(_ location: NSPoint, in window: NSWindow) -> Bool {
        registeredViews.removeAll { $0.value == nil }
        return registeredViews.contains { entry in
            guard let view = entry.value, view.window === window else { return false }
            return view.convert(view.bounds, to: nil).contains(location)
        }
    }
}

/// Registers the rendered navigation capsule without participating in hit
/// testing. The drag responder resolves its actual bounds when needed.
private struct SettingsTitlebarDragExclusionReporter: NSViewRepresentable {
    @Environment(\.settingsTitlebarDragExclusionRegistry) private var registry

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.registry = registry
        view.register()
        return view
    }

    func updateNSView(_ view: ReporterView, context: Context) {
        view.registry = registry
        view.register()
    }

    final class ReporterView: NSView {
        weak var registry: SettingsTitlebarDragExclusionRegistry?

        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            register()
        }

        func register() {
            registry?.register(self)
        }
    }
}

/// A small AppKit button that consumes its entire mouse sequence. It sends its
/// action only when the pointer has not moved beyond the drag tolerance and
/// ends within the button, so a titlebar drag can never become an accidental
/// navigation or sidebar toggle on mouse-up.
struct SettingsClickOnlyIconButton: NSViewRepresentable {
    let symbolName: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> ClickOnlyButton {
        let button = ClickOnlyButton()
        button.configure(symbolName: symbolName, label: label, action: action)
        button.isEnabled = isEnabled
        return button
    }

    func updateNSView(_ button: ClickOnlyButton, context: Context) {
        button.configure(symbolName: symbolName, label: label, action: action)
        button.isEnabled = isEnabled
    }

    final class ClickOnlyButton: NSButton {
        private var actionHandler: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            imagePosition = .imageOnly
            focusRingType = .none
            setButtonType(.momentaryChange)
            target = self
            action = #selector(performConfiguredAction(_:))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func configure(symbolName: String, label: String, action: @escaping () -> Void) {
            image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: label
            )?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            toolTip = label
            setAccessibilityLabel(label)
            actionHandler = action
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled, let window else { return }
            let start = event.locationInWindow
            isHighlighted = true
            defer { isHighlighted = false }
            var didDrag = false

            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp {
                    let end = next.locationInWindow
                    let endsInside = bounds.contains(convert(end, from: nil))
                    if !didDrag && settingsClickOnlyActionAllowed(
                        start: start, end: end, endsInside: endsInside
                    ) {
                        sendAction(action, to: target)
                    }
                    return
                }
                if !settingsClickOnlyActionAllowed(
                    start: start, end: next.locationInWindow, endsInside: true
                ) {
                    didDrag = true
                    isHighlighted = false
                }
            }
        }

        @objc private func performConfiguredAction(_ sender: Any?) {
            actionHandler?()
        }
    }
}

func settingsClickOnlyActionAllowed(
    start: NSPoint, end: NSPoint, endsInside: Bool, minimumDragDistance: CGFloat = 3
) -> Bool {
    guard endsInside else { return false }
    let deltaX = end.x - start.x
    let deltaY = end.y - start.y
    return deltaX * deltaX + deltaY * deltaY < minimumDragDistance * minimumDragDistance
}

private struct SettingsTopBarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var settingsTopBarHeight: CGFloat {
        get { self[SettingsTopBarHeightKey.self] }
        set { self[SettingsTopBarHeightKey.self] = newValue }
    }
}

struct SettingsLiquidGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 1))
        }
    }
}

struct SettingsHistorySearch: View {
    @Binding var text: String
    let prompt: String
    /// A parent which hides this control through a SwiftUI-only compositing
    /// opacity can pass that value here. The native reporter also samples an
    /// AppKit presentation opacity whenever one exists.
    var cutoutOpacity: Double = 1
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
                .focused($focused).accessibilityLabel(prompt)
        }
        .padding(.horizontal, 12).frame(width: 190, height: 36)
        .clipShape(Capsule())
        .modifier(SettingsLiquidGlass())
        .background {
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden().accessibilityHidden(true)
        }
        .settingsBackdropCutout(id: "search", opacity: cutoutOpacity)
    }
}

/// Shared by the real settings window and the isolated visual test harness.
struct SettingsWindowShell<Detail: View, Sidebar: View, Header: View>: View {
    let toggleLabel: String
    let expandedLabel: String
    let collapsedLabel: String
    var stabilizesDetailWidth = false
    var showsSearch = false
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var header: () -> Header
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarExpanded = true
    @State private var sidebarWidth: CGFloat = 180
    @State private var sidebarDragOrigin: CGFloat?
    @State private var chrome = SettingsWindowChromeMetrics()
    @State private var titlebarDragExclusionRegistry = SettingsTitlebarDragExclusionRegistry()
    @State private var adaptiveCutoutRegistry = SettingsAdaptiveCutoutRegistry()

    // Scroll content extends behind the B8 opacity cover and native glass controls.
    private var extendsScrollUnderHeader: Bool { true }
    private var sidebarAboveDetailBackdrop: Bool {
        if #available(macOS 26.0, *) {
            return SettingsScrollBlurConfiguration.defaultIsPreview
        }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
            let resolvedSidebarWidth = settingsSidebarWidth(sidebarWidth, windowWidth: geometry.size.width)
            SettingsChromeLayout(progress: sidebarExpanded ? 1 : 0,
                                 sidebarWidth: resolvedSidebarWidth,
                                 minimumToggleX: chrome.minimumToggleX,
                                 titlebarCenterY: chrome.titlebarCenterY,
                                 extendsDetailUnderHeader: extendsScrollUnderHeader,
                                 detailLayoutProgress: stabilizesDetailWidth ? (sidebarExpanded ? 1 : 0) : nil) {
                detail()
                    .environment(\.settingsTopBarHeight, max(64, chrome.titlebarCenterY + 28))
                    .environment(\.settingsSidebarIsResizing, sidebarDragOrigin != nil)
                    .clipped()
                    .transaction { transaction in
                        if stabilizesDetailWidth { transaction.animation = nil }
                    }
                sidebar()
                    .environment(\.settingsTopBarHeight, max(48, chrome.titlebarCenterY + 22))
                    // Clip both the scrolled rows and their backdrop before adding
                    // the glass rim; otherwise rows can escape above the panel.
                    .clipShape(RoundedRectangle(cornerRadius: 20).inset(by: 1.5))
                    .modifier(SettingsSidebarSurface())
                    .allowsHitTesting(sidebarExpanded)
                    .accessibilityHidden(!sidebarExpanded)
                    .overlay(alignment: .topTrailing) {
                        if sidebarExpanded {
                            SettingsSidebarResizeHandle(
                                titlebarBottomY: chrome.titlebarBottomY,
                                onChanged: { translation in
                                    let origin = sidebarDragOrigin ?? resolvedSidebarWidth
                                    sidebarDragOrigin = origin
                                    sidebarWidth = settingsSidebarWidth(origin + translation,
                                                                       windowWidth: geometry.size.width)
                                },
                                onEnded: { sidebarDragOrigin = nil }
                            )
                        }
                    }
                    // The public sidebar owns its native glass and shadow. The
                    // right backdrop must neither resample nor cover that shadow
                    // at detail.minX, or a hard vertical seam appears in light mode.
                    .zIndex(sidebarAboveDetailBackdrop ? 1 : 0)
                Group {
                    if extendsScrollUnderHeader {
                        SettingsChromeFadeLayer(progress: sidebarExpanded ? 1 : 0,
                            sidebarWidth: resolvedSidebarWidth,
                            minimumToggleX: chrome.minimumToggleX,
                            titlebarCenterY: chrome.titlebarCenterY,
                            detailLayoutProgress: stabilizesDetailWidth ? (sidebarExpanded ? 1 : 0) : nil,
                            titlebarBottomY: chrome.titlebarBottomY)
                    } else {
                        Color.clear
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                // Keep titlebar hit testing above the sidebar even though the
                // visual backdrop now sits below it.
                SettingsTitlebarDragRegion(registry: titlebarDragExclusionRegistry)
                    .frame(height: chrome.titlebarBottomY)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .accessibilityHidden(true)
                    .zIndex(2)
                SettingsClickOnlyIconButton(
                    symbolName: "sidebar.left", label: toggleLabel, isEnabled: true
                ) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                        sidebarExpanded.toggle()
                    }
                }
                .frame(width: 36, height: 36)
                .help(toggleLabel)
                .accessibilityLabel(toggleLabel)
                .accessibilityValue(sidebarExpanded ? expandedLabel : collapsedLabel)
                .accessibilityIdentifier("hushtype.settings.sidebar-toggle")
                .modifier(SettingsToggleGlassBackdrop(progress: sidebarExpanded ? 1 : 0,
                                                      sidebarWidth: resolvedSidebarWidth,
                                                      minimumToggleX: chrome.minimumToggleX))
                .zIndex(3)
                header()
                    .environment(\.settingsTitlebarDragExclusionRegistry, titlebarDragExclusionRegistry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(3)
            }
            .environment(\.settingsAdaptiveCutoutRegistry, adaptiveCutoutRegistry)
            .onChange(of: geometry.size.width) { _, width in
                sidebarWidth = settingsSidebarWidth(sidebarWidth, windowWidth: width)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(SettingsWindowChromeReader { chrome = $0 })
        .clipped()
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The accepted HTML prototype's single-progress layout, in window points.
/// Layout interpolation moves existing views; it never rebuilds the toggle or
/// asks a NavigationSplitView to create a second, independently moving toggle.
struct SettingsChromeFrames {
    let sidebar: CGRect
    let detail: CGRect
    let toggle: CGRect
    let header: CGRect

    init(size: CGSize, progress: CGFloat, sidebarWidth: CGFloat = 180,
         minimumToggleX: CGFloat = 100, titlebarCenterY: CGFloat = 28,
         extendsDetailUnderHeader: Bool = false, detailLayoutProgress: CGFloat? = nil) {
        let progress = min(1, max(0, progress))
        let sidebarRight = (sidebarWidth + 8) * progress
        let toggleX = max(minimumToggleX, sidebarRight - 44)
        let headerX = max(toggleX + 52, sidebarRight + 18)
        let headerBottom = max(64, titlebarCenterY + 28)
        // Lazy variable-height rows must not reflow at every animation frame.
        // Their target width changes once; the container origin still animates.
        let detailInset = (sidebarWidth + 8) * min(1, max(0, detailLayoutProgress ?? progress))
        sidebar = CGRect(x: sidebarRight - sidebarWidth, y: 8,
                         width: sidebarWidth, height: max(0, size.height - 16))
        // The native backdrop samples content as it scrolls underneath the bar.
        // Content padding establishes the resting position inside the viewport.
        let detailTop = extendsDetailUnderHeader ? 0 : headerBottom
        detail = CGRect(x: sidebarRight, y: detailTop,
                        width: max(0, size.width - detailInset), height: max(0, size.height - detailTop))
        toggle = CGRect(x: toggleX, y: titlebarCenterY - 18, width: 36, height: 36)
        header = CGRect(x: headerX, y: titlebarCenterY - 18,
                        width: max(0, size.width - headerX - max(8, titlebarCenterY - 18)), height: 36)
    }
}

struct SettingsChromeLayout: Layout {
    var progress: CGFloat
    var sidebarWidth: CGFloat = 180
    var minimumToggleX: CGFloat
    var titlebarCenterY: CGFloat
    var extendsDetailUnderHeader = false
    var detailLayoutProgress: CGFloat? = nil

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 950, height: 650))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5 || subviews.count == 6 else { return }
        let frames = SettingsChromeFrames(size: bounds.size, progress: progress,
                                          sidebarWidth: sidebarWidth,
                                          minimumToggleX: minimumToggleX, titlebarCenterY: titlebarCenterY,
                                          extendsDetailUnderHeader: extendsDetailUnderHeader,
                                          detailLayoutProgress: detailLayoutProgress)
        let fullFrame = CGRect(origin: .zero, size: bounds.size)
        // Older standalone previews combine the backdrop and drag region;
        // the product keeps them separate so their stacking can differ.
        let placements = subviews.count == 6
            ? [frames.detail, frames.sidebar, fullFrame, fullFrame, frames.toggle, frames.header]
            : [frames.detail, frames.sidebar, fullFrame, frames.toggle, frames.header]
        for (view, frame) in zip(subviews, placements) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

struct SettingsWindowChromeMetrics: Equatable {
    var minimumToggleX: CGFloat = 100
    var titlebarCenterY: CGFloat = 28
    var titlebarBottomY: CGFloat = 52
}

/// Public NSWindow standard buttons are the only geometry source. No titlebar
/// subview traversal, private class names, KVC or replacement of system buttons.
struct SettingsWindowChromeReader: NSViewRepresentable {
    let onChange: (SettingsWindowChromeMetrics) -> Void

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: Reader, context: Context) {
        view.onChange = onChange
        view.scheduleRead()
    }

    final class Reader: NSView {
        override var isFlipped: Bool { true }
        var onChange: ((SettingsWindowChromeMetrics) -> Void)?
        private var scheduled = false
        private var previous: SettingsWindowChromeMetrics?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleRead()
        }

        override func layout() {
            super.layout()
            scheduleRead()
        }

        func scheduleRead() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard let window = self.window, self.bounds.height > 0 else { return }
                let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                    .compactMap { window.standardWindowButton($0) }
                    .filter { !$0.isHiddenOrHasHiddenAncestor }
                let frames = buttons.map { self.convert($0.bounds, from: $0) }
                var metrics = SettingsWindowChromeMetrics()
                if let right = frames.map(\.maxX).max(), let centerY = frames.first?.midY {
                    metrics.minimumToggleX = right + 16
                    metrics.titlebarCenterY = centerY
                } else if window.styleMask.contains(.fullScreen) {
                    metrics.minimumToggleX = 16
                }
                let layoutTop = self.convert(window.contentLayoutRect, from: nil).minY
                metrics.titlebarBottomY = max(metrics.titlebarCenterY + 18, layoutTop)
                guard metrics != self.previous else { return }
                self.previous = metrics
                self.onChange?(metrics)
            }
        }
    }
}

struct SettingsSidebarSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.background {
                SettingsSidebarGlass()
            }
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

/// Preserve a single native glass surface. The blur host clips its captured
/// input before applying the separate variable-blur stage.
private struct SettingsSidebarGlass: View {
    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        } else {
            RoundedRectangle(cornerRadius: 20).fill(.regularMaterial)
        }
    }
}

func settingsSidebarWidthRange(windowWidth: CGFloat) -> ClosedRange<CGFloat> {
    let maximum = max(180, min(320, windowWidth - 520))
    return 180...maximum
}

func settingsSidebarWidth(_ requestedWidth: CGFloat, windowWidth: CGFloat) -> CGFloat {
    let range = settingsSidebarWidthRange(windowWidth: windowWidth)
    return min(range.upperBound, max(range.lowerBound, requestedWidth))
}

/// The hit target straddles the panel's right edge, but begins under the
/// titlebar so it does not steal the accepted window-drag region.
private struct SettingsSidebarResizeHandle: View {
    let titlebarBottomY: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let top = max(0, titlebarBottomY - 8)
            let height = max(0, geometry.size.height - top)
            SettingsSidebarResizeHandleView(onChanged: onChanged, onEnded: onEnded)
            .frame(width: 8, height: height)
            .position(x: geometry.size.width, y: top + height / 2)
        }
        .accessibilityHidden(true)
    }
}

/// The real hit view also owns the cursor rect. The former cursor-only view
/// returned `nil` from hit testing while a separate SwiftUI gesture consumed
/// mouse input, making cursor updates unreliable at the panel edge.
private struct SettingsSidebarResizeHandleView: NSViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> ResizeHandleView {
        let view = ResizeHandleView()
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ view: ResizeHandleView, context: Context) {
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.window?.invalidateCursorRects(for: view)
    }

    final class ResizeHandleView: NSView {
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: (() -> Void)?
        private var mouseMonitor: Any?
        private var ownsCursor = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                guard let self else { return event }
                let inside = event.window === self.window
                    && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                if inside {
                    NSCursor.resizeLeftRight.set()
                } else if self.ownsCursor {
                    NSCursor.arrow.set()
                }
                self.ownsCursor = inside
                return event
            }
        }

        deinit {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        }

        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }

        override func resetCursorRects() {
            discardCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let startX = event.locationInWindow.x
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp {
                    onEnded?()
                    return
                }
                onChanged?(next.locationInWindow.x - startX)
            }
            onEnded?()
        }
    }
}

private struct SettingsToggleGlassBackdrop: ViewModifier, Animatable {
    var progress: CGFloat
    let sidebarWidth: CGFloat
    let minimumToggleX: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    private var glassOpacity: Double { settingsToggleGlassOpacity(progress, sidebarWidth, minimumToggleX) }
    func body(content: Content) -> some View {
        content.background {
            Color.clear.frame(width: 44, height: 36)
                .modifier(SettingsLiquidGlass())
                .settingsBackdropCutout(id: "toggle", opacity: glassOpacity)
                .opacity(glassOpacity)
                .allowsHitTesting(false)
        }
    }
}

func settingsToggleGlassOpacity(_ progress: CGFloat, _ sidebarWidth: CGFloat = 180,
                                _ minimumToggleX: CGFloat) -> Double {
    let right = (sidebarWidth + 8) * min(1, max(0, progress))
    let gap = max(minimumToggleX, right - 44) - 4 - right
    let startingGap = max(1, minimumToggleX - 4)
    let t = min(1, max(0, (gap / startingGap - 0.2) / 0.8))
    return Double(t * t * (3 - 2 * t))
}

// One animation progress drives the content frames, glass and fade openings.
// This layer is below the actual controls; it cannot tint or clip their glyphs.
private struct SettingsChromeFadeLayer: View, Animatable {
    var progress: CGFloat
    let sidebarWidth: CGFloat
    let minimumToggleX, titlebarCenterY: CGFloat
    let detailLayoutProgress: CGFloat?
    @Environment(\.settingsAdaptiveCutoutRegistry) private var cutoutRegistry
    let titlebarBottomY: CGFloat
    @Environment(\.displayScale) private var displayScale
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    private var usesPublicSidebarEffect: Bool {
        if #available(macOS 26.0, *) {
            return SettingsScrollBlurConfiguration.defaultIsPreview
        }
        return false
    }
    var body: some View {
        GeometryReader { geometry in
            let f = SettingsChromeFrames(size: geometry.size, progress: progress,
                sidebarWidth: sidebarWidth,
                minimumToggleX: minimumToggleX, titlebarCenterY: titlebarCenterY,
                extendsDetailUnderHeader: true, detailLayoutProgress: detailLayoutProgress)
            ZStack(alignment: .topLeading) {
                fade(in: f.detail, height: max(0, titlebarBottomY - f.detail.minY), sidebar: false,
                     hostWidth: geometry.size.width, cutoutRegistry: cutoutRegistry)
                // Preview on macOS 26 uses the public scroll-edge host.
                // All other configurations retain the original sidebar effect.
                if !usesPublicSidebarEffect {
                    fade(in: f.sidebar, height: max(0, titlebarBottomY - f.sidebar.minY), sidebar: true,
                         hostWidth: geometry.size.width, cutoutRegistry: cutoutRegistry)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
    private func fade(in frame: CGRect, height: CGFloat, sidebar: Bool,
                      hostWidth: CGFloat,
                      cutoutRegistry: SettingsAdaptiveCutoutRegistry?) -> some View {
        // Apply the mask inside AppKit, rather than flattening the backdrop
        // through a SwiftUI compositing group. Glass controls sample through
        // the same openings, independently of the fading top material.
        SettingsNativeTopBackdrop(
            mask: SettingsTopBackdropMask(
                size: CGSize(width: frame.width, height: height),
                colorHeight: height,
                openingInset: 1.5 / max(1, displayScale),
                panelHeight: frame.height,
                sidebar: sidebar,
                cutouts: [],
                origin: frame.origin),
            cutoutRegistry: cutoutRegistry)
        // Keep the sampling host fixed in window coordinates. The right-panel
        // region and its mask move together inside one Core Animation commit.
        .frame(width: hostWidth, height: titlebarBottomY)
        .frame(width: hostWidth, height: frame.height, alignment: .top)
    }
}

/// Separate masks control the color cover and backdrop radius. Both keep
/// the sidebar rim and Liquid Glass capsules out of the backdrop effect.
struct SettingsTopBackdropMask: Equatable {
    let size: CGSize
    var colorHeight: CGFloat? = nil
    var openingInset: CGFloat = 0
    var excludedRects: [CGRect] = []
    var blurInset: CGFloat = 1.5
    let panelHeight: CGFloat
    let sidebar: Bool
    var cutouts: [SettingsTopBackdropCutout]
    let origin: CGPoint

    /// Only inputs read by the image renderer belong in its cache key.
    /// The panel's placement still updates every frame, independently of pixels.
    var rasterIdentity: Self {
        Self(size: size, colorHeight: colorHeight, openingInset: openingInset,
             excludedRects: excludedRects, blurInset: sidebar ? blurInset : 0,
             panelHeight: sidebar ? panelHeight : 0, sidebar: sidebar,
             cutouts: cutouts, origin: .zero)
    }

    func image(blur: Bool = false) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        // Both images are rendered in the shell's top-leading coordinates.
        return NSImage(size: size, flipped: true) { bounds in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            if sidebar {
                let inset = blur ? blurInset : 1.5
                if size.width <= 2 * inset || (blur && size.height <= 2 * inset) { return true }
                NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: panelHeight)
                    .insetBy(dx: inset, dy: inset), xRadius: max(0, 20 - inset), yRadius: max(0, 20 - inset)).addClip()
            }
            // Preserve the exact one-point rows and alpha curves. Filling the
            // existing CGContext avoids creating an NSColor and NSBezierPath
            // for every row of both images on each animation frame.
            let denominator = max(1, ceil(blur ? bounds.height : (colorHeight ?? bounds.height)) - 1)
            let component: CGFloat = blur ? 0 : 1
            for row in 0..<Int(ceil(bounds.height)) {
                let y = CGFloat(row)
                let alpha = blur ? settingsTopBlurStrength(y / denominator)
                                 : settingsTopTintOpacity(y / denominator)
                context.setFillColor(gray: component, alpha: alpha)
                context.fill(CGRect(x: 0, y: y, width: bounds.width, height: 1))
            }
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            func cutout(_ rect: CGRect, opacity: Double) {
                NSColor.white.withAlphaComponent(opacity).setFill()
                // Adaptive reporter geometry is already local to this mask's
                // top-leading image coordinate system.
                let local = rect.insetBy(dx: openingInset, dy: openingInset)
                guard local.width > 0, local.height > 0 else { return }
                NSBezierPath(roundedRect: local, xRadius: local.height / 2,
                             yRadius: local.height / 2).fill()
            }
            for cutoutEntry in cutouts {
                cutout(cutoutEntry.rect, opacity: cutoutEntry.opacity)
            }
            NSColor.white.setFill()
            for rect in excludedRects { NSBezierPath(rect: rect).fill() }
            return true
        }
    }
}

struct SettingsTopBackdropCutout: Equatable {
    let rect: CGRect
    let opacity: Double
}

private extension CGRect {
    var hasFiniteCoordinates: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite
    }
}

func settingsTopBlurStrength(_ normalizedY: CGFloat) -> CGFloat {
    return 0.1 * (1 - min(1, max(0, normalizedY)))
}


// Smoothstep gives both ends a flat tangent; peak tint remains translucent.
func settingsTopTintOpacity(_ normalizedY: CGFloat) -> CGFloat {
    let t = 1 - min(1, max(0, normalizedY))
    return 0.35 * t * t * (3 - 2 * t)
}

/// Maps real scroll velocity to the temporary top-blur radius. Keeping this
/// independent from the AppKit host makes the continuous response testable.
enum SettingsScrollBlurDynamics {
    /// At this many points per second the radius reaches its configured lower bound.
    static let speedForMinimumRadius: CGFloat = 1_800
    /// Low-pass filtering removes noisy per-event velocity changes.
    static let speedSmoothingTime: CFTimeInterval = 0.10
    /// The radius follows new input gently enough to avoid a triggered feel.
    static let liveRadiusResponseTime: CFTimeInterval = 0.16
    /// Once input stops, speed and radius decay more gradually back to rest.
    static let idleSpeedDecayTime: CFTimeInterval = 0.25
    static let idleRadiusResponseTime: CFTimeInterval = 0.24
    static let idleDelay: CFTimeInterval = 0.10
    static let settlingTimerInterval: TimeInterval = 1.0 / 30.0
    static let settleRadiusTolerance: CGFloat = 0.02
    static let settleSpeedTolerance: CGFloat = 1

    static func targetRadius(speed: CGFloat, minimumRadius: CGFloat, maximumRadius: CGFloat) -> CGFloat {
        let lower = min(minimumRadius, maximumRadius)
        let upper = max(minimumRadius, maximumRadius)
        let normalized = min(1, max(0, abs(speed) / speedForMinimumRadius))
        // Smoothstep avoids a visible corner at rest and at the configured limit.
        let eased = normalized * normalized * (3 - 2 * normalized)
        return upper - (upper - lower) * eased
    }

    static func exponentiallyApproached(
        current: CGFloat,
        target: CGFloat,
        elapsed: CFTimeInterval,
        timeConstant: CFTimeInterval
    ) -> CGFloat {
        guard elapsed > 0, timeConstant > 0 else { return current }
        let progress = 1 - CGFloat(exp(-elapsed / timeConstant))
        return current + (target - current) * min(1, max(0, progress))
    }
}

/// Viewport coordinates are converted into this backdrop's local space. The
/// complete panel participates, so nested editors below the top bar still count.
func settingsScrollViewportBelongsToPanel(_ viewport: CGRect, panel: CGRect) -> Bool {
    guard !viewport.isEmpty, !panel.isEmpty,
          viewport.midX >= panel.minX, viewport.midX < panel.maxX else { return false }
    let overlap = viewport.intersection(panel)
    return !overlap.isNull && overlap.width >= min(viewport.width, panel.width) * 0.5 && overlap.height > 0
}

/// Experimental Core Animation backdrop path. These two runtime types are
/// non-public API; keep this limitation explicit in preview delivery notes.
/// The original native Form and controls remain live and are never snapshotted.
private struct SettingsNativeTopBackdrop: NSViewRepresentable {
    let mask: SettingsTopBackdropMask
    let cutoutRegistry: SettingsAdaptiveCutoutRegistry?
    func makeNSView(context: Context) -> BackdropView { BackdropView() }
    func updateNSView(_ view: BackdropView, context: Context) { view.update(mask, cutoutRegistry: cutoutRegistry) }

    final class BackdropView: NSView {
        private var baseConfiguration: SettingsTopBackdropMask?
        private var configuration: SettingsTopBackdropMask?
        private var lastRasterIdentity: SettingsTopBackdropMask?
        private var lastRasterScale: CGFloat?
        private var cutoutRegistry: SettingsAdaptiveCutoutRegistry?
        private var cutoutObserver: UUID?
        @available(macOS 14.0, *) private var cutoutDisplayLink: CADisplayLink?
        private var cutoutTrackingStopTimer: Timer?
        private var cutoutTrackingDeadline: CFTimeInterval = 0
        private var lastAppliedCutoutRects: [String: CGRect] = [:]
        private var lastAppliedMaskOrigin: CGPoint = .zero
        @available(macOS 14.0, *) private let cutoutDisplayLinkProxy = CutoutDisplayLinkProxy()
        private var backdrop: CALayer?
        private let blurStage = CALayer()
        private let sourceClip = CAShapeLayer()
        private let outputClip = CAShapeLayer()
        private var reportedUnavailable = false
        private let cover = CALayer()
        private let coverMask = CALayer()
        private var scrollerRects: [CGRect] = []
        private let observedClips = NSHashTable<NSClipView>.weakObjects()
        private let scrollSamples = NSMapTable<NSClipView, ScrollSample>(keyOptions: .weakMemory, valueOptions: .strongMemory)
        // Preview-only defaults and hidden overrides are centralized; see
        // SettingsScrollBlurConfiguration.swift / SCROLL_BLUR_CONFIGURATION.md.
        private var blurConfiguration: SettingsScrollBlurConfiguration = .current
        private var currentBlurRadius: CGFloat = SettingsScrollBlurConfiguration.current.maximumRadius
        private var filteredScrollSpeed: CGFloat = 0
        private var radiusMask: CGImage?
        private var settlingLastTime: CFTimeInterval = 0
        private var settlingTimer: Timer?
        private final class ScrollSample: NSObject {
            var y: CGFloat
            var time: CFTimeInterval
            init(y: CGFloat, time: CFTimeInterval) { self.y = y; self.time = time }
        }
        @available(macOS 14.0, *)
        private final class CutoutDisplayLinkProxy: NSObject {
            weak var owner: BackdropView?

            @objc func didFire(_ displayLink: CADisplayLink) {
                owner?.cutoutDisplayLinkDidFire(displayLink)
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.addSublayer(blurStage)
            if let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type {
                let backdrop = backdropType.init()
                blurStage.addSublayer(backdrop)
                self.backdrop = backdrop
            }
            cover.mask = coverMask
            layer?.addSublayer(cover)
            NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidLiveScroll(_:)),
                name: NSScrollView.didLiveScrollNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(blurDefaultsChanged),
                name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            currentBlurRadius = blurConfiguration.maximumRadius
            if #available(macOS 14.0, *) { cutoutDisplayLinkProxy.owner = self }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        deinit {
            NotificationCenter.default.removeObserver(self)
            settlingTimer?.invalidate()
            cutoutRegistry?.removeObserver(cutoutObserver)
            stopCutoutTracking()
        }
        @objc private func scrollBoundsChanged(_ notification: Notification) {
            guard let clip = notification.object as? NSClipView, ownsScrollViewport(clip) else { return }
            // A scroll offset cannot move its scroller's frame. Discover new
            // scroll hosts once; normal scrolling does not scan the view tree.
            if !observedClips.contains(clip) {
                observedClips.add(clip)
                updateFrames()
            }
        }
        @objc private func scrollViewDidLiveScroll(_ notification: Notification) {
            guard let scrollView = notification.object as? NSScrollView,
                  ownsScrollViewport(scrollView.contentView),
                  blurConfiguration.enabled,
                  window?.inLiveResize != true else { return }

            let clip = scrollView.contentView
            if !observedClips.contains(clip) {
                observedClips.add(clip)
                updateFrames()
            }
            let now = CACurrentMediaTime()
            let y = clip.bounds.origin.y
            guard let previous = scrollSamples.object(forKey: clip) else {
                scrollSamples.setObject(ScrollSample(y: y, time: now), forKey: clip)
                return
            }
            let elapsed = now - previous.time
            let distance = abs(y - previous.y)
            defer { previous.y = y; previous.time = now }
            guard distance > 0.2, elapsed > 0, elapsed < 0.35 else { return }

            let measuredSpeed = distance / elapsed
            filteredScrollSpeed = SettingsScrollBlurDynamics.exponentiallyApproached(
                current: filteredScrollSpeed,
                target: measuredSpeed,
                elapsed: elapsed,
                timeConstant: SettingsScrollBlurDynamics.speedSmoothingTime
            )
            let target = SettingsScrollBlurDynamics.targetRadius(
                speed: filteredScrollSpeed,
                minimumRadius: blurConfiguration.minimumRadius,
                maximumRadius: blurConfiguration.maximumRadius
            )
            approachBlurRadius(
                target,
                elapsed: elapsed,
                timeConstant: SettingsScrollBlurDynamics.liveRadiusResponseTime
            )
            settlingLastTime = now
            scheduleSettlingTimer()
        }
        private func ownsScrollViewport(_ clip: NSClipView) -> Bool {
            guard let window, clip.window === window,
                  !clip.isHiddenOrHasHiddenAncestor,
                  let configuration else { return false }
            // NSView is bottom-left based here; the panel extends downward from
            // the top backdrop. Never use the moving document's bounds as area.
            let panel = CGRect(x: configuration.origin.x,
                               y: bounds.height - configuration.origin.y - configuration.panelHeight,
                               width: configuration.size.width, height: configuration.panelHeight)
            return settingsScrollViewportBelongsToPanel(convert(clip.bounds, from: clip), panel: panel)
        }
        private func scheduleSettlingTimer() {
            let fireDate = Date(timeIntervalSinceNow: SettingsScrollBlurDynamics.idleDelay)
            if let settlingTimer {
                // Continuous input keeps moving the fire date, so the timer does
                // no periodic work while the user is still scrolling.
                settlingTimer.fireDate = fireDate
                return
            }
            let timer = Timer(timeInterval: SettingsScrollBlurDynamics.settlingTimerInterval, repeats: true) { [weak self] timer in
                self?.settleAfterScroll(timer)
            }
            timer.fireDate = fireDate
            settlingTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        private func settleAfterScroll(_ timer: Timer) {
            guard blurConfiguration.enabled else {
                stopSettling(timer)
                return
            }
            let now = CACurrentMediaTime()
            let elapsed = max(0, now - settlingLastTime)
            settlingLastTime = now
            filteredScrollSpeed = SettingsScrollBlurDynamics.exponentiallyApproached(
                current: filteredScrollSpeed,
                target: 0,
                elapsed: elapsed,
                timeConstant: SettingsScrollBlurDynamics.idleSpeedDecayTime
            )
            let target = SettingsScrollBlurDynamics.targetRadius(
                speed: filteredScrollSpeed,
                minimumRadius: blurConfiguration.minimumRadius,
                maximumRadius: blurConfiguration.maximumRadius
            )
            approachBlurRadius(
                target,
                elapsed: elapsed,
                timeConstant: SettingsScrollBlurDynamics.idleRadiusResponseTime
            )
            if filteredScrollSpeed <= SettingsScrollBlurDynamics.settleSpeedTolerance,
               abs(currentBlurRadius - blurConfiguration.maximumRadius) <= SettingsScrollBlurDynamics.settleRadiusTolerance {
                filteredScrollSpeed = 0
                setBlurRadius(blurConfiguration.maximumRadius)
                stopSettling(timer)
            }
        }
        private func stopSettling(_ timer: Timer? = nil) {
            (timer ?? settlingTimer)?.invalidate()
            settlingTimer = nil
        }
        private func approachBlurRadius(_ target: CGFloat, elapsed: CFTimeInterval, timeConstant: CFTimeInterval) {
            setBlurRadius(SettingsScrollBlurDynamics.exponentiallyApproached(
                current: currentBlurRadius,
                target: target,
                elapsed: elapsed,
                timeConstant: timeConstant
            ))
        }
        private func setBlurRadius(_ radius: CGFloat) {
            let clamped = min(
                max(radius, blurConfiguration.minimumRadius),
                blurConfiguration.maximumRadius
            )
            guard abs(clamped - currentBlurRadius) > 0.001 else { return }
            currentBlurRadius = clamped
            applyBlurRadius()
        }
        @objc private func blurDefaultsChanged() {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in self?.blurDefaultsChanged() }
                return
            }
            let next = SettingsScrollBlurConfiguration.current
            guard next != blurConfiguration else { return }
            blurConfiguration = next
            if !next.enabled {
                filteredScrollSpeed = 0
                stopSettling()
                currentBlurRadius = next.maximumRadius
            } else if settlingTimer == nil {
                currentBlurRadius = next.maximumRadius
            } else {
                currentBlurRadius = min(max(currentBlurRadius, next.minimumRadius), next.maximumRadius)
            }
            applyBlurRadius()
            if let baseConfiguration { update(baseConfiguration, cutoutRegistry: cutoutRegistry) }
            updateFrames()
        }
        private func applyBlurRadius() {
            guard let radiusMask, let backdrop, let filter = Self.makeFilter() else { return }
            filter.setValue(currentBlurRadius, forKey: "inputRadius")
            filter.setValue(radiusMask, forKey: "inputMaskImage")
            filter.setValue(true, forKey: "inputNormalizeEdges")
            CATransaction.begin(); CATransaction.setDisableActions(true)
            install(filter, on: backdrop)
            CATransaction.commit()
        }
        private func install(_ filter: NSObject, on backdrop: CALayer) {
            if configuration?.sidebar == true {
                guard let capture = Self.makeFilter(typeName: "gaussianBlur") else {
                    backdrop.isHidden = true
                    blurStage.filters = nil
                    return
                }
                capture.setValue(0, forKey: "inputRadius")
                backdrop.filters = [capture]
                blurStage.filters = [filter]
            } else {
                blurStage.filters = nil
                backdrop.filters = [filter]
            }
        }
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            updateFrames()
            adaptiveCutoutGeometryDidChange()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateFrames()
            if window == nil {
                stopCutoutTracking()
            } else {
                adaptiveCutoutGeometryDidChange()
            }
        }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateFrames()
            adaptiveCutoutGeometryDidChange()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateFrames()
        }
        func update(_ input: SettingsTopBackdropMask, cutoutRegistry nextRegistry: SettingsAdaptiveCutoutRegistry?) {
            installCutoutRegistry(nextRegistry)
            var mask = input
            mask.excludedRects = scrollerRects
            mask.blurInset = blurConfiguration.edgeInsetPixels / max(1, window?.backingScaleFactor ?? 2)
            baseConfiguration = mask
            if refreshAdaptiveCutouts(preferPresentation: true) { startCutoutTracking() }
            updateFrames()
        }

        private func installCutoutRegistry(_ nextRegistry: SettingsAdaptiveCutoutRegistry?) {
            guard cutoutRegistry !== nextRegistry else { return }
            cutoutRegistry?.removeObserver(cutoutObserver)
            cutoutRegistry?.setDiagnosticSampler(nil)
            cutoutRegistry = nextRegistry
            cutoutObserver = nextRegistry?.observe { [weak self] in
                self?.adaptiveCutoutGeometryDidChange()
            }
            nextRegistry?.setDiagnosticSampler { [weak self] window in
                self?.diagnosticEntries(for: window) ?? []
            }
        }

        private func adaptiveCutoutGeometryDidChange() {
            // Update directly from the current layer tree. Deferring this work
            // by one main-queue turn visibly leaves the old opening behind.
            refreshAdaptiveCutouts(preferPresentation: true)
            startCutoutTracking()
        }

        @discardableResult
        private func refreshAdaptiveCutouts(preferPresentation: Bool) -> Bool {
            guard var mask = baseConfiguration else { return false }
            let resolved = resolvedAdaptiveCutouts(preferPresentation: preferPresentation)
            mask.cutouts = resolved.map {
                SettingsTopBackdropCutout(rect: $0.expectedLocalRect, opacity: $0.opacity)
            }.filter { $0.opacity > 0.0001 }
            let didUpdate = apply(mask)
            if didUpdate {
                lastAppliedMaskOrigin = mask.origin
                lastAppliedCutoutRects = Dictionary(uniqueKeysWithValues: resolved.compactMap {
                    $0.opacity > 0.0001 ? ($0.id, $0.expectedLocalRect) : nil
                })
            }
            cutoutRegistry?.record(maskDidUpdate: didUpdate,
                                   trackingActive: cutoutTrackingIsActive)
            return didUpdate
        }

        private struct ResolvedAdaptiveCutout {
            let id: String
            let sourceWindowRect: CGRect
            let presentationWindowRect: CGRect
            let expectedLocalRect: CGRect
            let opacity: Double
        }

        private func resolvedAdaptiveCutouts(preferPresentation: Bool) -> [ResolvedAdaptiveCutout] {
            guard let window, let cutoutRegistry else { return [] }
            return cutoutRegistry.registrations(in: window).compactMap { registration in
                guard !registration.view.isHiddenOrHasHiddenAncestor else { return nil }
                let source = registration.view.convert(registration.view.bounds, to: nil)
                guard !source.isNull, !source.isEmpty else { return nil }
                let presentation = preferPresentation
                    ? coherentPresentationGeometry(for: registration.view, modelWindowRect: source)
                    : nil
                let localAppKit = presentation?.localRect ?? convert(source, from: nil)
                guard localAppKit.hasFiniteCoordinates, !localAppKit.isNull, !localAppKit.isEmpty else { return nil }
                let panelOrigin = baseConfiguration?.origin ?? .zero
                let localImage = CGRect(x: localAppKit.minX - panelOrigin.x,
                                        y: bounds.height - localAppKit.maxY - panelOrigin.y,
                                        width: localAppKit.width, height: localAppKit.height)
                let presentationWindow = presentation?.windowRect ?? source
                // The explicit opacity is a fallback for SwiftUI compositing
                // groups whose alpha is not materialized as an AppKit ancestor.
                let opacity = min(registration.fallbackOpacity, presentation?.opacity ?? 1)
                return ResolvedAdaptiveCutout(
                    id: registration.id,
                    sourceWindowRect: source,
                    presentationWindowRect: presentationWindow,
                    expectedLocalRect: localImage,
                    opacity: opacity
                )
            }
        }

        private struct PresentationGeometry {
            let localRect: CGRect
            let windowRect: CGRect
            let opacity: Double
        }

        /// A presentation rectangle is accepted only when both layers are in a
        /// common live tree and have a plausible size. That keeps a model-space
        /// fallback coherent instead of mixing an orphaned presentation layer
        /// with a current AppKit conversion.
        private func coherentPresentationGeometry(for view: NSView, modelWindowRect: CGRect) -> PresentationGeometry? {
            guard let sourceLayer = view.layer,
                  let sourcePresentation = sourceLayer.presentation(),
                  let destinationLayer = layer,
                  let destinationPresentation = destinationLayer.presentation(),
                  let contentView = window?.contentView,
                  let contentPresentation = contentView.layer?.presentation()
            else { return nil }
            let candidate = sourcePresentation.convert(sourcePresentation.bounds, to: destinationPresentation)
            guard candidate.hasFiniteCoordinates, !candidate.isNull, !candidate.isEmpty,
                  candidate.intersects(bounds.insetBy(dx: -max(bounds.width, 1), dy: -max(bounds.height, 1)))
            else { return nil }
            guard let opacity = presentationOpacity(from: sourcePresentation, to: destinationPresentation) else { return nil }
            let contentRect = sourcePresentation.convert(sourcePresentation.bounds, to: contentPresentation)
            guard contentRect.hasFiniteCoordinates, !contentRect.isNull, !contentRect.isEmpty else { return nil }
            let windowRect = contentView.convert(contentRect, to: nil)
            return PresentationGeometry(localRect: candidate, windowRect: windowRect, opacity: opacity)
        }

        private func presentationOpacity(from source: CALayer, to destination: CALayer) -> Double? {
            var destinationAncestors = Set<ObjectIdentifier>()
            var cursor: CALayer? = destination
            while let layer = cursor {
                destinationAncestors.insert(ObjectIdentifier(layer))
                cursor = layer.superlayer
            }
            var opacity: Float = 1
            cursor = source
            while let layer = cursor {
                if destinationAncestors.contains(ObjectIdentifier(layer)) { return Double(opacity) }
                opacity *= layer.opacity
                cursor = layer.superlayer
            }
            return nil
        }

        private func diagnosticEntries(from resolved: [ResolvedAdaptiveCutout]) -> [SettingsAdaptiveCutoutDiagnosticEntry] {
            resolved.map { cutout in
                let appliedLocal = lastAppliedCutoutRects[cutout.id] ?? .zero
                let appliedWindow: CGRect
                if appliedLocal.isEmpty || cutout.expectedLocalRect.isEmpty || cutout.opacity <= 0.0001 {
                    appliedWindow = .zero
                } else {
                    let hostRect = CGRect(x: appliedLocal.minX + lastAppliedMaskOrigin.x,
                                          y: bounds.height - appliedLocal.maxY - lastAppliedMaskOrigin.y,
                                          width: appliedLocal.width, height: appliedLocal.height)
                    if let hostPresentation = layer?.presentation(),
                       let contentView = window?.contentView,
                       let contentPresentation = contentView.layer?.presentation(),
                       presentationOpacity(from: hostPresentation, to: contentPresentation) != nil {
                        appliedWindow = contentView.convert(hostPresentation.convert(hostRect, to: contentPresentation), to: nil)
                    } else {
                        appliedWindow = convert(hostRect, to: nil)
                    }
                }
                return SettingsAdaptiveCutoutDiagnosticEntry(
                    id: cutout.id,
                    sourceWindowRect: cutout.sourceWindowRect,
                    presentationWindowRect: cutout.presentationWindowRect,
                    appliedWindowRect: appliedWindow,
                    appliedLocalRect: appliedLocal,
                    opacity: cutout.opacity
                )
            }
        }

        /// Called by diagnostics without rebuilding a mask. The expected source
        /// is sampled now; the applied rectangle remains the last one sent to
        /// Core Animation, so a stale opening cannot look aligned by definition.
        private func diagnosticEntries(for window: NSWindow) -> [SettingsAdaptiveCutoutDiagnosticEntry] {
            guard self.window === window else { return [] }
            return diagnosticEntries(from: resolvedAdaptiveCutouts(preferPresentation: true))
        }

        private var cutoutTrackingIsActive: Bool {
            if #available(macOS 14.0, *) { return cutoutDisplayLink != nil }
            return false
        }

        private func startCutoutTracking() {
            guard window != nil else { return }
            let now = CACurrentMediaTime()
            cutoutTrackingDeadline = max(cutoutTrackingDeadline, now + 0.40)
            if #available(macOS 14.0, *) {
                if cutoutDisplayLink == nil {
                    let displayLink = displayLink(target: cutoutDisplayLinkProxy,
                                                  selector: #selector(CutoutDisplayLinkProxy.didFire(_:)))
                    displayLink.add(to: .main, forMode: .common)
                    cutoutDisplayLink = displayLink
                }
                cutoutRegistry?.setTrackingActive(true)
            }
            if cutoutTrackingStopTimer == nil { armCutoutTrackingStopTimer() }
        }

        private func armCutoutTrackingStopTimer() {
            cutoutTrackingStopTimer?.invalidate()
            let delay = max(0.05, cutoutTrackingDeadline - CACurrentMediaTime() + 0.05)
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }
                if CACurrentMediaTime() >= self.cutoutTrackingDeadline {
                    self.stopCutoutTracking()
                } else {
                    self.armCutoutTrackingStopTimer()
                }
            }
            cutoutTrackingStopTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func stopCutoutTracking() {
            cutoutTrackingStopTimer?.invalidate()
            cutoutTrackingStopTimer = nil
            if #available(macOS 14.0, *) {
                cutoutDisplayLink?.invalidate()
                cutoutDisplayLink = nil
            }
            cutoutRegistry?.setTrackingActive(false)
        }

        @available(macOS 14.0, *)
        @objc private func cutoutDisplayLinkDidFire(_ displayLink: CADisplayLink) {
            let changed = refreshAdaptiveCutouts(preferPresentation: true)
            let now = displayLink.timestamp
            if changed {
                cutoutTrackingDeadline = now + 0.40
                // The existing stop timer checks the extended deadline and
                // rearms itself; do not replace it on every display frame.
            }
            guard now >= cutoutTrackingDeadline else { return }
            stopCutoutTracking()
        }

        /// Geometry and pixels have separate invalidation. A panel move or
        /// right-side height change reuses the installed images; actual raster
        /// inputs and display-scale changes rebuild them in this same commit.
        @discardableResult
        private func apply(_ mask: SettingsTopBackdropMask) -> Bool {
            let scale = max(1, window?.backingScaleFactor ?? 2)
            let rasterIdentity = mask.rasterIdentity
            let needsRasterUpdate = lastRasterIdentity != rasterIdentity || lastRasterScale != scale
            guard configuration != mask || needsRasterUpdate else { return false }
            configuration = mask
            CATransaction.begin(); CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            updateEffectLayerFrames()
            guard needsRasterUpdate else { return true }
            // Remember failed attempts as well. An unavailable private filter
            // must not turn an unchanged window into an endless retry loop.
            lastRasterIdentity = rasterIdentity
            lastRasterScale = scale
            if let backdrop, let filter = Self.makeFilter(),
               let radiusImage = mask.image(blur: true)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let colorImage = mask.image()?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // Configure before attachment: mutating a filter already installed
                // on a CALayer does not reliably invalidate the render server.
                radiusMask = radiusImage
                filter.setValue(currentBlurRadius, forKey: "inputRadius")
                filter.setValue(radiusImage, forKey: "inputMaskImage")
                filter.setValue(true, forKey: "inputNormalizeEdges")
                install(filter, on: backdrop)
                coverMask.contents = colorImage
                cover.isHidden = false
            } else {
                backdrop?.filters = nil
                blurStage.filters = nil
                cover.isHidden = true
                if !reportedUnavailable {
                    NSLog("HushType: variable top backdrop unavailable; effect disabled.")
                    reportedUnavailable = true
                }
            }
            return true
        }
        private static func makeFilter(typeName: String = "variableBlur") -> NSObject? {
            let factory = NSSelectorFromString("filterWithType:")
            let keysSelector = NSSelectorFromString("inputKeys")
            guard let type = NSClassFromString("CAFilter") as? NSObject.Type,
                  type.responds(to: factory),
                  let filter = type.perform(factory, with: typeName)?.takeUnretainedValue() as? NSObject,
                  filter.responds(to: keysSelector),
                  let keys = filter.perform(keysSelector)?.takeUnretainedValue() as? [String],
                  Set(typeName == "variableBlur" ? ["inputRadius", "inputMaskImage", "inputNormalizeEdges"] : ["inputRadius"]).isSubset(of: Set(keys))
            else { return nil }
            return filter
        }
        private func updateFrames() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let scale = max(1, window?.backingScaleFactor ?? 2)
            updateEffectLayerFrames()
            if let configuration, configuration.sidebar {
                let inset = blurConfiguration.edgeInsetPixels / scale
                let effectBounds = blurStage.bounds
                let region = effectBounds.insetBy(dx: inset, dy: inset)
                backdrop?.isHidden = region.width <= 0 || region.height <= 0
                backdrop?.frame = region.isEmpty ? .zero : region
                let panel = CGRect(x: 0, y: effectBounds.height - configuration.panelHeight,
                                   width: effectBounds.width, height: configuration.panelHeight)
                    .insetBy(dx: inset, dy: inset)
                let radius = max(0, 20 - inset)
                sourceClip.frame = backdrop?.bounds ?? .zero
                sourceClip.path = CGPath(roundedRect: panel.offsetBy(dx: -region.minX, dy: -region.minY),
                                        cornerWidth: radius, cornerHeight: radius, transform: nil)
                backdrop?.mask = sourceClip
                outputClip.frame = effectBounds
                outputClip.path = CGPath(roundedRect: panel, cornerWidth: radius, cornerHeight: radius, transform: nil)
                let band = CAShapeLayer()
                band.frame = effectBounds
                band.path = CGPath(rect: region.isEmpty ? .zero : region, transform: nil)
                outputClip.mask = band
                blurStage.mask = outputClip
            } else {
                backdrop?.frame = blurStage.bounds
                backdrop?.isHidden = false
                backdrop?.mask = nil
                blurStage.mask = nil
            }
            backdrop?.setValue(scale, forKey: "scale")
            coverMask.frame = cover.bounds
            effectiveAppearance.performAsCurrentDrawingAppearance {
                cover.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            CATransaction.commit()
            if let baseConfiguration, baseConfiguration.blurInset != blurConfiguration.edgeInsetPixels / scale {
                update(baseConfiguration, cutoutRegistry: cutoutRegistry)
            }
            let nextRects = currentScrollerRects()
            if scrollerRects != nextRects {
                scrollerRects = nextRects
                if let baseConfiguration { update(baseConfiguration, cutoutRegistry: cutoutRegistry) }
            }
        }

        private func updateEffectLayerFrames() {
            let frame: CGRect
            if let configuration {
                frame = CGRect(x: configuration.origin.x,
                               y: bounds.height - configuration.origin.y - configuration.size.height,
                               width: configuration.size.width, height: configuration.size.height)
            } else {
                frame = bounds
            }
            blurStage.frame = frame
            backdrop?.frame = blurStage.bounds
            cover.frame = frame
            coverMask.frame = cover.bounds
        }

        private func currentScrollerRects() -> [CGRect] {
            guard let content = window?.contentView, let configuration else { return [] }
            let maskFrame = CGRect(x: configuration.origin.x,
                                   y: bounds.height - configuration.origin.y - configuration.size.height,
                                   width: configuration.size.width, height: configuration.size.height)
            var result: [CGRect] = []
            func visit(_ view: NSView) {
                if let scroll = view as? NSScrollView,
                   scroll.hasVerticalScroller, let scroller = scroll.verticalScroller {
                    let rect = convert(scroller.bounds, from: scroller).intersection(maskFrame)
                    if !rect.isNull && !rect.isEmpty {
                        // Convert AppKit bottom-left to the image's top-left coordinates.
                        result.append(CGRect(x: rect.minX - configuration.origin.x,
                                             y: bounds.height - rect.maxY - configuration.origin.y,
                                             width: rect.width, height: rect.height))
                    }
                }
                for child in view.subviews { visit(child) }
            }
            visit(content)
            return result
        }
    }
}
