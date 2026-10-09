import Foundation

/// Developer hooks for the Phase 6b screenshots, since synthetic clicks do not reach SwiftUI.
///
/// `RBXPORT_DEMO_CHROME` is a comma-separated list of steps:
/// - `backup`: takes a backup now and waits for it. Refuses unless the library is a generated
///   fixture (`RBXPORT_FIXTURE_DIR` set and confirmed by the core) and the backup folder is under a
///   temporary directory: the real library is never backed up by a hook.
/// - `report`: opens the Report a Problem window.
/// - `newlibrary`: opens the New Library sheet; `newlibrary-create` also presses Create. Both refuse
///   unless `RBXPORT_OPTIONS` and `RBXPORT_DEFAULT_LIBRARY_DIR` name places under a temporary
///   directory, so a library is only ever made there.
enum ChromeDemoGuard {
    static func backupAllowed(
        environment: [String: String], isFixture: Bool, backupDirectory: String, roots: [String] = DeviceDemoGuard.temporaryRoots()
    ) -> Bool {
        environment["RBXPORT_FIXTURE_DIR"] != nil && isFixture && DeviceDemoGuard.isTemporary(backupDirectory, roots: roots)
    }

    static func newLibraryAllowed(environment: [String: String], roots: [String] = DeviceDemoGuard.temporaryRoots()) -> Bool {
        guard let options = environment["RBXPORT_OPTIONS"], let dir = environment["RBXPORT_DEFAULT_LIBRARY_DIR"] else { return false }
        return DeviceDemoGuard.isTemporary(options, roots: roots) && DeviceDemoGuard.isTemporary(dir, roots: roots)
    }
}

extension AppModel {
    func runChromeDemo(_ steps: String, environment: [String: String]) async {
        for step in steps.split(separator: ",").map(String.init) {
            switch step {
            case "backup":
                let directory = await backend.backupDirectory()
                let isFixture = await backend.isFixtureLibrary()
                guard ChromeDemoGuard.backupAllowed(environment: environment, isFixture: isFixture, backupDirectory: directory) else {
                    notice = "Backup demo refused: it runs only against a fixture library with a temporary backup folder (fixture: \(isFixture), folder: \(directory))."
                    return
                }
                await backups.load()
                await backups.start()
                _ = await eventuallyDone { !self.backups.isRunning }
                await backups.refreshList()
            case "report":
                openReportWindow()
            case "newlibrary", "newlibrary-create":
                guard ChromeDemoGuard.newLibraryAllowed(environment: environment) else {
                    notice = "New library demo refused: RBXPORT_OPTIONS and RBXPORT_DEFAULT_LIBRARY_DIR must be under a temporary folder."
                    return
                }
                await openNewLibrary()
                if step == "newlibrary-create" {
                    try? await Task.sleep(for: .milliseconds(800))
                    await newLibrary?.create()
                }
            default: break
            }
        }
    }

    private func eventuallyDone(timeout: Duration = .seconds(120), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
