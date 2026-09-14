import Foundation

enum LiveCaptionTranslationQueueError: LocalizedError, Equatable, Sendable {
    case backlogFull(limit: Int)

    var errorDescription: String? {
        switch self {
        case .backlogFull(let limit):
            L10n.format(
                "caption.translation.backlog_full",
                "Translation backlog is full at %1$d items.",
                arguments: [Int32(limit)]
            )
        }
    }
}

/// Serializes completed-caption translation without holding up ASR events.
/// Each session owns one queue; cancellation permanently retires that queue so
/// a late result from the local-model gate cannot update a later session.
@MainActor
final class LiveCaptionTranslationQueue {
    typealias Translate = @Sendable (String) async throws -> String

    private struct Job: Sendable {
        let id: UUID
        let text: String
    }

    var onResult: ((UUID, Result<String, Error>) -> Void)?
    var onPendingCountChanged: ((Int) -> Void)?

    private let translate: Translate
    private let maximumPending: Int
    private var pending: [Job] = []
    private var active: Job?
    private var activeTask: Task<Void, Never>?
    private var isAcceptingWork = true
    private var generation: UInt64 = 0

    init(translate: @escaping Translate, maximumPending: Int = 32) {
        precondition(maximumPending > 0, "maximumPending must be positive")
        self.translate = translate
        self.maximumPending = maximumPending
    }

    /// Starts immediately when idle; otherwise queues behind the active
    /// request. A full backlog reports an error for the new sentence, so its
    /// source text remains visible with an explicit translation status.
    func enqueue(id: UUID, text: String) {
        guard isAcceptingWork else { return }

        let job = Job(id: id, text: text)
        guard active != nil else {
            start(job)
            reportPendingCount()
            return
        }

        guard pending.count < maximumPending else {
            onResult?(id, .failure(LiveCaptionTranslationQueueError.backlogFull(limit: maximumPending)))
            return
        }
        pending.append(job)
        reportPendingCount()
    }

    /// Drops waiting work, cancels the active request, and blocks any result
    /// which returns after cancellation. The underlying model gate may still
    /// drain its cancelled request before another session can use it.
    func cancel() {
        guard isAcceptingWork else { return }
        isAcceptingWork = false
        generation &+= 1
        pending.removeAll()
        activeTask?.cancel()
        activeTask = nil
        active = nil
        reportPendingCount()
    }

    /// Call after all ASR events have been delivered, before archiving the session.
    func waitUntilFinished() async {
        while let task = activeTask {
            await task.value
        }
    }

    private func start(_ job: Job) {
        precondition(active == nil)
        active = job
        let activeGeneration = generation
        let translate = translate
        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await translate(job.text))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            await self?.finish(job, generation: activeGeneration, result: result)
        }
    }

    private func finish(
        _ job: Job,
        generation: UInt64,
        result: Result<String, Error>
    ) {
        guard isAcceptingWork,
              self.generation == generation,
              active?.id == job.id else { return }

        active = nil
        activeTask = nil
        onResult?(job.id, result)

        guard isAcceptingWork, !pending.isEmpty else {
            reportPendingCount()
            return
        }
        let next = pending.removeFirst()
        start(next)
        reportPendingCount()
    }

    private func reportPendingCount() {
        onPendingCountChanged?(pending.count + (active == nil ? 0 : 1))
    }
}
