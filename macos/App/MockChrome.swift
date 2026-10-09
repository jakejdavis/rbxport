import Foundation

/// What `MockBackend` answers for the Phase 6b calls (backups, the bug report, a new library),
/// and what it was asked. Nothing here touches a disk.
struct MockChromeScript: Sendable {
    var backups: [BackupInfo] = []
    var progress = BackupProgress(
        running: false, phase: .idle, copiedBytes: 0, totalBytes: 0, error: nil, path: nil, currentItem: nil)
    var directory = "/tmp/rbxport-backups"
    var startError: FfiError?
    var deleteError: FfiError?
    var directoryError: FfiError?
    var createError: FfiError?
    var createOutcome: LoadOutcome = .ready
    var plan: NewLibraryPlan?
    var problem: LibraryProblem?
    var report = SystemReport(
        appVersion: "0.1.0", os: "macos", osVersion: "26.0", arch: "aarch64", cpu: 3.5, memoryMb: 412.25,
        threads: 31, openFiles: 64, logDir: "/tmp/rbxport/logs", logPath: "/tmp/rbxport/logs/rbxport.2026-10-09.log",
        logTail: "2026-10-09T10:00:00Z DEBUG rbl_app: started\n")
    var health = AudioHealth(load: 0.125, xruns: 2)
    /// Every call, in order, as `name(args)` text.
    var calls: [String] = []
}

extension MockBackend {
    func scriptChrome(_ change: @Sendable (inout MockChromeScript) -> Void) { change(&chrome6b) }
    func chromeCalls() -> [String] { chrome6b.calls }

    /// Ends the running backup the way the core does: one more archive, and the event.
    func finishBackup(_ info: BackupInfo) {
        chrome6b.backups.insert(info, at: 0)
        chrome6b.progress = BackupProgress(
            running: false, phase: .complete, copiedBytes: info.bytes, totalBytes: info.bytes, error: nil,
            path: info.path, currentItem: nil)
        emit(.backupProgress(progress: chrome6b.progress))
    }

    func moveBackup(_ progress: BackupProgress) {
        chrome6b.progress = progress
        emit(.backupProgress(progress: progress))
    }

    func startBackup() async throws {
        chrome6b.calls.append("startBackup")
        if let error = chrome6b.startError { throw error }
        if chrome6b.progress.running { throw FfiError.Internal(message: "A backup is already running.", detail: nil) }
        moveBackup(BackupProgress(
            running: true, phase: .preparing, copiedBytes: 0, totalBytes: 0, error: nil, path: nil, currentItem: nil))
    }

    func cancelBackup() async {
        chrome6b.calls.append("cancelBackup")
        guard chrome6b.progress.running else { return }
        chrome6b.progress.phase = .stopping
    }

    func backupProgress() async -> BackupProgress { chrome6b.progress }

    func listBackups() async throws -> [BackupInfo] {
        chrome6b.calls.append("listBackups")
        return chrome6b.backups
    }

    func deleteBackup(path: String) async throws {
        chrome6b.calls.append("deleteBackup(\(path))")
        if let error = chrome6b.deleteError { throw error }
        chrome6b.backups.removeAll { $0.path == path }
    }

    func backupDirectory() async -> String { chrome6b.directory }

    func setBackupDirectory(_ path: String) async throws -> String {
        chrome6b.calls.append("setBackupDirectory(\(path))")
        if let error = chrome6b.directoryError { throw error }
        chrome6b.directory = path
        return path
    }

    func ensureBackupDirectory() async throws -> String {
        chrome6b.calls.append("ensureBackupDirectory")
        return chrome6b.directory
    }

    func systemReport() async -> SystemReport {
        chrome6b.calls.append("systemReport")
        return chrome6b.report
    }

    func audioHealth() async -> AudioHealth { chrome6b.health }

    func planNewLibrary() async throws -> NewLibraryPlan? { chrome6b.plan }

    func createLibrary(folder: String?) async throws -> LoadOutcome {
        chrome6b.calls.append("createLibrary(\(folder ?? "nil"))")
        if let error = chrome6b.createError { throw error }
        if chrome6b.createOutcome == .ready { emit(.libraryReady) }
        return chrome6b.createOutcome
    }

    func libraryProblem() async -> LibraryProblem? { chrome6b.problem }
}
