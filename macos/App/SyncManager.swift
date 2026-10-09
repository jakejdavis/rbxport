import Foundation
import Observation
import SwiftUI

/// One row of the Sync Manager's playlist tree.
struct SyncRow: Identifiable, Equatable {
    /// The source list's node id (`pl:3`, `pf:2`).
    let id: String
    /// The core's playlist or folder id.
    let libraryID: String
    let name: String
    let depth: Int
    let isFolder: Bool
}

enum TickState: Equatable {
    case on, off, mixed
}

/// The Sync Manager: which playlists go to which devices, the progress of the run, and what
/// each device said. The selection is in memory only, as in the React window.
@MainActor @Observable
final class SyncManagerModel {
    private let backend: any BackendProtocol
    private let sidebar: SidebarModel
    private let devices: DevicesModel
    private let jobs: ExportJobsModel
    let prefs: DeviceExportPrefs
    private let dialogs: @MainActor () -> Dialogs
    private let notify: @MainActor (String) -> Void
    private let refreshDeviceList: @MainActor () async -> Void

    /// Ticked playlists, by the core's id. Folders are not stored: their state follows their children.
    private(set) var ticked: Set<String> = []
    /// Ticked devices, by mount point.
    private(set) var selectedDevices: Set<String> = []
    private(set) var collapsed: Set<String> = []
    private(set) var states: [String: DeviceSyncState] = [:]
    /// What each device said about the last sync, verify or eject.
    private(set) var results: [String: String] = [:]
    private(set) var statusLines: [String] = []
    private(set) var isSyncing = false
    private(set) var verifying: Set<String> = []
    var expandedDevices: Set<String> = []

    var ejectAfterSync: Bool {
        get { access(keyPath: \.ejectAfterSync); return prefs.ejectAfterSync }
        set { withMutation(keyPath: \.ejectAfterSync) { prefs.ejectAfterSync = newValue } }
    }

    var deleteUnlistedMusic: Bool {
        get { access(keyPath: \.deleteUnlistedMusic); return prefs.deleteUnlistedMusic }
        set { withMutation(keyPath: \.deleteUnlistedMusic) { prefs.deleteUnlistedMusic = newValue } }
    }

    init(
        backend: any BackendProtocol, sidebar: SidebarModel, devices: DevicesModel, jobs: ExportJobsModel,
        prefs: DeviceExportPrefs, dialogs: @escaping @MainActor () -> Dialogs, notify: @escaping @MainActor (String) -> Void,
        refreshDevices: @escaping @MainActor () async -> Void
    ) {
        self.backend = backend
        self.sidebar = sidebar
        self.devices = devices
        self.jobs = jobs
        self.prefs = prefs
        self.dialogs = dialogs
        self.notify = notify
        self.refreshDeviceList = refreshDevices
    }

    // MARK: Playlist tree

    /// Every row of the tree, ignoring collapsed folders.
    var allRows: [SyncRow] {
        var out: [SyncRow] = []
        func walk(_ nodes: [SidebarNode], depth: Int) {
            for node in nodes {
                switch node.kind {
                case .folder:
                    out.append(SyncRow(id: node.id, libraryID: String(node.id.dropFirst(3)), name: node.name, depth: depth, isFolder: true))
                    walk(node.children, depth: depth + 1)
                case .playlist, .smartPlaylist:
                    out.append(SyncRow(id: node.id, libraryID: String(node.id.dropFirst(3)), name: node.name, depth: depth, isFolder: false))
                default: break
                }
            }
        }
        walk(sidebar.section(.playlists).children, depth: 0)
        return out
    }

    /// The rows to draw: everything under a collapsed folder is left out.
    var rows: [SyncRow] {
        var out: [SyncRow] = []
        var hiddenBelow: Int?
        for row in allRows {
            if let limit = hiddenBelow {
                if row.depth > limit { continue }
                hiddenBelow = nil
            }
            out.append(row)
            if row.isFolder && collapsed.contains(row.id) { hiddenBelow = row.depth }
        }
        return out
    }

    /// The playlist ids under a folder row, in tree order.
    private func leaves(under row: SyncRow) -> [String] {
        let all = allRows
        guard let start = all.firstIndex(of: row) else { return [] }
        var out: [String] = []
        for next in all[(start + 1)...] {
            if next.depth <= row.depth { break }
            if !next.isFolder { out.append(next.libraryID) }
        }
        return out
    }

    func tickState(_ row: SyncRow) -> TickState {
        guard row.isFolder else { return ticked.contains(row.libraryID) ? .on : .off }
        let below = leaves(under: row)
        guard !below.isEmpty else { return .off }
        let count = below.filter { ticked.contains($0) }.count
        return count == 0 ? .off : (count == below.count ? .on : .mixed)
    }

    func toggle(_ row: SyncRow) {
        if row.isFolder {
            let below = leaves(under: row)
            if tickState(row) == .on { ticked.subtract(below) } else { ticked.formUnion(below) }
        } else if ticked.contains(row.libraryID) {
            ticked.remove(row.libraryID)
        } else {
            ticked.insert(row.libraryID)
        }
    }

    func toggleCollapsed(_ row: SyncRow) {
        if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
    }

    /// The ticked playlists in tree order, which is the order the stick lists them.
    var selectedPlaylists: [String] { allRows.filter { !$0.isFolder && ticked.contains($0.libraryID) }.map(\.libraryID) }

    func tickAll() { ticked = Set(allRows.filter { !$0.isFolder }.map(\.libraryID)) }

    func clearTicks() { ticked = [] }

    // MARK: Devices

    /// Ticking a device restores the playlists it was last synced with, added to what is ticked.
    func toggleDevice(_ path: String) async {
        if selectedDevices.contains(path) {
            selectedDevices.remove(path)
            return
        }
        selectedDevices.insert(path)
        if states[path] == nil { await loadState(path) }
        if let state = states[path] {
            let known = Set(allRows.map(\.libraryID))
            ticked.formUnion(state.selected.map(\.libraryId).filter { known.contains($0) })
        }
    }

    func loadState(_ path: String) async {
        if let state = try? await backend.deviceSyncState(path: path) { states[path] = state }
    }

    /// Re-lists the volumes and re-reads each one's state; vanished devices leave the selection.
    func refresh() async {
        await refreshDeviceList()
        await devicesChanged()
        for device in devices.devices { await loadState(device.path) }
    }

    func devicesChanged() async {
        let present = Set(devices.devices.map(\.path))
        selectedDevices.formIntersection(present)
        states = states.filter { present.contains($0.key) }
        results = results.filter { present.contains($0.key) }
    }

    var summaryText: String {
        let lists = selectedPlaylists.count
        let sticks = selectedDevices.count
        return "\(lists) playlist\(lists == 1 ? "" : "s") \u{2192} \(sticks) USB device\(sticks == 1 ? "" : "s")"
    }

    var canSync: Bool { !isSyncing && !selectedPlaylists.isEmpty && !selectedDevices.isEmpty }

    func isBusy(_ path: String) -> Bool { jobs.isActive(path: path) || verifying.contains(path) }

    // MARK: Sync

    static let goneMessage = "The selected USB device is no longer connected. Refresh and select it again."
    static let missingMessage = "Export cancelled because files are missing."

    /// SYNC: re-lists the devices, checks the audio is there, then writes every ticked playlist to
    /// every ticked device at once. Never turns on a stick's "automatic" flag.
    func sync() async {
        guard canSync else { return }
        isSyncing = true
        statusLines = []
        defer { isSyncing = false }
        await refresh()
        let destinations = devices.devices.map(\.path).filter { selectedDevices.contains($0) }
        guard !destinations.isEmpty else {
            statusLines = [Self.goneMessage]
            return
        }
        let playlists = selectedPlaylists
        do {
            let missing = try await backend.validateExportFiles(playlistIDs: playlists)
            if !missing.isEmpty {
                let shown = missing.prefix(10).map { "\($0.title)\n\($0.path)" }.joined(separator: "\n\n")
                let more = missing.count > 10 ? "\n\n\u{2026}and \(missing.count - 10) more." : ""
                let proceed = await dialogs().confirm(
                    "\(missing.count) file\(missing.count == 1 ? " is" : "s are") missing", shown + more, "Continue Anyway")
                guard proceed else {
                    statusLines = [Self.missingMessage]
                    return
                }
            }
        } catch {
            statusLines = [describe(error)]
            return
        }
        for path in destinations { results[path] = nil }
        let options = prefs.options(ejectAfterSync: ejectAfterSync)
        do {
            let reports = try await backend.syncDevices(playlistIDs: playlists, destinations: destinations, options: options)
            for report in reports { results[report.path] = Self.text(for: report) }
            statusLines = reports.map { "\(name(of: $0.path)): \(Self.text(for: $0))" }
        } catch {
            statusLines = [describe(error)]
        }
        await refresh()
    }

    static func text(for report: SyncDeviceReport) -> String {
        if let error = report.error { return error }
        if report.ejected { return "Safely ejected." }
        if let reason = report.ejectError { return "Not ejected: \(reason)" }
        guard let done = report.report else { return L10n.t("Sync complete.") }
        return done.skipped.isEmpty ? L10n.t("Sync complete.") : "Sync complete; \(done.skipped.count) skipped (audio missing)."
    }

    func name(of path: String) -> String {
        devices.device(path: path)?.name ?? (path as NSString).lastPathComponent
    }

    /// "Writing to DJ STICK\u{2026}" and the like, from the sync event.
    var progressLine: String? {
        let writing = jobs.syncStates.filter { $0.value == .writing || $0.value == .ejecting }
        guard let first = writing.sorted(by: { $0.key < $1.key }).first else { return nil }
        let verb = first.value == .ejecting ? "Ejecting" : "Writing to"
        return writing.count > 1 ? "\(verb) \(writing.count) devices\u{2026}" : "\(verb) \(name(of: first.key))\u{2026}"
    }

    func cancel(_ path: String) async { await backend.cancelExport(path: path) }

    func cancelAll() async {
        for job in jobs.activeJobs where job.state.canStop { await backend.cancelExport(path: job.path) }
    }

    // MARK: Per-device actions

    /// Reads the stick back with the independent parser.
    func verify(_ path: String) async {
        guard !isBusy(path) else { return }
        verifying.insert(path)
        defer { verifying.remove(path) }
        do {
            let report = try await backend.verifyDevice(path: path)
            if report.ok {
                results[path] = "Verified: \(report.tracks) tracks, \(report.playlists) playlists read back."
            } else {
                let detail = (report.errors + report.missingAudio.map { "Missing audio: \($0)" }).prefix(3).joined(separator: "; ")
                results[path] = "Verification found problems: \(detail)"
            }
        } catch {
            results[path] = describe(error)
        }
    }

    func eject(_ path: String) async {
        guard let device = devices.device(path: path) else { return }
        switch await devices.eject(device, using: backend) {
        case .ejected:
            results[path] = nil
            selectedDevices.remove(path)
            states[path] = nil
            notify("\(device.name): Safely ejected.")
        case .refused(let reason):
            results[path] = reason
        case .failed(let reason):
            results[path] = "Could not eject. \(reason)"
        }
        await refreshDeviceList()
        await devicesChanged()
    }
}

// MARK: - View

struct SyncManagerView: View {
    let model: SyncManagerModel
    let devices: DevicesModel
    let jobs: ExportJobsModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                playlistColumn.frame(minWidth: 260, idealWidth: 320)
                deviceColumn.frame(minWidth: 360, idealWidth: 480)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 440)
        .task { await model.refresh() }
        .accessibilityIdentifier("sync-manager")
    }

    // MARK: Playlists

    private var playlistColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Playlists").font(.headline)
                Spacer()
                Button("All") { model.tickAll() }.buttonStyle(.link)
                Button("None") { model.clearTicks() }.buttonStyle(.link)
            }
            .padding(10)
            Divider()
            if model.rows.isEmpty {
                ContentUnavailableView("No playlists", systemImage: "music.note.list")
            } else {
                List(model.rows) { row in
                    HStack(spacing: 6) {
                        if row.isFolder {
                            Button { model.toggleCollapsed(row) } label: {
                                Image(systemName: model.collapsed.contains(row.id) ? "chevron.right" : "chevron.down").frame(width: 12)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Spacer().frame(width: 12)
                        }
                        Button { model.toggle(row) } label: {
                            Image(systemName: symbol(model.tickState(row)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(row.name)
                        .accessibilityValue(model.tickState(row) == .on ? "ticked" : (model.tickState(row) == .mixed ? "partly ticked" : "not ticked"))
                        Image(systemName: row.isFolder ? "folder" : "music.note").foregroundStyle(.secondary)
                        Text(row.name).lineLimit(1)
                        Spacer()
                    }
                    .padding(.leading, CGFloat(row.depth) * 14)
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggle(row) }
                }
                .listStyle(.plain)
            }
        }
    }

    private func symbol(_ state: TickState) -> String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }

    // MARK: Devices

    private var deviceColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Devices").font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .labelStyle(.iconOnly).buttonStyle(.plain).help("Look for devices again")
            }
            .padding(10)
            Divider()
            if devices.devices.isEmpty {
                ContentUnavailableView("No USB devices", systemImage: "externaldrive", description: Text("Plug in a USB drive to sync to it."))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(devices.devices, id: \.path) { device in
                            DeviceRow(device: device, model: model, jobs: jobs, devices: devices)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                Task { await model.sync() }
            } label: {
                Label(model.isSyncing ? L10n.t("Syncing\u{2026}") : L10n.t("Sync"), systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSync)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("sync-button")
            Toggle("Eject after syncing", isOn: Bindable(model).ejectAfterSync)
            Toggle("Delete unlisted music", isOn: Bindable(model).deleteUnlistedMusic)
                .help("Cut each stick down to the selection and remove the audio no playlist names.")
            if jobs.canStop {
                Button("Stop", systemImage: "stop.circle") { Task { await model.cancelAll() } }
                    .help("Stop after the current file operation finishes")
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let progress = model.progressLine {
                    Text(progress)
                } else if !model.statusLines.isEmpty {
                    Text(model.statusLines.joined(separator: " \u{00B7} ")).lineLimit(2)
                } else {
                    Text(model.summaryText)
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            .accessibilityIdentifier("sync-status")
        }
        .padding(10)
    }
}

private struct DeviceRow: View {
    let device: Device
    let model: SyncManagerModel
    let jobs: ExportJobsModel
    let devices: DevicesModel

    var body: some View {
        let busy = model.isBusy(device.path)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.toggleDevice(device.path) }
                } label: {
                    Image(systemName: model.selectedDevices.contains(device.path) ? "checkmark.square.fill" : "square")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(device.name)
                .accessibilityValue(model.selectedDevices.contains(device.path) ? "ticked" : "not ticked")
                Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).fontWeight(.medium)
                    Text(device.contentsText + (device.spaceText.isEmpty ? "" : " \u{00B7} " + device.spaceText))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if device.hasUnusualFileSystem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("Pioneer DJ recommends FAT32 (this is \(device.fileSystem)).")
                }
                Spacer()
                Button("Verify") { Task { await model.verify(device.path) } }
                    .controlSize(.small).disabled(busy)
                    .help("Read the stick back and check its databases")
                Button("Eject", systemImage: "eject") { Task { await model.eject(device.path) } }
                    .labelStyle(.iconOnly).buttonStyle(.plain).disabled(!devices.canEject(device) || busy)
                    .help(busy ? DevicesModel.busyMessage : "Eject \(device.name)")
            }
            if let used = device.usedFraction {
                ProgressView(value: used).progressViewStyle(.linear).tint(used > 0.9 ? .red : .accentColor)
                    .accessibilityLabel("Storage used")
            }
            if let job = jobs.job(for: device.path), job.state != .done || model.results[device.path] == nil {
                HStack(spacing: 8) {
                    if let fraction = jobs.fraction(for: device.path) {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                    }
                    Text(job.state.label).font(.caption).foregroundStyle(.secondary)
                    if job.state.canStop {
                        Button("Stop", systemImage: "stop.circle") { Task { await model.cancel(device.path) } }
                            .labelStyle(.iconOnly).buttonStyle(.plain).help("Stop after the current file operation finishes")
                    }
                }
                if let failure = jobs.failure(for: device.path) {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            }
            if let result = model.results[device.path] {
                Text(result).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let state = model.states[device.path], !state.onDevice.isEmpty {
                DisclosureGroup(
                    "On device (\(state.onDevice.count))",
                    isExpanded: Binding(
                        get: { model.expandedDevices.contains(device.path) },
                        set: { if $0 { model.expandedDevices.insert(device.path) } else { model.expandedDevices.remove(device.path) } })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(state.onDevice.enumerated()), id: \.offset) { Text($0.element).font(.caption) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

/// The Sync Manager's window scene id.
enum SyncManagerScene {
    static let id = "sync-manager"
}
