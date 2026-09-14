import AppKit
import AVFoundation
import ApplicationServices
import Combine
import CoreBluetooth

enum HushTypeSettingsSection: String, CaseIterable, Identifiable {
    case overview
    case dictation
    case captions
    case profiles
    case shortcuts
    case history
    case model
    case dictionary
    case permissions
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: L10n.string("settings.sidebar.overview", fallback: "Overview")
        case .dictation: L10n.string("settings.sidebar.dictation", fallback: "Dictation")
        case .captions: L10n.string("settings.sidebar.captions", fallback: "Captions")
        case .profiles: L10n.string("profiles.title", fallback: "Processing Configurations")
        case .shortcuts: L10n.string("settings.sidebar.shortcuts", fallback: "Shortcuts")
        case .history: L10n.string("settings.sidebar.history", fallback: "Recognition History")
        case .model: L10n.string("settings.sidebar.model", fallback: "Model")
        case .dictionary: L10n.string("settings.sidebar.dictionary", fallback: "Dictionary")
        case .permissions: L10n.string("settings.sidebar.permissions", fallback: "Permissions")
        case .general: L10n.string("settings.sidebar.general", fallback: "General")
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .dictation: "mic.fill"
        case .captions: "captions.bubble"
        case .profiles: "slider.horizontal.3"
        case .shortcuts: "keyboard"
        case .history: "clock.arrow.circlepath"
        case .model: "cpu"
        case .dictionary: "text.book.closed"
        case .permissions: "checklist"
        case .general: "gearshape"
        }
    }

    static func visibleSections(onboardingRequired: Bool, isPreview: Bool) -> [Self] {
        guard !onboardingRequired else { return [.permissions] }
        return allCases
    }
}

enum HushTypeModelControl {
    case stopDownload
    case unload
    case load
    case none
}

/// Imperative work stays in `AppDelegate` / `OnboardingManager`; the settings
/// window only owns presentation state and calls these narrow, UI-safe hooks.
struct HushTypeSettingsActions {
    var loadedModelID: () -> String? = { nil }
    var loadingModelID: () -> String? = { nil }
    var reloadModel: () -> Void = {}
    var unloadModel: () -> Void = {}
    var stopModelDownload: () -> Void = {}
    var cancelRecording: () -> Void = {}
    var toggleDictation: () -> Void = {}
    var startCaptions: () -> Void = {}
    var switchDictationEngine: (AppConfig.DictationEngine) -> Void = { _ in }
    var startCaptionMic: () -> Void = {}
    var startCaptionSystem: () -> Void = {}
    var stopCaptions: () -> Void = {}
    var openAccessibilitySettings: () -> Void = {}
    var resetOldAccessibilityEntry: () -> Bool = { false }
    var requestMicrophone: (@escaping (Bool) -> Void) -> Void = { completion in completion(false) }
    var openMicrophoneSettings: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var updateChannelChanged: () -> Void = {}
    var restart: () -> Void = {}
    var quit: () -> Void = {}

    init(
        loadedModelID: @escaping () -> String? = { nil },
        loadingModelID: @escaping () -> String? = { nil },
        reloadModel: @escaping () -> Void = {},
        unloadModel: @escaping () -> Void = {},
        stopModelDownload: @escaping () -> Void = {},
        cancelRecording: @escaping () -> Void = {},
        toggleDictation: @escaping () -> Void = {},
        startCaptions: @escaping () -> Void = {},
        switchDictationEngine: @escaping (AppConfig.DictationEngine) -> Void = { _ in },
        startCaptionMic: @escaping () -> Void = {},
        startCaptionSystem: @escaping () -> Void = {},
        stopCaptions: @escaping () -> Void = {},
        openAccessibilitySettings: @escaping () -> Void = {},
        resetOldAccessibilityEntry: @escaping () -> Bool = { false },
        requestMicrophone: @escaping (@escaping (Bool) -> Void) -> Void = { completion in completion(false) },
        openMicrophoneSettings: @escaping () -> Void = {},
        checkForUpdates: @escaping () -> Void = {},
        updateChannelChanged: @escaping () -> Void = {},
        restart: @escaping () -> Void = {},
        quit: @escaping () -> Void = {}
    ) {
        self.loadedModelID = loadedModelID
        self.loadingModelID = loadingModelID
        self.reloadModel = reloadModel
        self.unloadModel = unloadModel
        self.stopModelDownload = stopModelDownload
        self.cancelRecording = cancelRecording
        self.toggleDictation = toggleDictation
        self.startCaptions = startCaptions
        self.switchDictationEngine = switchDictationEngine
        self.startCaptionMic = startCaptionMic
        self.startCaptionSystem = startCaptionSystem
        self.stopCaptions = stopCaptions
        self.openAccessibilitySettings = openAccessibilitySettings
        self.resetOldAccessibilityEntry = resetOldAccessibilityEntry
        self.requestMicrophone = requestMicrophone
        self.openMicrophoneSettings = openMicrophoneSettings
        self.checkForUpdates = checkForUpdates
        self.updateChannelChanged = updateChannelChanged
        self.restart = restart
        self.quit = quit
    }
}

@MainActor
final class HushTypeSettingsModel: ObservableObject {
    let modelLibrary = LocalModelLibrary()
    let recognitionHistory: RecognitionHistoryStore
    // Keep unsaved dictionary edits when navigating or closing the settings window.
    let dictionaryEditor = DictionaryEditorModel()
    lazy var dictionaryLibraryEditors = DictionaryLibraryEditorSession(defaultEditor: dictionaryEditor)
    private var navigationHistory = SettingsNavigationHistory()
    @Published var isProfileInspectorPresented = false
    @Published var isDictionaryInspectorPresented = false
    func openDictionaryInspector(id: UUID) {
        let store = ProcessingProfileStore.shared
        if ProfileEditorPreferences.autosaveEnabled, store.isDirty, !store.save() {
            isProfileInspectorPresented = true
            return
        }
        dictionaryLibraryEditors.selectedID = id
        isProfileInspectorPresented = false
        isDictionaryInspectorPresented = true
    }
    func openProfileInspector(_ profile: ProcessingProfile) {
        let store = ProcessingProfileStore.shared
        if store.draft?.id != profile.id {
            if store.isDirty, !ProfileEditorPreferences.autosaveEnabled {
                store.errorMessage = ProfileError.unsaved.localizedDescription
                isDictionaryInspectorPresented = false
                isProfileInspectorPresented = true
                return
            }
            if store.isDirty, !store.save() {
                isProfileInspectorPresented = true
                return
            }
            store.edit(profile)
        } else if !store.isDirty {
            store.edit(profile)
        }
        isDictionaryInspectorPresented = false
        isProfileInspectorPresented = store.draft != nil
    }
    @Published var selection: HushTypeSettingsSection = .overview {
        didSet { navigationHistory.visit(selection) }
    }
    var canNavigateBack: Bool { !onboardingRequired && navigationHistory.canGoBack }
    var canNavigateForward: Bool { !onboardingRequired && navigationHistory.canGoForward }
    func navigateBack() {
        guard canNavigateBack, let target = navigationHistory.back() else { return }
        selection = target
    }
    func navigateForward() {
        guard canNavigateForward, let target = navigationHistory.forward() else { return }
        selection = target
    }
    @Published private(set) var appState: StatusBarController.State = .setupRequired
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var isRequestingMicrophone = false
    @Published private(set) var systemAudioGranted = SystemAudioPermissionFlow.isGranted
    @Published private(set) var didRequestSystemAudio = false
    @Published private(set) var systemAudioSettingsOpened = false
    @Published private(set) var didResetSystemAudio = false
    @Published private(set) var bluetoothStatus = CBManager.authorization
    @Published private(set) var isRequestingBluetooth = false
    private let bluetoothPermissionRequest = BluetoothPermissionRequest()
    @Published private(set) var accessibilitySettingsOpened = false
    @Published private(set) var didResetAccessibility = false
    /// Becomes true only after this process has observed permissions recover
    /// from an incomplete state. Accessibility grants need a fresh process for
    /// the event tap to see them reliably, including after a rebuilt app is
    /// granted again.
    @Published private(set) var needsPermissionRestart = false
    @Published var onboardingRequired = false
    @Published private(set) var currentDictationEngine = AppConfig.shared.dictationEngine
    @Published private(set) var captionMode: AppConfig.CaptionMode?
    @Published private(set) var captionSource: AudioSourceKind?
    @Published private(set) var isCaptionActive = false
    @Published private(set) var isCaptionStarting = false
    @Published private(set) var isCaptionFinishing = false
    @Published private(set) var dictationTaskState: OverviewTaskState = .stopped
    @Published var activeDictationProfile: ProcessingProfile?
    @Published var activeCaptionProfile: ProcessingProfile?
    private var isDictationPreparing = false
    @Published private(set) var loadedModelID: String?
    @Published var modelID = AppConfig.shared.modelId {
        didSet { AppConfig.shared.modelId = modelID }
    }
    @Published var floatingOverlayEnabled = AppConfig.shared.floatingOverlayEnabled {
        didSet { AppConfig.shared.floatingOverlayEnabled = floatingOverlayEnabled }
    }
    @Published var audioInputSelection = AppConfig.shared.audioInputSelection {
        didSet {
            guard !isRefreshing else { return }
            AppConfig.shared.audioInputSelection = audioInputSelection
            if let uid = AudioInputSelection.deviceUID(from: audioInputSelection),
               let selected = audioInputDevices.first(where: { $0.id == uid }) {
                currentAudioInputDeviceName = selected.name
            }
            refreshAudioInputDevices()
        }
    }
    @Published private(set) var audioInputDevices: [AudioInputDevice] = []
    @Published private(set) var currentAudioInputDeviceName: String? = nil
    private var isAudioDeviceRefreshInFlight = false
    @Published var releaseF5WhenModelUnloaded = AppConfig.shared.releaseF5WhenModelUnloaded {
        didSet { AppConfig.shared.releaseF5WhenModelUnloaded = releaseF5WhenModelUnloaded }
    }
    @Published var numberConversionEnabled = AppConfig.shared.numberConversionEnabled {
        didSet { AppConfig.shared.numberConversionEnabled = numberConversionEnabled }
    }
    @Published var textPolishEnabled = AppConfig.shared.textPolishEnabled {
        didSet { AppConfig.shared.textPolishEnabled = textPolishEnabled }
    }
    @Published var textTranslationEnabled = AppConfig.shared.textTranslationEnabled {
        didSet { AppConfig.shared.textTranslationEnabled = textTranslationEnabled }
    }
    @Published var punctuationMode = AppConfig.shared.punctuationMode {
        didSet { AppConfig.shared.punctuationMode = punctuationMode }
    }
    @Published var speechLanguage = AppConfig.shared.language ?? "auto" {
        didSet {
            guard !isRefreshing else { return }
            AppConfig.shared.language = speechLanguage == "auto" ? nil : speechLanguage
        }
    }
    @Published var chineseConversionEnabled = AppConfig.shared.chineseConversionEnabled {
        didSet { AppConfig.shared.chineseConversionEnabled = chineseConversionEnabled }
    }
    @Published var interfaceLanguageRaw = AppConfig.shared.interfaceLanguage.rawValue {
        didSet {
            guard !isRefreshing,
                  let language = InterfaceLanguage(rawValue: interfaceLanguageRaw) else { return }
            AppConfig.shared.interfaceLanguage = language
        }
    }
    @Published var updateChannelRaw = AppConfig.shared.updateChannel.rawValue {
        didSet {
            guard !isRefreshing,
                  let channel = UpdateChannel(rawValue: updateChannelRaw) else { return }
            AppConfig.shared.updateChannel = channel
            actions.updateChannelChanged()
        }
    }
    @Published var silentUpdateRelaunch = AppConfig.shared.silentUpdateRelaunch {
        didSet {
            guard !isRefreshing else { return }
            AppConfig.shared.silentUpdateRelaunch = silentUpdateRelaunch
        }
    }
    @Published var historyMaximumEntries = AppConfig.shared.recognitionHistoryMaximumEntries {
        didSet {
            guard !isRefreshing else { return }
            applyHistoryRetentionPolicy(maximumEntries: historyMaximumEntries, retentionDays: historyRetentionDays)
        }
    }
    /// Zero is the settings UI's stable representation of "never expire".
    @Published var historyRetentionDays = AppConfig.shared.recognitionHistoryRetentionDays ?? 0 {
        didSet {
            guard !isRefreshing else { return }
            applyHistoryRetentionPolicy(maximumEntries: historyMaximumEntries, retentionDays: historyRetentionDays)
        }
    }
    @Published private(set) var historyErrorMessage: String?

    private var actions = HushTypeSettingsActions()
    private var isRefreshing = false
    private var hasObservedMissingPermission: Bool
    private var werePermissionsComplete: Bool

    init() {
        recognitionHistory = RecognitionHistoryStore(
            retentionPolicy: RecognitionHistoryRetentionPolicy(
                maximumEntries: AppConfig.shared.recognitionHistoryMaximumEntries,
                retentionDays: AppConfig.shared.recognitionHistoryRetentionDays
            )
        )
        let accessibilityGranted = AXIsProcessTrusted()
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let permissionsComplete = accessibilityGranted && microphoneStatus == .authorized

        self.accessibilityGranted = accessibilityGranted
        self.microphoneStatus = microphoneStatus
        self.hasObservedMissingPermission = !permissionsComplete
        self.werePermissionsComplete = permissionsComplete
        refreshAudioInputDevices()
    }

    var permissionsComplete: Bool {
        accessibilityGranted && microphoneStatus == .authorized
    }

    var appVersionDisplay: String {
        Self.appVersionDisplay(infoDictionary: Bundle.main.infoDictionary)
    }

    static func appVersionDisplay(infoDictionary: [String: Any]?) -> String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = infoDictionary?["CFBundleVersion"] as? String,
              !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    var visibleSections: [HushTypeSettingsSection] {
        HushTypeSettingsSection.visibleSections(
            onboardingRequired: onboardingRequired,
            isPreview: SettingsScrollBlurConfiguration.defaultIsPreview
        )
    }

    var modelControl: HushTypeModelControl {
        switch appState {
        case .loading:
            return .none
        case let .loadingDetailed(progress):
            switch progress.phase {
            case .downloading:
                return .stopDownload
            case .checkingLocalModel, .verifying, .loadingTokenizer, .loadingAudio, .loadingText, .ready:
                return .none
            }
        case .idle:
            return .unload
        case .error:
            return loadedModelID == nil ? .load : .unload
        case .unloaded:
            return .load
        case .setupRequired, .connecting, .recording, .transcribing, .polishing:
            return .none
        }
    }

    func configure(actions: HushTypeSettingsActions) {
        self.actions = actions
        refresh()
    }

    func updateAppState(_ state: StatusBarController.State) {
        appState = state
        switch state {
        case .connecting, .recording:
            dictationTaskState = .running
        case .transcribing, .polishing:
            if dictationTaskState != .stopped { dictationTaskState = .finishing }
        case .loading, .loadingDetailed:
            dictationTaskState = isDictationPreparing ? .running : .stopped
        default:
            dictationTaskState = .stopped
        }
        loadedModelID = actions.loadedModelID()
        modelLibrary.updateEngineState(
            state,
            loadingModelID: actions.loadingModelID(),
            loadedModelID: loadedModelID
        )
    }

    /// Active dictation and captions share one loaded speech model and queue
    /// recognition work. Model loading and caption teardown remain exclusive.
    static func canStartCaptions(
        for appState: StatusBarController.State,
        isCaptionStarting: Bool = false,
        hasLoadedModel: Bool = false
    ) -> Bool {
        guard !isCaptionStarting else { return false }
        return switch appState {
        case .idle, .unloaded:
            true
        case .connecting, .recording, .transcribing, .polishing:
            hasLoadedModel
        case .setupRequired, .loading, .loadingDetailed, .error:
            false
        }
    }

    var canStartCaptions: Bool {
        !isCaptionFinishing && Self.canStartCaptions(
            for: appState, isCaptionStarting: isCaptionStarting,
            hasLoadedModel: loadedModelID != nil
        )
    }

    func startCaptionMic() {
        guard canStartCaptions else { return }
        actions.startCaptionMic()
    }

    func startCaptionSystem() {
        guard canStartCaptions else { return }
        actions.startCaptionSystem()
    }

    func stopCaptions() {
        guard isCaptionActive || isCaptionStarting else { return }
        actions.stopCaptions()
    }

    var captionTaskState: OverviewTaskState {
        if isCaptionFinishing { return .finishing }
        return isCaptionActive || isCaptionStarting ? .running : .stopped
    }

    var canToggleDictation: Bool {
        if dictationTaskState == .finishing { return false }
        if dictationTaskState == .running { return true }
        switch appState {
        case .idle, .unloaded, .error: return true
        default: return false
        }
    }

    func setDictationPreparing(_ preparing: Bool) {
        isDictationPreparing = preparing
        if preparing { dictationTaskState = .running }
        else { updateAppState(appState) }
    }

    func toggleDictation() {
        guard canToggleDictation else { return }
        actions.toggleDictation()
    }

    func toggleCaptions() {
        if captionTaskState == .running { stopCaptions() }
        else if captionTaskState == .stopped, canStartCaptions { actions.startCaptions() }
    }

    func updateCaptionState(
        mode: AppConfig.CaptionMode?,
        source: AudioSourceKind?,
        isStarting: Bool = false,
        isFinishing: Bool = false
    ) {
        captionMode = mode
        captionSource = source
        isCaptionActive = mode != nil
        isCaptionStarting = isStarting
        isCaptionFinishing = isFinishing
    }

    func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }
        refreshBluetoothPermission()
        systemAudioGranted = SystemAudioPermissionFlow.isGranted
        updatePermissionState(
            accessibilityGranted: AXIsProcessTrusted(),
            microphoneStatus: AVCaptureDevice.authorizationStatus(for: .audio)
        )
        currentDictationEngine = AppConfig.shared.dictationEngine
        loadedModelID = actions.loadedModelID()
        modelID = AppConfig.shared.modelId
        floatingOverlayEnabled = AppConfig.shared.floatingOverlayEnabled
        audioInputSelection = AppConfig.shared.audioInputSelection
        refreshAudioInputDevices()
        releaseF5WhenModelUnloaded = AppConfig.shared.releaseF5WhenModelUnloaded
        numberConversionEnabled = AppConfig.shared.numberConversionEnabled
        textPolishEnabled = AppConfig.shared.textPolishEnabled
        textTranslationEnabled = AppConfig.shared.textTranslationEnabled
        punctuationMode = AppConfig.shared.punctuationMode
        speechLanguage = AppConfig.shared.language ?? "auto"
        chineseConversionEnabled = AppConfig.shared.chineseConversionEnabled
        interfaceLanguageRaw = AppConfig.shared.interfaceLanguage.rawValue
        updateChannelRaw = AppConfig.shared.updateChannel.rawValue
        silentUpdateRelaunch = AppConfig.shared.silentUpdateRelaunch
        historyMaximumEntries = AppConfig.shared.recognitionHistoryMaximumEntries
        historyRetentionDays = AppConfig.shared.recognitionHistoryRetentionDays ?? 0
        modelLibrary.updateEngineState(
            appState,
            loadingModelID: actions.loadingModelID(),
            loadedModelID: loadedModelID
        )
        modelLibrary.refresh()
    }

    func loadOrReloadModel() { actions.reloadModel() }
    func unloadModel() { actions.unloadModel() }
    func stopModelDownload() { actions.stopModelDownload() }

    static func canCancelRecording(for appState: StatusBarController.State) -> Bool {
        if case .recording = appState { return true }
        return false
    }

    static func forwardRecordingCancellation(
        for appState: StatusBarController.State,
        action: () -> Void
    ) {
        guard canCancelRecording(for: appState) else { return }
        action()
    }

    var canCancelRecording: Bool {
        Self.canCancelRecording(for: appState)
    }

    /// The overview control is only an escape hatch for an active recording;
    /// finishing or cancelling any other workflow stays outside this UI.
    func cancelRecording() {
        Self.forwardRecordingCancellation(for: appState, action: actions.cancelRecording)
    }

    func refreshOverviewResources() {
        let currentModelID = actions.loadedModelID()
        if loadedModelID != currentModelID { loadedModelID = currentModelID }
        refreshAudioInputDevices()
    }

    func refreshAudioInputDevices() {
        guard !isAudioDeviceRefreshInFlight else { return }
        isAudioDeviceRefreshInFlight = true
        let requestedSelection = audioInputSelection
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                let devices = AudioInputDeviceManager.availableDevices()
                let effectiveName = AudioInputDeviceManager.currentDeviceName(
                    rawValue: requestedSelection,
                    devices: devices
                )
                return (devices, effectiveName)
            }.value
            guard let self else { return }
            self.audioInputDevices = snapshot.0
            if self.audioInputSelection == requestedSelection {
                self.currentAudioInputDeviceName = snapshot.1
            }
            self.isAudioDeviceRefreshInFlight = false
            if self.audioInputSelection != requestedSelection {
                self.refreshAudioInputDevices()
            }
        }
    }

    func appendRecognitionHistory(_ text: String) throws {
        do {
            try recognitionHistory.append(text)
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
            throw error
        }
    }

    func appendCaptionHistory(
        _ text: String,
        startedAt: Date,
        endedAt: Date,
        sourceLabel: String?
    ) throws {
        do {
            try recognitionHistory.appendCaption(
                text,
                startedAt: startedAt,
                endedAt: endedAt,
                sourceLabel: sourceLabel
            )
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
            throw error
        }
    }

    private func applyHistoryRetentionPolicy(maximumEntries: Int, retentionDays: Int) {
        do {
            try recognitionHistory.updateRetentionPolicy(
                RecognitionHistoryRetentionPolicy(
                    maximumEntries: maximumEntries,
                    retentionDays: retentionDays == 0 ? nil : retentionDays
                )
            )
            AppConfig.shared.recognitionHistoryMaximumEntries = maximumEntries
            AppConfig.shared.recognitionHistoryRetentionDays = retentionDays == 0 ? nil : retentionDays
            historyErrorMessage = nil
        } catch {
            isRefreshing = true
            historyMaximumEntries = AppConfig.shared.recognitionHistoryMaximumEntries
            historyRetentionDays = AppConfig.shared.recognitionHistoryRetentionDays ?? 0
            isRefreshing = false
            historyErrorMessage = error.localizedDescription
            print("[HushType] Failed to apply recognition history retention: \(error.localizedDescription)")
        }
    }

    func removeRecognitionHistory(id: UUID) {
        do {
            try recognitionHistory.remove(id: id)
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func clearRecognitionHistory() {
        do {
            try recognitionHistory.removeAll()
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func applyRecognitionHistoryCleanup() {
        do {
            try recognitionHistory.applyCurrentRetentionPolicy()
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func dismissRecognitionHistoryError() {
        historyErrorMessage = nil
    }

    func switchDictationEngine(to engine: AppConfig.DictationEngine) {
        actions.switchDictationEngine(engine)
        currentDictationEngine = AppConfig.shared.dictationEngine
    }

    func openAccessibilitySettings() {
        accessibilitySettingsOpened = true
        actions.openAccessibilitySettings()
    }

    func resetOldAccessibilityEntry() {
        guard actions.resetOldAccessibilityEntry() else { return }
        didResetAccessibility = true
        accessibilitySettingsOpened = true
        updatePermissionState(accessibilityGranted: false, microphoneStatus: microphoneStatus)
    }

    func requestMicrophone() {
        guard !isRequestingMicrophone else { return }
        isRequestingMicrophone = true
        actions.requestMicrophone { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.isRequestingMicrophone = false
                self.updatePermissionState(
                    accessibilityGranted: AXIsProcessTrusted(),
                    microphoneStatus: granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .audio)
                )
            }
        }
    }

    func openMicrophoneSettings() {
        actions.openMicrophoneSettings()
    }

    func requestSystemAudio() {
        didRequestSystemAudio = true
        _ = SystemAudioPermissionFlow.requestAccess()
        systemAudioGranted = SystemAudioPermissionFlow.isGranted
    }

    func openSystemAudioSettings() {
        systemAudioSettingsOpened = true
        SystemAudioPermissionFlow.openScreenCaptureSettings()
    }

    func resetOldSystemAudioEntry() {
        guard SystemAudioPermissionFlow.resetStaleScreenCaptureEntries() else { return }
        didResetSystemAudio = true
        systemAudioGranted = false
        openSystemAudioSettings()
    }

    func requestBluetooth() {
        refreshBluetoothPermission()
        guard bluetoothStatus == .notDetermined, !isRequestingBluetooth else { return }
        isRequestingBluetooth = true
        bluetoothPermissionRequest.onAuthorizationChanged = { [weak self] in
            self?.refreshBluetoothPermission()
        }
        bluetoothPermissionRequest.request()
    }

    private func refreshBluetoothPermission() {
        bluetoothStatus = CBManager.authorization
        if bluetoothStatus != .notDetermined { isRequestingBluetooth = false }
    }

    func openBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") else { return }
        NSWorkspace.shared.open(url)
    }

    func checkForUpdates() { actions.checkForUpdates() }
    func restart() { actions.restart() }
    func quit() { actions.quit() }

    private func updatePermissionState(
        accessibilityGranted: Bool,
        microphoneStatus: AVAuthorizationStatus
    ) {
        let permissionsComplete = accessibilityGranted && microphoneStatus == .authorized
        if !permissionsComplete {
            hasObservedMissingPermission = true
            needsPermissionRestart = false
        } else if hasObservedMissingPermission && !werePermissionsComplete {
            needsPermissionRestart = true
        }

        self.accessibilityGranted = accessibilityGranted
        self.microphoneStatus = microphoneStatus
        werePermissionsComplete = permissionsComplete
    }
}
