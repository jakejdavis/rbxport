import Foundation

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

/// A layout store over a throwaway `UserDefaults` suite, so tests never touch real preferences.
func isolatedStore() -> ColumnLayoutStore {
    let suite = "rbxport-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return ColumnLayoutStore(defaults: defaults)
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
