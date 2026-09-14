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
    @ObservedObject private var order = SettingsSidebarOrder.shared
    @State private var editingOrder = false
    @State private var dragging: HushTypeSettingsSection?
    @State private var rowFrames: [HushTypeSettingsSection: CGRect] = [:]
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
        Group {
        if #available(macOS 26.0, *), SettingsScrollBlurConfiguration.defaultIsPreview {
            officialEffectSidebar
        } else {
            legacySidebar
        }
        }
        .background(SidebarEditingOutsideClick(enabled: editingOrder, finish: finishOrdering))
        .onDisappear { if editingOrder { finishOrdering() } }
    }

    private var legacySidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
            sidebarHeading
            sidebarContent
            }
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
            sidebarHeading
            .padding(.horizontal, 12)
            .frame(height: configuration.barHeight, alignment: .bottom)
        }
        .modifier(sidebarInteraction)
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(orderedSections) { section in
                HStack(spacing: 8) {
                    SidebarReorderIcon(name: section.symbolName, editing: editingOrder,
                        tint: selection == section && activeState != .inactive ? .white : (activeState == .inactive ? .secondaryLabelColor : .labelColor))
                        .frame(width: 20, height: 20)
                    Text(section.title)
                    Spacer(minLength: 0)
                    if editingOrder {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("sidebarOrder"))
                                .onChanged { value in
                                    guard editingOrder else { return }
                                    dragging = section
                                    if let target = orderedSections.first(where: { rowFrames[$0]?.contains(value.location) == true }), target != section {
                                        withAnimation(.easeInOut(duration: 0.18)) { order.move(section, to: target) }
                                    }
                                }.onEnded { _ in dragging = nil })
                            .help(L10n.string("settings.sidebar.reorder", fallback: "Drag to reorder"))
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .foregroundStyle(selection == section && activeState != .inactive
                        ? Color.white : Color(nsColor: activeState == .inactive ? .secondaryLabelColor : .labelColor))
                    .background(selection == section
                        ? (activeState == .inactive ? Color.gray.opacity(0.25) : Color.accentColor)
                        : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in editingOrder = true })
                    .onTapGesture { if !editingOrder { selection = section; focused = true } }
                    .background { if editingOrder { GeometryReader { geometry in
                        Color.clear.preference(key: SidebarOrderFramesKey.self, value: [section: geometry.frame(in: .named("sidebarOrder"))])
                    } } }
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
        .coordinateSpace(name: "sidebarOrder")
        .onPreferenceChange(SidebarOrderFramesKey.self) { if editingOrder { rowFrames = $0 } }
    }

    private var orderedSections: [HushTypeSettingsSection] { order.items.filter(sections.contains) }
    private func finishOrdering() { editingOrder = false; dragging = nil; order.save() }
    private var sidebarHeading: some View {
        HStack {
            Text("HushType").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if editingOrder {
                Button(action: finishOrdering) { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("settings.sidebar.reorder_done", fallback: "Finish arranging sidebar"))
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
        guard !editingOrder, let index = orderedSections.firstIndex(of: selection) else { return .ignored }
        let next = min(orderedSections.count - 1, max(0, index + direction))
        guard orderedSections.indices.contains(next) else { return .ignored }
        selection = orderedSections[next]
        return .handled
    }
}
