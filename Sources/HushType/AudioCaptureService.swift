import AVFoundation
import CoreMedia
import ExceptionCatcher
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "audio")

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
    private var isRecording = false
    private var recordingAttemptID: UUID?
    private var isContinuousCapturing = false

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
    func startRecording(completion: @escaping (Result<Void, Error>) -> Void) {
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
            let completeStart: (Result<Void, Error>) -> Void = { result in
                self.sessionQueue.async {
                    guard self.isRecording,
                          self.recordingAttemptID == attemptID,
                          !didCompleteStart else { return }
                    didCompleteStart = true
                    completion(result)
                }
            }

            do {
                self.recordingAttemptID = attemptID
                self.setActiveRecordingAttempt(attemptID)
                try self.startCapture(selection: selection) { [weak self] buffer in
                    guard let self else { return }
                    guard self.isActiveRecordingAttempt(attemptID) else { return }
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
                    guard self.isActiveRecordingAttempt(attemptID) else { return }
                    self.samplesLock.lock()
                    self.samples.append(contentsOf: newSamples)
                    self.samplesLock.unlock()
                    self.onRMSLevel?(rms)
                    completeStart(.success(()))
                }
                self.isRecording = true
                log.info("Capture session running; waiting for first audio buffer")

                self.sessionQueue.asyncAfter(deadline: .now() + 15) {
                    guard self.isRecording,
                          self.recordingAttemptID == attemptID,
                          !didCompleteStart else { return }
                    didCompleteStart = true
                    self.setActiveRecordingAttempt(nil)
                    self.stopCapture()
                    self.isRecording = false
                    self.recordingAttemptID = nil
                    completion(.failure(self.captureError("The selected input device did not provide audio")))
                }
            } catch {
                self.setActiveRecordingAttempt(nil)
                self.recordingAttemptID = nil
                self.isRecording = false
                completion(.failure(error))
            }
        }
    }

    /// Stops capture on the session queue, then drains already-delivered audio
    /// callbacks before returning the final sample buffer.
    func stopRecording(completion: @escaping ([Float]) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setActiveRecordingAttempt(nil)
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
        try startCapture(selection: AppConfig.shared.audioInputSelection) { [weak self] buffer in
            guard let self else { return }
            guard let pcmBuffer = converter.convert(buffer) else { return }

            guard let channelData = pcmBuffer.floatChannelData?[0] else { return }
            let frameCount = Int(pcmBuffer.frameLength)
            guard frameCount > 0 else { return }

            let newSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            self.onSamples?(newSamples)
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
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        guard let device = AudioInputDeviceManager.captureDevice(rawValue: selection) else {
            throw captureError("The selected input device is unavailable")
        }
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
        session.startRunning()
        guard session.isRunning else {
            stopCapture()
            throw captureError("The selected input device did not start")
        }
        log.info("Capture session started: \(device.localizedName, privacy: .public)")
    }

    private func stopCapture() {
        captureSession?.stopRunning()
        captureSession = nil
        sampleBufferReceiver = nil
    }

    private func setActiveRecordingAttempt(_ id: UUID?) {
        activeAttemptLock.lock()
        activeRecordingAttemptID = id
        activeAttemptLock.unlock()
    }

    private func isActiveRecordingAttempt(_ id: UUID) -> Bool {
        activeAttemptLock.lock()
        defer { activeAttemptLock.unlock() }
        return activeRecordingAttemptID == id
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
