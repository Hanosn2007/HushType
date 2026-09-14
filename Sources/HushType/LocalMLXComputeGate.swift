import Foundation

/// Coordinates app-owned speech and text work. Cancellation removes queued
/// work, but an admitted operation keeps its slot until it has actually ended.
actor LocalMLXComputeGate {
    static let shared = LocalMLXComputeGate()

    private final class Request: @unchecked Sendable {
        let id = UUID()
        var isCancelled = false // Accessed only on this actor.
    }
    private struct Waiter {
        let request: Request
        let continuation: CheckedContinuation<Void, Error>
    }
    private var owner: UUID?
    private var waiters: [Waiter] = []

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let request = Request()
        return try await withTaskCancellationHandler {
            try await acquire(request)
            do {
                try Task.checkCancellation()
                let result = try await operation()
                try Task.checkCancellation()
                release(request)
                return result
            } catch {
                release(request)
                throw error
            }
        } onCancel: {
            Task { await self.cancel(request) }
        }
    }

    private func acquire(_ request: Request) async throws {
        try Task.checkCancellation()
        guard !request.isCancelled else { throw CancellationError() }
        if owner == nil {
            owner = request.id
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(request: request, continuation: continuation))
        }
    }

    private func cancel(_ request: Request) {
        request.isCancelled = true
        guard let index = waiters.firstIndex(where: { $0.request.id == request.id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ request: Request) {
        guard owner == request.id else { return }
        owner = nil
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        owner = next.request.id
        next.continuation.resume()
    }
}
