import Foundation

enum QwenASRInferenceClient: Equatable, Sendable {
    case dictation
    case liveCaption
}

enum QwenASRInferenceCoordinatorError: Error, Equatable, Sendable {
    case modelUnavailable
    case shuttingDown
}

/// Serializes access to one Qwen model and fairly alternates dictation and
/// Live Caption requests when both products are waiting.
///
/// `Qwen3ASRModel.transcribe` is synchronous and cannot be interrupted once it
/// starts. Cancelling a queued request resumes it immediately. Cancelling the
/// in-flight request marks its result unwanted, but the caller does not resume
/// until the model call returns. `shutdownAndWait()` therefore forms a real
/// model-release barrier without blocking the main thread.
final class QwenASRInferenceCoordinator: @unchecked Sendable {
    typealias Transcriber = @Sendable (
        _ audio: [Float],
        _ language: String?,
        _ maxTokens: Int
    ) -> String
    typealias ComputeGate = @Sendable (
        _ operation: @escaping @Sendable () async -> String
    ) async throws -> String

    struct Snapshot: Equatable, Sendable {
        let isAcceptingRequests: Bool
        let hasTranscriber: Bool
        let runningClient: QwenASRInferenceClient?
        let runningRequestIsCancelled: Bool
        let pendingDictationRequests: Int
        let pendingLiveCaptionRequests: Int
    }

    private final class Request: @unchecked Sendable {
        let id: UUID
        let sequence: UInt64
        let client: QwenASRInferenceClient
        let audio: [Float]
        let language: String?
        let maxTokens: Int
        let continuation: CheckedContinuation<String, Error>
        var isCancelled = false
        var executionTask: Task<Void, Never>?

        init(
            id: UUID,
            sequence: UInt64,
            client: QwenASRInferenceClient,
            audio: [Float],
            language: String?,
            maxTokens: Int,
            continuation: CheckedContinuation<String, Error>
        ) {
            self.id = id
            self.sequence = sequence
            self.client = client
            self.audio = audio
            self.language = language
            self.maxTokens = maxTokens
            self.continuation = continuation
        }
    }

    private let stateLock = NSLock()
    private let inferenceQueue = DispatchQueue(
        label: "com.felix.hushtype.qwen-asr-inference",
        qos: .userInitiated
    )
    private let computeGate: ComputeGate

    private var transcriber: Transcriber?
    private var acceptsRequests = true
    private var nextSequence: UInt64 = 0
    private var lastServedClient: QwenASRInferenceClient?
    private var runningRequest: Request?
    private var dictationQueue: [Request] = []
    private var liveCaptionQueue: [Request] = []
    private var registeredRequestIDs: Set<UUID> = []
    private var cancelledRequestIDs: Set<UUID> = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        transcriber: @escaping Transcriber,
        computeGate: @escaping ComputeGate = QwenASRInferenceCoordinator.sharedComputeGate
    ) {
        self.transcriber = transcriber
        self.computeGate = computeGate
    }

    func transcribe(
        audio: [Float],
        language: String?,
        maxTokens: Int,
        client: QwenASRInferenceClient
    ) async throws -> String {
        let requestID = UUID()
        register(requestID)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    id: requestID,
                    client: client,
                    audio: audio,
                    language: language,
                    maxTokens: maxTokens,
                    continuation: continuation
                )
            }
        } onCancel: { [weak self] in
            self?.cancel(requestID)
        }
    }

    /// Stop admission, cancel queued work, and mark an in-flight result as
    /// unwanted. The synchronous model call remains strongly owned until it
    /// returns; use `shutdownAndWait()` before releasing shared MLX state.
    func shutdown() {
        var cancelled: [Request] = []
        var waiters: [CheckedContinuation<Void, Never>] = []

        stateLock.lock()
        acceptsRequests = false
        cancelled = dictationQueue + liveCaptionQueue
        dictationQueue.removeAll(keepingCapacity: false)
        liveCaptionQueue.removeAll(keepingCapacity: false)
        for request in cancelled {
            registeredRequestIDs.remove(request.id)
            cancelledRequestIDs.remove(request.id)
        }
        runningRequest?.isCancelled = true
        runningRequest?.executionTask?.cancel()
        if runningRequest == nil {
            transcriber = nil
            waiters = drainWaiters
            drainWaiters.removeAll(keepingCapacity: false)
        }
        stateLock.unlock()

        for request in cancelled {
            request.continuation.resume(throwing: CancellationError())
        }
        waiters.forEach { $0.resume() }
    }

    func shutdownAndWait() async {
        shutdown()
        await withCheckedContinuation { continuation in
            addDrainWaiter(continuation)
        }
    }

    func snapshot() -> Snapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Snapshot(
            isAcceptingRequests: acceptsRequests,
            hasTranscriber: transcriber != nil,
            runningClient: runningRequest?.client,
            runningRequestIsCancelled: runningRequest?.isCancelled ?? false,
            pendingDictationRequests: dictationQueue.count,
            pendingLiveCaptionRequests: liveCaptionQueue.count
        )
    }

    private func register(_ requestID: UUID) {
        stateLock.lock()
        registeredRequestIDs.insert(requestID)
        stateLock.unlock()
    }

    private func enqueue(
        id: UUID,
        client: QwenASRInferenceClient,
        audio: [Float],
        language: String?,
        maxTokens: Int,
        continuation: CheckedContinuation<String, Error>
    ) {
        var immediateError: Error?

        stateLock.lock()
        if cancelledRequestIDs.remove(id) != nil {
            registeredRequestIDs.remove(id)
            immediateError = CancellationError()
        } else if !acceptsRequests {
            registeredRequestIDs.remove(id)
            immediateError = QwenASRInferenceCoordinatorError.shuttingDown
        } else if transcriber == nil {
            registeredRequestIDs.remove(id)
            immediateError = QwenASRInferenceCoordinatorError.modelUnavailable
        } else {
            let request = Request(
                id: id,
                sequence: nextSequence,
                client: client,
                audio: audio,
                language: language,
                maxTokens: max(1, maxTokens),
                continuation: continuation
            )
            nextSequence &+= 1
            switch client {
            case .dictation:
                dictationQueue.append(request)
            case .liveCaption:
                liveCaptionQueue.append(request)
            }
            scheduleNextLocked()
        }
        stateLock.unlock()

        if let immediateError {
            continuation.resume(throwing: immediateError)
        }
    }

    private func cancel(_ requestID: UUID) {
        var cancelledRequest: Request?

        stateLock.lock()
        if runningRequest?.id == requestID {
            runningRequest?.isCancelled = true
            runningRequest?.executionTask?.cancel()
        } else if let index = dictationQueue.firstIndex(where: { $0.id == requestID }) {
            cancelledRequest = dictationQueue.remove(at: index)
            registeredRequestIDs.remove(requestID)
        } else if let index = liveCaptionQueue.firstIndex(where: { $0.id == requestID }) {
            cancelledRequest = liveCaptionQueue.remove(at: index)
            registeredRequestIDs.remove(requestID)
        } else if registeredRequestIDs.contains(requestID) {
            // Cancellation may win the race with continuation registration.
            cancelledRequestIDs.insert(requestID)
        }
        stateLock.unlock()

        cancelledRequest?.continuation.resume(throwing: CancellationError())
    }

    /// Must be called with `stateLock` held.
    private func scheduleNextLocked() {
        guard runningRequest == nil,
              acceptsRequests,
              let transcriber,
              let request = takeNextLocked()
        else { return }

        runningRequest = request
        lastServedClient = request.client
        let computeGate = self.computeGate
        let inferenceQueue = self.inferenceQueue
        // Keep the coordinator alive through completion. The task is the last
        // owner after the engine detaches a coordinator in the non-blocking
        // unload path, and it still must resume the caller's continuation.
        request.executionTask = Task.detached(priority: .userInitiated) { [self] in
            do {
                let result = try await computeGate {
                    await withCheckedContinuation { continuation in
                        inferenceQueue.async {
                            continuation.resume(returning: transcriber(
                                request.audio,
                                request.language,
                                request.maxTokens
                            ))
                        }
                    }
                }
                finish(request, result: .success(result))
            } catch {
                finish(request, result: .failure(error))
            }
        }
    }

    /// Must be called with `stateLock` held.
    private func takeNextLocked() -> Request? {
        if !dictationQueue.isEmpty, !liveCaptionQueue.isEmpty {
            switch lastServedClient {
            case .dictation:
                return liveCaptionQueue.removeFirst()
            case .liveCaption:
                return dictationQueue.removeFirst()
            case nil:
                if dictationQueue[0].sequence < liveCaptionQueue[0].sequence {
                    return dictationQueue.removeFirst()
                }
                return liveCaptionQueue.removeFirst()
            }
        }
        if !dictationQueue.isEmpty { return dictationQueue.removeFirst() }
        if !liveCaptionQueue.isEmpty { return liveCaptionQueue.removeFirst() }
        return nil
    }

    private func finish(_ request: Request, result: Result<String, Error>) {
        var waiters: [CheckedContinuation<Void, Never>] = []

        stateLock.lock()
        guard runningRequest === request else {
            stateLock.unlock()
            return
        }
        runningRequest = nil
        request.executionTask = nil
        registeredRequestIDs.remove(request.id)
        cancelledRequestIDs.remove(request.id)
        if acceptsRequests {
            scheduleNextLocked()
        } else {
            transcriber = nil
            waiters = drainWaiters
            drainWaiters.removeAll(keepingCapacity: false)
        }
        let wasCancelled = request.isCancelled
        stateLock.unlock()

        if wasCancelled {
            request.continuation.resume(throwing: CancellationError())
        } else {
            request.continuation.resume(with: result)
        }
        waiters.forEach { $0.resume() }
    }

    private func addDrainWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        var shouldResume = false
        stateLock.lock()
        if !acceptsRequests, runningRequest == nil {
            shouldResume = true
        } else {
            drainWaiters.append(continuation)
        }
        stateLock.unlock()
        if shouldResume { continuation.resume() }
    }

    private static let sharedComputeGate: ComputeGate = { operation in
        try await LocalMLXComputeGate.shared.run(operation)
    }
}
