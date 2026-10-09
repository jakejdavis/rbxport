import AppKit
import Observation
import SwiftUI

/// Library backups in Settings > Advanced: start, stop, the archives in the folder, delete, the
/// folder itself. The work is the core's (`backups.rs`): this holds what the pane shows, and asks
/// before anything is removed. There is no restore here, as in the React app: an archive carries
/// its own restore script, and RBXport Restore is a separate program.
@MainActor @Observable
final class BackupsModel {
    let backend: any BackendProtocol
    private let dialogs: @MainActor () -> Dialogs
    /// Where messages for the status line go.
    var notify: (String) -> Void
    /// Opens a folder in the Finder; replaced in tests.
    @ObservationIgnored var openFolder: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Shows an archive selected in the Finder; replaced in tests.
    @ObservationIgnored var revealFile: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    private(set) var backups: [BackupInfo] = []
    private(set) var progress: BackupProgress?
    private(set) var directory = ""
    /// The last thing that went wrong (a failed backup, a refused folder), shown in the pane.
    private(set) var error: String?
    private(set) var loaded = false

    init(backend: any BackendProtocol, dialogs: @escaping @MainActor () -> Dialogs, notify: @escaping (String) -> Void = { _ in }) {
        self.backend = backend
        self.dialogs = dialogs
        self.notify = notify
    }

    var isRunning: Bool { progress?.running ?? false }
    /// Stop was pressed and the job has not yet noticed.
    var isStopping: Bool { progress?.phase == .stopping }

    /// 0...1 while the byte total is known, else nil (an indeterminate bar).
    var fraction: Double? {
        guard let progress, progress.running, progress.totalBytes > 0 else { return nil }
        return min(1, Double(progress.copiedBytes) / Double(progress.totalBytes))
    }

    /// The pane's headline for the running job.
    var statusText: String? {
        guard let progress, progress.running else { return nil }
        switch progress.phase {
        case .stopping: return L10n.t("Removing the unfinished backup\u{2026}")
        case .compressing: return L10n.t("Finishing your compressed ZIP backup.")
        case .validating: return L10n.t("Checking the saved files before finishing.")
        default: return L10n.t("Backing up your library")
        }
    }

    /// `12.0 MB of 340.0 MB`, once the total is known.
    var byteText: String? {
        guard let progress, progress.running, progress.totalBytes > 0 else { return nil }
        return "\(CellFormat.bytes(progress.copiedBytes)) of \(CellFormat.bytes(progress.totalBytes))"
    }

    /// What the job is working on (a file name), when the core said.
    var itemText: String? {
        guard let progress, progress.running else { return nil }
        return progress.currentItem
    }

    // MARK: Reading

    /// Reads the folder, the list and where a job has got to.
    func load() async {
        directory = await backend.backupDirectory()
        let current = await backend.backupProgress()
        progress = current.phase == .idle ? nil : current
        await refreshList()
        loaded = true
    }

    func refreshList() async {
        do {
            backups = try await backend.listBackups()
        } catch {
            self.error = Self.message(error)
        }
    }

    /// A progress event from the core.
    func handle(progress new: BackupProgress) {
        progress = new
        switch new.phase {
        case .complete:
            error = nil
            notify("Backup finished.")
            Task { await refreshList() }
        case .failed:
            error = new.error ?? "The backup failed."
        case .cancelled:
            error = nil
            notify(L10n.t("Backup stopped."))
            Task { await refreshList() }
        default: break
        }
    }

    // MARK: Actions

    func start() async {
        guard !isRunning else { return }
        error = nil
        do {
            try await backend.startBackup()
            // The events carry it on; this is the first frame of it.
            progress = BackupProgress(
                running: true, phase: .preparing, copiedBytes: 0, totalBytes: 0, error: nil, path: nil, currentItem: nil)
        } catch {
            self.error = Self.message(error)
        }
    }

    func cancel() async {
        guard isRunning else { return }
        await backend.cancelBackup()
        if var current = progress { current.phase = .stopping; progress = current }
    }

    /// Asks first (it cannot be undone), then removes the archive.
    func delete(_ backup: BackupInfo) async {
        let confirmed = await dialogs().confirm(
            "Delete the backup from \(Self.dateText(backup)) at \(Self.timeText(backup))?", "This cannot be undone.", "Delete")
        guard confirmed else { return }
        do {
            try await backend.deleteBackup(path: backup.path)
            error = nil
            await refreshList()
        } catch {
            self.error = Self.message(error)
        }
    }

    /// Choose default backup folder. Existing archives stay where they are.
    func chooseDirectory() async {
        guard !isRunning else {
            error = L10n.t("Wait for the current backup to finish before changing its folder.")
            return
        }
        guard let url = await dialogs().chooseFolder("Choose default backup folder") else { return }
        do {
            directory = try await backend.setBackupDirectory(url.path)
            error = nil
            await refreshList()
        } catch {
            self.error = Self.message(error)
        }
    }

    /// Opens the backup folder in the Finder, making it first if no backup has been taken yet.
    func showFolder() async {
        do {
            let path = try await backend.ensureBackupDirectory()
            openFolder(URL(fileURLWithPath: path, isDirectory: true))
        } catch {
            self.error = Self.message(error)
        }
    }

    func reveal(_ backup: BackupInfo) { revealFile(URL(fileURLWithPath: backup.path)) }

    /// The core hides an internal error's words behind a stock message and keeps them in the
    /// detail; for backups the detail is what the person needs ("A backup for this minute exists").
    nonisolated static func message(_ error: Error) -> String {
        if case FfiError.Internal(_, let detail) = error, let detail, !detail.isEmpty {
            return detail.hasPrefix("Backup: ") ? String(detail.dropFirst(8)) : detail
        }
        return describe(error)
    }

    // MARK: Formatting

    nonisolated static func date(_ backup: BackupInfo) -> Date {
        Date(timeIntervalSince1970: Double(backup.createdAt) / 1000)
    }
    nonisolated static func dateText(_ backup: BackupInfo) -> String {
        date(backup).formatted(.dateTime.year().month(.abbreviated).day())
    }
    nonisolated static func timeText(_ backup: BackupInfo) -> String {
        date(backup).formatted(.dateTime.hour().minute())
    }
    /// `just now`, `3 minutes ago`: how long ago the newest backup was, as React words it.
    nonisolated static func relativeText(_ backup: BackupInfo, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date(backup)))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return L10n.t("just now") }
        if minutes < 60 { return L10n.t(minutes == 1 ? "{count} minute ago" : "{count} minutes ago", ["count": minutes]) }
        let hours = minutes / 60
        if hours < 24 { return L10n.t(hours == 1 ? "{count} hour ago" : "{count} hours ago", ["count": hours]) }
        let days = hours / 24
        return L10n.t(days == 1 ? "{count} day ago" : "{count} days ago", ["count": days])
    }
}

extension BackupInfo: Identifiable {
    public var id: String { path }
}

// MARK: - View

/// The Backups section of the Advanced pane.
struct BackupsSection: View {
    let model: BackupsModel

    var body: some View {
        Section("Backups") {
            LabeledContent("Backup folder") {
                HStack {
                    Text(model.directory).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Change\u{2026}") { Task { await model.chooseDirectory() } }
                        .disabled(model.isRunning)
                    Button("Show in Finder") { Task { await model.showFolder() } }
                }
            }
            .accessibilityIdentifier("backup-folder")

            if model.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.statusText ?? L10n.t("Backing up your library")).font(.headline)
                    if let fraction = model.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text(model.byteText ?? "").monospacedDigit()
                        if let item = model.itemText {
                            Text(item).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(model.isStopping ? L10n.t("Stopping\u{2026}") : L10n.t("Stop backup")) { Task { await model.cancel() } }
                            .disabled(model.isStopping)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text("You can keep using RBXport while this runs.").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("backup-progress")
            } else {
                HStack {
                    Button("Back Up Now") { Task { await model.start() } }
                        .accessibilityIdentifier("backup-start")
                    if let newest = model.backups.first {
                        Text("Last backup \(BackupsModel.relativeText(newest))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("backup-error")
            }

            if model.backups.isEmpty {
                Text("No backups yet.").foregroundStyle(.secondary).accessibilityIdentifier("backup-empty")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Date"); Text("Time"); Text("Size"); Text("")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.backups) { backup in
                        GridRow {
                            Text(BackupsModel.dateText(backup))
                            Text(BackupsModel.timeText(backup)).monospacedDigit()
                            Text(CellFormat.bytes(backup.bytes)).monospacedDigit()
                            HStack {
                                Button("Show", systemImage: "magnifyingglass") { model.reveal(backup) }
                                    .labelStyle(.iconOnly).help("Show in Finder")
                                Button("Delete", systemImage: "trash") { Task { await model.delete(backup) } }
                                    .labelStyle(.iconOnly).help("Delete this backup")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .accessibilityIdentifier("backup-list")
            }
            Text("Backups hold your database, analysis and artwork, not your music. To restore, quit RBXport and open RBXport Restore, or run the restore script inside the archive.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.load() }
    }
}
