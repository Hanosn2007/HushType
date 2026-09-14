import Foundation

/// The hardware driver retains device selection, first-buffer readiness,
/// automatic fallback and disconnect detection. This interface also permits
/// ownership tests to use numbered PCM buffers without opening a microphone.
protocol MicrophoneCaptureDriverProtocol: AnyObject {
    var retainsRecordedSamples: Bool { get set }
    var onSamples: (([Float]) -> Void)? { get set }
    var onRMSLevel: ((Float) -> Void)? { get set }
    func startRecording(
        onUnexpectedStop: @escaping (Error) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func stopRecording(completion: @escaping ([Float]) -> Void)
}

/// One physical input session with independent dictation and caption leases.
/// Stopping either consumer leaves the other consumer's stream running.
final class AudioCaptureService: @unchecked Sendable {
    @MainActor private static var profileSources: [String: AudioCaptureService] = [:]

    /// Reuse the existing two-consumer ownership logic for each actual source.
    @MainActor static func shared(for input: ProcessingProfile.Input) -> AudioCaptureService {
        let key: String
        let driver: () -> any MicrophoneCaptureDriverProtocol
        switch input.kind {
        case .microphone:
            let uid = AudioInputDeviceManager.captureDevice(rawValue: input.device)?.captureDevice.uniqueID
            let selection = uid.map(AudioInputSelection.device) ?? input.device
            let automatic = input.device == AudioInputSelection.automatic
            key = "mic:" + (automatic ? "automatic:" : "") + selection
            driver = { MicrophoneCaptureDriver(selection: automatic ? AudioInputSelection.automatic : selection) }
        case .application:
            key = "app:" + input.bundleID
            driver = { ApplicationAudioCaptureDriver(bundleID: input.bundleID) }
        }
        if let source = profileSources[key] { return source }
        let source = AudioCaptureService(driver: driver())
        profileSources[key] = source
        return source
    }

    private enum DriverState {
        case stopped
        case starting(UUID)
        case running(UUID)
        case stopping(UUID)

        var generation: UUID? {
            switch self {
            case .stopped: nil
            case .starting(let id), .running(let id), .stopping(let id): id
            }
        }
        var isRunning: Bool { if case .running = self { true } else { false } }
        var acceptsSamples: Bool {
            switch self {
            case .starting, .running: true
            case .stopped, .stopping: false
            }
        }
    }

    private struct RecordingLease {
        var receivedSamples = false
        var completions: [(Result<Void, Error>) -> Void]
        let onUnexpectedStop: (Error) -> Void
    }

    private struct ContinuousLease {
        let id: UUID
        var receivedSamples = false
        var waiters: [UUID: CheckedContinuation<Void, Error>]
    }

    private final class ContinuousStartRequest: @unchecked Sendable {
        let id = UUID()
        // Accessed only on the consumer queue, including cancellation.
        var isCancelled = false
    }

    private let driver: any MicrophoneCaptureDriverProtocol
    private let queue = DispatchQueue(label: "com.felix.hushtype.microphone-consumers", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let callbacksLock = NSLock()
    private var rmsCallback: ((Float) -> Void)?
    private var samplesCallback: (([Float]) -> Void)?
    private var errorCallback: ((Error) -> Void)?
    private var driverState: DriverState = .stopped
    private var recordingLease: RecordingLease?
    private var continuousLease: ContinuousLease?
    private var recordedSamples: [Float] = []

    init(driver: any MicrophoneCaptureDriverProtocol = MicrophoneCaptureDriver()) {
        self.driver = driver
        driver.retainsRecordedSamples = false
        queue.setSpecific(key: queueKey, value: true)
    }

    var onRMSLevel: ((Float) -> Void)? {
        get { callbacksLock.withLock { rmsCallback } }
        set { callbacksLock.withLock { rmsCallback = newValue } }
    }
    var onSamples: (([Float]) -> Void)? {
        get { callbacksLock.withLock { samplesCallback } }
        set { callbacksLock.withLock { samplesCallback = newValue } }
    }
    var onError: ((Error) -> Void)? {
        get { callbacksLock.withLock { errorCallback } }
        set { callbacksLock.withLock { errorCallback = newValue } }
    }

    func startRecording(
        onUnexpectedStop: @escaping (Error) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [self] in
            if recordingLease != nil {
                recordingLease?.completions.append(completion)
            } else {
                recordedSamples.removeAll(keepingCapacity: true)
                recordingLease = RecordingLease(completions: [completion], onUnexpectedStop: onUnexpectedStop)
            }
            ensureCapture()
            completeReadyConsumers()
        }
    }

    func stopRecording(completion: @escaping ([Float]) -> Void) {
        queue.async { [self] in
            let pending = recordingLease?.completions ?? []
            recordingLease = nil
            let result = recordedSamples
            recordedSamples.removeAll(keepingCapacity: true)
            pending.forEach { $0(.failure(CancellationError())) }
            stopCaptureIfUnused()
            completion(result)
        }
    }

    func startContinuousCapture() async throws {
        let request = ContinuousStartRequest()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    if request.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if continuousLease != nil {
                        continuousLease?.waiters[request.id] = continuation
                    } else {
                        continuousLease = ContinuousLease(id: request.id, waiters: [request.id: continuation])
                    }
                    ensureCapture()
                    completeReadyConsumers()
                }
            }
        } onCancel: { [weak self] in
            self?.queue.async { [weak self] in
                request.isCancelled = true
                self?.cancelContinuousStart(request.id)
            }
        }
    }

    func stopContinuousCapture() {
        onQueue {
            let waiters = self.continuousLease?.waiters.values.map { $0 } ?? []
            self.continuousLease = nil
            waiters.forEach { $0.resume(throwing: CancellationError()) }
            self.stopCaptureIfUnused()
        }
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { body() }
        else { queue.sync(execute: body) }
    }

    private func cancelContinuousStart(_ id: UUID) {
        guard let lease = continuousLease else { return }
        if lease.id == id {
            continuousLease = nil
            lease.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
            stopCaptureIfUnused()
        } else if let waiter = continuousLease?.waiters.removeValue(forKey: id) {
            waiter.resume(throwing: CancellationError())
        }
    }

    private func ensureCapture() {
        guard recordingLease != nil || continuousLease != nil else { return }
        guard case .stopped = driverState else { return }
        let generation = UUID()
        driverState = .starting(generation)
        driver.onSamples = { [weak self] samples in
            self?.queue.async { [weak self] in self?.receiveSamples(samples, generation: generation) }
        }
        driver.onRMSLevel = { [weak self] level in
            self?.queue.async { [weak self] in
                guard let self, self.driverState.generation == generation,
                      self.driverState.acceptsSamples, self.recordingLease != nil else { return }
                self.onRMSLevel?(level)
            }
        }
        driver.startRecording(onUnexpectedStop: { [weak self] error in
            self?.queue.async { [weak self] in self?.captureFailed(error, generation: generation) }
        }, completion: { [weak self] result in
            self?.queue.async { [weak self] in
                guard let self, case .starting(let active) = self.driverState, active == generation else { return }
                switch result {
                case .success:
                    self.driverState = .running(generation)
                    self.completeReadyConsumers()
                case .failure(let error):
                    self.captureFailed(error, generation: generation)
                }
            }
        })
    }

    private func receiveSamples(_ samples: [Float], generation: UUID) {
        guard driverState.generation == generation, driverState.acceptsSamples, !samples.isEmpty else { return }
        if recordingLease != nil {
            recordedSamples.append(contentsOf: samples)
            recordingLease?.receivedSamples = true
        }
        if continuousLease != nil {
            continuousLease?.receivedSamples = true
            onSamples?(samples)
        }
        completeReadyConsumers()
    }

    private func completeReadyConsumers() {
        guard driverState.isRunning else { return }
        if recordingLease?.receivedSamples == true {
            let completions = recordingLease?.completions ?? []
            recordingLease?.completions.removeAll()
            completions.forEach { $0(.success(())) }
        }
        if continuousLease?.receivedSamples == true {
            let waiters = continuousLease?.waiters.values.map { $0 } ?? []
            continuousLease?.waiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func stopCaptureIfUnused() {
        guard recordingLease == nil, continuousLease == nil else { return }
        guard let generation = driverState.generation else { return }
        if case .stopping = driverState { return }
        driverState = .stopping(generation)
        driver.stopRecording { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, case .stopping(let active) = self.driverState, active == generation else { return }
                self.driverState = .stopped
                // A new lease may have arrived while the old driver's input
                // callbacks were draining. It starts a fresh generation now.
                self.ensureCapture()
            }
        }
    }

    private func captureFailed(_ error: Error, generation: UUID) {
        guard driverState.generation == generation, driverState.acceptsSamples else { return }
        let recording = recordingLease
        let continuous = continuousLease
        driverState = .stopped
        recordingLease = nil
        continuousLease = nil
        recordedSamples.removeAll(keepingCapacity: true)
        if let recording {
            if recording.completions.isEmpty { recording.onUnexpectedStop(error) }
            else { recording.completions.forEach { $0(.failure(error)) } }
        }
        if let continuous {
            if continuous.waiters.isEmpty { onError?(error) }
            else { continuous.waiters.values.forEach { $0.resume(throwing: error) } }
        }
    }
}
