import AppKit
import SwiftUI

/// The toolbar owns the docked control. Keep a live slot, not a snapshot of its
/// window coordinates: an ancestor can move without changing the slot's frame.
final class SettingsInspectorDockAnchor: ObservableObject {
    weak var slot: NSView?
    weak var cutoutRegistry: SettingsAdaptiveCutoutRegistry?
    var onSlotChange: (() -> Void)?
    func register(_ view: NSView, cutoutRegistry: SettingsAdaptiveCutoutRegistry? = nil) {
        guard slot !== view || self.cutoutRegistry !== cutoutRegistry else { return }
        slot = view
        self.cutoutRegistry = cutoutRegistry
        onSlotChange?()
    }
}
struct SettingsInspectorDockAnchorReader: NSViewRepresentable {
    let anchor: SettingsInspectorDockAnchor
    @Environment(\.settingsAdaptiveCutoutRegistry) private var cutoutRegistry
    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) { anchor.register(view, cutoutRegistry: cutoutRegistry) }
    final class Reader: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }
    }
}

/// The trailing cluster receives spacing directly from the shell's measured
/// chrome; an outer preference round trip must not give it a different value.
struct SettingsInspectorToolbarControls: View {
    let anchor: SettingsInspectorDockAnchor
    let showsSearch: Bool
    @Binding var searchText: String
    let searchPrompt: String
    @Environment(\.settingsToolbarEdgeGap) private var gap
    var body: some View {
        HStack(spacing: gap) {
            if showsSearch {
                SettingsHistorySearch(text: $searchText, prompt: searchPrompt)
            }
            SettingsInspectorDockAnchorReader(anchor: anchor).frame(width: 36, height: 36)
        }
    }
}
