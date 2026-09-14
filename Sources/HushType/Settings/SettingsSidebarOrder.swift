import AppKit
import SwiftUI

final class SettingsSidebarOrder: ObservableObject {
    static let shared = SettingsSidebarOrder()
    static let key = "hushtype.settings.sidebarOrder"
    @Published private(set) var items: [HushTypeSettingsSection]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = Self.normalized(defaults.stringArray(forKey: Self.key) ?? [])
    }
    static func normalized(_ saved: [String]) -> [HushTypeSettingsSection] {
        var result: [HushTypeSettingsSection] = []
        for item in saved.compactMap(HushTypeSettingsSection.init(rawValue:)) + HushTypeSettingsSection.allCases {
            if !result.contains(item) { result.append(item) }
        }
        return result
    }
    func move(_ item: HushTypeSettingsSection, to target: HushTypeSettingsSection) {
        guard item != target, let from = items.firstIndex(of: item), let to = items.firstIndex(of: target) else { return }
        items.remove(at: from)
        items.insert(item, at: to)
    }
    func save() { defaults.set(items.map(\.rawValue), forKey: Self.key) }
}

struct SidebarOrderFramesKey: PreferenceKey {
    static let defaultValue: [HushTypeSettingsSection: CGRect] = [:]
    static func reduce(value: inout [HushTypeSettingsSection: CGRect], nextValue: () -> [HushTypeSettingsSection: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct SidebarEditingOutsideClick: NSViewRepresentable {
    let enabled: Bool
    let finish: () -> Void
    func makeNSView(context: Context) -> Monitor { Monitor() }
    func updateNSView(_ view: Monitor, context: Context) { view.enabled = enabled; view.finish = finish }
    final class Monitor: NSView {
        var enabled = false
        var finish: (() -> Void)?
        private var token: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NSEvent.removeMonitor(token); self.token = nil }
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                if let self, self.enabled, event.window === self.window,
                   !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.finish?() }
                return event
            }
        }
        deinit { if let token { NSEvent.removeMonitor(token) } }
    }
}

struct SidebarReorderIcon: NSViewRepresentable {
    let name: String
    let editing: Bool
    var tint: NSColor = .labelColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context: Context) -> WiggleImage { WiggleImage() }
    func updateNSView(_ view: WiggleImage, context: Context) {
        if view.symbolName != name {
        view.symbolName = name
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        }
        view.contentTintColor = tint
        view.setEditing(editing && !reduceMotion)
    }
    final class WiggleImage: NSImageView {
        var symbolName = ""
        private var editing = false
        static let animationKey = "sidebarReorderWiggle"
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; isEditable = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func setEditing(_ enabled: Bool) {
            guard let layer else { return }
            guard enabled != editing else { return }
            editing = enabled
            if enabled {
                guard layer.animation(forKey: Self.animationKey) == nil else { return }
                // Stable per-symbol variation; layout updates never restart or
                // randomize the animation. Avoid the synchronized metronome look.
                let seed = symbolName.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
                let amplitude = 0.024 + Double(seed % 997) / 997 * 0.018
                let duration = 0.24 + Double((seed / 997) % 991) / 991 * 0.09
                let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                animation.values = [-amplitude, amplitude, -amplitude]
                animation.duration = duration
                animation.timeOffset = duration * Double((seed / 988027) % 983) / 983
                animation.repeatCount = .infinity
                animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
                layer.add(animation, forKey: Self.animationKey)
            } else {
                layer.removeAnimation(forKey: Self.animationKey)
            }
        }
    }
}
