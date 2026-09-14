import AppKit
import ApplicationServices
import MLX
import os
import Sparkle
import UserNotifications

private let log = Logger(subsystem: "com.felix.hushtype", category: "app")

/// T2 bridge only. T3 replaces these placeholders with the real provider
/// engines; reporting `isLoaded == true` keeps cloud hotkey presses on the
/// throwing error path instead of silently treating them as an unloaded model.
private final class CloudDictationPlaceholderEngine: TranscriptionEngine {
    let isLoaded = true

    func load(progressHandler: ((Double, String) -> Void)?) async throws {}

    func transcribe(audio: [Float], language: String?) async throws -> String {
        throw TranscriptionError.noKey
    }
}

private final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    private var pendingRelaunchBuild: String?

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        AppConfig.shared.updateChannel.allowedSparkleChannels
    }

    /// Sparkle documents this item as the update immediately about to install.
    /// Hold its build only until the subsequent pre-relaunch callback so a
    /// cancelled or non-relaunching install cannot alter a future launch.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        pendingRelaunchBuild = item.versionString
    }

    /// Public Sparkle API: called immediately before the application is
    /// relaunched. Store a build-bound, one-shot marker before this process is
    /// terminated; the replacement process validates and consumes it.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        guard let pendingRelaunchBuild else { return }
        UpdateRelaunchIntent.markForRelaunch(targetBuild: pendingRelaunchBuild)
        self.pendingRelaunchBuild = nil
    }
}

@MainActor
private final class TapArbiter {
    static let doubleTapWindow: TimeInterval = 0.35

    private final class PendingTap {
        var fired = false
        var workItem: DispatchWorkItem!
    }

    private var pendingTap: PendingTap?
    private(set) var secondTapCandidate = false

    func deferSingleTap(_ action: @escaping @MainActor () -> Void) {
        reset()

        let pending = PendingTap()
        pending.workItem = DispatchWorkItem { [weak self, weak pending] in
            pending?.fired = true
            guard let self, let pending, !pending.workItem.isCancelled else { return }
            guard self.pendingTap === pending else { return }
            self.pendingTap = nil
            action()
        }
        pendingTap = pending
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.doubleTapWindow,
            execute: pending.workItem
        )
    }

    /// Called at the start of every Right ⌥ press. Main-queue serialization
    /// makes `fired` the boundary interlock: either the deferred action began,
    /// or this press cancels it and owns the intent as tap #2—never both.
    @discardableResult
    func cancelPendingForSecondPress() -> Bool {
        guard let pendingTap, !pendingTap.fired else { return false }
        pendingTap.workItem.cancel()
        self.pendingTap = nil
        secondTapCandidate = true
        return true
    }

    func consumeSecondTapCandidate() -> Bool {
        guard secondTapCandidate else { return false }
        secondTapCandidate = false
        return true
    }

    func reset() {
        pendingTap?.workItem.cancel()
        pendingTap = nil
        secondTapCandidate = false
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated override init() {
        super.init()
    }

    enum AppState {
        case loading
        case idle
        case connecting
        case recording
        case transcribing
        case inserting
        case translating
        case polishing
        case unloaded
    }

    private var state: AppState = .loading {
        didSet {
            log.info("State: \(String(describing: self.state))")
        }
    }

    private var updaterController: SPUStandardUpdaterController!
    private let updateChannelDelegate = UpdateChannelDelegate()
    private var statusBar: StatusBarController!
    private var hotkeyManager: HotkeyManager!
    private var audioCapture: AudioCaptureService!
    private var localEngine: Qwen3TranscriptionEngine!
    private var activeEngine: (any TranscriptionEngine)!
    private var translationManager: TranslationManager!
    private var liveCaptionManager: LiveCaptionManager?
    private var captionStartTask: Task<Void, Never>?
    private var captionStartGeneration: UInt64 = 0
    private var captionSourcePickerPending = false
    private var captionSourceRequestGeneration: UInt64 = 0
    private let tapArbiter = TapArbiter()
    private var hotkeyResumeWorkItem: DispatchWorkItem?
    private var hotkeyLifecycleGeneration: UInt = 0
    private var inputSessionIsActive = true
    private var displayIsAwake = true
    private var consecutiveCloudNetworkFailures = 0
    /// Rejects progress callbacks that were already queued when a download
    /// was stopped and then started again.
    private var modelLoadAttemptID = UUID()
    private var historyCleanupTimer: Timer?
    private var lastExternalApplication: NSRunningApplication?
    private var overviewDictationLoadPending = false
    private var profilePreparationTask: Task<Void, Never>?
    private var runningDictationSnapshot: ProcessingProfileSnapshot?

    private enum RecordingTrigger {
        case rightOption
        case f5
    }
    /// Keeps one hotkey's release from stopping a recording started by the
    /// other hotkey when F5 and Right Option overlap.
    private var recordingTrigger: RecordingTrigger?
    /// Rejects first-buffer/failure callbacks from a capture attempt that the
    /// user already stopped or replaced.
    private var recordingAttemptID = UUID()

    private enum SelectionSource {
        case copySelection
        case provided(String)
    }

    // Floating overlay (created lazily on first use)
    private let overlayState = OverlayStateModel()
    private lazy var overlayWindow = FloatingOverlayWindow(stateModel: overlayState)
    private let modelNoticeState = OverlayStateModel()
    private lazy var modelNoticeWindow = FloatingOverlayWindow(stateModel: modelNoticeState)

    // Translation card (created lazily on first use)
    private lazy var translationCardWindow = TranslationCardWindow()
    private lazy var polishCardWindow = PolishCardWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[HushType] Starting...")
        lastExternalApplication = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(trackExternalApplication(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        // macOS exposes Login Item launch intent as a parameter on its
        // initial open-application AppleEvent. Read it without replacing
        // AppKit's own handler, then consume the update marker exactly once.
        let launchWasAsLoginItem = AppLaunchReason.isLoginItemLaunch(
            NSAppleEventManager.shared().currentAppleEvent
        )
        let shouldOpenSettingsAfterUpdate = UpdateRelaunchIntent.consumeIfMatching(
            currentBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            isLoginItemLaunch: launchWasAsLoginItem,
            silentRelaunch: AppConfig.shared.silentUpdateRelaunch
        )

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updateChannelDelegate,
            userDriverDelegate: nil
        )

        // Resolve app-owned model storage before Qwen or the model library
        // asks the dependency downloader for a cache directory.
        AppStoragePaths.prepareModelStorage()

        // Cap MLX's GPU buffer recycle pool process-wide. The dictation path
        // never bounds this pool (clearCache() runs only on manual Unload and
        // LiveCaption stop), and LiveCaptionManager.start() was the only place
        // that set cacheLimit — so a dictation-only session ran on MLX's
        // unbounded default and phys_footprint climbed to 5+ GB over a session.
        // Setting it here at launch bounds the pool for every path. Value
        // mirrors LiveCaptionTuning.mlxCacheLimitMB (1024). This caps only the
        // *idle* reuse pool, never live inference memory, so it can never
        // truncate or fail a transcription — at worst a heavy request does a
        // little more OS alloc/free churn.
        MLX.Memory.cacheLimit = 1024 * 1024 * 1024  // 1 GB

        // Local-only MVP: a previous cloud selection must never decide the
        // startup path. Normalize the persisted preference before creating
        // the status menu or active engine; the cloud engine code remains in
        // place for a later product mode.
        if AppConfig.shared.dictationEngine != .local {
            log.info("Ignoring persisted cloud dictation engine in local-only MVP")
            AppConfig.shared.dictationEngine = .local
        }

        localEngine = Qwen3TranscriptionEngine()
        statusBar = StatusBarController(localEngine: localEngine)
        hotkeyManager = HotkeyManager()
        audioCapture = AudioCaptureService()
        activeEngine = makeDictationEngine(for: .local)
        translationManager = TranslationManager()
        let manager = LiveCaptionManager(
            localEngine: localEngine,
            captureService: audioCapture
        )
        manager.onStateChanged = { [weak self] mode, source in
            let manager = self?.liveCaptionManager
            HushTypeSettingsWindowController.shared.updateProfileUsage(
                mode != nil || manager?.isFinishing == true ? manager?.activeProfile : nil, captions: true
            )
            self?.statusBar.setLiveCaptionState(mode: mode, source: source)
            let isStarting = self?.liveCaptionManager.map { $0.isStarting && !$0.isActive } ?? false
            HushTypeSettingsWindowController.shared.updateCaptionState(
                mode: mode, source: source, isStarting: isStarting,
                isFinishing: self?.liveCaptionManager?.isFinishing ?? false
            )
        }
        manager.onSessionFinished = { summary in
            do {
                try HushTypeSettingsWindowController.shared.appendCaptionHistory(summary)
            } catch {
                log.error("Caption history could not be saved: \(error.localizedDescription, privacy: .public)")
            }
        }
        liveCaptionManager = manager

        TextPolisher.refreshAvailabilityCache()
        statusBar.setTextPolishAvailability(TextPolisher.isAvailableCached)
        NSApp.servicesProvider = self

        // Short F5 remains dictation; a held F5 toggles local captions only.
        // Inherited Right Option / Right Command shortcuts remain unwired.
        hotkeyManager.onDictationToggle = { [weak self] in
            self?.handleF5Toggle()
        }
        hotkeyManager.onCaptionToggle = { [weak self] in
            self?.handleF5LongPress()
        }
        hotkeyManager.onTranslateSelection = { [weak self] in
            self?.handleTranslation(source: .copySelection)
        }
        hotkeyManager.onPolishSelection = { [weak self] in
            self?.handlePolish(source: .copySelection)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(localTextPreferencesChanged),
            name: LocalTextPreferences.didChange, object: nil
        )
        hotkeyManager.shouldPassThroughDictationShortcut = { [weak self] in
            guard let self else { return true }
            return AppConfig.shared.releaseF5WhenModelUnloaded
                && self.liveCaptionManager?.isBusy != true
                && AppConfig.shared.dictationEngine == .local
                && self.state == .unloaded
        }
        hotkeyManager.onTapDisabled = { [weak self] reason in
            self?.rebuildHotkeyAfterSystemDisable(reason: reason)
        }

        // RMS callback fires on the CoreAudio IO thread — must hop to main
        // before touching @Published state on the overlay model.
        audioCapture.onRMSLevel = { [weak self] level in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .recording(_, let provider) = self.overlayState.state {
                    self.overlayState.state = .recording(level: level, provider: provider)
                }
            }
        }

        // Wire quit
        statusBar.onQuit = { [weak self] in
            self?.hotkeyManager.stop()
            self?.hideOverlay()
        }
        statusBar.onCheckForUpdates = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }

        // Wire unload/reload
        statusBar.onUnloadModel = { [weak self] in
            Task { @MainActor in
                await self?.unloadModel()
            }
        }
        statusBar.onReloadModel = { [weak self] in
            self?.reloadModel(showCompletionNotice: true)
        }
        statusBar.onStopModelDownload = { [weak self] in
            self?.stopModelDownload()
        }
        statusBar.onCancelRecording = { [weak self] in
            self?.cancelActiveRecording(reason: "status menu")
        }
        statusBar.onDictationEngineChanged = { [weak self] engine in
            self?.switchDictationEngine(to: engine)
        }

        let settingsWindow = HushTypeSettingsWindowController.shared
        settingsWindow.configure(actions: HushTypeSettingsActions(
            loadedModelID: { [weak self] in
                self?.localEngine.loadedModelID
            },
            loadingModelID: { [weak self] in
                self?.localEngine.loadingModelID
            },
            reloadModel: { [weak self] in
                self?.reloadModel(showCompletionNotice: true)
            },
            unloadModel: { [weak self] in
                Task { @MainActor in
                    await self?.unloadModel()
                }
            },
            stopModelDownload: { [weak self] in
                self?.stopModelDownload()
            },
            cancelRecording: { [weak self] in
                self?.cancelActiveRecording(reason: "settings overview")
            },
            toggleDictation: { [weak self] in
                self?.handleOverviewDictation()
            },
            startCaptions: { [weak self] in
                self?.toggleProductWithLastSource(.local)
            },
            switchDictationEngine: { [weak self] engine in
                self?.switchDictationEngine(to: engine)
            },
            startCaptionMic: { [weak self] in
                self?.startCaptionMode(.local, source: .mic)
            },
            startCaptionSystem: { [weak self] in
                self?.startCaptionModeOnSystemAudio(.local, forcePicker: true)
            },
            stopCaptions: { [weak self] in
                self?.stopLiveCaptions()
            },
            openAccessibilitySettings: {
                OnboardingManager.openAccessibilitySettings()
            },
            resetOldAccessibilityEntry: {
                OnboardingManager.resetOldAccessibilityEntry()
            },
            requestMicrophone: { completion in
                OnboardingManager.requestMicrophoneAccess(completion: completion)
            },
            openMicrophoneSettings: {
                OnboardingManager.openMicrophoneSettings()
            },
            checkForUpdates: { [weak self] in
                self?.updaterController.checkForUpdates(nil)
            },
            updateChannelChanged: { [weak self] in
                self?.updaterController.updater.resetUpdateCycle()
            },
            restart: {
                OnboardingManager.relaunchAndQuit(reopenPermissions: true)
            },
            quit: { [weak self] in
                self?.hotkeyManager.stop()
                self?.hideOverlay()
                NSApp.terminate(nil)
            }
        ))
        settingsWindow.applyRecognitionHistoryCleanup()
        historyCleanupTimer = Timer.scheduledTimer(
            timeInterval: 3_600,
            target: self,
            selector: #selector(cleanupRecognitionHistory),
            userInfo: nil,
            repeats: true
        )
        statusBar.onOpenSettings = { section in
            settingsWindow.present(section: section)
        }
        if #unavailable(macOS 26.0) {
            HushTypeMainMenuController.shared.install {
                settingsWindow.present(section: .overview)
            }
        }
        statusBar.onStateChanged = { [weak self] state in
            switch state {
            case .unloaded, .error, .setupRequired:
                self?.overviewDictationLoadPending = false
                settingsWindow.setDictationPreparing(false)
            default: break
            }
            settingsWindow.updateAppState(state)
        }

        // Wire Live Caption (local) submenu. The manager exists from launch;
        // if Qwen is absent, its local path loads the shared engine lazily.
        statusBar.onLiveCaptionStartMic = { [weak self] in
            self?.startCaptionMode(.local, source: .mic)
        }
        statusBar.onLiveCaptionStartSystem = { [weak self] in
            self?.startCaptionModeOnSystemAudio(.local, forcePicker: false)
        }
        statusBar.onLiveCaptionChangeSystemSource = { [weak self] in
            self?.startCaptionModeOnSystemAudio(.local, forcePicker: true)
        }
        statusBar.onLiveCaptionStop = { [weak self] in
            self?.stopLiveCaptions()
        }

        // Wire Live Translated Caption (cloud) submenu.
        statusBar.onLiveTranslatedStartMic = { [weak self] in
            self?.startCaptionMode(.translated, source: .mic)
        }
        statusBar.onLiveTranslatedStartSystem = { [weak self] in
            self?.startCaptionModeOnSystemAudio(.translated, forcePicker: false)
        }
        statusBar.onLiveTranslatedChangeSystemSource = { [weak self] in
            self?.startCaptionModeOnSystemAudio(.translated, forcePicker: true)
        }
        statusBar.onLiveTranslatedStop = { [weak self] in
            self?.liveCaptionManager?.stop()
        }
        statusBar.onLiveCaptionHeaderClicked = { [weak self] in
            self?.toggleProductWithLastSource(.local)
        }
        statusBar.onLiveTranslatedHeaderClicked = { [weak self] in
            self?.toggleProductWithLastSource(.translated)
        }

        #if DEBUG
        _ = FillerFilter.runSelfTests()
        #endif

        // Onboarding: if accessibility permission is missing, show our friendly
        // flow BEFORE we ever call CGEvent.tapCreate. If onboarding is needed,
        // it blocks via NSAlert and either quits or relaunches the app — in
        // either case the rest of startup never runs.
        if !AXIsProcessTrusted() {
            // The setup flow intentionally stops startup before the global
            // event tap and model loader are created. Make that pause explicit
            // instead of leaving the menu's initial state at a misleading 0%.
            statusBar.setState(.setupRequired)
        }
        if OnboardingManager.runIfNeeded() {
            return
        }

        if shouldOpenSettingsAfterUpdate {
            settingsWindow.present(section: .overview)
        }

        // A session event tap must not survive across lock-screen secure input
        // or display/system sleep. Rebuild it only after the active session has
        // settled again.
        observeInputSessionLifecycle()

        // Start hotkey listener
        hotkeyManager.start()

        // Keep the cloud branch for the future cloud-enabled product mode.
        // The local-only startup normalization above makes this branch
        // unreachable in the current MVP.
        guard AppConfig.shared.dictationEngine == .local else {
            state = .idle
            statusBar.setState(.idle)
            log.info("HushType ready with cloud dictation; local model not loaded")
            return
        }

        // Load local model async.
        let loadAttemptID = UUID()
        modelLoadAttemptID = loadAttemptID
        statusBar.setState(.loadingDetailed(ModelLoadProgress(
            phase: .checkingLocalModel,
            fraction: 0,
            totalBytes: QwenModelDownloadSizing.weightBytes(for: AppConfig.shared.modelId)
        )))
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.localEngine.load(detailProgressHandler: { progress in
                    DispatchQueue.main.async {
                        guard self.modelLoadAttemptID == loadAttemptID,
                              self.state == .loading else { return }
                        self.statusBar.setState(.loadingDetailed(progress))
                    }
                })
                await MainActor.run {
                    guard self.modelLoadAttemptID == loadAttemptID else { return }
                    self.state = .idle
                    self.statusBar.setState(.idle)
                    log.info("HushType ready")
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.modelLoadAttemptID == loadAttemptID,
                          self.state == .loading else { return }
                    self.state = .unloaded
                    self.statusBar.setState(.unloaded)
                    self.statusBar.setModelDownloadStopped()
                }
            } catch {
                log.error("Failed to load model: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    guard self.modelLoadAttemptID == loadAttemptID else { return }
                    self.state = .idle
                    self.statusBar.setState(.error(L10n.string(
                        "status.model_load_failed",
                        fallback: "Model load failed"
                    )))
                    self.statusBar.setModelUnloaded()
                }
            }
        }

        // FoundationModels prewarm is deferred until after Qwen3-ASR finishes
        // loading and the app reaches `.idle`. This keeps the sensitive
        // post-onboarding launch path predictable while still letting users
        // benefit from `prewarm()` on relaunch when Text Polish is already on.
    }

    // Closing settings must leave the menu-bar app and global hotkey running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        captionStartTask?.cancel()
        liveCaptionManager?.stop()
        historyCleanupTimer?.invalidate()
        hotkeyResumeWorkItem?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        tapArbiter.reset()
        hotkeyManager.stop()
        hideOverlay()
        modelNoticeWindow.hideImmediately()
        log.info("HushType terminated")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        TextPolisher.refreshAvailabilityCache()
        statusBar?.setTextPolishAvailability(TextPolisher.isAvailableCached)
    }

    private func observeInputSessionLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(inputSessionDidResignActive(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(inputSessionDidBecomeActive(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(displayWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(displayDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(displayWillSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(displayDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    @objc private func inputSessionDidResignActive(_ notification: Notification) {
        inputSessionIsActive = false
        suspendHotkey(reason: "session resigned active")
    }

    @objc private func inputSessionDidBecomeActive(_ notification: Notification) {
        inputSessionIsActive = true
        scheduleHotkeyResume(reason: "session became active")
    }

    @objc private func displayWillSleep(_ notification: Notification) {
        displayIsAwake = false
        suspendHotkey(reason: "display or system will sleep")
    }

    @objc private func displayDidWake(_ notification: Notification) {
        displayIsAwake = true
        scheduleHotkeyResume(reason: "display or system woke")
    }

    private func rebuildHotkeyAfterSystemDisable(reason: HotkeyManager.DisableReason) {
        suspendHotkey(reason: "tap disabled by \(reason.rawValue)")
        scheduleHotkeyResume(reason: "tap disabled by \(reason.rawValue)")
    }

    private func suspendHotkey(reason: String) {
        hotkeyLifecycleGeneration &+= 1
        hotkeyResumeWorkItem?.cancel()
        hotkeyResumeWorkItem = nil
        tapArbiter.reset()
        hotkeyManager.stop()
        log.info("Hotkey suspended: \(reason, privacy: .public)")
    }

    private func scheduleHotkeyResume(reason: String) {
        guard inputSessionIsActive, displayIsAwake else {
            log.info("Hotkey resume deferred while session/display is inactive: \(reason, privacy: .public)")
            return
        }

        hotkeyLifecycleGeneration &+= 1
        let generation = hotkeyLifecycleGeneration
        hotkeyResumeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.hotkeyLifecycleGeneration == generation,
                  self.inputSessionIsActive,
                  self.displayIsAwake,
                  AXIsProcessTrusted() else { return }
            self.hotkeyManager.stop()
            self.hotkeyManager.start()
            self.hotkeyResumeWorkItem = nil
            log.info("Hotkey rebuilt after session transition (generation \(generation))")
        }
        hotkeyResumeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
        log.info("Hotkey rebuild scheduled: \(reason, privacy: .public)")
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            HushTypeSettingsWindowController.shared.reopen()
        }
        return true
    }

    // MARK: - Overlay helpers

    private func showOverlayConnecting() {
        modelNoticeWindow.hideImmediately()
        guard AppConfig.shared.floatingOverlayEnabled else { return }
        overlayState.state = .connecting
        overlayWindow.show()
    }

    private func switchOverlayToRecording() {
        guard AppConfig.shared.floatingOverlayEnabled else { return }
        let provider: String?
        switch AppConfig.shared.dictationEngine {
        case .local: provider = nil
        case .openai: provider = "OpenAI"
        case .gemini: provider = "Gemini"
        }
        overlayState.state = .recording(level: 0, provider: provider)
    }

    private func showOverlayConnectionFailed() {
        guard AppConfig.shared.floatingOverlayEnabled else { return }
        overlayState.state = .connectionFailed
        overlayWindow.showConnectionFailure {
            HushTypeSettingsWindowController.shared.present(section: .general)
        }
    }

    private func showOverlayConnectionDisconnected() {
        guard AppConfig.shared.floatingOverlayEnabled else { return }
        overlayState.state = .connectionDisconnected
        overlayWindow.showConnectionFailure {
            HushTypeSettingsWindowController.shared.present(section: .general)
        }
    }

    private func switchOverlayToTranscribing() {
        guard AppConfig.shared.floatingOverlayEnabled else { return }
        // Window stays visible; only the inner state changes.
        let provider: String?
        switch AppConfig.shared.dictationEngine {
        case .local: provider = nil
        case .openai: provider = "OpenAI"
        case .gemini: provider = "Gemini"
        }
        overlayState.state = .transcribing(provider: provider)
    }

    private func showOverlayPolishing() {
        modelNoticeWindow.hideImmediately()
        guard AppConfig.shared.floatingOverlayEnabled else { return }
        overlayState.state = .polishing
        overlayWindow.show()
    }

    private func hideOverlay() {
        overlayWindow.hide()
        overlayState.state = .hidden
    }

    private func showModelNotice(_ kind: ModelNoticeKind) {
        // Recording/polishing owns the pill position while active. Model
        // notices use a separate ordinary-level window and never steal focus.
        guard overlayState.state == .hidden else { return }
        modelNoticeWindow.showModelNotice(kind) {
            HushTypeSettingsWindowController.shared.present(section: .model)
        }
    }

    // MARK: - Hotkey Handlers

    /// F5 is a discrete toggle, unlike Right Option's press-and-hold flow.
    /// It deliberately bypasses tap translation/polish so the second press
    /// always owns the recording stop and transcription path.
    private func handleOverviewDictation() {
        handleF5Toggle(preferPreviousApplication: true)
    }

    private func handleF5Toggle(preferPreviousApplication: Bool = false) {
        // App-modal alerts must exclusively own input while they are visible.
        guard NSApp.modalWindow == nil else { return }

        if overviewDictationLoadPending { cancelProfilePreparation(); return }

        tapArbiter.reset()

        if state == .connecting {
            cancelPendingRecordingStart(reason: "F5")
            return
        }

        if state == .recording {
            finishRecording(allowTapAction: false, preferPreviousApplication: preferPreviousApplication)
            return
        }

        // Keep the existing unloaded-model behavior used by Right Option.
        if state == .unloaded {
            if AppConfig.shared.dictationEngine == .local {
                print("[HushType] Model unloaded — auto-reloading...")
                startRecording(trigger: .f5)
                return
            }
            state = .idle
            statusBar.setState(.idle)
        }

        guard state == .idle else {
            log.info("Ignoring F5 press — state is \(String(describing: self.state), privacy: .public)")
            return
        }

        startRecording(trigger: .f5)
    }

    private func handleF5LongPress() {
        guard NSApp.modalWindow == nil else { return }
        toggleLiveCaptionViaHotkey()
    }

    private func handleHotkeyPress() {
        // App-modal alerts must exclusively own input while they are visible.
        guard NSApp.modalWindow == nil else { return }

        let claimedSecondTap = tapArbiter.cancelPendingForSecondPress()

        // If model is unloaded and user holds Right ⌥, auto-reload
        if state == .unloaded {
            if claimedSecondTap { tapArbiter.reset() }
            if AppConfig.shared.dictationEngine == .local {
                print("[HushType] Model unloaded — auto-reloading...")
                reloadModel()
                return
            }
            // A cloud engine is ready without Qwen. This state can occur when
            // the user unloads locally, then switches to cloud before T4's
            // menu/status treatment lands.
            state = .idle
            statusBar.setState(.idle)
        }

        guard state == .idle else {
            if claimedSecondTap { tapArbiter.reset() }
            print("[HushType] Ignoring press — state is \(state)")
            return
        }

        guard activeEngine.isLoaded else {
            if claimedSecondTap { tapArbiter.reset() }
            print("[HushType] Model not loaded yet")
            return
        }

        startRecording(trigger: .rightOption)
    }

    private func startRecording(trigger: RecordingTrigger) {
        let snapshot: ProcessingProfileSnapshot
        do {
            guard let profile = ProcessingProfileStore.shared.selected(.dictation) else { throw ProfileError.invalid }
            let validated = try profile.validated()
            // An application-audio configuration with no selected app is a
            // valid resting state. Starting it is intentionally a no-op: do
            // not load a model, create ScreenCaptureKit input, or ask for its
            // permission until an application has been selected.
            guard validated.input.hasCaptureSource else { return }
            try validated.requireAvailableModels(loadedSpeechModelID: localEngine.loadedModelID)
            snapshot = ProcessingProfileSnapshot(profile: validated)
            if localEngine.loadedModelID != snapshot.profile.modelID, liveCaptionManager?.isBusy == true {
                throw ProfileError.modelBusy
            }
        } catch { showProfileError(error); return }

        let attemptID = UUID()
        recordingAttemptID = attemptID
        recordingTrigger = trigger
        runningDictationSnapshot = snapshot
        HushTypeSettingsWindowController.shared.updateProfileUsage(snapshot.profile, captions: false)
        if localEngine.loadedModelID != snapshot.profile.modelID {
            overviewDictationLoadPending = true
            HushTypeSettingsWindowController.shared.setDictationPreparing(true)
            state = .loading
            statusBar.setState(.loading(0))
            profilePreparationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.localEngine.unloadAndWait()
                guard self.recordingAttemptID == attemptID, !Task.isCancelled else { return }
                AppConfig.shared.modelId = snapshot.profile.modelID
                self.reloadModel { [weak self] success in
                    guard let self, self.recordingAttemptID == attemptID else { return }
                    self.overviewDictationLoadPending = false
                    HushTypeSettingsWindowController.shared.setDictationPreparing(false)
                    if success { self.beginProfileRecording(snapshot, attemptID: attemptID) }
                }
            }
        } else {
            beginProfileRecording(snapshot, attemptID: attemptID)
        }
    }

    private func beginProfileRecording(_ snapshot: ProcessingProfileSnapshot, attemptID: UUID) {
        guard recordingAttemptID == attemptID else { return }
        runningDictationSnapshot = snapshot
        HushTypeSettingsWindowController.shared.updateProfileUsage(snapshot.profile, captions: false)
        audioCapture = AudioCaptureService.shared(for: snapshot.profile.input)
        audioCapture.onRMSLevel = { [weak self] level in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .recording(_, let provider) = self.overlayState.state {
                    self.overlayState.state = .recording(level: level, provider: provider)
                }
            }
        }
        state = .connecting
        statusBar.setState(.connecting)
        showOverlayConnecting()
        let begin = { [weak self] in
            guard let self, self.recordingAttemptID == attemptID, self.state == .connecting else { return }
            self.audioCapture.startRecording(onUnexpectedStop: { [weak self] error in
                DispatchQueue.main.async { self?.handleRecordingInputDisconnected(error, attemptID: attemptID) }
            }) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.recordingAttemptID == attemptID, self.state == .connecting else { return }
                    switch result {
                    case .success:
                        self.state = .recording
                        self.statusBar.setState(.recording)
                        self.switchOverlayToRecording()
                    case .failure(let error):
                        self.recordingTrigger = nil
                        self.state = .idle
                        self.statusBar.setState(.error(error.localizedDescription))
                        self.showOverlayConnectionFailed()
                    }
                }
            }
        }
        if snapshot.profile.input.kind == .application {
            // Permission setup requires a restart and never calls onReady later.
            var started = false
            SystemAudioPermissionFlow.ensurePermission { started = true; begin() }
            if !started { cancelPendingRecordingStart(reason: "application audio permission setup") }
        } else { begin() }
    }

    private func showProfileError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.string("profiles.cannot_start", fallback: "Cannot start this configuration")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func cancelProfilePreparation() {
        recordingAttemptID = UUID()
        recordingTrigger = nil
        overviewDictationLoadPending = false
        profilePreparationTask?.cancel()
        HushTypeSettingsWindowController.shared.setDictationPreparing(false)
        stopModelDownload()
    }

    private func handleRecordingInputDisconnected(_ error: Error, attemptID: UUID) {
        guard recordingAttemptID == attemptID, state == .recording else {
            log.info("Ignoring capture interruption outside active recording")
            return
        }
        recordingAttemptID = UUID()
        recordingTrigger = nil
        tapArbiter.reset()
        state = .idle
        statusBar.setState(.error(error.localizedDescription))
        audioCapture.stopRecording { _ in }
        showOverlayConnectionDisconnected()
        log.error("Recording input disconnected: \(error.localizedDescription, privacy: .public)")
    }

    private func handleHotkeyRelease() {
        if overviewDictationLoadPending, recordingTrigger == .rightOption {
            cancelProfilePreparation()
            return
        }
        guard recordingTrigger == .rightOption else {
            log.info("Ignoring Right Option release during F5-owned recording")
            return
        }
        finishRecording(allowTapAction: true)
    }

    private func finishRecording(allowTapAction: Bool, preferPreviousApplication: Bool = false) {
        guard state == .recording || state == .connecting else {
            print("[HushType] Ignoring recording stop — state is \(state)")
            return
        }

        recordingAttemptID = UUID()
        recordingTrigger = nil
        tapArbiter.reset()
        state = .transcribing
        statusBar.setState(.transcribing)
        switchOverlayToTranscribing()

        audioCapture.stopRecording { [weak self] samples in
            DispatchQueue.main.async {
                self?.continueFinishedRecording(samples: samples, allowTapAction: allowTapAction,
                                               preferPreviousApplication: preferPreviousApplication)
            }
        }
    }

    private func continueFinishedRecording(samples: [Float], allowTapAction: Bool,
                                          preferPreviousApplication: Bool = false) {
        guard state == .transcribing else { return }
        print("[HushType] Recording stopped: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000.0))s)")

        // Right Option's short hold remains a TAP for translation. F5 is a
        // strict start/stop toggle, so even a short non-empty clip transcribes.
        if allowTapAction && samples.count <= 4800 {
            hideOverlay()
            state = .idle
            statusBar.setState(.idle)
            handleTapDetected()
            return
        }

        // Avoid sending an empty F5 clip to an engine that expects audio.
        guard !samples.isEmpty else {
            hideOverlay()
            state = .idle
            statusBar.setState(.idle)
            print("[HushType] Empty recording, skipping transcription")
            return
        }

        print("[HushType] Transcribing...")

        let snapshot = runningDictationSnapshot
        let language = snapshot.map { $0.profile.language == "auto" ? nil : $0.profile.language } ?? AppConfig.shared.language
        let selection = AppConfig.shared.dictationEngine
        let engine = activeEngine!
        let insertionFocus = captureInsertionFocus(preferPreviousApplication: preferPreviousApplication)

        if selection == .local {
            launchTranscription(
                samples: samples,
                language: language,
                selection: selection,
                engine: engine,
                insertionFocus: insertionFocus,
                profileSnapshot: snapshot
            )
        } else {
            // The hotkey callbacks originate inside CGEventTap. Queue consent
            // for the next main-loop turn so NSAlert never blocks that tap.
            Task { @MainActor [weak self] in
                await self?.continueCloudTranscriptionAfterConsent(
                    samples: samples,
                    language: language,
                    selection: selection,
                    engine: engine,
                    insertionFocus: insertionFocus
                )
            }
        }
    }

    private func continueCloudTranscriptionAfterConsent(
        samples: [Float],
        language: String?,
        selection: AppConfig.DictationEngine,
        engine: any TranscriptionEngine,
        insertionFocus: NSRunningApplication?
    ) async {
        guard state == .transcribing else { return }
        let provider = consentProvider(for: selection)
        guard let provider else { return }

        let keyIsEmpty: Bool
        switch selection {
        case .openai:
            if case .empty = OpenAIKeyStore.load() {
                keyIsEmpty = true
            } else {
                keyIsEmpty = false
            }
        case .gemini:
            if case .empty = GeminiKeyStore.load() {
                keyIsEmpty = true
            } else {
                keyIsEmpty = false
            }
        case .local:
            keyIsEmpty = false
        }
        if keyIsEmpty {
            await handleCloudFailure(
                .noKey,
                samples: samples,
                language: language,
                selection: selection,
                engine: engine,
                insertionFocus: insertionFocus
            )
            return
        }

        // Guard before consent, WAV encoding, or request construction. The
        // cloud engine repeats the payload guard as defense in depth.
        if let maxSampleCount = engine.maxSampleCount,
           samples.count > maxSampleCount {
            await handleCloudFailure(
                .payloadTooLarge,
                samples: samples,
                language: language,
                selection: selection,
                engine: engine,
                insertionFocus: insertionFocus
            )
            return
        }

        let metering = cloudDictationMetering(for: selection)
        if let metering {
            let projection = await CloudUsageTracker.shared.evaluateDictationUpload(
                seconds: Double(samples.count) / 16_000.0,
                dollarsPerMinute: metering.rate,
                warningThreshold: AppConfig.shared.cloudDailyCapDollars
            )
            // The actor hop gives menu/settings actions a chance to change app
            // state. Never upload a retained buffer after the request was
            // cancelled or another flow took ownership.
            guard state == .transcribing else { return }
            if projection.shouldBlock {
                await handleDailySpendWarning(
                    projection,
                    samples: samples,
                    language: language,
                    insertionFocus: insertionFocus
                )
                return
            }
        }

        if !CloudDictationOnboardingAlert.shared.hasConsent(for: provider),
           CloudDictationOnboardingAlert.shared.requestConsent(for: provider) == .revertToLocal {
            switchDictationEngine(to: .local)
            hideOverlay()
            if localEngine.isLoaded {
                state = .idle
                statusBar.setState(.idle)
            }
            Task { @MainActor [weak self] in
                _ = await self?.restoreInsertionFocus(insertionFocus)
            }
            return
        }

        launchTranscription(
            samples: samples,
            language: language,
            selection: selection,
            engine: engine,
            metering: metering,
            insertionFocus: insertionFocus
        )
    }

    private func launchTranscription(
        samples: [Float],
        language: String?,
        selection: AppConfig.DictationEngine,
        engine: any TranscriptionEngine,
        metering: CloudDictationMetering? = nil,
        insertionFocus: NSRunningApplication?,
        profileSnapshot: ProcessingProfileSnapshot? = nil
    ) {
        let metering = metering ?? cloudDictationMetering(for: selection)
        Task.detached { [weak self, engine] in
            do {
                let text: String
                if let profileSnapshot, let local = engine as? Qwen3TranscriptionEngine {
                    let raw = try await local.transcribeRaw(audio: samples, language: language, client: .dictation)
                    if profileSnapshot.profile.llm.polish || profileSnapshot.profile.llm.translate {
                        await MainActor.run { self?.statusBar.setState(.polishing) }
                    }
                    text = try await profileSnapshot.process(raw)
                } else {
                    text = try await engine.transcribe(audio: samples, language: language)
                }
                if let metering {
                    let snapshot = await CloudUsageTracker.shared.recordDictation(
                        seconds: Double(samples.count) / 16_000.0,
                        provider: metering.provider,
                        dollarsPerMinute: metering.rate
                    )
                    let cap = AppConfig.shared.cloudDailyCapDollars
                    if await CloudUsageTracker.shared.shouldFireDailyCapWarning(cap: cap) {
                        await CloudUsageTracker.shared.markDailyCapWarned()
                        await self?.postDailySpendWarningNotification(snapshot: snapshot, threshold: cap)
                    }
                }
                await self?.finishSuccessfulTranscription(
                    text,
                    insertionFocus: insertionFocus,
                    resetNetworkFailures: selection != .local
                )
            } catch {
                log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                guard selection != .local else {
                    await self?.finishWithoutInsertion(restoreFocus: insertionFocus)
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = L10n.string("overview.dictation_failed", fallback: "Dictation failed")
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                    return
                }
                let mapped = error as? TranscriptionError ?? .network
                switch mapped {
                case .malformedResponse, .safetyBlocked, .timeout:
                    if let metering {
                        let snapshot = await CloudUsageTracker.shared.recordDictation(
                            seconds: Double(samples.count) / 16_000.0,
                            provider: metering.provider,
                            dollarsPerMinute: metering.rate
                        )
                        let cap = AppConfig.shared.cloudDailyCapDollars
                        if await CloudUsageTracker.shared.shouldFireDailyCapWarning(cap: cap) {
                            await CloudUsageTracker.shared.markDailyCapWarned()
                            await self?.postDailySpendWarningNotification(snapshot: snapshot, threshold: cap)
                        }
                    }
                default:
                    break
                }
                await self?.handleCloudFailure(
                    mapped,
                    samples: samples,
                    language: language,
                    selection: selection,
                    engine: engine,
                    insertionFocus: insertionFocus
                )
            }
        }
    }

    private func finishSuccessfulTranscription(
        _ text: String,
        insertionFocus: NSRunningApplication?,
        resetNetworkFailures: Bool
    ) async {
        if resetNetworkFailures { consecutiveCloudNetworkFailures = 0 }
        guard !text.isEmpty else {
            _ = await restoreInsertionFocus(insertionFocus)
            print("[HushType] Empty transcription, skipping insert")
            state = .idle
            statusBar.setState(.idle)
            hideOverlay()
            return
        }

        print("[HushType] Transcription result: '\(text)'")
        do {
            // Persist the final, post-processed text before insertion so a
            // blocked or unsupported target app cannot make it unrecoverable.
            try HushTypeSettingsWindowController.shared.appendRecognitionHistory(text)
        } catch {
            log.error("Failed to save recognition history: \(error.localizedDescription, privacy: .public)")
        }
        _ = await restoreInsertionFocus(insertionFocus)
        print("[HushType] Inserting text...")
        state = .inserting
        let insertionFailure = await TextInserter.insert(text)
        state = .idle
        if let insertionFailure {
            statusBar.setState(.error(insertionFailure.message))
            NSSound.beep()
        } else {
            statusBar.setState(.idle)
        }
        hideOverlay()
        print(insertionFailure == nil ? "[HushType] Input dispatched" : "[HushType] Automatic input failed; check recognition history")
    }

    @objc private func cleanupRecognitionHistory() {
        HushTypeSettingsWindowController.shared.applyRecognitionHistoryCleanup()
    }

    private func finishWithoutInsertion(restoreFocus application: NSRunningApplication?) async {
        _ = await restoreInsertionFocus(application)
        state = .idle
        statusBar.setState(.idle)
        hideOverlay()
    }

    private func handleTapDetected() {
        guard state == .idle else {
            tapArbiter.reset()
            log.info("Ignoring tap — state is \(String(describing: self.state), privacy: .public)")
            return
        }

        if tapArbiter.consumeSecondTapCandidate() {
            print("[HushType] Double tap detected — triggering Text Polish")
            handlePolish(source: .copySelection)
            return
        }

        if AppConfig.shared.textPolishEnabled && TextPolisher.isAvailableCached {
            tapArbiter.deferSingleTap { [weak self] in
                guard let self, self.state == .idle else {
                    log.info("Deferred translation dropped — app is no longer idle")
                    return
                }
                guard AppConfig.shared.textTranslationEnabled else { return }
                self.handleTranslation(source: .copySelection)
            }
            return
        }

        guard AppConfig.shared.textTranslationEnabled else {
            print("[HushType] Too short, skipping (translation not enabled)")
            return
        }
        print("[HushType] Short tap detected — triggering translation")
        handleTranslation(source: .copySelection)
    }

    private func handleCancelledHotkeyRelease() {
        cancelActiveRecording(reason: "option-character chord")
    }

    /// Stops and discards the current capture without entering the normal
    /// stop-and-transcribe path. The state guard takes ownership before the
    /// capture service is stopped, so a delayed hotkey release or a second
    /// menu click cannot stop the same recording twice.
    private func cancelActiveRecording(reason: String) {
        if state == .connecting {
            cancelPendingRecordingStart(reason: reason)
            return
        }
        guard state == .recording else {
            log.info("Ignoring recording cancellation from \(reason, privacy: .public) — no active recording")
            return
        }

        recordingAttemptID = UUID()
        state = .idle
        recordingTrigger = nil
        tapArbiter.reset()
        audioCapture.stopRecording { _ in }
        hideOverlay()

        if AXIsProcessTrusted() {
            statusBar.setState(.idle)
        } else {
            // The tray action does not rely on the event tap, so it still
            // works after Accessibility permission disappears. Stop any stale
            // tap and expose the existing permission-recovery entry.
            suspendHotkey(reason: "Accessibility permission missing after recording cancellation")
            statusBar.setState(.setupRequired)
            HushTypeSettingsWindowController.shared.setOnboardingRequired(true)
        }
        log.info("Cancelled and discarded recording from \(reason, privacy: .public)")
    }

    private func cancelPendingRecordingStart(reason: String) {
        guard state == .connecting else { return }
        recordingAttemptID = UUID()
        state = .idle
        recordingTrigger = nil
        tapArbiter.reset()
        hideOverlay()
        statusBar.setState(.idle)
        audioCapture.stopRecording { _ in }
        log.info("Cancelled microphone connection from \(reason, privacy: .public)")
    }

    // MARK: - Translation

    private struct ResolvedSelection {
        let text: String
        let priorPasteboardItems: [NSPasteboardItem]?
    }

    private func handleTranslation(source: SelectionSource) {
        guard state == .idle else {
            log.info("Ignoring translation — state is \(String(describing: self.state), privacy: .public)")
            return
        }

        // The tap sites check the toggle before calling in, but the Services
        // entry ("Translate with HushType") dispatches here directly — enforce
        // the menu toggle for that path too.
        if !AppConfig.shared.textTranslationEnabled {
            showTranslationError(TranslationError.translationFailed(
                L10n.string(
                    "error.translation.disabled",
                    fallback: "Text Translation is turned off in the HushType menu."
                )))
            return
        }

        state = .translating
        Task { @MainActor [weak self] in
            guard let self else { return }
            let selection = await self.resolveSelection(source, preservingPasteboard: true)
            self.restorePasteboardIfNeeded(selection.priorPasteboardItems)
            let text = selection.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.state = .idle
                self.statusBar.setState(.idle)
                switch source {
                case .copySelection:
                    // A bare Right ⌥ tap with nothing selected is a common
                    // accident — stay silent like pre-0.6 releases. Only the
                    // explicit Services path earns an alert.
                    print("[HushType] No text on clipboard for translation")
                case .provided:
                    self.showTranslationError(TranslationError.translationFailed(
                        L10n.string(
                            "error.selection.none",
                            fallback: "No text was selected."
                        )
                    ))
                }
                return
            }

            do {
                let target = LocalTextPreferences.selectionTarget(for: text)
                let translated = try await LocalTextResources.transform(.translate(text, target: target))
                self.translationCardWindow.show(
                    sourceLanguage: target.title,
                    sourceText: text,
                    translatedText: translated
                )
            } catch is CancellationError {
                // The text-model controls can cancel an active request.
            } catch {
                self.showTranslationError(error)
            }
            self.state = .idle
            self.statusBar.setState(.idle)
        }
    }

    // MARK: - Text Polish

    private func handlePolish(source: SelectionSource) {
        guard state == .idle else {
            log.info("Ignoring polish — state is \(String(describing: self.state), privacy: .public)")
            return
        }

        state = .polishing
        statusBar.setState(.polishing)
        showOverlayPolishing()

        Task { @MainActor [weak self] in
            guard let self else { return }
            let selection = await self.resolveSelection(source, preservingPasteboard: true)
            self.restorePasteboardIfNeeded(selection.priorPasteboardItems)
            let result = await TextPolisher.polish(selection.text)

            switch result {
            case .success(let polished, let changed):
                self.finishPolishing()
                self.polishCardWindow.show(
                    originalText: selection.text,
                    polishedText: polished,
                    changed: changed
                )

            case .failure(let error):
                self.finishPolishing()
                if case .cancelled = error { return }
                self.showPolishError(error)
            }
        }
    }

    private func finishPolishing() {
        state = .idle
        statusBar.setState(.idle)
        hideOverlay()
    }

    private func showPolishError(_ error: PolishError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        alert.messageText = L10n.string(
            "alert.polish_failed.title",
            fallback: "Text Polish Failed"
        )
        alert.informativeText = L10n.format(
            "alert.polish_failed.message",
            "Unable to polish the selected text.\n\n%1$@",
            arguments: [error.localizedDescription]
        )
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }

    private func resolveSelection(
        _ source: SelectionSource,
        preservingPasteboard: Bool = false
    ) async -> ResolvedSelection {
        switch source {
        case .provided(let text):
            return ResolvedSelection(text: text, priorPasteboardItems: nil)

        case .copySelection:
            let pasteboard = NSPasteboard.general
            let priorItems = preservingPasteboard
                ? copyPasteboardItems(pasteboard.pasteboardItems ?? [])
                : nil
            let previousChangeCount = pasteboard.changeCount
            simulateCmdC()
            try? await Task.sleep(nanoseconds: 150_000_000)
            if pasteboard.changeCount == previousChangeCount {
                // Slow apps (Chrome/Electron) can take >150 ms to service ⌘C —
                // give one extra beat before declaring the selection empty.
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard pasteboard.changeCount != previousChangeCount else {
                return ResolvedSelection(text: "", priorPasteboardItems: priorItems)
            }
            return ResolvedSelection(
                text: pasteboard.string(forType: .string) ?? "",
                priorPasteboardItems: priorItems
            )
        }
    }

    private func copyPasteboardItems(_ items: [NSPasteboardItem]) -> [NSPasteboardItem] {
        items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restorePasteboardIfNeeded(_ items: [NSPasteboardItem]?) {
        guard let items else { return }
        NSPasteboard.general.clearContents()
        if !items.isEmpty {
            NSPasteboard.general.writeObjects(items)
        }
    }

    // MARK: - Services

    @objc func polishSelection(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        error.pointee = nil
        let text = pboard.string(forType: .string) ?? ""
        Task { @MainActor [weak self] in
            self?.handlePolish(source: .provided(text))
        }
    }

    @objc func translateSelection(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        error.pointee = nil
        let text = pboard.string(forType: .string) ?? ""
        Task { @MainActor [weak self] in
            self?.handleTranslation(source: .provided(text))
        }
    }

    private func simulateCmdC() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: C (keycode 0x08) with Cmd
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    private func showTranslationError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)

        if let translationError = error as? TranslationError {
            switch translationError {
            case .unsupportedLanguage(let lang):
                alert.messageText = L10n.string(
                    "alert.translation.unsupported.title",
                    fallback: "Language Not Supported"
                )
                alert.informativeText = L10n.format(
                    "alert.translation.unsupported.message",
                    "The detected language (%1$@) is not supported by Apple Translation Framework.\n\nSupported languages include English, Chinese, Japanese, Korean, French, German, Spanish, and others.",
                    arguments: [lang]
                )
                alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
                alert.runModal()

            case .languagePackMissing(let source, let target):
                alert.messageText = L10n.string(
                    "alert.translation.pack_missing.title",
                    fallback: "Language Pack Not Installed"
                )
                alert.informativeText = L10n.format(
                    "alert.translation.pack_missing.message",
                    "Translation from %1$@ to %2$@ requires downloading the language pack.\n\nSystem Settings → General → Language & Region → Translation Languages → Download",
                    arguments: [source, target]
                )
                alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
                alert.addButton(withTitle: L10n.string(
                    "common.button.open_translation_settings",
                    fallback: "Open Settings"
                ))
                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Localization") {
                        NSWorkspace.shared.open(url)
                    }
                }

            case .translationFailed(let detail):
                alert.messageText = L10n.string(
                    "alert.translation.failed.title",
                    fallback: "Translation Failed"
                )
                alert.informativeText = L10n.format(
                    "alert.translation.failed.message",
                    "Unable to translate the selected text.\n\n%1$@",
                    arguments: [detail]
                )
                alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
                alert.runModal()
            }
        } else {
            alert.messageText = L10n.string(
                "alert.translation.failed.title",
                fallback: "Translation Failed"
            )
            alert.informativeText = L10n.format(
                "alert.translation.failed.message",
                "Unable to translate the selected text.\n\n%1$@",
                arguments: [error.localizedDescription]
            )
            alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
            alert.runModal()
        }
    }

    // MARK: - Live Caption helpers

    private var canStartCaptionInCurrentState: Bool {
        switch state {
        case .idle, .unloaded:
            return true
        case .connecting, .recording, .transcribing, .inserting, .translating, .polishing:
            return localEngine.isLoaded
        case .loading:
            return false
        }
    }

    /// Start (or auto-switch to) the requested caption product on the given
    /// audio source. The engine setting flips to match the mode before the
    /// manager start fires. If a session of the OTHER product is running,
    /// it's torn down first (auto-stop-then-start) so we never have two
    /// products contending for the same panel. If the SAME product is
    /// running on a different source, we use switchSource for fast handoff.
    /// For .translated mode we gate on the cloud-disclosure modal first.
    @MainActor
    private func startCaptionMode(_ mode: AppConfig.CaptionMode, source: AudioSourceKind,
                                  profileOverride: ProcessingProfile? = nil) {
        guard let manager = self.liveCaptionManager else {
            NSSound.beep()
            return
        }
        if captionSourcePickerPending {
            captionSourceRequestGeneration &+= 1
            captionSourcePickerPending = false
            SystemAudioPicker.cancel()
        }
        guard canStartCaptionInCurrentState else {
            NSSound.beep()
            return
        }
        guard !manager.isStarting else { return }
        guard captionStartTask == nil else { return }
        // Cloud-first-time disclosure. The cloudOnboardingShown flag is
        // persisted, so this only fires once per macOS user account.
        if mode == .translated && !AppConfig.shared.cloudOnboardingShown {
            let accepted = CloudOnboardingAlert.presentIfNeeded()
            if !accepted { return }
        }

        let targetEngine: AppConfig.LiveCaptionEngine = (mode == .translated) ? .cloudTranslate : .local
        let snapshot: ProcessingProfileSnapshot?
        do {
            if mode == .local {
                guard var profile = profileOverride ?? ProcessingProfileStore.shared.selected(.captions) else { throw ProfileError.invalid }
                try profile.requireAvailableModels(loadedSpeechModelID: localEngine.loadedModelID)
                switch source {
                case .mic: profile.input.kind = .microphone
                case .system(let id): profile.input.kind = .application; profile.input.bundleID = id
                }
                snapshot = ProcessingProfileSnapshot(profile: try profile.validated())
            } else { snapshot = nil }
        } catch { showProfileError(error); return }

        captionStartGeneration &+= 1
        let generation = captionStartGeneration
        captionStartTask = Task { @MainActor in
            defer {
                if self.captionStartGeneration == generation {
                    self.captionStartTask = nil
                    if !manager.isActive && !manager.isStarting && !manager.isFinishing {
                        HushTypeSettingsWindowController.shared.updateCaptionState(mode: nil, source: nil)
                        HushTypeSettingsWindowController.shared.updateProfileUsage(nil, captions: true)
                    }
                }
            }
            do {
                try Task.checkCancellation()
                let currentMode: AppConfig.CaptionMode? = manager.isActive
                    ? (AppConfig.shared.liveCaptionEngine == .cloudTranslate ? .translated : .local)
                    : nil
                if manager.isActive && currentMode == mode {
                    // Same product, possibly different source → fast in-place switch.
                    try await manager.switchSource(to: source, profile: snapshot)
                    return
                }
                if manager.isBusy {
                    // Different product → tear down fully, then start fresh.
                    manager.stop()
                    await manager.waitUntilStopped()
                }
                try Task.checkCancellation()
                guard self.canStartCaptionInCurrentState else { return }
                if let snapshot, self.localEngine.loadedModelID != snapshot.profile.modelID {
                    guard self.state == .idle || self.state == .unloaded else { throw ProfileError.modelBusy }
                    HushTypeSettingsWindowController.shared.updateProfileUsage(snapshot.profile, captions: true)
                    HushTypeSettingsWindowController.shared.updateCaptionState(mode: mode, source: source, isStarting: true)
                    self.state = .loading
                    self.statusBar.setState(.loading(0))
                    do {
                        await self.localEngine.unloadAndWait()
                        try Task.checkCancellation()
                        AppConfig.shared.modelId = snapshot.profile.modelID
                        try await self.localEngine.load(progressHandler: nil)
                        self.state = .idle
                        self.statusBar.setState(.idle)
                    } catch {
                        self.state = self.localEngine.isLoaded ? .idle : .unloaded
                        self.statusBar.setState(self.localEngine.isLoaded ? .idle : .unloaded)
                        throw error
                    }
                }
                try Task.checkCancellation()
                AppConfig.shared.liveCaptionEngine = targetEngine
                try await manager.start(source: source, profile: snapshot)
                if manager.isActive, self.state == .unloaded, self.localEngine.isLoaded {
                    self.state = .idle
                    self.statusBar.setState(.idle)
                    self.statusBar.setModelLoaded()
                }
            } catch is CancellationError {
                return
            } catch let error as ProfileError {
                self.showProfileError(error)
            } catch let error as LocalTextModelError {
                let alert = NSAlert()
                alert.messageText = L10n.string("error.local_text.title", fallback: "Text model unavailable")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L10n.string("common.button.open_settings", fallback: "Open Settings"))
                alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
                if alert.runModal() == .alertFirstButtonReturn {
                    HushTypeSettingsWindowController.shared.present(section: .model)
                }
            } catch {
                log.error("LiveCaption start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Long F5 always controls local captions, including their loading state.
    @MainActor
    private func toggleLiveCaptionViaHotkey() {
        guard let manager = self.liveCaptionManager else {
            NSSound.beep()
            return
        }
        if captionSourcePickerPending || manager.isActive || manager.isStarting || captionStartTask != nil {
            stopLiveCaptions()
            return
        }
        guard !manager.isBusy else { return }
        toggleProductWithLastSource(.local)
    }

    @MainActor
    private func stopLiveCaptions() {
        captionSourceRequestGeneration &+= 1
        captionSourcePickerPending = false
        SystemAudioPicker.cancel()
        captionStartGeneration &+= 1
        captionStartTask?.cancel()
        captionStartTask = nil
        liveCaptionManager?.finish()
        let finishing = liveCaptionManager?.isFinishing ?? false
        HushTypeSettingsWindowController.shared.updateCaptionState(mode: nil, source: nil, isFinishing: finishing)
        if !finishing { HushTypeSettingsWindowController.shared.updateProfileUsage(nil, captions: true) }
    }

    /// Shared entry point for "start `mode` with whatever source the user
    /// picked last." Used by the hotkey (last-used mode) and by both menu-
    /// header clicks (mode pinned per header). Reads the PERSISTED
    /// `lastStartedCaptionUsesMicSource` — not the session-only
    /// `liveCaptionUsesMicSource` which is reset to false on every stop
    /// because the dictation gate watches it.
    @MainActor
    private func toggleProductWithLastSource(_ mode: AppConfig.CaptionMode) {
        if mode == .local {
            guard let profile = ProcessingProfileStore.shared.selected(.captions) else { showProfileError(ProfileError.invalid); return }
            // Keep an unconfigured application source stopped without opening
            // the system-audio permission flow or beginning model work.
            guard profile.input.hasCaptureSource else { return }
            do { try profile.requireAvailableModels(loadedSpeechModelID: localEngine.loadedModelID) }
            catch { showProfileError(error); return }
            if profile.input.kind == .microphone {
                startCaptionMode(mode, source: .mic, profileOverride: profile)
            } else {
                SystemAudioPermissionFlow.ensurePermission { [weak self] in
                    self?.startCaptionMode(mode, source: .system(bundleID: profile.input.bundleID), profileOverride: profile)
                }
            }
            return
        }
        if AppConfig.shared.lastStartedCaptionUsesMicSource {
            startCaptionMode(mode, source: .mic)
        } else {
            startCaptionModeOnSystemAudio(mode, forcePicker: false)
        }
    }

    /// Resolve the system-audio bundle ID (from tuning file or via picker)
    /// then start the requested mode on that source. Gates on permission via
    /// `SystemAudioPermissionFlow` first.
    @MainActor
    private func startCaptionModeOnSystemAudio(_ mode: AppConfig.CaptionMode, forcePicker: Bool) {
        guard self.liveCaptionManager != nil else {
            NSSound.beep()
            return
        }
        guard canStartCaptionInCurrentState,
              !captionSourcePickerPending, captionStartTask == nil else { return }
        captionSourceRequestGeneration &+= 1
        let generation = captionSourceRequestGeneration
        SystemAudioPermissionFlow.ensurePermission { [weak self] in
            guard let self, self.captionSourceRequestGeneration == generation else { return }
            let tuning = LiveCaptionTuning.load()
            if !forcePicker && !tuning.systemAudioBundleID.isEmpty {
                self.startCaptionMode(mode, source: .system(bundleID: tuning.systemAudioBundleID))
                return
            }
            self.captionSourcePickerPending = true
            SystemAudioPicker.present { [weak self] bundleID in
                guard let self, self.captionSourceRequestGeneration == generation else { return }
                self.captionSourcePickerPending = false
                guard let bundleID else { return }
                self.startCaptionMode(mode, source: .system(bundleID: bundleID))
            }
        }
    }

    // MARK: - Model Unload / Reload

    /// Entry point for T4's engine picker. The persisted selection and the
    /// active protocol existential change together. Keeping a warm local
    /// model on Local → Cloud makes switching back instant; Cloud → Local
    /// performs the existing progress-bearing reload when needed.
    func switchDictationEngine(to engine: AppConfig.DictationEngine) {
        let previous = AppConfig.shared.dictationEngine
        guard previous != engine else { return }

        AppConfig.shared.dictationEngine = engine
        activeEngine = makeDictationEngine(for: engine)
        NotificationCenter.default.post(name: .hushTypeDictationEngineDidChange, object: nil)

        if engine == .local {
            if !localEngine.isLoaded {
                reloadModel()
            }
        } else if state == .unloaded || state == .loading {
            localEngine.unload()
            state = .idle
            statusBar.setState(.idle)
        }
    }

    private func unloadModel() async {
        guard state == .idle else {
            print("[HushType] Cannot unload — state is \(state)")
            return
        }
        modelNoticeWindow.hideImmediately()
        // Block dictation while a local-caption backend drains. The status
        // row stays unchanged until the final unloaded/idle transition.
        state = .loading

        // Snapshot the physical footprint at each step so a user reporting
        // "memory didn't release" can post the numbers and we can see exactly
        // which step held the bytes. Output appears in Console.app /
        // `log show --predicate 'subsystem == "com.felix.hushtype"'`.
        func snapshot(_ tag: String) {
            let footprint = MemoryUtils.physFootprintMB()
            let mlxActive = MLX.Memory.activeMemory / (1024 * 1024)
            let mlxCache  = MLX.Memory.cacheMemory  / (1024 * 1024)
            log.info("unload step=\(tag, privacy: .public) footprint=\(footprint, privacy: .public)MB mlxActive=\(mlxActive, privacy: .public)MB mlxCache=\(mlxCache, privacy: .public)MB")
        }
        snapshot("0_begin")

        // Release only the manager's local-model handle. A local caption
        // backend is stopped because it strongly owns Qwen; a cloud-translate
        // backend has no Qwen reference and must survive this operation.
        _ = await liveCaptionManager?.releaseLocalModel()
        snapshot("1_manager_release")

        await localEngine.unloadAndWait()
        snapshot("2_engine_unload")

        // Drop any MLX buffers retained from prior transcribes — the model
        // pointers are now gone, so cached intermediate tensors are dead
        // weight. clearCache() walks MLX's buffer pool and frees everything
        // not currently in flight. Without this, hundreds of MB can linger
        // even after the model itself releases.
        try? await LocalMLXComputeGate.shared.run { MLX.Memory.clearCache() }
        snapshot("3_clearCache")

        if AppConfig.shared.dictationEngine == .local {
            state = .unloaded
            statusBar.setState(.unloaded)
        } else {
            state = .idle
            statusBar.setState(.idle)
        }
        print("[HushType] Model unloaded — memory freed")

        // A completed background operation must not enter an app-modal loop.
        // Keep the menu usable and offer a nonactivating route to model settings.
        showModelNotice(.unloaded)
    }

    private func reloadModel(showCompletionNotice: Bool = false, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard liveCaptionManager?.isBusy != true else {
            liveCaptionManager?.flashGatedMessage()
            return
        }
        guard AXIsProcessTrusted() else {
            statusBar.setState(.setupRequired)
            let settingsWindow = HushTypeSettingsWindowController.shared
            settingsWindow.setOnboardingRequired(true)
            settingsWindow.present(section: .permissions)
            return
        }
        guard state == .unloaded || !localEngine.isLoaded else {
            print("[HushType] Model already loaded")
            return
        }

        modelNoticeWindow.hideImmediately()
        state = .loading
        let loadAttemptID = UUID()
        modelLoadAttemptID = loadAttemptID
        statusBar.setState(.loadingDetailed(ModelLoadProgress(
            phase: .checkingLocalModel,
            fraction: 0,
            totalBytes: QwenModelDownloadSizing.weightBytes(for: AppConfig.shared.modelId)
        )))

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.localEngine.load(detailProgressHandler: { progress in
                    DispatchQueue.main.async {
                        guard self.modelLoadAttemptID == loadAttemptID,
                              self.state == .loading else { return }
                        self.statusBar.setState(.loadingDetailed(progress))
                    }
                })
                await MainActor.run {
                    guard self.modelLoadAttemptID == loadAttemptID else { return }
                    self.state = .idle
                    self.statusBar.setState(.idle)
                    self.statusBar.setModelLoaded()
                    log.info("Model reloaded")
                    if showCompletionNotice {
                        self.showModelNotice(.loaded)
                    }
                    completion?(true)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.modelLoadAttemptID == loadAttemptID,
                          self.state == .loading else { return }
                    self.state = .unloaded
                    self.statusBar.setState(.unloaded)
                    self.statusBar.setModelDownloadStopped()
                    completion?(false)
                }
            } catch {
                log.error("Failed to reload model: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    guard self.modelLoadAttemptID == loadAttemptID else { return }
                    self.state = .unloaded
                    self.statusBar.setState(.error(L10n.string(
                        "status.model_reload_failed",
                        fallback: "Reload failed"
                    )))
                    self.statusBar.setModelUnloaded()
                    completion?(false)
                }
            }
        }
    }

    /// Cancels only an in-flight model load. Completed Hub cache entries are
    /// kept for the next start; the underlying public URLSession downloader
    /// does not expose its temporary file as resumable app state.
    private func stopModelDownload() {
        guard state == .loading else {
            print("[HushType] No model download to stop")
            return
        }
        modelLoadAttemptID = UUID()
        localEngine.unload()
        state = .unloaded
        statusBar.setState(.unloaded)
        statusBar.setModelDownloadStopped()
        print("[HushType] Model download stopped")
    }

    private func makeDictationEngine(
        for selection: AppConfig.DictationEngine
    ) -> any TranscriptionEngine {
        switch selection {
        case .local:
            return localEngine
        case .openai:
            return OpenAITranscribeEngine()
        case .gemini:
            return GeminiTranscribeEngine()
        }
    }

    @objc private func localTextPreferencesChanged() {
        TextPolisher.refreshAvailabilityCache()
        statusBar?.setTextPolishAvailability(TextPolisher.isAvailableCached)
        if !LocalTextPreferences.translatesCaptions {
            liveCaptionManager?.stopLocalTranslation()
        }
    }

    private enum CloudFailureChoice {
        case retryCloud
        case useLocalOnce
        case switchToLocal
        case cancel
        case openSettings
        case openKeyFile
    }

    private typealias CloudDictationMetering = (
        provider: CloudUsageTracker.Provider,
        rate: Double
    )

    private func cloudDictationMetering(
        for selection: AppConfig.DictationEngine
    ) -> CloudDictationMetering? {
        guard let provider = Self.usageProvider(for: selection) else { return nil }
        let model: String
        switch selection {
        case .openai:
            model = AppConfig.shared.cloudDictationModelOpenAI
        case .gemini:
            model = AppConfig.shared.cloudDictationModelGemini
        case .local:
            return nil
        }
        return (
            provider: provider,
            rate: CloudUsageTracker.dictationRate(provider: provider, model: model)
        )
    }

    private func handleDailySpendWarning(
        _ projection: CloudUsageTracker.DictationUploadProjection,
        samples: [Float],
        language: String?,
        insertionFocus: NSRunningApplication?
    ) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string(
            "alert.daily_spend_gate.title",
            fallback: "Daily spend warning reached"
        )
        alert.informativeText = L10n.format(
            "alert.daily_spend_gate.message",
            "This upload would bring today's estimated cloud usage to %1$@ (warning: %2$@). No audio was uploaded. Open Settings and reset today's counter to use cloud again.",
            arguments: [
                CloudUsageTracker.formatDollars(projection.projectedTotalDollars),
                CloudUsageTracker.formatDollars(projection.warningThreshold)
            ]
        )
        alert.addButton(withTitle: L10n.string("common.button.open_settings", fallback: "Open Settings"))
        alert.addButton(withTitle: L10n.string("common.button.use_local_once", fallback: "Use Local Once"))
        alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            state = .idle
            statusBar.setState(.idle)
            hideOverlay()
            HushTypeSettingsWindowController.shared.present(section: .dictation)
        case .alertSecondButtonReturn:
            await transcribeLocallyOnce(
                samples: samples,
                language: language,
                insertionFocus: insertionFocus
            )
        default:
            await finishWithoutInsertion(restoreFocus: insertionFocus)
        }
    }

    private func handleCloudFailure(
        _ error: TranscriptionError,
        samples: [Float],
        language: String?,
        selection: AppConfig.DictationEngine,
        engine: any TranscriptionEngine,
        insertionFocus: NSRunningApplication?
    ) async {
        switch error {
        case .network, .timeout:
            consecutiveCloudNetworkFailures += 1
        default:
            consecutiveCloudNetworkFailures = 0
        }

        let choice = presentCloudFailureAlert(
            error: error,
            selection: selection,
            preferSwitchToLocal: consecutiveCloudNetworkFailures >= 2
        )

        switch choice {
        case .retryCloud:
            await continueCloudTranscriptionAfterConsent(
                samples: samples,
                language: language,
                selection: selection,
                engine: engine,
                insertionFocus: insertionFocus
            )
        case .useLocalOnce:
            await transcribeLocallyOnce(
                samples: samples,
                language: language,
                insertionFocus: insertionFocus
            )
        case .switchToLocal:
            switchDictationEngine(to: .local)
            hideOverlay()
            if localEngine.isLoaded {
                state = .idle
                statusBar.setState(.idle)
            }
            _ = await restoreInsertionFocus(insertionFocus)
        case .cancel:
            await finishWithoutInsertion(restoreFocus: insertionFocus)
        case .openSettings:
            state = .idle
            statusBar.setState(.idle)
            hideOverlay()
            HushTypeSettingsWindowController.shared.present(section: .dictation)
        case .openKeyFile:
            state = .idle
            statusBar.setState(.idle)
            hideOverlay()
            switch selection {
            case .openai: OpenAIKeyStore.openInDefaultEditor()
            case .gemini: GeminiKeyStore.openInDefaultEditor()
            case .local: break
            }
        }
    }

    private func transcribeLocallyOnce(
        samples: [Float],
        language: String?,
        insertionFocus: NSRunningApplication?
    ) async {
        do {
            if !localEngine.isLoaded {
                state = .loading
                statusBar.setState(.loadingDetailed(ModelLoadProgress(
                    phase: .checkingLocalModel,
                    fraction: 0,
                    totalBytes: QwenModelDownloadSizing.weightBytes(for: AppConfig.shared.modelId)
                )))
                try await localEngine.load(detailProgressHandler: { [weak self] progress in
                    DispatchQueue.main.async {
                        self?.statusBar.setState(.loadingDetailed(progress))
                    }
                })
            }
            state = .transcribing
            statusBar.setState(.transcribing)
            if AppConfig.shared.floatingOverlayEnabled {
                overlayState.state = .transcribing(provider: nil)
            }
            let text = try await localEngine.transcribe(audio: samples, language: language)
            await finishSuccessfulTranscription(
                text,
                insertionFocus: insertionFocus,
                resetNetworkFailures: false
            )
        } catch {
            log.error("Use Local Once failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = L10n.string(
                "alert.local_transcription_failed.title",
                fallback: "Local transcription failed"
            )
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
            alert.runModal()
            await finishWithoutInsertion(restoreFocus: insertionFocus)
        }
    }

    private func presentCloudFailureAlert(
        error: TranscriptionError,
        selection: AppConfig.DictationEngine,
        preferSwitchToLocal: Bool
    ) -> CloudFailureChoice {
        let provider = providerName(for: selection)
        let alert = NSAlert()
        alert.alertStyle = .warning

        switch error {
        case .noKey:
            alert.messageText = L10n.string(
                "alert.cloud.no_key.title",
                fallback: "API key not set"
            )
            alert.informativeText = L10n.format(
                "alert.cloud.no_key.message",
                "Add your %1$@ API key in Dictation Engine Settings before using cloud dictation.",
                arguments: [provider]
            )
            alert.addButton(withTitle: L10n.string("common.button.open_settings", fallback: "Open Settings"))
            alert.addButton(withTitle: L10n.string("common.button.switch_to_local", fallback: "Switch to Local"))
            alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .openSettings
            case .alertSecondButtonReturn: return .switchToLocal
            default: return .cancel
            }

        case .auth:
            let path = selection == .gemini ? GeminiKeyStore.displayPath : OpenAIKeyStore.displayPath
            alert.messageText = L10n.format(
                "alert.cloud.auth.title",
                "%1$@ rejected the API key",
                arguments: [provider]
            )
            alert.informativeText = L10n.format(
                "alert.cloud.auth.message",
                "Check %1$@.",
                arguments: [path]
            )
            alert.addButton(withTitle: L10n.string("common.button.open_file", fallback: "Open File"))
            alert.addButton(withTitle: L10n.string("common.button.use_local_once", fallback: "Use Local Once"))
            return alert.runModal() == .alertFirstButtonReturn ? .openKeyFile : .useLocalOnce

        case .permissionDenied(let deniedProvider):
            let path = selection == .gemini ? GeminiKeyStore.displayPath : OpenAIKeyStore.displayPath
            alert.messageText = L10n.format(
                "alert.cloud.permission.title",
                "%1$@ denied this request",
                arguments: [deniedProvider]
            )
            alert.informativeText = L10n.format(
                "alert.cloud.permission.message",
                "The API key is present, but its project or model permissions may not allow this request. Check provider access and %1$@.",
                arguments: [path]
            )
            alert.addButton(withTitle: L10n.string("common.button.open_file", fallback: "Open File"))
            alert.addButton(withTitle: L10n.string("common.button.use_local_once", fallback: "Use Local Once"))
            return alert.runModal() == .alertFirstButtonReturn ? .openKeyFile : .useLocalOnce

        case .rateLimited(let limitedProvider):
            alert.messageText = L10n.format(
                "alert.cloud.rate_limit.title",
                "%1$@ quota or rate limit reached",
                arguments: [limitedProvider]
            )
            alert.informativeText = L10n.format(
                "alert.cloud.rate_limit.message",
                "This limit comes from %1$@, not HushType's Daily spend warning. Check provider usage or billing, or try again later.",
                arguments: [limitedProvider]
            )
            alert.addButton(withTitle: L10n.string("common.button.use_local_once", fallback: "Use Local Once"))
            alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
            return alert.runModal() == .alertFirstButtonReturn ? .useLocalOnce : .cancel

        case .payloadTooLarge:
            alert.messageText = L10n.string(
                "alert.cloud.payload.title",
                fallback: "Recording too long for cloud transcription"
            )
            alert.informativeText = L10n.string(
                "alert.cloud.payload.message",
                fallback: "This recording exceeds the cloud upload limit. No audio was uploaded."
            )
            alert.addButton(withTitle: L10n.string("common.button.use_local_once", fallback: "Use Local Once"))
            alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
            return alert.runModal() == .alertFirstButtonReturn ? .useLocalOnce : .cancel

        case .timeout:
            alert.messageText = L10n.string(
                "alert.cloud.timeout.title",
                fallback: "Cloud transcription timed out"
            )
            alert.informativeText = L10n.format(
                "alert.cloud.timeout.message",
                "%1$@ did not respond within 180 seconds. The recording is still available.",
                arguments: [provider]
            )
            alert.addButton(withTitle: L10n.string("common.button.retry_cloud", fallback: "Retry Cloud"))
            alert.addButton(withTitle: L10n.string("common.button.use_local_once", fallback: "Use Local Once"))
            alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .retryCloud
            case .alertSecondButtonReturn: return .useLocalOnce
            default: return .cancel
            }

        case .network:
            alert.messageText = L10n.string(
                "alert.cloud.network.title",
                fallback: "Cloud transcription unavailable"
            )
            alert.informativeText = L10n.format(
                "alert.cloud.network.message",
                "HushType could not reach %1$@. The recording is still available for local transcription.",
                arguments: [provider]
            )
            addStandardCloudFailureButtons(to: alert, preferSwitchToLocal: preferSwitchToLocal)
            return standardCloudFailureChoice(from: alert.runModal())

        case .malformedResponse:
            alert.messageText = L10n.format(
                "alert.cloud.malformed.title",
                "%1$@ returned an unreadable transcript",
                arguments: [provider]
            )
            alert.informativeText = L10n.string(
                "alert.cloud.no_insert_local_available",
                fallback: "Nothing was inserted. The recording is still available for local transcription."
            )
            addStandardCloudFailureButtons(to: alert, preferSwitchToLocal: false)
            return standardCloudFailureChoice(from: alert.runModal())

        case .safetyBlocked:
            alert.messageText = L10n.string(
                "alert.cloud.safety.title",
                fallback: "Gemini blocked this transcription"
            )
            alert.informativeText = L10n.string(
                "alert.cloud.no_insert_local_available",
                fallback: "Nothing was inserted. The recording is still available for local transcription."
            )
            addStandardCloudFailureButtons(to: alert, preferSwitchToLocal: false)
            return standardCloudFailureChoice(from: alert.runModal())
        }
    }

    private func addStandardCloudFailureButtons(
        to alert: NSAlert,
        preferSwitchToLocal: Bool
    ) {
        alert.addButton(withTitle: L10n.string("common.button.use_local_once", fallback: "Use Local Once"))
        alert.addButton(withTitle: L10n.string("common.button.switch_to_local", fallback: "Switch to Local"))
        alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        if preferSwitchToLocal {
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        }
    }

    private func standardCloudFailureChoice(from response: NSApplication.ModalResponse) -> CloudFailureChoice {
        switch response {
        case .alertFirstButtonReturn: return .useLocalOnce
        case .alertSecondButtonReturn: return .switchToLocal
        default: return .cancel
        }
    }

    private func consentProvider(
        for selection: AppConfig.DictationEngine
    ) -> CloudDictationOnboardingAlert.Provider? {
        switch selection {
        case .local: return nil
        case .openai: return .openai
        case .gemini: return .gemini
        }
    }

    nonisolated private static func usageProvider(
        for selection: AppConfig.DictationEngine
    ) -> CloudUsageTracker.Provider? {
        switch selection {
        case .local: return nil
        case .openai: return .openai
        case .gemini: return .gemini
        }
    }

    private func providerName(for selection: AppConfig.DictationEngine) -> String {
        switch selection {
        case .local: return "Local"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    private func postDailySpendWarningNotification(
        snapshot: CloudUsageTracker.Snapshot,
        threshold: Double
    ) {
        let content = UNMutableNotificationContent()
        content.title = L10n.string(
            "notification.daily_spend.title",
            fallback: "Daily spend warning reached"
        )
        content.body = L10n.format(
            "notification.daily_spend.body",
            "Today's cloud total is %1$@ (warning: %2$@).",
            arguments: [
                CloudUsageTracker.formatDollars(snapshot.dayDollars),
                CloudUsageTracker.formatDollars(threshold)
            ]
        )
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "hushtype-cloud-cap-\(snapshot.dayKey)",
                content: content,
                trigger: nil
            )
        )
    }

    /// Capture before a modal that may lead to insertion, then reactivate and
    /// wait for the original app to confirm focus before simulating paste.
    /// T4's consent/failure alerts use these helpers.
    @objc private func trackExternalApplication(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApplication = application
    }

    /// Only the overview button steals focus from an external input target.
    /// Keyboard dictation must retain the frontmost application, including HushType.
    static func insertionFocus(current: NSRunningApplication?, previous: NSRunningApplication?,
                               preferPreviousApplication: Bool,
                               ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier) -> NSRunningApplication? {
        if preferPreviousApplication,
           current?.processIdentifier == ownProcessID {
            guard let previous, !previous.isTerminated,
                  previous.processIdentifier != ownProcessID else { return nil }
            return previous
        }
        return current
    }

    private func captureInsertionFocus(preferPreviousApplication: Bool = false) -> NSRunningApplication? {
        Self.insertionFocus(current: UnicodeTextInput.focusedApplication() ?? NSWorkspace.shared.frontmostApplication,
                            previous: lastExternalApplication,
                            preferPreviousApplication: preferPreviousApplication)
    }

    static func shouldActivateInsertionTarget(targetPID: pid_t, focusedPID: pid_t?, frontmostPID: pid_t?) -> Bool {
        // AX focus takes precedence over Workspace for auxiliary input panels.
        (focusedPID ?? frontmostPID) != targetPID
    }

    @discardableResult
    private func restoreInsertionFocus(_ application: NSRunningApplication?) async -> Bool {
        guard let application else { return false }
        guard Self.shouldActivateInsertionTarget(
            targetPID: application.processIdentifier,
            focusedPID: UnicodeTextInput.focusedApplication()?.processIdentifier,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) else { return true }
        application.activate()
        for _ in 0..<20 {
            if UnicodeTextInput.focusedApplication()?.processIdentifier == application.processIdentifier
                || application.isActive { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return application.isActive
    }
}
