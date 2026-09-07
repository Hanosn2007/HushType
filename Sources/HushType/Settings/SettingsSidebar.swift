import SwiftUI

struct SettingsDrawnSidebar: View {
    let sections: [HushTypeSettingsSection]
    @Binding var selection: HushTypeSettingsSection
    @Environment(\.settingsTopBarHeight) private var topInset
    @Environment(\.controlActiveState) private var activeState
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sections) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .foregroundStyle(selection == section && activeState != .inactive
                            ? Color.white : Color(nsColor: activeState == .inactive ? .secondaryLabelColor : .labelColor))
                        .background(selection == section
                            ? (activeState == .inactive ? Color.gray.opacity(0.25) : Color.accentColor)
                            : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                        .onTapGesture { selection = section; focused = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(selection == section ? .isSelected : [])
                        .accessibilityAction { selection = section }
                }
            }
            .padding(.top, topInset + 8)
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
    }
    private func move(_ direction: Int) -> KeyPress.Result {
        guard let index = sections.firstIndex(of: selection) else { return .ignored }
        let next = min(sections.count - 1, max(0, index + direction))
        guard sections.indices.contains(next) else { return .ignored }
        selection = sections[next]
        return .handled
    }
}
