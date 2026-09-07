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
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .frame(width: 35, height: 36).contentShape(Rectangle())
            }
            .disabled(backDisabled)
            .accessibilityLabel(backLabel)
            Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 18)
            Button(action: forward) {
                Image(systemName: "chevron.right")
                    .frame(width: 35, height: 36).contentShape(Rectangle())
            }
            .disabled(forwardDisabled)
            .accessibilityLabel(forwardLabel)
        }
        .font(.system(size: 18))
        .buttonStyle(.plain)
        .modifier(SettingsLiquidGlass())
        .fixedSize()
    }
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

    // Scroll content extends behind the B8 opacity cover and native glass controls.
    private var extendsScrollUnderHeader: Bool { true }

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
                ZStack(alignment: .topLeading) {
                    Group {
                        if extendsScrollUnderHeader {
                            SettingsChromeFadeLayer(progress: sidebarExpanded ? 1 : 0,
                                sidebarWidth: resolvedSidebarWidth,
                                minimumToggleX: chrome.minimumToggleX,
                                titlebarCenterY: chrome.titlebarCenterY,
                                detailLayoutProgress: stabilizesDetailWidth ? (sidebarExpanded ? 1 : 0) : nil,
                                hasSearch: showsSearch, titlebarBottomY: chrome.titlebarBottomY)
                        } else {
                            Color.clear
                        }
                    }
                    .allowsHitTesting(false)
                    SettingsTitlebarDragRegion()
                        .frame(height: chrome.titlebarBottomY)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .accessibilityHidden(true)
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                        sidebarExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 18))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(toggleLabel)
                .accessibilityLabel(toggleLabel)
                .accessibilityValue(sidebarExpanded ? expandedLabel : collapsedLabel)
                .accessibilityIdentifier("hushtype.settings.sidebar-toggle")
                .modifier(SettingsToggleGlassBackdrop(progress: sidebarExpanded ? 1 : 0,
                                                      sidebarWidth: resolvedSidebarWidth,
                                                      minimumToggleX: chrome.minimumToggleX))
                header().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
        guard subviews.count == 5 else { return }
        let frames = SettingsChromeFrames(size: bounds.size, progress: progress,
                                          sidebarWidth: sidebarWidth,
                                          minimumToggleX: minimumToggleX, titlebarCenterY: titlebarCenterY,
                                          extendsDetailUnderHeader: extendsDetailUnderHeader,
                                          detailLayoutProgress: detailLayoutProgress)
        for (view, frame) in zip(subviews, [frames.detail, frames.sidebar, CGRect(origin: .zero, size: bounds.size), frames.toggle, frames.header]) {
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
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            }
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
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
            ZStack {
                SettingsSidebarResizeCursorRegion()
                    .frame(width: 8, height: height)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { onChanged($0.translation.width) }
                            .onEnded { _ in onEnded() }
                    )
            }
            .frame(width: 8, height: height)
            .position(x: geometry.size.width, y: top + height / 2)
        }
        .accessibilityHidden(true)
    }
}

/// AppKit owns cursor-rect lifetime. Unlike SwiftUI's `onHover`, it restores
/// the cursor as soon as the pointer leaves this narrow resize target.
private struct SettingsSidebarResizeCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {}

    final class CursorView: NSView {
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }

        override func resetCursorRects() {
            discardCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
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
                .opacity(glassOpacity).allowsHitTesting(false)
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
    let hasSearch: Bool
    let titlebarBottomY: CGFloat
    @Environment(\.displayScale) private var displayScale
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    var body: some View {
        GeometryReader { geometry in
            let f = SettingsChromeFrames(size: geometry.size, progress: progress,
                sidebarWidth: sidebarWidth,
                minimumToggleX: minimumToggleX, titlebarCenterY: titlebarCenterY,
                extendsDetailUnderHeader: true, detailLayoutProgress: detailLayoutProgress)
            let navigation = CGRect(x: f.header.minX, y: f.header.minY, width: 71, height: 36)
            let search = CGRect(x: f.header.maxX - 190, y: f.header.minY, width: 190, height: 36)
            let toggle = f.toggle.insetBy(dx: -4, dy: 0)
            ZStack(alignment: .topLeading) {
                fade(in: f.detail, height: max(0, titlebarBottomY - f.detail.minY), sidebar: false,
                     navigation: navigation, search: search, toggle: toggle)
                fade(in: f.sidebar, height: max(0, titlebarBottomY - f.sidebar.minY), sidebar: true,
                     navigation: navigation, search: search, toggle: toggle)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
    private func fade(in frame: CGRect, height: CGFloat, sidebar: Bool,
                      navigation: CGRect, search: CGRect, toggle: CGRect) -> some View {
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
                holes: [navigation] + (hasSearch ? [search] : []),
                toggle: toggle,
                toggleOpacity: settingsToggleGlassOpacity(progress, sidebarWidth, minimumToggleX),
                origin: frame.origin))
        .frame(width: frame.width, height: height)
        .frame(width: frame.width, height: frame.height, alignment: .top)
        .offset(x: frame.minX, y: frame.minY)
    }
}

/// Separate masks control the color cover and backdrop radius. Both keep
/// the sidebar rim and Liquid Glass capsules out of the backdrop effect.
struct SettingsTopBackdropMask: Equatable {
    let size: CGSize
    var colorHeight: CGFloat? = nil
    var openingInset: CGFloat = 0
    var excludedRects: [CGRect] = []
    let panelHeight: CGFloat
    let sidebar: Bool
    let holes: [CGRect]
    let toggle: CGRect
    let toggleOpacity: Double
    let origin: CGPoint

    func image(blur: Bool = false) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        // Both images are rendered in the shell's top-leading coordinates.
        return NSImage(size: size, flipped: true) { bounds in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            if sidebar {
                NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: panelHeight)
                    .insetBy(dx: 1.5, dy: 1.5), xRadius: 18.5, yRadius: 18.5).addClip()
            }
            if blur {
                // The backdrop filter consumes a radius mask, not view opacity.
                // Linear radius reaches zero at the clear edge.
                for row in 0..<Int(ceil(bounds.height)) {
                    let y = CGFloat(row)
                    NSColor.black.withAlphaComponent(settingsTopBlurStrength(y / max(1, ceil(bounds.height) - 1))).setFill()
                    NSBezierPath(rect: CGRect(x: 0, y: y, width: bounds.width, height: 1)).fill()
                }
            } else {
                // Independent translucent tint: never fully hides the content.
                for row in 0..<Int(ceil(bounds.height)) {
                    let y = CGFloat(row)
                    NSColor.white.withAlphaComponent(settingsTopTintOpacity(y / max(1, ceil(colorHeight ?? bounds.height) - 1))).setFill()
                    NSBezierPath(rect: CGRect(x: 0, y: y, width: bounds.width, height: 1)).fill()
                }
            }
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            func cutout(_ rect: CGRect, opacity: Double) {
                NSColor.white.withAlphaComponent(opacity).setFill()
                let local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
                    .insetBy(dx: openingInset, dy: openingInset)
                guard local.width > 0, local.height > 0 else { return }
                NSBezierPath(roundedRect: local, xRadius: local.height / 2,
                             yRadius: local.height / 2).fill()
            }
            for hole in holes { cutout(hole, opacity: 1) }
            cutout(toggle, opacity: toggleOpacity)
            NSColor.white.setFill()
            for rect in excludedRects { NSBezierPath(rect: rect).fill() }
            return true
        }
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

/// Experimental Core Animation backdrop path. These two runtime types are
/// non-public API; keep this limitation explicit in preview delivery notes.
/// The original native Form and controls remain live and are never snapshotted.
private struct SettingsNativeTopBackdrop: NSViewRepresentable {
    let mask: SettingsTopBackdropMask
    func makeNSView(context: Context) -> BackdropView { BackdropView() }
    func updateNSView(_ view: BackdropView, context: Context) { view.update(mask) }

    final class BackdropView: NSView {
        private var configuration: SettingsTopBackdropMask?
        private var backdrop: CALayer?
        private var reportedUnavailable = false
        private let cover = CALayer()
        private let coverMask = CALayer()
        private var scrollerRects: [CGRect] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            if let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type {
                let backdrop = backdropType.init()
                layer?.addSublayer(backdrop)
                self.backdrop = backdrop
            }
            cover.mask = coverMask
            layer?.addSublayer(cover)
            NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc private func scrollBoundsChanged(_ notification: Notification) {
            guard let clip = notification.object as? NSClipView, clip.window === window else { return }
            updateFrames()
        }
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); updateFrames() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateFrames() }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateFrames() }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateFrames()
        }
        func update(_ input: SettingsTopBackdropMask) {
            var mask = input
            mask.excludedRects = scrollerRects
            guard configuration != mask else { return }
            configuration = mask
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if let backdrop, let filter = Self.makeFilter(),
               let radiusImage = mask.image(blur: true)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let colorImage = mask.image()?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // Configure before attachment: mutating a filter already installed
                // on a CALayer does not reliably invalidate the render server.
                filter.setValue(30, forKey: "inputRadius")
                filter.setValue(radiusImage, forKey: "inputMaskImage")
                filter.setValue(true, forKey: "inputNormalizeEdges")
                backdrop.filters = [filter]
                coverMask.contents = colorImage
                cover.isHidden = false
            } else {
                backdrop?.filters = nil
                cover.isHidden = true
                if !reportedUnavailable {
                    NSLog("HushType: variable top backdrop unavailable; effect disabled.")
                    reportedUnavailable = true
                }
            }
            CATransaction.commit()
            updateFrames()
        }
        private static func makeFilter() -> NSObject? {
            let factory = NSSelectorFromString("filterWithType:")
            let keysSelector = NSSelectorFromString("inputKeys")
            guard let type = NSClassFromString("CAFilter") as? NSObject.Type,
                  type.responds(to: factory),
                  let filter = type.perform(factory, with: "variableBlur")?.takeUnretainedValue() as? NSObject,
                  filter.responds(to: keysSelector),
                  let keys = filter.perform(keysSelector)?.takeUnretainedValue() as? [String],
                  Set(["inputRadius", "inputMaskImage", "inputNormalizeEdges"]).isSubset(of: Set(keys))
            else { return nil }
            return filter
        }
        private func updateFrames() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            backdrop?.frame = bounds
            backdrop?.setValue(window?.backingScaleFactor ?? 2, forKey: "scale")
            cover.frame = bounds
            coverMask.frame = cover.bounds
            effectiveAppearance.performAsCurrentDrawingAppearance {
                cover.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            CATransaction.commit()
            let nextRects = currentScrollerRects()
            if scrollerRects != nextRects {
                scrollerRects = nextRects
                if let configuration { update(configuration) }
            }
        }

        private func currentScrollerRects() -> [CGRect] {
            guard let content = window?.contentView else { return [] }
            var result: [CGRect] = []
            func visit(_ view: NSView) {
                if let scroll = view as? NSScrollView,
                   scroll.hasVerticalScroller, let scroller = scroll.verticalScroller {
                    let rect = convert(scroller.bounds, from: scroller).intersection(bounds)
                    if !rect.isNull && !rect.isEmpty {
                        // Convert AppKit bottom-left to the image's top-left coordinates.
                        result.append(CGRect(x: rect.minX, y: bounds.height - rect.maxY,
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
