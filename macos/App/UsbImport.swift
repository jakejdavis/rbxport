import Foundation
import Observation
import SwiftUI

/// What the "Import from USB" sheet can bring in, in the order it is done.
enum UsbImportKind: String, CaseIterable, Identifiable, Sendable {
    case cues, history, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cues: L10n.t("Cues and beat grids")
        case .history: L10n.t("Play history")
        case .settings: L10n.t("CDJ/mixer settings")
        }
    }

    /// What the failure line calls it.
    var noun: String {
        switch self {
        case .cues: "cues and beat grids"
        case .history: "play history"
        case .settings: L10n.t("CDJ/mixer settings")
        }
    }

    var detail: String {
        switch self {
        case .cues: "Replaces the cues and beat grids of matching tracks in your library."
        case .history: "Adds the sessions played on the device as history playlists."
        case .settings: "Keeps a copy of the device\u{2019}s CDJ and mixer settings files."
        }
    }

    /// Cues and history write the library; settings only copy files into the app\u{2019}s data folder.
    var writesLibrary: Bool { self != .settings }
}

/// The Import from USB sheet: which kinds to bring in from one stick, the run, and what each said.
/// Tracks are matched by identity (the stick\u{2019}s export of this library), never by title.
@MainActor @Observable
final class UsbImportModel: Identifiable {
    enum Phase: Equatable { case choosing, running, finished }

    /// One line of the summary.
    struct Line: Identifiable, Equatable {
        enum Level: Equatable { case ok, warning, failed }
        let id: Int
        let kind: UsbImportKind?
        let text: String
        let level: Level
    }

    static let confirmMessage = "Import cue and beat-grid changes from this USB device?"
    static let confirmDetail = "This replaces cues and grids for matching tracks in your library."

    let path: String
    let deviceName: String
    private let backend: any BackendProtocol
    private let prefs: DeviceExportPrefs
    private let dialogs: @MainActor () -> Dialogs
    /// Why a kind cannot run right now (Library Protection, rekordbox open), or nil.
    private let blockReason: @MainActor (UsbImportKind) -> String?
    /// Told when a run starts and ends, so the status bar can follow the core\u{2019}s progress.
    private let busy: @MainActor (Bool) -> Void
    private let didImport: @MainActor () async -> Void

    private(set) var phase: Phase = .choosing
    private(set) var ticked: Set<UsbImportKind>
    private(set) var lines: [Line] = []
    private(set) var current: UsbImportKind?
    /// What the run brought in, summed over the kinds that succeeded.
    private(set) var totals = UsbImportReport(tracks: 0, histories: 0, settings: 0, skipped: 0, warnings: [])
    private(set) var failed = false

    init(
        path: String, deviceName: String, backend: any BackendProtocol, prefs: DeviceExportPrefs,
        dialogs: @escaping @MainActor () -> Dialogs, blockReason: @escaping @MainActor (UsbImportKind) -> String?,
        busy: @escaping @MainActor (Bool) -> Void = { _ in }, didImport: @escaping @MainActor () async -> Void = {}
    ) {
        self.path = path
        self.deviceName = deviceName
        self.backend = backend
        self.prefs = prefs
        self.dialogs = dialogs
        self.blockReason = blockReason
        self.busy = busy
        self.didImport = didImport
        var initial: Set<UsbImportKind> = []
        if prefs.importButtonCues { initial.insert(.cues) }
        if prefs.importButtonHistory { initial.insert(.history) }
        if prefs.importButtonSettings { initial.insert(.settings) }
        ticked = initial
    }

    func blocked(_ kind: UsbImportKind) -> String? { blockReason(kind) }

    func isTicked(_ kind: UsbImportKind) -> Bool { ticked.contains(kind) && blocked(kind) == nil }

    func set(_ kind: UsbImportKind, _ on: Bool) {
        guard blocked(kind) == nil else { return }
        if on { ticked.insert(kind) } else { ticked.remove(kind) }
        switch kind {
        case .cues: prefs.importButtonCues = on
        case .history: prefs.importButtonHistory = on
        case .settings: prefs.importButtonSettings = on
        }
    }

    /// The kinds a run would do, in order.
    var plan: [UsbImportKind] { UsbImportKind.allCases.filter(isTicked) }

    var canRun: Bool { phase == .choosing && !plan.isEmpty }

    /// Back to the choices, keeping the ticks (Try Again, or to change them).
    func reset() {
        phase = .choosing
        lines = []
        failed = false
        totals = UsbImportReport(tracks: 0, histories: 0, settings: 0, skipped: 0, warnings: [])
    }

    /// Cues replace work, so they ask first; the other kinds go straight ahead.
    func run() async {
        let kinds = plan
        guard phase == .choosing, !kinds.isEmpty else { return }
        if kinds.contains(.cues) {
            let proceed = await dialogs().confirm(Self.confirmMessage, Self.confirmDetail, "Import")
            guard proceed else { return }
        }
        phase = .running
        lines = []
        failed = false
        busy(true)
        // One kind at a time, so each is reported on its own and one that fails does not keep
        // the others from being brought in.
        for kind in kinds {
            current = kind
            do {
                let report = try await backend.importUSB(
                    path: path, cues: kind == .cues, history: kind == .history, settings: kind == .settings)
                add(kind: kind, text: Self.text(for: kind, report), level: .ok)
                for warning in report.warnings { add(kind: kind, text: warning, level: .warning) }
                totals.tracks += report.tracks
                totals.histories += report.histories
                totals.settings += report.settings
                totals.skipped += report.skipped
                totals.warnings += report.warnings
            } catch {
                failed = true
                add(kind: kind, text: "Couldn\u{2019}t import \(kind.noun). \(describe(error))", level: .failed)
            }
        }
        current = nil
        busy(false)
        phase = .finished
        await didImport()
    }

    private func add(kind: UsbImportKind, text: String, level: Line.Level) {
        lines.append(Line(id: lines.count, kind: kind, text: text, level: level))
    }

    /// The words for one kind\u{2019}s result, as the React Sync Manager says them.
    static func text(for kind: UsbImportKind, _ report: UsbImportReport) -> String {
        func plural(_ n: UInt32, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        switch kind {
        case .cues:
            return "Updated \(plural(report.tracks, "track"))" + (report.skipped > 0 ? "; skipped \(report.skipped)." : ".")
        case .history:
            return report.histories > 0
                ? (report.histories == 1 ? "Imported 1 play-history entry." : "Imported \(report.histories) play-history entries.")
                : "No new play-history entries."
        case .settings:
            return report.settings > 0
                ? "Imported \(plural(report.settings, "CDJ/mixer settings file"))." : "No CDJ/mixer settings files found."
        }
    }

    /// The headline of the finished sheet.
    var summaryTitle: String {
        failed ? "Import finished with problems" : "Import complete"
    }
}

// MARK: - App model

extension AppModel {
    /// Why Library Protection or a running rekordbox stops a kind, in the words the sheet shows.
    func usbBlockReason(_ kind: UsbImportKind) -> String? {
        guard kind.writesLibrary else { return nil }
        if protectLibrary { return "Turn off Library Protection to import \(kind.noun)." }
        if !canEdit { return "Quit rekordbox to import \(kind.noun)." }
        return nil
    }

    /// Opens the Import from USB sheet for a device. Refused when it is gone.
    func openUsbImport(path: String) {
        guard let device = devices.device(path: path) else {
            notice = L10n.t("That device is no longer connected.")
            return
        }
        guard !exportJobs.isActive(path: path) else {
            notice = "An export to \(device.name) is running. Wait for it to finish."
            return
        }
        usbImport = UsbImportModel(
            path: path, deviceName: device.name, backend: backend, prefs: exportPrefs,
            dialogs: { [weak self] in self?.dialogs ?? .live },
            blockReason: { [weak self] kind in self?.usbBlockReason(kind) },
            busy: { [weak self] on in
                self?.importInFlight = on
                self?.importProgress = on ? ImportProgressState(done: 0, total: 0, title: "") : nil
            },
            didImport: { [weak self] in await self?.refreshDevices() })
    }

    /// File > Import > USB Device: the selected device, or the only one.
    func openUsbImportFromMenu() {
        if let device = selectedDevice {
            openUsbImport(path: device.path)
        } else if devices.devices.count == 1, let only = devices.devices.first {
            openUsbImport(path: only.path)
        } else if devices.devices.isEmpty {
            notice = "No USB device is connected."
        } else {
            notice = "Select a device in the Devices list first."
        }
    }

    func closeUsbImport() { usbImport = nil }
}

// MARK: - View

struct UsbImportSheet: View {
    let model: UsbImportModel
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.phase == .finished ? model.summaryTitle : "Import from \(model.deviceName)").font(.headline)
                Text(model.phase == .finished ? "From \(model.deviceName)" : "Bring what was changed on this device back into your library.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            switch model.phase {
            case .choosing: choices
            case .running: running
            case .finished: summary
            }
            Divider()
            buttons
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityIdentifier("usb-import-sheet")
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(UsbImportKind.allCases) { kind in
                let reason = model.blocked(kind)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(
                        kind.label,
                        isOn: Binding(get: { model.isTicked(kind) }, set: { model.set(kind, $0) })
                    )
                    .disabled(reason != nil)
                    Text(reason ?? kind.detail)
                        .font(.caption).foregroundStyle(reason == nil ? Color.secondary : Color.orange)
                        .padding(.leading, 20)
                }
                .help(reason ?? "")
            }
            if model.isTicked(.cues) {
                Label(UsbImportModel.confirmDetail, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = app.importProgress?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text("Importing \(model.current?.noun ?? "")\u{2026}").font(.callout).foregroundStyle(.secondary)
            if let title = app.importProgress?.title, !title.isEmpty {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(line.level)).foregroundStyle(color(line.level))
                    VStack(alignment: .leading, spacing: 1) {
                        if let kind = line.kind, line.level != .warning { Text(kind.label).font(.callout.weight(.medium)) }
                        Text(line.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityIdentifier("usb-import-summary")
    }

    private func symbol(_ level: UsbImportModel.Line.Level) -> String {
        switch level {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func color(_ level: UsbImportModel.Line.Level) -> Color {
        switch level {
        case .ok: .green
        case .warning: .orange
        case .failed: .red
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            switch model.phase {
            case .choosing:
                Button("Cancel") { app.closeUsbImport() }.keyboardShortcut(.cancelAction)
                Button("Import") { Task { await model.run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRun)
                    .accessibilityIdentifier("usb-import-run")
            case .running:
                ProgressView().controlSize(.small)
            case .finished:
                if model.failed { Button("Try Again") { model.reset() } }
                Button("Done") { app.closeUsbImport() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
