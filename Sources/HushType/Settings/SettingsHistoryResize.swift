import AppKit
import SwiftUI

private struct SettingsSidebarIsResizingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsSidebarIsResizing: Bool {
        get { self[SettingsSidebarIsResizingKey.self] }
        set { self[SettingsSidebarIsResizingKey.self] = newValue }
    }
}

/// Keep lazy row heights unchanged during a continuous drag. Reflow once at
/// the final width, instead of repeatedly invalidating offscreen estimates.
struct SettingsHistoryResizeState {
    private var windowResizing = false
    private var sidebarResizing = false
    private(set) var frozenWidth: CGFloat?

    func layoutWidth(available: CGFloat) -> CGFloat { frozenWidth ?? available }

    mutating func setWindowResizing(_ active: Bool, width: CGFloat) {
        windowResizing = active
        update(width: width)
    }

    mutating func setSidebarResizing(_ active: Bool, width: CGFloat) {
        sidebarResizing = active
        update(width: width)
    }

    private mutating func update(width: CGFloat) {
        if windowResizing || sidebarResizing {
            if frozenWidth == nil, width > 0 { frozenWidth = width }
        } else {
            frozenWidth = nil
        }
    }
}

struct SettingsHistoryLiveResizeObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            onChange?(true)
        }
        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            onChange?(false)
        }
    }
}
