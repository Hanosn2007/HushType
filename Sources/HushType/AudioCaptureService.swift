import AVFoundation
import ExceptionCatcher
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "audio")

final class AudioCaptureService {
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

    private var audioEngine = AVAudioEngine()
    private var samples: [Float] = []
    private let samplesLock = NSLock()
    private var isRecording = false
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

    func startRecording() throws {
        guard !isRecording else { return }

        samplesLock.lock()
        samples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        guard let converter = Converter() else { throw targetFormatError() }
        audioEngine.stop()
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode

        try installTap(on: inputNode) { [weak self] buffer, _ in
            guard let self else { return }
            guard let pcmBuffer = converter.convert(buffer) else { return }

            guard let channelData = pcmBuffer.floatChannelData?[0] else { return }
            let frameCount = Int(pcmBuffer.frameLength)

            // Calculate RMS
            var rms: Float = 0
            for i in 0..<frameCount {
                rms += channelData[i] * channelData[i]
            }
            rms = sqrt(rms / max(Float(frameCount), 1))
            self.onRMSLevel?(rms)

            // Accumulate samples
            let newSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            self.samplesLock.lock()
            self.samples.append(contentsOf: newSamples)
            self.samplesLock.unlock()
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            log.info("Recording started with automatic input-format matching")
        } catch {
            inputNode.removeTap(onBus: 0)
            log.error("Failed to start audio engine: \(error.localizedDescription)")
            throw captureError(error.localizedDescription)
        }
    }

    func stopRecording() -> [Float] {
        guard isRecording else { return [] }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false

        samplesLock.lock()
        let result = samples
        samples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        let duration = Double(result.count) / 16000.0
        log.info("Recording stopped: \(result.count) samples (\(String(format: "%.1f", duration))s)")
        return result
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
        audioEngine.stop()
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode

        try installTap(on: inputNode) { [weak self] buffer, _ in
            guard let self else { return }
            guard let pcmBuffer = converter.convert(buffer) else { return }

            guard let channelData = pcmBuffer.floatChannelData?[0] else { return }
            let frameCount = Int(pcmBuffer.frameLength)
            guard frameCount > 0 else { return }

            let newSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            self.onSamples?(newSamples)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isContinuousCapturing = true
            log.info("Continuous capture started with automatic input-format matching")
        } catch {
            // Tap was installed; clean up before rethrowing.
            inputNode.removeTap(onBus: 0)
            log.error("Failed to start continuous capture: \(error.localizedDescription)")
            throw captureError(error.localizedDescription)
        }
    }

    func stopContinuousCapture() {
        guard isContinuousCapturing else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isContinuousCapturing = false
        log.info("Continuous capture stopped")
    }

    private func installTap(
        on inputNode: AVAudioInputNode,
        block: @escaping AVAudioNodeTapBlock
    ) throws {
        var exceptionError: NSError?
        let installed = HTCatchException({
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil, block: block)
        }, &exceptionError)
        guard installed else {
            throw captureError(exceptionError?.localizedDescription ?? "AVAudioEngine rejected the input format")
        }
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
