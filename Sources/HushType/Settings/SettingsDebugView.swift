import AppKit
import Combine
import SwiftUI

/// Preview-only controls for the small set of runtime settings that are otherwise
/// intentionally hidden from normal settings pages.
struct SettingsDebugView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @Environment(\.settingsTopBarHeight) private var topBarHeight
    @State private var configuration = SettingsScrollBlurConfiguration.current

    var body: some View {
        GeometryReader { geometry in
            Form {
                Section {
                    Text(L10n.string(
                        "settings.debug.subtitle",
                        fallback: "Inspect Preview-only settings and diagnostics."
                    ))
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
                    Toggle(isOn: enabledBinding) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.string("settings.debug.scroll_blur", fallback: "Enable scroll-driven blur"))
                            Text(L10n.string(
                                "settings.debug.scroll_blur.description",
                                fallback: "Adjust the settings-page top blur while scrolling."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    radiusSlider(
                        label: L10n.string("settings.debug.scroll_blur.minimum_radius", fallback: "Minimum radius"),
                        value: minimumRadiusBinding
                    )
                    radiusSlider(
                        label: L10n.string("settings.debug.scroll_blur.maximum_radius", fallback: "Maximum radius"),
                        value: maximumRadiusBinding
                    )

                    HStack {
                        Button(L10n.string("settings.debug.restore_defaults", fallback: "Restore Defaults")) {
                            restoreDefaults()
                        }
                        Spacer()
                        Text(L10n.string("settings.debug.scroll_blur.apply_immediately", fallback: "Changes apply immediately"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label(
                        L10n.string("settings.debug.scroll_blur", fallback: "Scroll-driven blur"),
                        systemImage: "circle.lefthalf.filled"
                    )
                }

                Section {
                    Text(L10n.string(
                        "settings.debug.logs.description",
                        fallback: "HushType writes diagnostics to the unified log under subsystem com.felix.hushtype."
                    ))
                    .foregroundStyle(.secondary)

                    Button(L10n.string("settings.debug.open_console", fallback: "Open Console")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
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
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        ).receive(on: RunLoop.main)) { _ in
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
                in: Double(SettingsScrollBlurConfiguration.allowedRadiusRange.lowerBound)...Double(SettingsScrollBlurConfiguration.allowedRadiusRange.upperBound),
                step: 0.5
            )
        }
    }

    private func save(
        enabled: Bool? = nil,
        minimumRadius: CGFloat? = nil,
        maximumRadius: CGFloat? = nil
    ) {
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

    private func reloadConfiguration() {
        configuration = SettingsScrollBlurConfiguration.current
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
}
