import Combine
import SwiftUI

/// Local Live Caption controls. This page intentionally exposes neither the
/// translated-caption product nor any network or API-key configuration.
struct SettingsCaptionsView: View {
    @ObservedObject var model: HushTypeSettingsModel
    @AppStorage(OverviewPreferences.developerModeKey) private var developerMode = false
    @AppStorage("hushtype.liveCaption.showsTimestamps") private var showsTimestamps = false
    @AppStorage(OverviewPreferences.keepCaptionWindowKey) private var keepsWindow = false
    @AppStorage(OverviewPreferences.keepCaptionTextKey) private var keepsText = false
    @AppStorage(LocalTextPreferences.captionTranslationKey) private var translatesCaptions = false
    @AppStorage(LocalTextPreferences.captionTargetKey) private var translationTarget = LocalTextLanguage.simplifiedChinese.rawValue

    @State private var presentation = LiveCaptionPresentationConfiguration.load()
    @State private var snappingEnabled = LiveCaptionDragPreferences.snappingEnabled
    @State private var hapticsEnabled = LiveCaptionDragPreferences.hapticsEnabled
    @State private var snapRadius = Double(LiveCaptionDragPreferences.snapRadius)
    @State private var guideEnabled = LiveCaptionDragPreferences.guideEnabled
    @State private var guideOpacity = Double(LiveCaptionDragPreferences.guideOpacity)
    @State private var fadeExponent = Double(LiveCaptionDragPreferences.fadeExponent)

    var body: some View {
        SettingsPage {
            SettingsTaskControlSection(
                taskName: L10n.string("settings.sidebar.captions", fallback: "Captions"),
                statusLabel: L10n.string("settings.captions.status", fallback: "Status"),
                status: captionStatus,
                state: model.captionTaskState,
                enabled: model.captionTaskState == .running || model.canStartCaptions,
                action: model.toggleCaptions
            )
            ProfileSelectionSection(use: .captions, model: model)

            Section {
                Toggle(L10n.string("overview.keep_caption_window", fallback: "Keep caption window after stopping"), isOn: $keepsWindow)
                Toggle(L10n.string("overview.keep_caption_text", fallback: "Keep existing captions when restarting"), isOn: $keepsText)
            }

            if developerMode {

                Section {
                    SettingsFeatureGroup(
                        title: L10n.string("settings.captions.display", fallback: "Display"),
                        systemImage: "rectangle.on.rectangle"
                    ) {
                        Toggle(
                            L10n.string("settings.captions.timestamps", fallback: "Show timestamps"),
                            isOn: $showsTimestamps
                        )
                        displaySlider(
                            label: L10n.string("settings.captions.max_sentences", fallback: "Visible sentences"),
                            value: Binding(
                                get: { Double(presentation.maximumAutomaticSentences) },
                                set: { savePresentation(maximumAutomaticSentences: Int($0)) }
                            ),
                            range: 1...30,
                            step: 1,
                            valueText: "\(presentation.maximumAutomaticSentences)"
                        )
                        Text(L10n.string(
                            "settings.captions.display.description",
                            fallback: "This only limits automatic window sizing. You can still scroll through the full caption history."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        displaySlider(
                            label: L10n.string("settings.captions.max_width", fallback: "Maximum width"),
                            value: Binding(
                                get: { Double(presentation.maximumAutomaticWidth) },
                                set: { savePresentation(maximumAutomaticWidth: CGFloat($0)) }
                            ),
                            range: 280...1600,
                            step: 20,
                            valueText: String(format: "%.0f pt", presentation.maximumAutomaticWidth)
                        )
                        displaySlider(
                            label: L10n.string("settings.captions.max_height", fallback: "Maximum height"),
                            value: Binding(
                                get: { Double(presentation.maximumAutomaticHeight) },
                                set: { savePresentation(maximumAutomaticHeight: CGFloat($0)) }
                            ),
                            range: 120...800,
                            step: 20,
                            valueText: String(format: "%.0f pt", presentation.maximumAutomaticHeight)
                        )
                        Button(L10n.string("settings.captions.display.restore", fallback: "Restore display defaults")) {
                            restorePresentationDefaults()
                        }
                    }
                } header: { SettingsDebugDivider() }

                Section {
                    SettingsFeatureGroup(
                        title: L10n.string("settings.captions.drag_snap", fallback: "Drag and snapping"),
                        systemImage: "arrow.up.and.down.and.arrow.left.and.right"
                    ) {
                        Toggle(
                            L10n.string("settings.captions.snapping", fallback: "Enable snapping"),
                            isOn: snappingEnabledBinding
                        )
                        Toggle(
                            L10n.string("settings.captions.haptics", fallback: "Snap haptic feedback"),
                            isOn: hapticsEnabledBinding
                        )
                        displaySlider(
                            label: L10n.string("settings.captions.snap_radius", fallback: "Snap radius"),
                            value: Binding(
                                get: { snapRadius },
                                set: { snapRadius = Double(LiveCaptionDragPreferences.save(CGFloat($0))) }
                            ),
                            range: 2...40,
                            step: 1,
                            valueText: String(format: "%.0f pt", snapRadius)
                        )
                        Button(L10n.string("settings.captions.drag_snap.restore", fallback: "Restore drag defaults")) {
                            restoreDragDefaults()
                        }
                    }
                }

                Section {
                    SettingsFeatureGroup(
                        title: L10n.string("settings.captions.glass", fallback: "Glass appearance"),
                        systemImage: "drop"
                    ) {
                        Toggle(
                            L10n.string("settings.captions.glass.guide", fallback: "Show snap guide"),
                            isOn: guideEnabledBinding
                        )
                        displaySlider(
                            label: L10n.string("settings.captions.glass.opacity", fallback: "Guide opacity"),
                            value: guideOpacityBinding,
                            range: 0.1...1,
                            step: 0.05,
                            valueText: String(format: "%.0f%%", guideOpacity * 100)
                        )
                        displaySlider(
                            label: L10n.string("settings.captions.glass.fade", fallback: "Fade acceleration"),
                            value: fadeExponentBinding,
                            range: 1...4,
                            step: 0.1,
                            valueText: String(format: "%.1f", fadeExponent)
                        )
                        Button(L10n.string("settings.captions.glass.restore", fallback: "Restore glass defaults")) {
                            restoreGlassDefaults()
                        }
                    }
                }
            }
        }
        .onAppear(perform: reloadPreferences)
        .onReceive(
            NotificationCenter.default.publisher(
                for: UserDefaults.didChangeNotification,
                object: UserDefaults.standard
            ).receive(on: RunLoop.main)
        ) { _ in
            reloadPreferences()
        }
    }

    private var captionStatus: String {
        if model.isCaptionFinishing {
            return L10n.string("overview.finishing", fallback: "Finishing")
        }
        if model.isCaptionStarting {
            return L10n.string("settings.captions.status.starting", fallback: "Starting")
        }
        guard model.isCaptionActive else {
            return L10n.string("settings.captions.status.stopped", fallback: "Stopped")
        }

        switch model.captionSource {
        case .some(.mic):
            return L10n.string("settings.captions.status.microphone", fallback: "Captions from Microphone")
        case .some(.system):
            return L10n.string("settings.captions.status.app_audio", fallback: "Captions from App Audio")
        case .none:
            return L10n.string("settings.captions.status.starting", fallback: "Starting")
        }
    }

    private var microphoneButtonTitle: String {
        if model.isCaptionActive, model.captionSource == .some(.mic) {
            return L10n.string("settings.captions.microphone.active", fallback: "Using Microphone")
        }
        return model.isCaptionActive
            ? L10n.string("settings.captions.microphone.switch", fallback: "Switch to Microphone")
            : L10n.string("settings.captions.microphone.start", fallback: "Start Microphone")
    }

    private var appAudioButtonTitle: String {
        if model.isCaptionActive, case .some(.system) = model.captionSource {
            return L10n.string("settings.captions.app_audio.active", fallback: "Using App Audio")
        }
        return model.isCaptionActive
            ? L10n.string("settings.captions.app_audio.switch", fallback: "Switch to App Audio…")
            : L10n.string("settings.captions.app_audio.start", fallback: "Start App Audio…")
    }

    private var snappingEnabledBinding: Binding<Bool> {
        Binding(
            get: { snappingEnabled },
            set: { enabled in
                UserDefaults.standard.set(enabled, forKey: LiveCaptionDragPreferences.snappingEnabledKey)
                snappingEnabled = LiveCaptionDragPreferences.snappingEnabled
            }
        )
    }

    private var hapticsEnabledBinding: Binding<Bool> {
        Binding(
            get: { hapticsEnabled },
            set: { enabled in
                UserDefaults.standard.set(enabled, forKey: LiveCaptionDragPreferences.hapticsEnabledKey)
                hapticsEnabled = LiveCaptionDragPreferences.hapticsEnabled
            }
        )
    }

    private var guideEnabledBinding: Binding<Bool> {
        Binding(
            get: { guideEnabled },
            set: { enabled in
                UserDefaults.standard.set(enabled, forKey: LiveCaptionDragPreferences.guideEnabledKey)
                guideEnabled = LiveCaptionDragPreferences.guideEnabled
            }
        )
    }

    private var guideOpacityBinding: Binding<Double> {
        Binding(
            get: { guideOpacity },
            set: { value in
                UserDefaults.standard.set(value, forKey: LiveCaptionDragPreferences.guideOpacityKey)
                guideOpacity = Double(LiveCaptionDragPreferences.guideOpacity)
            }
        )
    }

    private var fadeExponentBinding: Binding<Double> {
        Binding(
            get: { fadeExponent },
            set: { value in
                UserDefaults.standard.set(value, forKey: LiveCaptionDragPreferences.fadeExponentKey)
                fadeExponent = Double(LiveCaptionDragPreferences.fadeExponent)
            }
        )
    }

    private func displaySlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(Text(label))
        }
    }

    private func savePresentation(
        maximumAutomaticSentences: Int? = nil,
        maximumAutomaticWidth: CGFloat? = nil,
        maximumAutomaticHeight: CGFloat? = nil
    ) {
        let sentences = maximumAutomaticSentences ?? presentation.maximumAutomaticSentences
        let width = maximumAutomaticWidth ?? presentation.maximumAutomaticWidth
        let height = maximumAutomaticHeight ?? presentation.maximumAutomaticHeight
        UserDefaults.standard.set(sentences, forKey: LiveCaptionPresentationConfiguration.maximumAutomaticSentencesKey)
        UserDefaults.standard.set(Double(width), forKey: LiveCaptionPresentationConfiguration.maximumAutomaticWidthKey)
        UserDefaults.standard.set(Double(height), forKey: LiveCaptionPresentationConfiguration.maximumAutomaticHeightKey)
        presentation = LiveCaptionPresentationConfiguration.load()
    }

    private func restorePresentationDefaults() {
        showsTimestamps = false
        let defaults = LiveCaptionPresentationConfiguration.defaults
        savePresentation(
            maximumAutomaticSentences: defaults.maximumAutomaticSentences,
            maximumAutomaticWidth: defaults.maximumAutomaticWidth,
            maximumAutomaticHeight: defaults.maximumAutomaticHeight
        )
    }

    private func restoreDragDefaults() {
        UserDefaults.standard.set(true, forKey: LiveCaptionDragPreferences.snappingEnabledKey)
        UserDefaults.standard.set(true, forKey: LiveCaptionDragPreferences.hapticsEnabledKey)
        _ = LiveCaptionDragPreferences.save(LiveCaptionDragPreferences.defaultRadius)
        reloadPreferences()
    }

    private func restoreGlassDefaults() {
        UserDefaults.standard.set(true, forKey: LiveCaptionDragPreferences.guideEnabledKey)
        UserDefaults.standard.set(1.0, forKey: LiveCaptionDragPreferences.guideOpacityKey)
        UserDefaults.standard.set(2.0, forKey: LiveCaptionDragPreferences.fadeExponentKey)
        reloadPreferences()
    }

    private func reloadPreferences() {
        presentation = LiveCaptionPresentationConfiguration.load()
        snappingEnabled = LiveCaptionDragPreferences.snappingEnabled
        hapticsEnabled = LiveCaptionDragPreferences.hapticsEnabled
        snapRadius = Double(LiveCaptionDragPreferences.snapRadius)
        guideEnabled = LiveCaptionDragPreferences.guideEnabled
        guideOpacity = Double(LiveCaptionDragPreferences.guideOpacity)
        fadeExponent = Double(LiveCaptionDragPreferences.fadeExponent)
    }
}
