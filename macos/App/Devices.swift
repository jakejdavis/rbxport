import AppKit
import Foundation
import Observation

// MARK: - Preferences

/// The export preferences, kept in the preferences store under the names the React app used
/// (`usbExport.*`, `djSystem.*`). The dead "Setup PIONEER folder" switch is not carried over.
@MainActor struct DeviceExportPrefs {
    let store: PreferencesStore

    init(store: PreferencesStore) { self.store = store }

    init(defaults: UserDefaults) { store = PreferencesStore(defaults: defaults) }

    /// The ticks the Import from USB sheet opens with (the React names; cues and history on, settings off).
    var importButtonCues: Bool {
        get { store.importButtonCues }
        nonmutating set { store.importButtonCues = newValue }
    }
    var importButtonHistory: Bool {
        get { store.importButtonHistory }
        nonmutating set { store.importButtonHistory = newValue }
    }
    var importButtonSettings: Bool {
        get { store.importButtonSettings }
        nonmutating set { store.importButtonSettings = newValue }
    }

    /// Cuts a stick down to the selection, removing unlisted music. Off by default.
    var deleteUnlistedMusic: Bool {
        get { store.deleteUnlistedMusic }
        nonmutating set { store.deleteUnlistedMusic = newValue }
    }

    var ejectAfterSync: Bool {
        get { store.ejectAfterSync }
        nonmutating set { store.ejectAfterSync = newValue }
    }

    /// Maximum CDJ compatibility: convert formats a player cannot read on export.
    var maximumCompatibility: Bool {
        get { store.maximumCompatibility }
        nonmutating set { store.maximumCompatibility = newValue }
    }

    var conversionFormat: CompatibilityFormat {
        get {
            switch store.conversionFormat {
            case .aiff: .aiff
            case .mp3: .mp3
            case .wav: .wav
            }
        }
        nonmutating set {
            store.conversionFormat =
                switch newValue {
                case .wav: .wav
                case .aiff: .aiff
                case .mp3: .mp3
                }
        }
    }

    /// What a stick with no settings of its own is given (the DJ System defaults).
    var stickDefaults: StickDefaults {
        let color: WaveformColor =
            switch store.djWaveformColor {
            case .blue: .blue
            case .rgb: .rgb
            case .threeBand: .threeBand
            }
        return StickDefaults(
            waveformColor: color,
            waveformPosition: store.djWaveformPosition == .left ? .left : .center,
            overviewWaveform: store.djOverview == .full ? .full : .half,
            keyDisplay: store.djKeyDisplay == .alphanumeric ? .alphanumeric : .classic)
    }

    func options(ejectAfterSync eject: Bool = false) -> ExportOptions {
        ExportOptions(
            defaults: stickDefaults, deleteUnlistedMusic: deleteUnlistedMusic,
            compatibility: maximumCompatibility ? conversionFormat : nil, ejectAfterSync: eject)
    }
}

// MARK: - Progress

extension ExportState {
    /// A job in one of these states is writing to, or ejecting, the stick.
    var isActive: Bool {
        switch self {
        case .done, .cancelled, .failed: false
        default: true
        }
    }

    /// Stop is offered until the databases are written; after that the export finishes.
    var canStop: Bool {
        switch self {
        case .preparing, .checking, .copying, .database: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .preparing: "Preparing"
        case .checking: "Checking files"
        case .copying: "Copying"
        case .database: "Writing database"
        case .verifying: "Verifying"
        case .publishing: "Publishing"
        case .ejecting: "Ejecting"
        case .done: "Done"
        case .cancelled: "Stopped"
        case .failed: "Failed"
        }
    }
}

/// Where every export and sync has got to, by device path. Fed by the core's events.
@MainActor @Observable
final class ExportJobsModel {
    private(set) var jobs: [String: ExportProgress] = [:]
    private(set) var syncStates: [String: SyncState] = [:]
    /// Device name for a path, for the status text. Set by the app model.
    @ObservationIgnored var nameFor: (String) -> String = { ($0 as NSString).lastPathComponent }
    /// Called when a device becomes busy or free, so its sidebar row can dim its Eject button.
    @ObservationIgnored var onActivityChange: () -> Void = {}

    /// Progress from the core. A new batch (a job starting while none is active) replaces the
    /// finished jobs of the last one, as the core does.
    func handle(progress: ExportProgress) {
        if progress.state == .preparing && !isActive { jobs.removeAll() }
        let was = isActive(path: progress.path)
        jobs[progress.path] = progress
        if was != progress.state.isActive { onActivityChange() }
    }

    /// A sync step. The first stick to start writing while none is replaces the last run's outcomes;
    /// the others of the same run (they start together) keep them.
    func handle(sync: SyncProgress) {
        if sync.state == .writing, !syncStates.values.contains(where: { $0 == .writing || $0 == .ejecting }) {
            syncStates.removeAll()
        }
        syncStates[sync.path] = sync.state
    }

    /// Adopts the core's snapshot, for a UI that started after an export did.
    func seed(_ snapshot: [ExportProgress]) {
        for item in snapshot where jobs[item.path] == nil { jobs[item.path] = item }
    }

    var isActive: Bool { jobs.values.contains { $0.state.isActive } }
    func isActive(path: String) -> Bool { jobs[path]?.state.isActive ?? false }
    func isSyncing(path: String) -> Bool { syncStates[path].map { $0 == .writing || $0 == .ejecting } ?? false }
    func job(for path: String) -> ExportProgress? { jobs[path] }

    var activeJobs: [ExportProgress] { jobs.values.filter { $0.state.isActive }.sorted { $0.path < $1.path } }

    /// Done tracks over all tracks of the batch, held under 1 until every job has finished.
    var fraction: Double? {
        let total = jobs.values.reduce(0) { $0 + Double($1.total) }
        guard total > 0 else { return nil }
        let done = jobs.values.reduce(0) { $0 + Double($1.state == .done ? $1.total : $1.done) }
        let raw = done / total
        return isActive ? min(raw, 0.99) : raw
    }

    func fraction(for path: String) -> Double? {
        guard let job = jobs[path], job.total > 0 else { return nil }
        if job.state == .done { return 1 }
        return min(Double(job.done) / Double(job.total), job.state.isActive ? 0.99 : 1)
    }

    /// One line for the status bar: nil when nothing is running.
    var statusText: String? {
        let active = activeJobs
        guard !active.isEmpty else { return nil }
        if active.count == 1, let job = active.first {
            var text = "\(job.state.label) \(nameFor(job.path))"
            if job.state == .copying || job.state == .checking, job.total > 0 { text += ": \(job.done) of \(job.total)" }
            if job.state == .copying, !job.title.isEmpty { text += " \u{00B7} \(job.title)" }
            return text + "\u{2026}"
        }
        let percent = Int(((fraction ?? 0) * 100).rounded(.down))
        return "Exporting to \(active.count) devices: \(percent)%"
    }

    /// What a failed job says: the reason, or the usual advice when the core gave none.
    func failure(for path: String) -> String? {
        guard let job = jobs[path], job.state == .failed else { return nil }
        return job.title.isEmpty
            ? L10n.t("The export failed before the device could be verified. Check that it is connected, writable, and has enough free space.")
            : job.title
    }

    var canStop: Bool { activeJobs.contains { $0.state.canStop } }

    func clearFinished() {
        jobs = jobs.filter { $0.value.state.isActive }
        syncStates = syncStates.filter { $0.value == .writing || $0.value == .ejecting }
    }
}

/// The words after an export, so every place says the same thing.
enum ExportSummary {
    static func text(_ report: ExportReport, device: String) -> String {
        func plural(_ n: UInt32, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        var parts = ["\(plural(report.tracks, "track")) on \(device)"]
        if report.playlists > 0 { parts.append(plural(report.playlists, "playlist")) }
        if !report.skipped.isEmpty { parts.append("\(report.skipped.count) skipped (audio missing)") }
        if !report.verified { parts.append("could not be verified") }
        return "Exported: " + parts.joined(separator: ", ") + "."
    }
}

// MARK: - The device list

/// The mounted volumes, and ejecting one.
@MainActor @Observable
final class DevicesModel {
    private(set) var devices: [Device] = []
    private(set) var ejecting: Set<String> = []
    let jobs: ExportJobsModel

    init(jobs: ExportJobsModel) { self.jobs = jobs }

    static let busyMessage = "This device is being exported to. Wait for the export to finish."

    enum EjectOutcome: Equatable {
        case ejected
        case refused(String)
        case failed(String)
    }

    func set(_ devices: [Device]) {
        self.devices = devices
        ejecting.formIntersection(devices.map(\.path))
    }

    func device(path: String) -> Device? { devices.first { $0.path == path } }

    func canEject(_ device: Device) -> Bool { !jobs.isActive(path: device.path) && !ejecting.contains(device.path) }

    /// Ejects through the core. Refused here, without asking the core, while a job on the device
    /// is in flight (the core refuses too).
    func eject(_ device: Device, using backend: any BackendProtocol) async -> EjectOutcome {
        guard canEject(device) else { return .refused(Self.busyMessage) }
        ejecting.insert(device.path)
        defer { ejecting.remove(device.path) }
        do {
            try await backend.ejectDevice(path: device.path)
            return .ejected
        } catch {
            return .failed(describe(error))
        }
    }
}

extension Device {
    /// "62.4 GB free of 64.0 GB"-style text for a capacity line; empty when the size is unknown.
    var spaceText: String {
        guard totalBytes > 0 else { return "" }
        return "\(CellFormat.bytes(freeBytes)) free of \(CellFormat.bytes(totalBytes))"
    }

    /// Pioneer recommends FAT32 for players.
    var hasUnusualFileSystem: Bool {
        let name = fileSystem.uppercased()
        return !name.isEmpty && !name.hasPrefix("FAT32") && name != "VFAT" && name != "MS-DOS FAT32"
    }

    /// Used fraction for a capacity bar; nil when the size is unknown.
    var usedFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(totalBytes - min(freeBytes, totalBytes)) / Double(totalBytes))
    }

    /// What the stick holds, as one line.
    var contentsText: String {
        guard let export else { return "No export" }
        let tracks = "\(export.tracks) track\(export.tracks == 1 ? "" : "s")"
        let lists = "\(export.playlists) playlist\(export.playlists == 1 ? "" : "s")"
        return "\(tracks), \(lists)"
    }
}

// MARK: - App model glue

/// A device the export menus offer.
struct DeviceTarget: Equatable, Sendable {
    let path: String
    let name: String
}

extension AppModel {
    static let deviceNodePrefix = "dev:"

    /// The devices the Export menus offer, in list order.
    var deviceTargets: [DeviceTarget] { devices.devices.map { DeviceTarget(path: $0.path, name: $0.name) } }

    /// The device the sidebar has selected, if one is.
    var selectedDevice: Device? {
        guard let id = selectedNodeID, id.hasPrefix(Self.deviceNodePrefix) else { return nil }
        return devices.device(path: String(id.dropFirst(Self.deviceNodePrefix.count)))
    }

    /// Re-lists the volumes (the sidebar and the Sync Manager read the result).
    func refreshDevices() async {
        guard let list = try? await backend.listDevices() else { return }
        sidebar.setDevices(list)
    }

    /// The core said volumes changed. A device that vanished while selected drops the selection.
    func devicesChanged() async {
        await refreshDevices()
        if let id = selectedNodeID, id.hasPrefix(Self.deviceNodePrefix), selectedDevice == nil {
            selectedNodeID = "all"
        }
        await syncManager.devicesChanged()
    }

    /// Writes a playlist to a device. Needs no write access to the library: only the stick changes.
    @discardableResult
    func exportPlaylist(id playlistID: String, to path: String) async -> ExportReport? {
        guard let device = devices.device(path: path) else {
            notice = L10n.t("That device is no longer connected.")
            return nil
        }
        guard !exportJobs.isActive(path: path) else {
            notice = "An export to \(device.name) is already running."
            return nil
        }
        let options = exportPrefs.options()
        do {
            let report = try await backend.exportPlaylistToDevice(playlistID: playlistID, destination: path, options: options)
            notice = ExportSummary.text(report, device: device.name)
            await deviceWritten(path)
            return report
        } catch {
            notice = exportFailureText(error)
            await deviceWritten(path)
            return nil
        }
    }

    /// Export Track: puts tracks on the device in no playlist.
    @discardableResult
    func exportTracks(_ ids: [String], to path: String) async -> ExportReport? {
        let tracks = ids.filter { !Self.isLoose($0) }
        guard !tracks.isEmpty else {
            notice = "Import the file to the collection before exporting it to a device."
            return nil
        }
        guard let device = devices.device(path: path) else {
            notice = L10n.t("That device is no longer connected.")
            return nil
        }
        guard !exportJobs.isActive(path: path) else {
            notice = "An export to \(device.name) is already running."
            return nil
        }
        do {
            let report = try await backend.exportTracksToDevice(trackIDs: tracks, destination: path, options: exportPrefs.options())
            notice = ExportSummary.text(report, device: device.name)
            await deviceWritten(path)
            return report
        } catch {
            notice = exportFailureText(error)
            await deviceWritten(path)
            return nil
        }
    }

    private func exportFailureText(_ error: Error) -> String {
        if let ffi = error as? FfiError, case .Cancelled = ffi { return L10n.t("Export stopped.") }
        return "Export failed: \(describe(error))"
    }

    /// A stick was written: re-read the list (it holds an export now) and the open panel.
    func deviceWritten(_ path: String) async {
        await refreshDevices()
        if selectedDevice?.path == path { await devicePanel?.load() }
    }

    func cancelExport(path: String) {
        let backend = backend
        Task { await backend.cancelExport(path: path) }
    }

    func cancelAllExports() {
        for job in exportJobs.activeJobs where job.state.canStop { cancelExport(path: job.path) }
    }

    /// Eject, with the words the status line says after it. Refused while the device is busy.
    @discardableResult
    func eject(path: String) async -> DevicesModel.EjectOutcome? {
        guard let device = devices.device(path: path) else { return nil }
        let outcome = await devices.eject(device, using: backend)
        switch outcome {
        case .ejected: notice = "\(device.name): Safely ejected."
        case .refused(let reason): notice = reason
        case .failed(let reason): notice = "\(device.name): Could not eject. \(reason)"
        }
        await refreshDevices()
        if case .ejected = outcome, selectedDevice == nil, selectedNodeID?.hasPrefix(Self.deviceNodePrefix) == true {
            selectedNodeID = "all"
        }
        return outcome
    }

    /// Acts on a device entry of a source-list menu.
    func runDeviceMenu(_ command: MenuCommand, on node: SidebarNode) {
        switch command {
        case .exportToDevice(let path):
            guard let playlist = node.libraryID else { return }
            Task { await exportPlaylist(id: playlist, to: path) }
        case .ejectDevice:
            if let path = node.path { Task { await eject(path: path) } }
        case .importFromDevice:
            if let path = node.path { openUsbImport(path: path) }
        case .openSyncManager:
            openSyncManager()
        default: break
        }
    }

    func openSyncManager() { syncWindowRequests += 1 }
}
