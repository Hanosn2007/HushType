import AVFoundation
import CoreMedia
import ExceptionCatcher
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "audio")

enum AudioCaptureRecoveryPolicy {
    static func shouldAttemptAutomaticFallback(selection: String, alreadyAttempted: Bool) -> Bool {
        selection == AudioInputSelection.automatic && !alreadyAttempted
    }
}

final class AudioCaptureService {
    private final class SampleBufferReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        let onBuffer: (AVAudioPCMBuffer) -> Void

        init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
            self.onBuffer = onBuffer
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: streamDescription) else { return }
            let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            buffer.frameLength = frameCount
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(frameCount),
                into: buffer.mutableAudioBufferList
            )
            guard status == noErr else { return }
            onBuffer(buffer)
        }
    }

    private final class Converter {
        let targetFormat: AVAudioFormat
        private var sourceFormat: AVAudioFormat?
        private var converter: AVAudioConverter?

        init?() {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ) else { return nil }
            targetFormat = format
        }

        func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            let format = buffer.format
            if format.sampleRate == targetFormat.sampleRate,
               format.channelCount == targetFormat.channelCount,
               format.commonFormat == targetFormat.commonFormat,
               !format.isInterleaved {
                return buffer
            }

            if sourceFormat?.isEqual(format) != true {
                sourceFormat = format
                converter = AVAudioConverter(from: format, to: targetFormat)
            }
            guard let converter else { return nil }

            let capacity = AVAudioFrameCount(
                ceil(Double(buffer.frameLength) * targetFormat.sampleRate / format.sampleRate)
            )
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return nil
            }

            var error: NSError?
            var supplied = false
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                guard !supplied else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else {
                log.error("Audio conversion error: \(error?.localizedDescription ?? "unknown")")
                return nil
            }
            return output
        }
    }

    private var captureSession: AVCaptureSession?
    private var sampleBufferReceiver: SampleBufferReceiver?
    private let sessionQueue = DispatchQueue(label: "com.felix.hushtype.audio-session", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "com.felix.hushtype.audio-capture", qos: .userInitiated)
    private var samples: [Float] = []
    private let samplesLock = NSLock()
    private let activeAttemptLock = NSLock()
    private var activeRecordingAttemptID: UUID?
    private var activeRecordingCandidateID: UUID?
    private var isRecording = false
    private var recordingAttemptID: UUID?
    private var isContinuousCapturing = false
    private var captureObserverTokens: [NSObjectProtocol] = []
    private var captureGeneration: UUID?

    /// Called on each audio buffer with the current RMS level (0.0–1.0).
    var onRMSLevel: ((Float) -> Void)?

    /// Called on each audio buffer with the converted 16kHz mono Float32 samples.
    /// Fires on the CoreAudio IO thread (same lifecycle as `onRMSLevel`).
    /// Only invoked while `startContinuousCapture()` is active.
    var onSamples: (([Float]) -> Void)?

    /// Called on mid-session AVAudioEngine errors (device disconnect, route
    /// change failures). Fires on whatever thread surfaces the error.
    var onError: ((Error) -> Void)?

    /// Starts push-to-talk capture away from the main thread. Completion is
    /// delivered only after the selected device produces its first usable PCM
    /// buffer, so a remote/route-changing microphone is not reported as ready
    /// merely because AVCaptureSession says it is running.
    func startRecording(
        onUnexpectedStop: @escaping (Error) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let selection = AppConfig.shared.audioInputSelection
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isRecording else {
                completion(.success(()))
                return
            }

            self.samplesLock.lock()
            self.samples.removeAll(keepingCapacity: true)
            self.samplesLock.unlock()

            guard let converter = Converter() else {
                completion(.failure(self.targetFormatError()))
                return
            }

            let attemptID = UUID()
            var didCompleteStart = false
            var didAttemptAutomaticFallback = false
            var startTimeout: DispatchWorkItem?
            var activeDeviceUID: String?

            func finishWithError(_ error: Error) {
                guard self.isRecording,
                      self.recordingAttemptID == attemptID else { return }
                startTimeout?.cancel()
                self.setActiveRecordingAttempt(nil, candidateID: nil)
                self.stopCapture()
                self.isRecording = false
                self.recordingAttemptID = nil
                if didCompleteStart {
                    onUnexpectedStop(error)
                } else {
                    didCompleteStart = true
                    completion(.failure(error))
                }
            }

            var startCandidate: ((String?) throws -> Void)!
            var attemptFallbackOrFail: ((Error) -> Void)!
            var processBuffer: ((AVAudioPCMBuffer, UUID) -> Void)!

            func scheduleStartTimeout(candidateID: UUID, seconds: TimeInterval, detail: String) {
                startTimeout?.cancel()
                let timeout = DispatchWorkItem {
                    guard self.isRecording,
                          self.recordingAttemptID == attemptID,
                          !didCompleteStart,
                          self.isActiveRecordingAttempt(attemptID, candidateID: candidateID) else { return }
                    attemptFallbackOrFail(self.captureError(detail))
                }
                startTimeout = timeout
                self.sessionQueue.asyncAfter(deadline: .now() + seconds, execute: timeout)
            }

            attemptFallbackOrFail = { error in
                guard self.isRecording,
                      self.recordingAttemptID == attemptID else { return }

                if didCompleteStart {
                    finishWithError(error)
                    return
                }

                guard AudioCaptureRecoveryPolicy.shouldAttemptAutomaticFallback(
                    selection: selection,
                    alreadyAttempted: didAttemptAutomaticFallback
                ) else {
                    finishWithError(error)
                    return
                }

                didAttemptAutomaticFallback = true
                let unavailableUID = activeDeviceUID
                self.stopCapture()
                do {
                    try startCandidate(unavailableUID)
                    log.info("Automatic input fallback started; waiting for first audio buffer")
                } catch {
                    finishWithError(error)
                }
            }

            processBuffer = { [weak self] buffer, candidateID in
                guard let self else { return }
                guard self.isActiveRecordingAttempt(attemptID, candidateID: candidateID) else { return }
                guard let pcmBuffer = converter.convert(buffer) else { return }
                guard let channelData = pcmBuffer.floatChannelData?[0] else { return }
                let frameCount = Int(pcmBuffer.frameLength)
                guard frameCount > 0 else { return }

                var rms: Float = 0
                for i in 0..<frameCount {
                    rms += channelData[i] * channelData[i]
                }
                rms = sqrt(rms / max(Float(frameCount), 1))

                let newSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
                guard self.isActiveRecordingAttempt(attemptID, candidateID: candidateID) else { return }
                self.samplesLock.lock()
                self.samples.append(contentsOf: newSamples)
                self.samplesLock.unlock()
                self.onRMSLevel?(rms)

                self.sessionQueue.async {
                    guard self.isRecording,
                          self.recordingAttemptID == attemptID,
                          self.isActiveRecordingAttempt(attemptID, candidateID: candidateID) else { return }
                    if !didCompleteStart {
                        startTimeout?.cancel()
                        startTimeout = nil
                        didCompleteStart = true
                        completion(.success(()))
                    }
                }
            }

            startCandidate = { excludingUID in
                let candidateID = UUID()
                self.setActiveRecordingAttempt(attemptID, candidateID: candidateID)
                activeDeviceUID = nil
                activeDeviceUID = try self.startCapture(
                    selection: selection,
                    excludingUID: excludingUID,
                    onDeviceResolved: { activeDeviceUID = $0 },
                    onBuffer: { buffer in processBuffer(buffer, candidateID) },
                    onUnexpectedStop: { error in
                        guard self.isActiveRecordingAttempt(attemptID, candidateID: candidateID) else { return }
                        attemptFallbackOrFail(error)
                    }
                )
                scheduleStartTimeout(
                    candidateID: candidateID,
                    seconds: didAttemptAutomaticFallback ? 5 : 15,
                    detail: didAttemptAutomaticFallback
                        ? "The fallback input device did not provide audio"
                        : "The selected input device did not provide audio"
                )
            }

            self.recordingAttemptID = attemptID
            self.isRecording = true
            do {
                try startCandidate(nil)
                log.info("Capture session running; waiting for first audio buffer")
            } catch {
                attemptFallbackOrFail(error)
            }
        }
    }

    /// Stops capture on the session queue, then drains already-delivered audio
    /// callbacks before returning the final sample buffer.
    func stopRecording(completion: @escaping ([Float]) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setActiveRecordingAttempt(nil, candidateID: nil)
            if self.isRecording {
                self.stopCapture()
            }
            self.isRecording = false
            self.recordingAttemptID = nil

            self.captureQueue.async {
                self.samplesLock.lock()
                let result = self.samples
                self.samples.removeAll(keepingCapacity: true)
                self.samplesLock.unlock()

                let duration = Double(result.count) / 16000.0
                log.info("Recording stopped: \(result.count) samples (\(String(format: "%.1f", duration))s)")
                completion(result)
            }
        }
    }

    // MARK: - Continuous capture (live caption mode)

    /// Live-caption capture path: installs a tap that pushes 16kHz mono Float32
    /// samples to `onSamples` per buffer. Does NOT accumulate into `samples`.
    /// Throws if the AVAudioEngine fails to start.
    func startContinuousCapture() throws {
        guard !isContinuousCapturing else { return }
        guard !isRecording else {
            throw NSError(
                domain: "AudioCaptureService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.string(
                    "error.audio_capture.push_to_talk_active",
                    fallback: "Push-to-talk recording is active; cannot start continuous capture."
                )]
            )
        }

        guard let converter = Converter() else { throw targetFormatError() }
        _ = try startCapture(selection: AppConfig.shared.audioInputSelection) { [weak self] buffer in
            guard let self else { return }
            guard let pcmBuffer = converter.convert(buffer) else { return }

            guard let channelData = pcmBuffer.floatChannelData?[0] else { return }
            let frameCount = Int(pcmBuffer.frameLength)
            guard frameCount > 0 else { return }

            let newSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            self.onSamples?(newSamples)
        } onUnexpectedStop: { [weak self] error in
            guard let self, self.isContinuousCapturing else { return }
            self.stopCapture()
            self.isContinuousCapturing = false
            self.onError?(error)
        }
        isContinuousCapturing = true
        log.info("Continuous capture started with selected capture device")
    }

    func stopContinuousCapture() {
        guard isContinuousCapturing else { return }
        stopCapture()
        isContinuousCapturing = false
        log.info("Continuous capture stopped")
    }

    private func startCapture(
        selection: String,
        excludingUID: String? = nil,
        onDeviceResolved: @escaping (String) -> Void = { _ in },
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onUnexpectedStop: @escaping (Error) -> Void = { _ in }
    ) throws -> String {
        guard let device = AudioInputDeviceManager.captureDevice(
            rawValue: selection,
            excludingUID: excludingUID
        ) else {
            throw captureError("The selected input device is unavailable")
        }
        onDeviceResolved(device.uniqueID)
        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw captureError(error.localizedDescription)
        }
        let output = AVCaptureAudioDataOutput()
        let receiver = SampleBufferReceiver(onBuffer: onBuffer)
        output.setSampleBufferDelegate(receiver, queue: captureQueue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw captureError("The selected input device cannot be connected")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        captureSession = session
        sampleBufferReceiver = receiver
        observeUnexpectedStop(
            session: session,
            device: device,
            onUnexpectedStop: onUnexpectedStop
        )
        session.startRunning()
        guard session.isRunning else {
            stopCapture()
            throw captureError("The selected input device did not start")
        }
        log.info("Capture session started: \(device.localizedName, privacy: .public)")
        return device.uniqueID
    }

    private func stopCapture() {
        removeCaptureObservers()
        captureSession?.stopRunning()
        captureSession = nil
        sampleBufferReceiver = nil
    }

    private func observeUnexpectedStop(
        session: AVCaptureSession,
        device: AVCaptureDevice,
        onUnexpectedStop: @escaping (Error) -> Void
    ) {
        removeCaptureObservers()
        let generation = UUID()
        captureGeneration = generation
        let center = NotificationCenter.default

        func deliver(_ error: Error) {
            sessionQueue.async { [weak self] in
                guard let self,
                      self.captureGeneration == generation,
                      self.captureSession === session else { return }
                onUnexpectedStop(error)
            }
        }

        captureObserverTokens.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device,
            queue: nil
        ) { _ in
            deliver(self.captureError("The input device was disconnected"))
        })
        captureObserverTokens.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { notification in
            let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                ?? "The capture session stopped unexpectedly"
            deliver(self.captureError(detail))
        })
    }

    private func removeCaptureObservers() {
        captureGeneration = nil
        let center = NotificationCenter.default
        captureObserverTokens.forEach(center.removeObserver)
        captureObserverTokens.removeAll(keepingCapacity: true)
    }

    private func setActiveRecordingAttempt(_ id: UUID?, candidateID: UUID?) {
        activeAttemptLock.lock()
        activeRecordingAttemptID = id
        activeRecordingCandidateID = candidateID
        activeAttemptLock.unlock()
    }

    private func isActiveRecordingAttempt(_ id: UUID, candidateID: UUID) -> Bool {
        activeAttemptLock.lock()
        defer { activeAttemptLock.unlock() }
        return activeRecordingAttemptID == id && activeRecordingCandidateID == candidateID
    }

    private func targetFormatError() -> NSError {
        NSError(
            domain: "AudioCaptureService",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: L10n.string(
                "error.audio_capture.target_format",
                fallback: "Failed to create target audio format."
            )]
        )
    }

    private func captureError(_ detail: String) -> NSError {
        NSError(
            domain: "AudioCaptureService",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: L10n.format(
                "error.audio_capture.unavailable",
                "Could not start microphone input: %1$@. Check the selected input device and try again.",
                arguments: [detail]
            )]
        )
    }
}
