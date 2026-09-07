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
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 1))
        .fixedSize()
    }
}

/// Shared by the real settings window and the isolated visual test harness.
struct SettingsWindowShell<Detail: View, Sidebar: View, Header: View>: View {
    let toggleLabel: String
    let expandedLabel: String
    let collapsedLabel: String
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var header: () -> Header
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarExpanded = true
    @State private var chrome = SettingsWindowChromeMetrics()

    var body: some View {
        SettingsChromeLayout(progress: sidebarExpanded ? 1 : 0,
                             minimumToggleX: chrome.minimumToggleX,
                             titlebarCenterY: chrome.titlebarCenterY) {
            detail().clipped()
            sidebar()
                .padding(.top, max(48, chrome.titlebarCenterY + 22))
                .modifier(SettingsSidebarSurface())
                .allowsHitTesting(sidebarExpanded)
                .accessibilityHidden(!sidebarExpanded)
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
            header().frame(maxWidth: .infinity, maxHeight: .infinity)
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
         minimumToggleX: CGFloat = 100, titlebarCenterY: CGFloat = 28) {
        let progress = min(1, max(0, progress))
        let sidebarRight = (sidebarWidth + 8) * progress
        let toggleX = max(minimumToggleX, sidebarRight - 44)
        let headerX = max(toggleX + 52, sidebarRight + 18)
        let headerBottom = max(64, titlebarCenterY + 28)
        sidebar = CGRect(x: sidebarRight - sidebarWidth, y: 8,
                         width: sidebarWidth, height: max(0, size.height - 16))
        detail = CGRect(x: sidebarRight, y: headerBottom,
                        width: max(0, size.width - sidebarRight), height: max(0, size.height - headerBottom))
        toggle = CGRect(x: toggleX, y: titlebarCenterY - 18, width: 36, height: 36)
        header = CGRect(x: headerX, y: titlebarCenterY - 18,
                        width: max(0, size.width - headerX - 20), height: 36)
    }
}

struct SettingsChromeLayout: Layout {
    var progress: CGFloat
    var minimumToggleX: CGFloat
    var titlebarCenterY: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 950, height: 650))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let frames = SettingsChromeFrames(size: bounds.size, progress: progress,
                                          minimumToggleX: minimumToggleX, titlebarCenterY: titlebarCenterY)
        for (view, frame) in zip(subviews, [frames.detail, frames.sidebar, frames.toggle, frames.header]) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

struct SettingsWindowChromeMetrics: Equatable {
    var minimumToggleX: CGFloat = 100
    var titlebarCenterY: CGFloat = 28
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
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
