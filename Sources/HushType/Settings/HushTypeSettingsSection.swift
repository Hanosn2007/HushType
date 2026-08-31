import AppKit
import AVFoundation
import ApplicationServices
import Combine

enum HushTypeSettingsSection: String, CaseIterable, Identifiable {
    case overview
    case dictation
    case model
    case dictionary
    case permissions
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: L10n.string("settings.sidebar.overview", fallback: "Overview")
        case .dictation: L10n.string("settings.sidebar.dictation", fallback: "Dictation")
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
        case .model: "cpu"
        case .dictionary: "text.book.closed"
        case .permissions: "checklist"
        case .general: "gearshape"
        }
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
    var switchDictationEngine: (AppConfig.DictationEngine) -> Void = { _ in }
    var openDictionary: () -> Void = {}
    var openAccessibilitySettings: () -> Void = {}
    var resetOldAccessibilityEntry: () -> Bool = { false }
    var requestMicrophone: (@escaping (Bool) -> Void) -> Void = { completion in completion(false) }
    var openMicrophoneSettings: () -> Void = {}
    var restart: () -> Void = {}
    var quit: () -> Void = {}

    init(
        loadedModelID: @escaping () -> String? = { nil },
        loadingModelID: @escaping () -> String? = { nil },
        reloadModel: @escaping () -> Void = {},
        unloadModel: @escaping () -> Void = {},
        stopModelDownload: @escaping () -> Void = {},
        switchDictationEngine: @escaping (AppConfig.DictationEngine) -> Void = { _ in },
        openDictionary: @escaping () -> Void = {},
        openAccessibilitySettings: @escaping () -> Void = {},
        resetOldAccessibilityEntry: @escaping () -> Bool = { false },
        requestMicrophone: @escaping (@escaping (Bool) -> Void) -> Void = { completion in completion(false) },
        openMicrophoneSettings: @escaping () -> Void = {},
        restart: @escaping () -> Void = {},
        quit: @escaping () -> Void = {}
    ) {
        self.loadedModelID = loadedModelID
        self.loadingModelID = loadingModelID
        self.reloadModel = reloadModel
        self.unloadModel = unloadModel
        self.stopModelDownload = stopModelDownload
        self.switchDictationEngine = switchDictationEngine
        self.openDictionary = openDictionary
        self.openAccessibilitySettings = openAccessibilitySettings
        self.resetOldAccessibilityEntry = resetOldAccessibilityEntry
        self.requestMicrophone = requestMicrophone
        self.openMicrophoneSettings = openMicrophoneSettings
        self.restart = restart
        self.quit = quit
    }
}

@MainActor
final class HushTypeSettingsModel: ObservableObject {
    let modelLibrary = LocalModelLibrary()
    @Published var selection: HushTypeSettingsSection = .overview
    @Published private(set) var appState: StatusBarController.State = .setupRequired
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var isRequestingMicrophone = false
    @Published private(set) var accessibilitySettingsOpened = false
    @Published private(set) var didResetAccessibility = false
    /// Becomes true only after this process has observed permissions recover
    /// from an incomplete state. Accessibility grants need a fresh process for
    /// the event tap to see them reliably, including after a rebuilt app is
    /// granted again.
    @Published private(set) var needsPermissionRestart = false
    @Published var onboardingRequired = false
    @Published private(set) var currentDictationEngine = AppConfig.shared.dictationEngine
    @Published private(set) var loadedModelID: String?
    @Published var modelID = AppConfig.shared.modelId {
        didSet { AppConfig.shared.modelId = modelID }
    }
    @Published var floatingOverlayEnabled = AppConfig.shared.floatingOverlayEnabled {
        didSet { AppConfig.shared.floatingOverlayEnabled = floatingOverlayEnabled }
    }
    @Published var releaseF5WhenModelUnloaded = AppConfig.shared.releaseF5WhenModelUnloaded {
        didSet { AppConfig.shared.releaseF5WhenModelUnloaded = releaseF5WhenModelUnloaded }
    }
    @Published var numberConversionEnabled = AppConfig.shared.numberConversionEnabled {
        didSet { AppConfig.shared.numberConversionEnabled = numberConversionEnabled }
    }
    @Published var textPolishEnabled = AppConfig.shared.textPolishEnabled {
        didSet { AppConfig.shared.textPolishEnabled = textPolishEnabled }
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

    private var actions = HushTypeSettingsActions()
    private var isRefreshing = false
    private var hasObservedMissingPermission: Bool
    private var werePermissionsComplete: Bool

    init() {
        let accessibilityGranted = AXIsProcessTrusted()
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let permissionsComplete = accessibilityGranted && microphoneStatus == .authorized

        self.accessibilityGranted = accessibilityGranted
        self.microphoneStatus = microphoneStatus
        self.hasObservedMissingPermission = !permissionsComplete
        self.werePermissionsComplete = permissionsComplete
    }

    var permissionsComplete: Bool {
        accessibilityGranted && microphoneStatus == .authorized
    }

    var visibleSections: [HushTypeSettingsSection] {
        onboardingRequired ? [.permissions] : HushTypeSettingsSection.allCases
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
        case .setupRequired, .recording, .transcribing, .polishing:
            return .none
        }
    }

    func configure(actions: HushTypeSettingsActions) {
        self.actions = actions
        refresh()
    }

    func updateAppState(_ state: StatusBarController.State) {
        appState = state
        loadedModelID = actions.loadedModelID()
        modelLibrary.updateEngineState(
            state,
            loadingModelID: actions.loadingModelID(),
            loadedModelID: loadedModelID
        )
    }

    func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }
        updatePermissionState(
            accessibilityGranted: AXIsProcessTrusted(),
            microphoneStatus: AVCaptureDevice.authorizationStatus(for: .audio)
        )
        currentDictationEngine = AppConfig.shared.dictationEngine
        loadedModelID = actions.loadedModelID()
        modelID = AppConfig.shared.modelId
        floatingOverlayEnabled = AppConfig.shared.floatingOverlayEnabled
        releaseF5WhenModelUnloaded = AppConfig.shared.releaseF5WhenModelUnloaded
        numberConversionEnabled = AppConfig.shared.numberConversionEnabled
        textPolishEnabled = AppConfig.shared.textPolishEnabled
        punctuationMode = AppConfig.shared.punctuationMode
        speechLanguage = AppConfig.shared.language ?? "auto"
        chineseConversionEnabled = AppConfig.shared.chineseConversionEnabled
        interfaceLanguageRaw = AppConfig.shared.interfaceLanguage.rawValue
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
    func openDictionary() { actions.openDictionary() }
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
