import Foundation

/// Adapts the existing app-audio source to the existing shared capture leases.
final class ApplicationAudioCaptureDriver: MicrophoneCaptureDriverProtocol, @unchecked Sendable {
    var retainsRecordedSamples = false
    var onSamples: (([Float]) -> Void)?
    var onRMSLevel: ((Float) -> Void)?
    private let bundleID: String
    private let lock = NSLock()
    private var source: SystemAudioSource?
    private var generation = UUID()

    init(bundleID: String) { self.bundleID = bundleID }

    func startRecording(onUnexpectedStop: @escaping (Error) -> Void,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        let source = SystemAudioSource(bundleID: bundleID)
        let attempt = UUID()
        let samplesCallback = onSamples
        let rmsCallback = onRMSLevel
        source.onSamples = { samples in
            samplesCallback?(samples)
            if !samples.isEmpty {
                rmsCallback?(sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)))
            }
        }
        source.onError = onUnexpectedStop
        lock.lock(); self.source = source; generation = attempt; lock.unlock()
        Task {
            do {
                try await source.start()
                guard self.isCurrent(attempt) else {
                    await source.stopAndWait()
                    completion(.failure(CancellationError()))
                    return
                }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    func stopRecording(completion: @escaping ([Float]) -> Void) {
        lock.lock()
        let previous = source
        source = nil
        generation = UUID()
        lock.unlock()
        Task { await previous?.stopAndWait(); completion([]) }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return id == generation
    }
}
