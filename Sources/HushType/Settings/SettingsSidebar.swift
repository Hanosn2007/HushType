import Combine
import SwiftUI

enum SettingsSidebarScrollTestConfiguration {
    static let enabledKey = "hushtype.preview.sidebarScrollTest.enabled"
    static let itemCount = 100

    static func isEnabled(
        defaults: UserDefaults = .standard,
        isPreview: Bool = SettingsScrollBlurConfiguration.defaultIsPreview
    ) -> Bool {
        isPreview && ((defaults.object(forKey: enabledKey) as? Bool) ?? false)
    }
}

struct SettingsDrawnSidebar: View {
    @AppStorage(SettingsOfficialSidebarConfiguration.styleKey) private var officialStyle =
        SettingsOfficialSidebarConfiguration.defaultStyle.rawValue
    @AppStorage(SettingsOfficialSidebarConfiguration.barHeightKey) private var officialBarHeight =
        Double(SettingsOfficialSidebarConfiguration.defaultBarHeight)
    @AppStorage(SettingsOfficialSidebarConfiguration.barSpacingKey) private var officialBarSpacing =
        Double(SettingsOfficialSidebarConfiguration.defaultBarSpacing)
    let sections: [HushTypeSettingsSection]
    @Binding var selection: HushTypeSettingsSection
    @Environment(\.settingsTopBarHeight) private var topInset
    @Environment(\.controlActiveState) private var activeState
    @FocusState private var focused: Bool
    @State private var showsScrollTestItems = SettingsSidebarScrollTestConfiguration.isEnabled()

    var body: some View {
        if #available(macOS 26.0, *), SettingsScrollBlurConfiguration.defaultIsPreview {
            officialEffectSidebar
        } else {
            legacySidebar
        }
    }

    private var legacySidebar: some View {
        ScrollView {
            sidebarContent
            .padding(.top, topInset + 8)
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .modifier(sidebarInteraction)
    }

    @available(macOS 26.0, *)
    private var officialEffectSidebar: some View {
        let configuration = SettingsOfficialSidebarConfiguration.make(
            styleRawValue: officialStyle,
            barHeight: officialBarHeight,
            barSpacing: officialBarSpacing
        )

        return ScrollView {
            sidebarContent
                .padding(.top, 8)
                .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .scrollEdgeEffectStyle(scrollEdgeStyle(for: configuration.style), for: .top)
        .safeAreaBar(edge: .top, spacing: configuration.barSpacing) {
            // A Color.clear-only bar did not create the soft edge in the accepted
            // Preview demo, so retain fixed visible content here.
            HStack {
                Text("HushType")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: configuration.barHeight, alignment: .bottom)
        }
        .modifier(sidebarInteraction)
    }

    private var sidebarContent: some View {
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

            if showsScrollTestItems {
                ForEach(1...SettingsSidebarScrollTestConfiguration.itemCount, id: \.self) { index in
                    Text(
                        L10n.format(
                            "settings.debug.sidebar_scroll_test.filler_item",
                            "Scroll test item %1$d",
                            arguments: [index]
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    @available(macOS 26.0, *)
    private func scrollEdgeStyle(
        for style: SettingsOfficialSidebarConfiguration.Style
    ) -> ScrollEdgeEffectStyle {
        switch style {
        case .soft: .soft
        case .hard: .hard
        case .automatic: .automatic
        }
    }

    private var sidebarInteraction: some ViewModifier {
        SidebarInteraction(
            focused: $focused,
            move: move,
            refreshScrollTest: { showsScrollTestItems = SettingsSidebarScrollTestConfiguration.isEnabled() }
        )
    }

    private struct SidebarInteraction: ViewModifier {
        @FocusState.Binding var focused: Bool
        let move: (Int) -> KeyPress.Result
        let refreshScrollTest: () -> Void

        func body(content: Content) -> some View {
            content
                .focusable().focusEffectDisabled().focused($focused)
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UserDefaults.didChangeNotification,
                        object: UserDefaults.standard
                    ).receive(on: RunLoop.main)
                ) { _ in
                    refreshScrollTest()
                }
        }
    }
    private func move(_ direction: Int) -> KeyPress.Result {
        guard let index = sections.firstIndex(of: selection) else { return .ignored }
        let next = min(sections.count - 1, max(0, index + direction))
        guard sections.indices.contains(next) else { return .ignored }
        selection = sections[next]
        return .handled
    }
}
