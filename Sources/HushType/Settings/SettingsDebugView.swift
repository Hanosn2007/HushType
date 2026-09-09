import AppKit
import Combine
import SwiftUI

/// Preview-only controls for the small set of runtime settings that are otherwise
/// intentionally hidden from normal settings pages.
struct SettingsDebugView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @Environment(\.settingsTopBarHeight) private var topBarHeight
    @Environment(\.displayScale) private var displayScale
    @State private var configuration = SettingsScrollBlurConfiguration.current
    @State private var officialSidebarConfiguration = SettingsOfficialSidebarConfiguration.current
    @State private var inputConfiguration = TextInsertionConfiguration.load()
    @State private var sidebarScrollTestEnabled = SettingsSidebarScrollTestConfiguration.isEnabled()

    var body: some View {
        GeometryReader { geometry in
            Form {
                Section {
                    Text(
                        L10n.string(
                            "settings.debug.subtitle",
                            fallback: "Inspect Preview-only settings and diagnostics."
                        )
                    )
                    .foregroundStyle(.secondary)
                }

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
                    Label(
                        L10n.string("settings.debug.status", fallback: "Current Status"),
                        systemImage: "info.circle"
                    )
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
                    Picker(
                        L10n.string("settings.debug.input_method", fallback: "Input method"),
                        selection: inputMethodBinding
                    ) {
                        inputMethodChoices
                    }
                    .pickerStyle(.menu)
                } header: {
                    Label(
                        L10n.string("settings.debug.input", fallback: "Text input"), systemImage: "text.cursor")
                }

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
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentMargins(.top, topBarHeight, for: .scrollContent)
            .contentMargins(.horizontal, max(0, (geometry.size.width - 736) / 2), for: .scrollContent)
            .focusSection()
            .accessibilityElement(children: .contain)
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

    private var inputMethodBinding: Binding<TextInsertionConfiguration.Method> {
        Binding(
            get: { inputConfiguration.method },
            set: { method in
                UserDefaults.standard.set(method.rawValue, forKey: TextInsertionConfiguration.methodKey)
                inputConfiguration = TextInsertionConfiguration.load()
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

    @ViewBuilder
    private var inputMethodChoices: some View {
        Text(L10n.string("settings.input_method.clipboard", fallback: "Temporary clipboard"))
            .tag(TextInsertionConfiguration.Method.clipboard)
        Text(L10n.string("settings.input_method.unicode", fallback: "Unicode keyboard input"))
            .tag(TextInsertionConfiguration.Method.unicode)
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

    private func reloadConfiguration() {
        configuration = SettingsScrollBlurConfiguration.current
        officialSidebarConfiguration = SettingsOfficialSidebarConfiguration.current
        inputConfiguration = TextInsertionConfiguration.load()
        sidebarScrollTestEnabled = SettingsSidebarScrollTestConfiguration.isEnabled()
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
