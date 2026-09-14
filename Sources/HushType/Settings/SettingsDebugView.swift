import AppKit
import Combine
import SwiftUI

/// One shared boundary between normal settings and developer-only controls.
struct SettingsDebugDivider: View {
    var body: some View {
        Label(L10n.string("settings.sidebar.debug", fallback: "Debug"),
              systemImage: "wrench.and.screwdriver")
            .font(.headline)
            .textCase(nil)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

/// Preview-only controls for the small set of runtime settings that are otherwise
/// intentionally hidden from normal settings pages.
struct SettingsDebugSections: View {
    @AppStorage(InspectorEdgeStyle.key) private var inspectorEdgeStyle = InspectorEdgeStyle.hard.rawValue
    enum Scope { case dictation, general }
    let scope: Scope
    @AppStorage(OverviewPreferences.developerModeKey) private var developerMode = false
    @ObservedObject var model: HushTypeSettingsModel
    @Environment(\.displayScale) private var displayScale
    @State private var configuration = SettingsScrollBlurConfiguration.current
    @State private var officialSidebarConfiguration = SettingsOfficialSidebarConfiguration.current
    @State private var inputConfiguration = TextInsertionConfiguration.load()
    @State private var sidebarScrollTestEnabled = SettingsSidebarScrollTestConfiguration.isEnabled()
    @State private var overlaySnappingEnabled = FloatingOverlayDragPreferences.snappingEnabled
    @State private var overlayHapticsEnabled = FloatingOverlayDragPreferences.hapticsEnabled
    @State private var overlaySnapRadius = Double(FloatingOverlayDragPreferences.snapRadius)
    @State private var fadeExponent = Double(FloatingOverlayDragPreferences.fadeExponent)
    @State private var overlayGuideEnabled = FloatingOverlayDragPreferences.guideEnabled
    @State private var overlayGuideOpacity = Double(FloatingOverlayDragPreferences.guideOpacity)

    var body: some View {
        Group {
            if developerMode {
                sections
            }
        }
        .onAppear { reloadConfiguration() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UserDefaults.didChangeNotification,
                object: UserDefaults.standard
            ).receive(on: RunLoop.main)
        ) { _ in
            reloadConfiguration()
        }
    }

    @ViewBuilder
    private var sections: some View {
        if scope == .dictation {
        Section {
            SettingsFeatureGroup(
                title: L10n.string("settings.debug.overlay.title", fallback: "Listening panel"),
                systemImage: "move.3d"
            ) {
                SettingsFeatureGroup(
                    title: L10n.string(
                        "settings.debug.overlay.drag_and_snap",
                        fallback: "Drag and snapping"
                    ),
                    systemImage: "arrow.up.and.down.and.arrow.left.and.right"
                ) {
                    Toggle(
                        L10n.string(
                            "settings.debug.overlay.snapping_enabled",
                            fallback: "Enable snapping"
                        ),
                        isOn: overlaySnappingEnabledBinding
                    )
                    Toggle(
                        L10n.string(
                            "settings.debug.overlay.haptics_enabled",
                            fallback: "Snap haptic feedback"
                        ),
                        isOn: overlayHapticsEnabledBinding
                    )
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(L10n.string("settings.debug.overlay.snap_radius", fallback: "Snap radius"))
                            Spacer()
                            Text(String(format: "%.0f pt", overlaySnapRadius))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: overlaySnapRadiusBinding, in: 2...40, step: 1)
                        .accessibilityLabel(Text(L10n.string("settings.debug.overlay.snap_radius", fallback: "Snap radius")))
                    }
                    Button(L10n.string(
                        "settings.debug.overlay.drag_restore",
                        fallback: "Restore drag defaults"
                    )) {
                        restoreOverlayDragDefaults()
                    }
                }

                overlayGlassGroup
            }
        } header: { SettingsDebugDivider() }

        Section {
            SettingsFeatureGroup(
                title: L10n.string("settings.input_method.unicode", fallback: "Unicode keyboard input"),
                systemImage: "keyboard"
            ) {
                Picker(
                    L10n.string(
                        "settings.debug.unicode_batch_size",
                        fallback: "UTF-16 code units per batch"
                    ),
                    selection: unicodeBatchSizeBinding
                ) {
                    ForEach(TextInsertionConfiguration.batchSizes, id: \.self) { size in
                        Text(
                            L10n.format(
                                "settings.debug.unicode_batch_size.value",
                                "%1$d UTF-16 units",
                                arguments: [size]
                            )
                        )
                        .tag(size)
                    }
                }
                .pickerStyle(.menu)

                Picker(
                    L10n.string(
                        "settings.debug.unicode_interval_milliseconds",
                        fallback: "Unicode batch interval"
                    ),
                    selection: unicodeIntervalBinding
                ) {
                    ForEach(TextInsertionConfiguration.intervals, id: \.self) { interval in
                        Text(
                            L10n.format(
                                "settings.debug.milliseconds.value",
                                "%1$d ms",
                                arguments: [interval]
                            )
                        )
                        .tag(interval)
                    }
                }
                .pickerStyle(.menu)
            }
        }

        Section {
            SettingsFeatureGroup(
                title: L10n.string(
                    "settings.debug.temporary_clipboard", fallback: "Temporary clipboard"),
                systemImage: "clipboard"
            ) {
                Picker(
                    L10n.string(
                        "settings.debug.clipboard_restore_milliseconds",
                        fallback: "Clipboard restore delay"
                    ),
                    selection: clipboardRestoreDelayBinding
                ) {
                    ForEach(TextInsertionConfiguration.restoreDelays, id: \.self) { delay in
                        Text(
                            L10n.format(
                                "settings.debug.milliseconds.value",
                                "%1$d ms",
                                arguments: [delay]
                            )
                        )
                        .tag(delay)
                    }
                }
                .pickerStyle(.menu)

                Toggle(
                    L10n.string(
                        "settings.debug.temporary_clipboard_markers",
                        fallback: "Add temporary clipboard marker"
                    ),
                    isOn: temporaryMarkersBinding
                )

                Text(
                    L10n.string(
                        "settings.debug.temporary_clipboard_markers.description",
                        fallback:
                            "Helps clipboard history tools that support this convention ignore automatic input. Turn it off to investigate compatibility; not every manager supports it."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }

        }
        if scope == .general {
        Section {
            LabeledContent(
                L10n.string("settings.debug.version", fallback: "Current version"),
                value: model.appVersionDisplay
            )
            LabeledContent(
                L10n.string("settings.debug.scroll_blur_status", fallback: "Scroll blur"),
                value: configuration.enabled
                    ? L10n.string("settings.debug.scroll_blur_enabled", fallback: "Enabled")
                    : L10n.string("settings.debug.scroll_blur_disabled", fallback: "Disabled")
            )
            LabeledContent(
                L10n.string("settings.debug.scroll_blur.effective_range", fallback: "Effective radius"),
                value: radiusRangeDescription
            )
        } header: {
            SettingsDebugDivider()
        }

        Section {
            Picker(L10n.string("inspector.edge_style", fallback: "Inspector top scroll edge"), selection: $inspectorEdgeStyle) {
                ForEach(InspectorEdgeStyle.allCases) { style in
                    Text(style == .none ? L10n.string("inspector.edge_none", fallback: "Off") : style.rawValue.capitalized)
                        .tag(style.rawValue)
                }
            }
        }

        Section {
            SettingsFeatureGroup(
                title: L10n.string("settings.debug.scroll_blur.right_preview", fallback: "Right · Preview effect"),
                systemImage: "circle.lefthalf.filled"
            ) {
                Toggle(isOn: enabledBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            L10n.string("settings.debug.scroll_blur", fallback: "Enable scroll-driven blur"))
                        Text(
                            L10n.string(
                                "settings.debug.scroll_blur.description",
                                fallback: "Adjust the settings-page top blur while scrolling."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                radiusSlider(
                    label: L10n.string(
                        "settings.debug.scroll_blur.minimum_radius", fallback: "Minimum radius"),
                    value: minimumRadiusBinding
                )
                radiusSlider(
                    label: L10n.string(
                        "settings.debug.scroll_blur.maximum_radius", fallback: "Maximum radius"),
                    value: maximumRadiusBinding
                )

                HStack {
                    Button(L10n.string("settings.debug.restore_defaults", fallback: "Restore Defaults")) {
                        restoreDefaults()
                    }
                    Spacer()
                    Text(
                        L10n.string(
                            "settings.debug.scroll_blur.apply_immediately",
                            fallback: "Changes apply immediately")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }

        Section {
            SettingsFeatureGroup(
                title: L10n.string(
                    "settings.debug.sidebar_official", fallback: "Left · System effect"),
                systemImage: "sidebar.leading"
            ) {
                Picker(
                    L10n.string(
                        "settings.debug.sidebar_official.style", fallback: "System style"),
                    selection: officialSidebarStyleBinding
                ) {
                    Text(
                        L10n.string(
                            "settings.debug.sidebar_official.style.soft", fallback: "Soft")
                    )
                    .tag(SettingsOfficialSidebarConfiguration.Style.soft)
                    Text(
                        L10n.string(
                            "settings.debug.sidebar_official.style.hard", fallback: "Hard")
                    )
                    .tag(SettingsOfficialSidebarConfiguration.Style.hard)
                    Text(
                        L10n.string(
                            "settings.debug.sidebar_official.style.automatic", fallback: "Automatic")
                    )
                    .tag(SettingsOfficialSidebarConfiguration.Style.automatic)
                }
                .pickerStyle(.menu)

                officialSidebarSlider(
                    label: L10n.string(
                        "settings.debug.sidebar_official.bar_height", fallback: "Fixed bar height"),
                    value: officialSidebarBarHeightBinding,
                    range: SettingsOfficialSidebarConfiguration.allowedBarHeightRange
                )
                officialSidebarSlider(
                    label: L10n.string(
                        "settings.debug.sidebar_official.bar_spacing", fallback: "Fixed bar spacing"),
                    value: officialSidebarBarSpacingBinding,
                    range: SettingsOfficialSidebarConfiguration.allowedBarSpacingRange
                )

                Text(
                    L10n.string(
                        "settings.debug.sidebar_official.description",
                        fallback:
                            "Only affects the left sidebar. Height and spacing change the fixed bar; macOS controls the blur."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Button(
                        L10n.string(
                            "settings.debug.sidebar_official.restore", fallback: "Restore left defaults")
                    ) {
                        restoreOfficialSidebarDefaults()
                    }
                    Spacer()
                    Text(
                        L10n.string(
                            "settings.debug.scroll_blur.apply_immediately",
                            fallback: "Changes apply immediately"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }

        Section {
            SettingsFeatureGroup(
                title: L10n.string(
                    "settings.debug.sidebar_scroll_test", fallback: "Sidebar scroll test"),
                systemImage: "sidebar.leading"
            ) {
                Toggle(isOn: sidebarScrollTestBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            L10n.string(
                                "settings.debug.sidebar_scroll_test.enabled",
                                fallback: "Add 100 filler items"
                            )
                        )
                        Text(
                            L10n.string(
                                "settings.debug.sidebar_scroll_test.description",
                                fallback:
                                    "Adds inert rows below the real navigation so you can inspect sidebar scrolling. Preview only."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if #unavailable(macOS 26.0) {
            Section {
                SettingsFeatureGroup(
                    title: L10n.string("settings.debug.scroll_blur.edge_inset", fallback: "Blur edge"),
                    systemImage: "rectangle.inset.filled"
                ) {
                    edgeInsetSlider

                    Text(
                        L10n.format(
                            "settings.debug.scroll_blur.edge_inset.description",
                            "The current %1$.0f-pixel inset is %2$.1f pt at this window's display scale.",
                            arguments: [
                                Double(configuration.edgeInsetPixels),
                                Double(configuration.edgeInsetPixels / max(1, displayScale))
                            ]
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Button(
                            L10n.string(
                                "settings.debug.scroll_blur.edge_inset.restore",
                                fallback: "Restore 2 px"
                            )
                        ) {
                            restoreEdgeInsetPixelsDefault()
                        }
                        Spacer()
                        Text(
                            L10n.string(
                                "settings.debug.scroll_blur.apply_immediately",
                                fallback: "Changes apply immediately"
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }

        Section {
            Text(
                L10n.string(
                    "settings.debug.logs.description",
                    fallback:
                        "HushType writes diagnostics to the unified log under subsystem com.felix.hushtype."
                )
            )
            .foregroundStyle(.secondary)

            Button(L10n.string("settings.debug.open_console", fallback: "Open Console")) {
                NSWorkspace.shared.open(
                    URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
            }
        } header: {
            Label(
                L10n.string("settings.debug.logs", fallback: "System Logs"),
                systemImage: "doc.text.magnifyingglass"
            )
        }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { configuration.enabled },
            set: { save(enabled: $0) }
        )
    }

    private var minimumRadiusBinding: Binding<Double> {
        Binding(
            get: { Double(configuration.minimumRadius) },
            set: { save(minimumRadius: CGFloat($0)) }
        )
    }

    private var maximumRadiusBinding: Binding<Double> {
        Binding(
            get: { Double(configuration.maximumRadius) },
            set: { save(maximumRadius: CGFloat($0)) }
        )
    }

    private var edgeInsetPixelsBinding: Binding<Double> {
        Binding(
            get: { Double(configuration.edgeInsetPixels) },
            set: { save(edgeInsetPixels: CGFloat($0)) }
        )
    }

    private var officialSidebarStyleBinding: Binding<SettingsOfficialSidebarConfiguration.Style> {
        Binding(
            get: { officialSidebarConfiguration.style },
            set: { saveOfficialSidebar(style: $0) }
        )
    }

    private var officialSidebarBarHeightBinding: Binding<Double> {
        Binding(
            get: { Double(officialSidebarConfiguration.barHeight) },
            set: { saveOfficialSidebar(barHeight: CGFloat($0)) }
        )
    }

    private var officialSidebarBarSpacingBinding: Binding<Double> {
        Binding(
            get: { Double(officialSidebarConfiguration.barSpacing) },
            set: { saveOfficialSidebar(barSpacing: CGFloat($0)) }
        )
    }

    private var sidebarScrollTestBinding: Binding<Bool> {
        Binding(
            get: { sidebarScrollTestEnabled },
            set: { enabled in
                UserDefaults.standard.set(enabled, forKey: SettingsSidebarScrollTestConfiguration.enabledKey)
                sidebarScrollTestEnabled = SettingsSidebarScrollTestConfiguration.isEnabled()
            }
        )
    }

    private var overlaySnappingEnabledBinding: Binding<Bool> {
        Binding(
            get: { overlaySnappingEnabled },
            set: { enabled in
                UserDefaults.standard.set(
                    enabled,
                    forKey: FloatingOverlayDragPreferences.snappingEnabledKey
                )
                reloadOverlayConfiguration()
            }
        )
    }

    private var overlayHapticsEnabledBinding: Binding<Bool> {
        Binding(
            get: { overlayHapticsEnabled },
            set: { enabled in
                UserDefaults.standard.set(
                    enabled,
                    forKey: FloatingOverlayDragPreferences.hapticsEnabledKey
                )
                reloadOverlayConfiguration()
            }
        )
    }

    private var overlayGuideEnabledBinding: Binding<Bool> {
        Binding(
            get: { overlayGuideEnabled },
            set: { enabled in
                UserDefaults.standard.set(
                    enabled,
                    forKey: FloatingOverlayDragPreferences.guideEnabledKey
                )
                reloadOverlayConfiguration()
            }
        )
    }

    private var overlaySnapRadiusBinding: Binding<Double> {
        Binding(
            get: { overlaySnapRadius },
            set: { value in
                FloatingOverlayDragPreferences.save(CGFloat(value))
                reloadOverlayConfiguration()
            }
        )
    }


    private var unicodeBatchSizeBinding: Binding<Int> {
        Binding(
            get: { inputConfiguration.unicodeBatchSize },
            set: { size in
                UserDefaults.standard.set(size, forKey: TextInsertionConfiguration.batchSizeKey)
                inputConfiguration = TextInsertionConfiguration.load()
            }
        )
    }

    private var unicodeIntervalBinding: Binding<Int> {
        Binding(
            get: { inputConfiguration.unicodeIntervalMilliseconds },
            set: { interval in
                UserDefaults.standard.set(interval, forKey: TextInsertionConfiguration.intervalKey)
                inputConfiguration = TextInsertionConfiguration.load()
            }
        )
    }

    private var clipboardRestoreDelayBinding: Binding<Int> {
        Binding(
            get: { inputConfiguration.clipboardRestoreMilliseconds },
            set: { delay in
                UserDefaults.standard.set(delay, forKey: TextInsertionConfiguration.restoreDelayKey)
                inputConfiguration = TextInsertionConfiguration.load()
            }
        )
    }

    private var temporaryMarkersBinding: Binding<Bool> {
        Binding(
            get: { inputConfiguration.temporaryMarkers },
            set: { enabled in
                UserDefaults.standard.set(enabled, forKey: TextInsertionConfiguration.markersKey)
                inputConfiguration = TextInsertionConfiguration.load()
            }
        )
    }


    private var overlayGlassGroup: some View {
        SettingsFeatureGroup(
            title: L10n.string("settings.debug.glass.title", fallback: "Guide glass"),
            systemImage: "drop"
        ) {
            Toggle(
                L10n.string("settings.debug.glass.enabled", fallback: "Show snap guide"),
                isOn: overlayGuideEnabledBinding
            )
            overlayGuideSlider(
                label: L10n.string("settings.debug.glass.opacity", fallback: "Guide opacity"),
                value: $overlayGuideOpacity,
                range: 0.1...1,
                step: 0.05,
                key: FloatingOverlayDragPreferences.guideOpacityKey,
                display: String(format: "%.0f%%", overlayGuideOpacity * 100)
            )
            overlayGuideSlider(
                label: L10n.string("settings.debug.overlay.curve", fallback: "Fade acceleration"),
                value: $fadeExponent,
                range: 1...4,
                step: 0.1,
                key: FloatingOverlayDragPreferences.fadeExponentKey,
                display: String(format: "%.1f", fadeExponent)
            )
            Text(L10n.string(
                "settings.debug.glass.control_center_help",
                fallback: "The system ControlCenter guide fades as the listening panel approaches."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            Button(L10n.string(
                "settings.debug.glass.restore",
                fallback: "Restore guide defaults"
            )) {
                restoreOverlayGuideDefaults()
            }
        }
    }

    private func overlayGuideSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, key: String, display: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                Spacer()
                Text(display).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value.wrappedValue }, set: {
                UserDefaults.standard.set($0, forKey: key)
                reloadOverlayConfiguration()
            }), in: range, step: step)
            .accessibilityLabel(Text(label))
        }
    }

    private var radiusRangeDescription: String {
        String(
            format: "%.1f–%.1f",
            locale: Locale.current,
            Double(configuration.minimumRadius),
            Double(configuration.maximumRadius)
        )
    }

    private func radiusSlider(label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.1f", locale: Locale.current, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: value,
                in: Double(
                    SettingsScrollBlurConfiguration.allowedRadiusRange.lowerBound)...Double(
                        SettingsScrollBlurConfiguration.allowedRadiusRange.upperBound),
                step: 0.5)
        }
    }

    private var edgeInsetSlider: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.string("settings.debug.scroll_blur.edge_inset.pixels", fallback: "Inset"))
                Spacer()
                Text(
                    L10n.format(
                        "settings.debug.scroll_blur.edge_inset.pixels.value",
                        "%1$.0f px",
                        arguments: [Double(configuration.edgeInsetPixels)]
                    )
                )
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Slider(
                value: edgeInsetPixelsBinding,
                in: Double(SettingsScrollBlurConfiguration.allowedEdgeInsetPixelsRange.lowerBound)...Double(
                    SettingsScrollBlurConfiguration.allowedEdgeInsetPixelsRange.upperBound),
                step: 1
            )
        }
    }

    private func officialSidebarSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<CGFloat>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                Spacer()
                Text(
                    L10n.format(
                        "settings.debug.sidebar_official.points.value",
                        "%1$.0f pt",
                        arguments: [value.wrappedValue]
                    )
                )
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Slider(
                value: value,
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
        }
    }

    private func save(
        enabled: Bool? = nil,
        minimumRadius: CGFloat? = nil,
        maximumRadius: CGFloat? = nil,
        edgeInsetPixels: CGFloat? = nil
    ) {
        if let edgeInsetPixels {
            configuration = SettingsDebugPreferences.saveScrollBlurEdgeInsetPixels(edgeInsetPixels)
            return
        }
        configuration = SettingsDebugPreferences.saveScrollBlur(
            enabled: enabled ?? configuration.enabled,
            minimumRadius: minimumRadius ?? configuration.minimumRadius,
            maximumRadius: maximumRadius ?? configuration.maximumRadius
        )
    }

    private func restoreDefaults() {
        SettingsDebugPreferences.restoreScrollBlurDefaults()
        reloadConfiguration()
    }

    private func restoreEdgeInsetPixelsDefault() {
        SettingsDebugPreferences.restoreScrollBlurEdgeInsetPixelsDefault()
        reloadConfiguration()
    }

    private func saveOfficialSidebar(
        style: SettingsOfficialSidebarConfiguration.Style? = nil,
        barHeight: CGFloat? = nil,
        barSpacing: CGFloat? = nil
    ) {
        let current = officialSidebarConfiguration
        let updated = SettingsOfficialSidebarConfiguration.make(
            styleRawValue: (style ?? current.style).rawValue,
            barHeight: Double(barHeight ?? current.barHeight),
            barSpacing: Double(barSpacing ?? current.barSpacing)
        )
        UserDefaults.standard.set(updated.style.rawValue, forKey: SettingsOfficialSidebarConfiguration.styleKey)
        UserDefaults.standard.set(updated.barHeight, forKey: SettingsOfficialSidebarConfiguration.barHeightKey)
        UserDefaults.standard.set(updated.barSpacing, forKey: SettingsOfficialSidebarConfiguration.barSpacingKey)
        officialSidebarConfiguration = updated
    }

    private func restoreOfficialSidebarDefaults() {
        UserDefaults.standard.removeObject(forKey: SettingsOfficialSidebarConfiguration.styleKey)
        UserDefaults.standard.removeObject(forKey: SettingsOfficialSidebarConfiguration.barHeightKey)
        UserDefaults.standard.removeObject(forKey: SettingsOfficialSidebarConfiguration.barSpacingKey)
        officialSidebarConfiguration = .current
    }

    private func restoreOverlayDragDefaults() {
        UserDefaults.standard.set(
            true,
            forKey: FloatingOverlayDragPreferences.snappingEnabledKey
        )
        UserDefaults.standard.set(
            true,
            forKey: FloatingOverlayDragPreferences.hapticsEnabledKey
        )
        FloatingOverlayDragPreferences.save(FloatingOverlayDragPreferences.defaultRadius)
        reloadOverlayConfiguration()
    }

    private func restoreOverlayGuideDefaults() {
        UserDefaults.standard.set(
            true,
            forKey: FloatingOverlayDragPreferences.guideEnabledKey
        )
        UserDefaults.standard.set(
            1.0,
            forKey: FloatingOverlayDragPreferences.guideOpacityKey
        )
        UserDefaults.standard.set(
            2.0,
            forKey: FloatingOverlayDragPreferences.fadeExponentKey
        )
        reloadOverlayConfiguration()
    }

    private func reloadOverlayConfiguration() {
        overlaySnappingEnabled = FloatingOverlayDragPreferences.snappingEnabled
        overlayHapticsEnabled = FloatingOverlayDragPreferences.hapticsEnabled
        overlaySnapRadius = Double(FloatingOverlayDragPreferences.snapRadius)
        fadeExponent = Double(FloatingOverlayDragPreferences.fadeExponent)
        overlayGuideEnabled = FloatingOverlayDragPreferences.guideEnabled
        overlayGuideOpacity = Double(FloatingOverlayDragPreferences.guideOpacity)
    }

    private func reloadConfiguration() {
        configuration = SettingsScrollBlurConfiguration.current
        officialSidebarConfiguration = SettingsOfficialSidebarConfiguration.current
        inputConfiguration = TextInsertionConfiguration.load()
        sidebarScrollTestEnabled = SettingsSidebarScrollTestConfiguration.isEnabled()
        reloadOverlayConfiguration()
    }
}


enum SettingsDebugPreferences {
    @discardableResult
    static func saveScrollBlur(
        enabled: Bool,
        minimumRadius: CGFloat,
        maximumRadius: CGFloat,
        defaults: UserDefaults = .standard,
        isPreview: Bool = SettingsScrollBlurConfiguration.defaultIsPreview
    ) -> SettingsScrollBlurConfiguration {
        let range = SettingsScrollBlurConfiguration.allowedRadiusRange
        let lower = min(max(minimumRadius, range.lowerBound), range.upperBound)
        let upper = min(max(maximumRadius, range.lowerBound), range.upperBound)

        defaults.set(enabled, forKey: SettingsScrollBlurConfiguration.enabledKey)
        defaults.set(min(lower, upper), forKey: SettingsScrollBlurConfiguration.minimumRadiusKey)
        defaults.set(max(lower, upper), forKey: SettingsScrollBlurConfiguration.maximumRadiusKey)
        return SettingsScrollBlurConfiguration.load(defaults: defaults, isPreview: isPreview)
    }

    static func restoreScrollBlurDefaults(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: SettingsScrollBlurConfiguration.enabledKey)
        defaults.removeObject(forKey: SettingsScrollBlurConfiguration.minimumRadiusKey)
        defaults.removeObject(forKey: SettingsScrollBlurConfiguration.maximumRadiusKey)
    }

    @discardableResult
    static func saveScrollBlurEdgeInsetPixels(
        _ pixels: CGFloat,
        defaults: UserDefaults = .standard,
        isPreview: Bool = SettingsScrollBlurConfiguration.defaultIsPreview
    ) -> SettingsScrollBlurConfiguration {
        let range = SettingsScrollBlurConfiguration.allowedEdgeInsetPixelsRange
        let sanitized = pixels.isFinite
            ? min(max(pixels, range.lowerBound), range.upperBound)
            : SettingsScrollBlurConfiguration.defaultEdgeInsetPixels
        defaults.set(sanitized, forKey: SettingsScrollBlurConfiguration.edgeInsetPixelsKey)
        return SettingsScrollBlurConfiguration.load(defaults: defaults, isPreview: isPreview)
    }

    static func restoreScrollBlurEdgeInsetPixelsDefault(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: SettingsScrollBlurConfiguration.edgeInsetPixelsKey)
    }
}
