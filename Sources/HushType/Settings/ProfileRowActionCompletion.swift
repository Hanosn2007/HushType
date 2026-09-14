import AppKit
import SwiftUI

/// Let AppKit close its row actions before presenting a sheet or changing data.
/// No row overlays, synthetic swipe offsets, frame polling, or timeout.
@MainActor
final class ProfileRowActionCompletion: ObservableObject {
    weak var table: NSTableView?
    private var generation: UInt = 0

    func cancel() { generation &+= 1 }

    func perform(for id: UUID, action: @escaping @MainActor () -> Void) {
        generation &+= 1
        let request = generation
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            // AppKit supplies the transition and its standard duration.
            table?.animator().rowActionsVisible = false
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == request else { return }
                action()
            }
        }
    }
}

/// Locates the native table from the List's background, never from a row.
struct ProfileListTableReporter: NSViewRepresentable {
    let completion: ProfileRowActionCompletion
    func makeNSView(context: Context) -> Reporter { Reporter() }
    func updateNSView(_ view: Reporter, context: Context) {
        view.completion = completion
        view.locateTable()
    }
    static func dismantleNSView(_ view: Reporter, coordinator: ()) {
        view.completion?.cancel()
        view.completion?.table = nil
    }

    final class Reporter: NSView {
        weak var completion: ProfileRowActionCompletion?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); locateTable() }
        override func layout() { super.layout(); locateTable() }
        func locateTable() {
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
            if let table = completion?.table, table.window === window {
                normalizeSpacing(table)
                return
            }
            func find(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView {
                    let rect = convert(table.bounds, from: table)
                    let overlap = rect.intersection(bounds)
                    if !overlap.isNull, overlap.width > bounds.width * 0.5 { return table }
                }
                for child in view.subviews {
                    if let table = find(in: child) { return table }
                }
                return nil
            }
            var parent = superview
            while let ancestor = parent {
                if let table = find(in: ancestor) {
                    completion?.table = table
                    normalizeSpacing(table)
                    return
                }
                parent = ancestor.superview
            }
        }
        private func normalizeSpacing(_ table: NSTableView) {
            // List's 17pt intercell spacing otherwise adds 8pt on the left and
            // 9pt on the right to the embedded Form's native section margins.
            guard table.intercellSpacing.width != 0 else { return }
            table.intercellSpacing.width = 0
            table.sizeLastColumnToFit()
            table.tile()
        }
    }
}
