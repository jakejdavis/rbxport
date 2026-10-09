import Foundation
import Testing

@testable import rbxport

/// Polls until `condition` holds, or fails after `timeout`. Returns whether it held.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Throwaway `UserDefaults` suites that never touch `~/Library/Preferences`.
///
/// A suite named by an absolute path keeps its plist at that path, so these live in a temporary
/// directory instead of leaving a `rbxport-tests-<uuid>.plist` behind in the user's preferences
/// (`removePersistentDomain(forName:)` alone empties a suite but leaves its file, and cfprefsd
/// rewrites it after it is deleted). A test that makes suites runs under the `.scratchDefaults`
/// trait, which removes each domain and its file when the test is done; the directory itself goes
/// when the process exits.
final class ScratchBox: @unchecked Sendable {
    /// The box of the test running in this task (and the tasks it starts).
    @TaskLocal static var current: ScratchBox?

    private let lock = NSLock()
    private var domains: Set<String> = []

    func add(_ domain: String) { lock.withLock { _ = domains.insert(domain) } }

    /// Removes every domain this box holds, and its file.
    func retire() {
        let names = lock.withLock { domains }
        for name in names {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(atPath: name + ".plist")
        }
    }
}

/// Run a suite's tests with a `ScratchBox`, so the suites they make are removed afterwards.
struct ScratchDefaultsTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else {
            try await function()
            return
        }
        let box = ScratchBox()
        defer { box.retire() }
        try await ScratchBox.$current.withValue(box) { try await function() }
    }
}

extension Trait where Self == ScratchDefaultsTrait {
    /// Removes the `UserDefaults` suites a test made (see `scratchDefaults()`).
    static var scratchDefaults: Self { Self() }
}

enum ScratchSuites {
    /// Where this run's suites live.
    static let directory: String = {
        let path = NSTemporaryDirectory() + "rbxport-tests-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(atPath: ScratchSuites.directory) }
        return path
    }()

    static func make(prefix: String) -> UserDefaults {
        let domain = "\(directory)/\(prefix)-\(UUID().uuidString)"
        ScratchBox.current?.add(domain)
        return UserDefaults(suiteName: domain)!
    }
}

/// Defaults for one test: a fresh suite, removed when the test is done with it.
func scratchDefaults(prefix: String = "rbxport-tests") -> UserDefaults { ScratchSuites.make(prefix: prefix) }

/// A layout store over a throwaway `UserDefaults` suite, so tests never touch real preferences.
func isolatedStore() -> ColumnLayoutStore {
    ColumnLayoutStore(defaults: scratchDefaults())
}

/// `eventually` for conditions that ask an actor (a mock backend's call log).
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
