import Foundation

/// Caps how many jobs run at once. Waiting is cancellable: a cancelled waiter leaves the queue
/// at once and `acquire` throws `CancellationError`.
actor AsyncLimiter {
    private let limit: Int
    private var active = 0
    private var nextID = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var cancelledEarly: Set<Int> = []

    init(limit: Int) { self.limit = max(1, limit) }

    var activeCount: Int { active }
    var waitingCount: Int { waiters.count }

    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelledEarly.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            // The slot passes straight to the next waiter.
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: Int) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else {
            cancelledEarly.insert(id)
        }
    }
}

/// Produces values for keys on demand, once per key however many callers ask, a few at a time.
///
/// A request returns a ticket; cancelling the ticket withdraws interest, and when nobody is
/// interested in a key any more its job is cancelled (waiting its settle delay, waiting for a
/// slot, or fetching). Completions run on the main actor; a cancelled ticket's never does.
@MainActor
final class LazyLoader<Key: Hashable & Sendable, Value: Sendable> {
    struct Ticket: Hashable, Sendable {
        fileprivate let id: Int
        fileprivate let key: Key
    }

    private final class Job {
        var task: Task<Void, Never>?
        var waiters: [Int: @MainActor (Value?) -> Void] = [:]
    }

    private let limiter: AsyncLimiter
    private let settle: Duration
    private let produce: @Sendable (Key) async -> Value?
    private var jobs: [Key: Job] = [:]
    private var nextTicket = 0

    /// - Parameters:
    ///   - maxConcurrent: jobs producing at the same time.
    ///   - settle: how long a key must stay wanted before its job starts (a flick past a row
    ///     is cancelled before it costs anything).
    ///   - produce: the work; runs off the main actor.
    init(maxConcurrent: Int, settle: Duration = .zero, produce: @escaping @Sendable (Key) async -> Value?) {
        limiter = AsyncLimiter(limit: maxConcurrent)
        self.settle = settle
        self.produce = produce
    }

    /// Keys with a job in flight (waiting or running).
    var inFlightCount: Int { jobs.count }

    func request(_ key: Key, completion: @escaping @MainActor (Value?) -> Void) -> Ticket {
        nextTicket += 1
        let ticket = Ticket(id: nextTicket, key: key)
        let job: Job
        if let existing = jobs[key] {
            job = existing
        } else {
            job = Job()
            jobs[key] = job
            let limiter = limiter
            let settle = settle
            let produce = produce
            job.task = Task { [weak self] in
                var value: Value?
                do {
                    if settle > .zero { try await Task.sleep(for: settle) }
                    try await limiter.acquire()
                    if !Task.isCancelled { value = await produce(key) }
                    await limiter.release()
                } catch {
                    return  // cancelled while waiting
                }
                guard !Task.isCancelled else { return }
                self?.finish(key, job: job, value: value)
            }
        }
        job.waiters[ticket.id] = completion
        return ticket
    }

    func cancel(_ ticket: Ticket) {
        guard let job = jobs[ticket.key], job.waiters.removeValue(forKey: ticket.id) != nil else { return }
        if job.waiters.isEmpty {
            job.task?.cancel()
            jobs[ticket.key] = nil
        }
    }

    private func finish(_ key: Key, job: Job, value: Value?) {
        guard jobs[key] === job else { return }
        jobs[key] = nil
        for completion in job.waiters.values { completion(value) }
    }
}
