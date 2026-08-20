import AppKit
import MLX
import os
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

    private var statusBar: StatusBarController!
    private var hotkeyManager: HotkeyManager!
    private var audioCapture: AudioCaptureService!
    private var localEngine: Qwen3TranscriptionEngine!
    private var activeEngine: (any TranscriptionEngine)!
    private var translationManager: TranslationManager!
    private var liveCaptionManager: LiveCaptionManager?
    private let tapArbiter = TapArbiter()
    private var consecutiveCloudNetworkFailures = 0

    private enum SelectionSource {
        case copySelection
        case provided(String)
    }

    /// Wall-clock at which the user pressed Right ⌥. Set on press, read on
    /// release for tap-vs-hold disambiguation (<0.3s = tap → translate).
    /// Used only when live caption is active and we gate the dictation path.
    private var liveCaptionGatePressTimestamp: Date?

    // Floating overlay (created lazily on first use)
    private let overlayState = OverlayStateModel()
    private lazy var overlayWindow = FloatingOverlayWindow(stateModel: overlayState)

    // Translation card (created lazily on first use)
    private lazy var translationCardWindow = TranslationCardWindow()
    private lazy var polishCardWindow = PolishCardWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[HushType] Starting...")

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

        localEngine = Qwen3TranscriptionEngine()
        statusBar = StatusBarController(localEngine: localEngine)
        hotkeyManager = HotkeyManager()
        audioCapture = AudioCaptureService()
        activeEngine = makeDictationEngine(for: AppConfig.shared.dictationEngine)
        translationManager = TranslationManager()
        let manager = LiveCaptionManager(
            localEngine: localEngine,
            captureService: audioCapture
        )
        manager.onStateChanged = { [weak self] mode, source in
            self?.statusBar.setLiveCaptionState(mode: mode, source: source)
        }
        liveCaptionManager = manager

        TextPolisher.refreshAvailabilityCache()
        statusBar.setTextPolishAvailability(TextPolisher.isAvailableCached)
        NSApp.servicesProvider = self

        // Wire hotkey callbacks
        hotkeyManager.onPress = { [weak self] in
            self?.handleHotkeyPress()
        }
        hotkeyManager.onRelease = { [weak self] in
            self?.handleHotkeyRelease()
        }
        hotkeyManager.onCancelledRelease = { [weak self] in
            self?.handleCancelledHotkeyRelease()
        }
        hotkeyManager.onLiveCaptionToggle = { [weak self] in
            Task { @MainActor in self?.toggleLiveCaptionViaHotkey() }
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

        // Wire unload/reload
        statusBar.onUnloadModel = { [weak self] in
            Task { @MainActor in
                await self?.unloadModel()
            }
        }
        statusBar.onReloadModel = { [weak self] in
            self?.reloadModel()
        }
        statusBar.onDictationEngineChanged = { [weak self] engine in
            self?.switchDictationEngine(to: engine)
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
            self?.liveCaptionManager?.stop()
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
        if OnboardingManager.runIfNeeded() {
            return
        }

        // Start hotkey listener
        hotkeyManager.start()

        // A persisted cloud selection deliberately skips Qwen at launch. The
        // app must still become ready immediately rather than remaining in
        // its initial `.loading` state forever.
        guard AppConfig.shared.dictationEngine == .local else {
            state = .idle
            statusBar.setState(.idle)
            scheduleTextPolishPrewarmIfNeeded(reason: "cloud-engine launch")
            log.info("HushType ready with cloud dictation; local model not loaded")
            return
        }

        // Load local model async.
        statusBar.setState(.loading(0))
        Task.detached { [weak self] in
            do {
                try await self?.localEngine.load { progress, description in
                    DispatchQueue.main.async {
                        self?.statusBar.setState(.loading(progress))
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.state = .idle
                    self.statusBar.setState(.idle)
                    log.info("HushType ready")
                }
                await self?.scheduleTextPolishPrewarmIfNeeded(reason: "local-model launch")
            } catch {
                log.error("Failed to load model: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self?.state = .idle
                    self?.statusBar.setState(.error("Model load failed"))
                }
            }
        }

        // FoundationModels prewarm is deferred until after Qwen3-ASR finishes
        // loading and the app reaches `.idle`. This keeps the sensitive
        // post-onboarding launch path predictable while still letting users
        // benefit from `prewarm()` on relaunch when Text Polish is already on.
    }

    func applicationWillTerminate(_ notification: Notification) {
        tapArbiter.reset()
        hotkeyManager.stop()
        hideOverlay()
        log.info("HushType terminated")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        TextPolisher.refreshAvailabilityCache()
        statusBar?.setTextPolishAvailability(TextPolisher.isAvailableCached)
    }

    // MARK: - Overlay helpers

    private func showOverlayRecording() {
        guard AppConfig.shared.floatingOverlayEnabled else { return }
        let provider: String?
        switch AppConfig.shared.dictationEngine {
        case .local: provider = nil
        case .openai: provider = "OpenAI"
        case .gemini: provider = "Gemini"
        }
        overlayState.state = .recording(level: 0, provider: provider)
        overlayWindow.show()
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
        guard AppConfig.shared.floatingOverlayEnabled else { return }
        overlayState.state = .polishing
        overlayWindow.show()
    }

    private func hideOverlay() {
        overlayWindow.hide()
        overlayState.state = .hidden
    }

    // MARK: - Hotkey Handlers

    private func handleHotkeyPress() {
        // App-modal alerts must exclusively own input while they are visible.
        guard NSApp.modalWindow == nil else { return }

        let claimedSecondTap = tapArbiter.cancelPendingForSecondPress()

        // Gate dictation only when Live Caption is active on the MIC source —
        // both would compete for the mic. System-audio Live Caption uses
        // ScreenCaptureKit (different audio path) so dictation works
        // concurrently. Record press timestamp for tap/hold disambiguation
        // on release; do NOT start recording. Pill stays hidden.
        if AppConfig.shared.liveCaptionUsesMicSource {
            guard state == .idle else {
                if claimedSecondTap { tapArbiter.reset() }
                log.info("Ignoring mic-gated press — state is \(String(describing: self.state), privacy: .public)")
                return
            }
            liveCaptionGatePressTimestamp = Date()
            return
        }

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

        state = .recording
        statusBar.setState(.recording)
        showOverlayRecording()
        audioCapture.startRecording()
        print("[HushType] Recording started...")
    }

    private func handleHotkeyRelease() {
        // Live caption mic-source gate: if mic-source Live Caption is active,
        // we never went into .recording on press. Decide tap-vs-hold using the
        // press timestamp and either translate (tap + translation enabled) or
        // flash the panel header (hold). System-audio Live Caption does NOT
        // gate dictation, so it never enters this branch.
        if AppConfig.shared.liveCaptionUsesMicSource {
            guard state == .idle else {
                liveCaptionGatePressTimestamp = nil
                tapArbiter.reset()
                log.info("Ignoring mic-gated release — state is \(String(describing: self.state), privacy: .public)")
                return
            }
            let elapsed = liveCaptionGatePressTimestamp.map { Date().timeIntervalSince($0) } ?? 0
            liveCaptionGatePressTimestamp = nil
            if elapsed < 0.3 {
                handleTapDetected()
            } else {
                tapArbiter.reset()
                Task { @MainActor [weak self] in
                    self?.liveCaptionManager?.flashGatedMessage()
                }
            }
            return
        }

        guard state == .recording else {
            print("[HushType] Ignoring release — state is \(state)")
            return
        }

        let samples = audioCapture.stopRecording()
        print("[HushType] Recording stopped: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000.0))s)")

        // Skip if too short (< 0.3s) — treat as a TAP for translation
        guard samples.count > 4800 else {
            hideOverlay()
            state = .idle
            statusBar.setState(.idle)
            handleTapDetected()
            return
        }

        tapArbiter.reset()
        state = .transcribing
        statusBar.setState(.transcribing)
        switchOverlayToTranscribing()
        print("[HushType] Transcribing...")

        let language = AppConfig.shared.language
        let selection = AppConfig.shared.dictationEngine
        let insertionFocus = captureInsertionFocus()

        if selection == .local {
            launchTranscription(
                samples: samples,
                language: language,
                selection: selection,
                insertionFocus: insertionFocus
            )
        } else {
            // The hotkey callbacks originate inside CGEventTap. Queue consent
            // for the next main-loop turn so NSAlert never blocks that tap.
            DispatchQueue.main.async { [weak self] in
                self?.continueCloudTranscriptionAfterConsent(
                    samples: samples,
                    language: language,
                    selection: selection,
                    insertionFocus: insertionFocus
                )
            }
        }
    }

    private func continueCloudTranscriptionAfterConsent(
        samples: [Float],
        language: String?,
        selection: AppConfig.DictationEngine,
        insertionFocus: NSRunningApplication?
    ) {
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
            Task { @MainActor [weak self] in
                await self?.handleCloudFailure(
                    .noKey,
                    samples: samples,
                    language: language,
                    selection: selection,
                    insertionFocus: insertionFocus
                )
            }
            return
        }

        // Guard before consent, WAV encoding, or request construction. The
        // cloud engine repeats the payload guard as defense in depth.
        if let maxSampleCount = activeEngine.maxSampleCount,
           samples.count > maxSampleCount {
            Task { @MainActor [weak self] in
                await self?.handleCloudFailure(
                    .payloadTooLarge,
                    samples: samples,
                    language: language,
                    selection: selection,
                    insertionFocus: insertionFocus
                )
            }
            return
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
            insertionFocus: insertionFocus
        )
    }

    private func launchTranscription(
        samples: [Float],
        language: String?,
        selection: AppConfig.DictationEngine,
        insertionFocus: NSRunningApplication?
    ) {
        let engine = activeEngine!
        let metering: (CloudUsageTracker.Provider, Double)? = {
            guard let provider = Self.usageProvider(for: selection) else { return nil }
            let model: String
            switch selection {
            case .openai: model = AppConfig.shared.cloudDictationModelOpenAI
            case .gemini: model = AppConfig.shared.cloudDictationModelGemini
            case .local: return nil
            }
            return (
                provider,
                CloudUsageTracker.dictationRate(provider: provider, model: model)
            )
        }()
        Task.detached { [weak self, engine] in
            do {
                let text = try await engine.transcribe(audio: samples, language: language)
                if let (provider, rate) = metering {
                    let snapshot = await CloudUsageTracker.shared.recordDictation(
                        seconds: Double(samples.count) / 16_000.0,
                        provider: provider,
                        dollarsPerMinute: rate
                    )
                    let cap = AppConfig.shared.cloudDailyCapDollars
                    if await CloudUsageTracker.shared.shouldFireDailyCapWarning(cap: cap) {
                        await CloudUsageTracker.shared.markDailyCapWarned()
                        await self?.postCloudCapNotification(snapshot: snapshot, cap: cap)
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
                    return
                }
                let mapped = error as? TranscriptionError ?? .network
                switch mapped {
                case .malformedResponse, .safetyBlocked, .timeout:
                    if let (provider, rate) = metering {
                        let snapshot = await CloudUsageTracker.shared.recordDictation(
                            seconds: Double(samples.count) / 16_000.0,
                            provider: provider,
                            dollarsPerMinute: rate
                        )
                        let cap = AppConfig.shared.cloudDailyCapDollars
                        if await CloudUsageTracker.shared.shouldFireDailyCapWarning(cap: cap) {
                            await CloudUsageTracker.shared.markDailyCapWarned()
                            await self?.postCloudCapNotification(snapshot: snapshot, cap: cap)
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
        _ = await restoreInsertionFocus(insertionFocus)
        guard !text.isEmpty else {
            print("[HushType] Empty transcription, skipping insert")
            state = .idle
            statusBar.setState(.idle)
            hideOverlay()
            return
        }

        print("[HushType] Transcription result: '\(text)'")
        print("[HushType] Inserting text...")
        state = .inserting
        TextInserter.insert(text)
        state = .idle
        statusBar.setState(.idle)
        hideOverlay()
        print("[HushType] Done")
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
        tapArbiter.reset()
        liveCaptionGatePressTimestamp = nil

        guard state == .recording else {
            log.info("Suppressed Right Option release had no active recording")
            return
        }

        _ = audioCapture.stopRecording()
        state = .idle
        statusBar.setState(.idle)
        hideOverlay()
        log.info("Cancelled recording after option-character chord")
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
        if case .provided = source, !AppConfig.shared.textTranslationEnabled {
            showTranslationError(TranslationError.translationFailed(
                "Text Translation is turned off in the HushType menu."))
            return
        }

        state = .translating
        Task { @MainActor [weak self] in
            guard let self else { return }
            let selection = await self.resolveSelection(source)
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
                    self.showTranslationError(TranslationError.translationFailed("No text was selected."))
                }
                return
            }

            print("[HushType] Translating: '\(text.prefix(50))...'")
            self.translationManager.translate(text: text) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }

                    switch result {
                    case .success(let (translated, direction)):
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translated, forType: .string)
                        print("[HushType] Translation result (\(direction)): '\(translated.prefix(80))...'")
                        self.translationCardWindow.show(
                            sourceLanguage: direction,
                            sourceText: text,
                            translatedText: translated
                        )

                    case .failure(let error):
                        print("[HushType] Translation error: \(error)")
                        self.showTranslationError(error)
                    }

                    self.state = .idle
                    self.statusBar.setState(.idle)
                }
            }
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
                if changed {
                    // The source application must retain focus through the
                    // complete simulated paste before any result window appears.
                    TextInserter.insert(polished)
                }

                self.finishPolishing()
                self.polishCardWindow.show(
                    originalText: selection.text,
                    polishedText: polished,
                    changed: changed
                )

            case .failure(let error):
                self.finishPolishing()
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
        alert.messageText = "Text Polish Failed"
        alert.informativeText = "Unable to polish the selected text.\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
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
                alert.messageText = "Language Not Supported"
                alert.informativeText = "The detected language (\(lang)) is not supported by Apple Translation Framework.\n\nSupported languages include English, Chinese, Japanese, Korean, French, German, Spanish, and others."
                alert.addButton(withTitle: "OK")
                alert.runModal()

            case .languagePackMissing(let source, let target):
                alert.messageText = "Language Pack Not Installed"
                alert.informativeText = "Translation from \(source) to \(target) requires downloading the language pack.\n\nSystem Settings → General → Language & Region → Translation Languages → Download"
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open Settings")
                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Localization") {
                        NSWorkspace.shared.open(url)
                    }
                }

            case .translationFailed(let detail):
                alert.messageText = "Translation Failed"
                alert.informativeText = "Unable to translate the selected text.\n\n\(detail)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        } else {
            alert.messageText = "Translation Failed"
            alert.informativeText = "Unable to translate the selected text.\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Live Caption helpers

    /// Start (or auto-switch to) the requested caption product on the given
    /// audio source. The engine setting flips to match the mode before the
    /// manager start fires. If a session of the OTHER product is running,
    /// it's torn down first (auto-stop-then-start) so we never have two
    /// products contending for the same panel. If the SAME product is
    /// running on a different source, we use switchSource for fast handoff.
    /// For .translated mode we gate on the cloud-disclosure modal first.
    @MainActor
    private func startCaptionMode(_ mode: AppConfig.CaptionMode, source: AudioSourceKind) {
        guard let manager = self.liveCaptionManager else {
            NSSound.beep()
            return
        }
        // Cloud-first-time disclosure. The cloudOnboardingShown flag is
        // persisted, so this only fires once per macOS user account.
        if mode == .translated && !AppConfig.shared.cloudOnboardingShown {
            let accepted = CloudOnboardingAlert.presentIfNeeded()
            if !accepted { return }
        }

        let targetEngine: AppConfig.LiveCaptionEngine = (mode == .translated) ? .cloudTranslate : .local

        Task { @MainActor in
            do {
                let currentMode: AppConfig.CaptionMode? = manager.isActive
                    ? (AppConfig.shared.liveCaptionEngine == .cloudTranslate ? .translated : .local)
                    : nil
                if manager.isActive && currentMode == mode {
                    // Same product, possibly different source → fast in-place switch.
                    try await manager.switchSource(to: source)
                    return
                }
                if manager.isActive {
                    // Different product → tear down fully, then start fresh.
                    manager.stop()
                    // Give the teardown's async block a chance to settle the
                    // panel and free MLX/URLSession state before we set up
                    // the new engine. 200ms matches the cloud graceful-close
                    // window plus a small buffer.
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                AppConfig.shared.liveCaptionEngine = targetEngine
                try await manager.start(source: source)
            } catch {
                log.error("LiveCaption start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Hotkey handler (Right ⌘ + /): toggle whichever product was last
    /// started. First-use (no AppConfig.lastStartedCaptionMode set) defaults
    /// to local — nobody accidentally starts a paid translation session via
    /// muscle memory on day one.
    @MainActor
    private func toggleLiveCaptionViaHotkey() {
        guard let manager = self.liveCaptionManager else {
            NSSound.beep()
            return
        }
        if manager.isActive {
            manager.stop()
            return
        }
        toggleProductWithLastSource(AppConfig.shared.lastStartedCaptionMode)
    }

    /// Shared entry point for "start `mode` with whatever source the user
    /// picked last." Used by the hotkey (last-used mode) and by both menu-
    /// header clicks (mode pinned per header). Reads the PERSISTED
    /// `lastStartedCaptionUsesMicSource` — not the session-only
    /// `liveCaptionUsesMicSource` which is reset to false on every stop
    /// because the dictation gate watches it.
    @MainActor
    private func toggleProductWithLastSource(_ mode: AppConfig.CaptionMode) {
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
        SystemAudioPermissionFlow.ensurePermission { [weak self] in
            guard let self else { return }
            let tuning = LiveCaptionTuning.load()
            if !forcePicker && !tuning.systemAudioBundleID.isEmpty {
                self.startCaptionMode(mode, source: .system(bundleID: tuning.systemAudioBundleID))
                return
            }
            SystemAudioPicker.present { [weak self] bundleID in
                guard let self, let bundleID else { return }
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
        let wasLocalCaptionActive = await liveCaptionManager?.releaseLocalModel() ?? false
        snapshot("1_manager_release")

        localEngine.unload()
        snapshot("2_engine_unload")

        if AppConfig.shared.textPolishEnabled {
            if #available(macOS 26.0, *) {
                Task { @MainActor in
                    FoundationModelsPolisher.releaseSession()
                }
            }
        }

        // Drop any MLX buffers retained from prior transcribes — the model
        // pointers are now gone, so cached intermediate tensors are dead
        // weight. clearCache() walks MLX's buffer pool and frees everything
        // not currently in flight. Without this, hundreds of MB can linger
        // even after the model itself releases.
        MLX.Memory.clearCache()
        snapshot("3_clearCache")

        if AppConfig.shared.dictationEngine == .local {
            state = .unloaded
            statusBar.setState(.unloaded)
        } else {
            state = .idle
            statusBar.setState(.idle)
        }
        print("[HushType] Model unloaded — memory freed")

        // Show confirmation alert with cold-start warning. If live caption
        // was active, the message changes to direct the user accordingly.
        let alert = NSAlert()
        if wasLocalCaptionActive {
            alert.messageText = "Live Caption Stopped"
            alert.informativeText = "The speech-to-text model was unloaded. Re-enable Live Caption from the menu after reloading the model."
        } else if AppConfig.shared.dictationEngine != .local {
            alert.messageText = "Local Model Unloaded"
            alert.informativeText = "The local speech recognition model has been removed from memory. Cloud dictation remains ready."
        } else {
            alert.messageText = "Model Unloaded"
            alert.informativeText = "The speech recognition model has been removed from memory.\n\nVoice input will require a cold start (~3 seconds) the next time you press Right ⌥."
        }
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func reloadModel() {
        guard state == .unloaded || !localEngine.isLoaded else {
            print("[HushType] Model already loaded")
            return
        }

        state = .loading
        statusBar.setState(.loading(0))
        statusBar.setModelLoaded()

        Task.detached { [weak self] in
            do {
                try await self?.localEngine.load { progress, description in
                    DispatchQueue.main.async {
                        self?.statusBar.setState(.loading(progress))
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.state = .idle
                    self.statusBar.setState(.idle)
                    log.info("Model reloaded")
                }
                await self?.scheduleTextPolishPrewarmIfNeeded(reason: "model reload")
            } catch {
                log.error("Failed to reload model: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self?.state = .unloaded
                    self?.statusBar.setState(.error("Reload failed"))
                }
            }
        }
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

    private func scheduleTextPolishPrewarmIfNeeded(reason: String) {
        guard AppConfig.shared.textPolishEnabled && TextPolisher.isAvailableCached else { return }
        if #available(macOS 26.0, *) {
            log.info("Scheduling Text Polish prewarm after \(reason, privacy: .public)")
            FoundationModelsPolisher.warmup()
        }
    }

    private enum CloudFailureChoice {
        case useLocalOnce
        case switchToLocal
        case cancel
        case openSettings
        case openKeyFile
    }

    private func handleCloudFailure(
        _ error: TranscriptionError,
        samples: [Float],
        language: String?,
        selection: AppConfig.DictationEngine,
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
            DictationEngineSettingsWindowController.shared.presentAndFocus(
                onSwitchEngine: { [weak self] engine in
                    self?.switchDictationEngine(to: engine)
                }
            )
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
                statusBar.setState(.loading(0))
                try await localEngine.load { [weak self] progress, _ in
                    DispatchQueue.main.async {
                        self?.statusBar.setState(.loading(progress))
                    }
                }
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
            alert.messageText = "Local transcription failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
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
            alert.messageText = "API key not set"
            alert.informativeText = "Add your \(provider) API key in Dictation Engine Settings before using cloud dictation."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Switch to Local")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .openSettings
            case .alertSecondButtonReturn: return .switchToLocal
            default: return .cancel
            }

        case .auth:
            let path = selection == .gemini ? GeminiKeyStore.displayPath : OpenAIKeyStore.displayPath
            alert.messageText = "\(provider) rejected the API key"
            alert.informativeText = "Check \(path)."
            alert.addButton(withTitle: "Open File")
            alert.addButton(withTitle: "Use Local Once")
            return alert.runModal() == .alertFirstButtonReturn ? .openKeyFile : .useLocalOnce

        case .rateLimited:
            alert.messageText = "\(provider) rate limit hit"
            alert.informativeText = selection == .gemini
                ? "You may have exhausted today's free tier."
                : "Wait a moment before trying cloud dictation again."
            alert.addButton(withTitle: "Use Local Once")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .useLocalOnce : .cancel

        case .payloadTooLarge:
            alert.messageText = "Recording too long for cloud transcription"
            alert.informativeText = "This recording exceeds the cloud upload limit. No audio was uploaded."
            alert.addButton(withTitle: "Use Local Once")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .useLocalOnce : .cancel

        case .network, .timeout:
            let timedOut: Bool
            if case .timeout = error { timedOut = true } else { timedOut = false }
            alert.messageText = timedOut
                ? "Cloud transcription timed out"
                : "Cloud transcription unavailable"
            alert.informativeText = "HushType could not reach \(provider). The recording is still available for local transcription."
            addStandardCloudFailureButtons(to: alert, preferSwitchToLocal: preferSwitchToLocal)
            return standardCloudFailureChoice(from: alert.runModal())

        case .malformedResponse:
            alert.messageText = "\(provider) returned an unreadable transcript"
            alert.informativeText = "Nothing was inserted. The recording is still available for local transcription."
            addStandardCloudFailureButtons(to: alert, preferSwitchToLocal: false)
            return standardCloudFailureChoice(from: alert.runModal())

        case .safetyBlocked:
            alert.messageText = "Gemini blocked this transcription"
            alert.informativeText = "Nothing was inserted. The recording is still available for local transcription."
            addStandardCloudFailureButtons(to: alert, preferSwitchToLocal: false)
            return standardCloudFailureChoice(from: alert.runModal())
        }
    }

    private func addStandardCloudFailureButtons(
        to alert: NSAlert,
        preferSwitchToLocal: Bool
    ) {
        alert.addButton(withTitle: "Use Local Once")
        alert.addButton(withTitle: "Switch to Local")
        alert.addButton(withTitle: "Cancel")
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

    private func postCloudCapNotification(
        snapshot: CloudUsageTracker.Snapshot,
        cap: Double
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Cloud daily-spend warning"
        content.body = "Today's total is \(CloudUsageTracker.formatDollars(snapshot.dayDollars)) (cap: \(CloudUsageTracker.formatDollars(cap)))."
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
    private func captureInsertionFocus() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    @discardableResult
    private func restoreInsertionFocus(_ application: NSRunningApplication?) async -> Bool {
        guard let application else { return false }
        application.activate()
        for _ in 0..<20 {
            if application.isActive { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return application.isActive
    }
}
