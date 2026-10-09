import Foundation
import Testing

@testable import rbxport

/// Counts concurrent producers and lets a test hold them open.
actor Gate {
    private(set) var started: [String] = []
    private(set) var running = 0
    private(set) var peak = 0
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter(_ key: String) async {
        started.append(key)
        running += 1
        peak = max(peak, running)
        if !open { await withCheckedContinuation { waiting.append($0) } }
        running -= 1
    }

    func release() {
        open = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

@MainActor
struct LazyLoaderTests {
    @Test func oneJobServesEveryRequestForAKey() async {
        let gate = Gate()
        let loader = LazyLoader<String, Int>(maxConcurrent: 4) { key in
            await gate.enter(key)
            return key.count
        }
        var results: [Int?] = []
        _ = loader.request("abc") { results.append($0) }
        _ = loader.request("abc") { results.append($0) }
        #expect(loader.inFlightCount == 1)
        #expect(await eventually { await gate.started.count == 1 })
        await gate.release()
        #expect(await eventually { results.count == 2 })
        #expect(results == [3, 3])
        #expect(loader.inFlightCount == 0)
        #expect(await gate.started == ["abc"])
    }

    @Test func atMostTheLimitRunAtOnce() async {
        let gate = Gate()
        let loader = LazyLoader<Int, Int>(maxConcurrent: 3) { key in
            await gate.enter(String(key))
            return key
        }
        var done = 0
        for i in 0..<10 { _ = loader.request(i) { _ in done += 1 } }
        #expect(await eventually { await gate.running == 3 })
        // Give the rest every chance to start; they must not.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await gate.running == 3)
        #expect(await gate.started.count == 3)
        await gate.release()
        #expect(await eventually { done == 10 })
        #expect(await gate.peak == 3)
    }

    @Test func aRequestCancelledDuringTheSettleDelayNeverStarts() async {
        let gate = Gate()
        await gate.release()
        let loader = LazyLoader<String, Int>(maxConcurrent: 4, settle: .milliseconds(80)) { key in
            await gate.enter(key)
            return 1
        }
        var delivered = false
        let ticket = loader.request("flick") { _ in delivered = true }
        try? await Task.sleep(for: .milliseconds(20))
        loader.cancel(ticket)
        #expect(loader.inFlightCount == 0)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await gate.started.isEmpty)
        #expect(!delivered)
        // A row that stays gets its load.
        var kept: Int?
        _ = loader.request("stay") { kept = $0 }
        #expect(await eventually { kept == 1 })
        #expect(await gate.started == ["stay"])
    }

    @Test func cancellingOneWaiterKeepsTheJobForTheOther() async {
        let gate = Gate()
        let loader = LazyLoader<String, Int>(maxConcurrent: 4) { key in
            await gate.enter(key)
            return 7
        }
        var first: Int?
        var second: Int?
        let a = loader.request("k") { first = $0 }
        _ = loader.request("k") { second = $0 }
        #expect(await eventually { await gate.started.count == 1 })
        loader.cancel(a)
        await gate.release()
        #expect(await eventually { second == 7 })
        #expect(first == nil)
    }

    @Test func cancelledJobsLeaveTheQueueSoNewOnesRun() async {
        let gate = Gate()
        let loader = LazyLoader<Int, Int>(maxConcurrent: 1) { key in
            await gate.enter(String(key))
            return key
        }
        _ = loader.request(0) { _ in }
        let queued = (1...5).map { loader.request($0) { _ in } }
        #expect(await eventually { await gate.running == 1 })
        for ticket in queued { loader.cancel(ticket) }
        #expect(loader.inFlightCount == 1)
        await gate.release()
        var late: Int?
        _ = loader.request(9) { late = $0 }
        #expect(await eventually { late == 9 })
        // Only the first and the late request ever ran.
        #expect(await gate.started == ["0", "9"])
    }
}

struct AsyncLimiterTests {
    @Test func slotsPassToWaitersInOrder() async throws {
        let limiter = AsyncLimiter(limit: 1)
        try await limiter.acquire()
        let order = OrderLog()
        let a = Task {
            try await limiter.acquire()
            await order.add("a")
            await limiter.release()
        }
        try await Task.sleep(for: .milliseconds(20))
        let b = Task {
            try await limiter.acquire()
            await order.add("b")
            await limiter.release()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await limiter.waitingCount == 2)
        await limiter.release()
        try await a.value
        try await b.value
        #expect(await order.items == ["a", "b"])
        #expect(await limiter.activeCount == 0)
    }

    @Test func aCancelledWaiterThrowsAndFreesNothing() async throws {
        let limiter = AsyncLimiter(limit: 1)
        try await limiter.acquire()
        let waiter = Task { try await limiter.acquire() }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await limiter.waitingCount == 0)
        #expect(await limiter.activeCount == 1)
    }
}

actor OrderLog {
    private(set) var items: [String] = []
    func add(_ item: String) { items.append(item) }
}
