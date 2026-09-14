import AppKit
import SwiftUI

/// A native popup refreshes its inventory immediately before opening the menu.
struct SettingsRefreshingPicker: NSViewRepresentable {
    struct Item { let id: String; let title: String }
    let selection: String
    let selectedTitle: String
    let options: @MainActor () -> [Item]
    let changed: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.menu?.delegate = context.coordinator
        context.coordinator.button = button
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        // A minimal selected item is enough between openings; no device scan
        // belongs in SwiftUI's per-frame update path.
        if button.selectedItem?.representedObject as? String != selection || button.title != selectedTitle {
            button.removeAllItems()
            button.addItem(withTitle: selectedTitle)
            button.lastItem?.representedObject = selection
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let ideal = nsView.intrinsicContentSize
        // The menu's longest title must not become the Form's minimum width.
        // Accept the parent's finite allocation and let AppKit truncate titles.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 180
        return CGSize(width: max(0, width), height: ideal.height)
    }
    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var parent: SettingsRefreshingPicker
        weak var button: NSPopUpButton?
        init(_ parent: SettingsRefreshingPicker) { self.parent = parent }
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let button else { return }
            let items = parent.options()
            button.removeAllItems()
            for item in items {
                button.addItem(withTitle: item.title)
                button.lastItem?.representedObject = item.id
            }
            if !items.contains(where: { $0.id == parent.selection }) {
                button.addItem(withTitle: parent.selectedTitle + " " + L10n.string("profiles.unavailable", fallback: "(Unavailable)"))
                button.lastItem?.representedObject = parent.selection
            }
            if let item = button.itemArray.first(where: { $0.representedObject as? String == parent.selection }) {
                button.select(item)
            }
        }
        @objc func select(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            parent.changed(id)
        }
    }
}
