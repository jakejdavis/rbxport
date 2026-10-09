import AppKit
import Observation
import SwiftUI

/// Everything the Report a Problem window shows, and the text "Copy Report" puts on the
/// pasteboard. Built on this computer from the core's readings; nothing is sent anywhere.
struct DiagnosticsReport: Equatable, Sendable {
    var system: SystemReport
    var health: AudioHealth
    /// The library as loaded, or nil with `libraryNote` saying why not.
    var library: LibrarySummary?
    var libraryNote: String?
    var generated: Date

    /// The report as plain text: System information, Library, then the log (verbatim, as React's
    /// attachment carries it, because the person reads it before deciding to share it).
    func text(timeZone: TimeZone = .current) -> String {
        var lines = ["rbxport diagnostics", "Generated: \(Self.stamp(generated, timeZone: timeZone))", ""]
        lines += systemLines
        lines += [""]
        lines += libraryLines
        lines += ["", "Application log (latest file)"]
        if let path = system.logPath { lines.append(path) }
        lines += ["", system.logTail]
        return lines.joined(separator: "\n")
    }

    var systemLines: [String] {
        let s = system
        var lines = [
            "System information",
            "rbxport \(s.appVersion)",
            "OS: \(s.os) \(s.osVersion)".trimmingCharacters(in: .whitespaces),
            "Architecture: \(s.arch)",
            "Process CPU: \(String(format: "%.1f", Double(s.cpu)))% of one core",
            "Resident memory: \(String(format: "%.1f", s.memoryMb)) MiB",
        ]
        if let threads = s.threads { lines.append("Threads: \(threads)") }
        if let files = s.openFiles { lines.append("Open files: \(files)") }
        lines.append("Audio deadline load: \(String(format: "%.1f", Double(health.load) * 100))%")
        lines.append("Audio callback overruns: \(health.xruns)")
        return lines
    }

    var libraryLines: [String] {
        guard let library else { return ["Library", libraryNote ?? "Not loaded."] }
        var lines = [
            "Library",
            "Tracks: \(library.trackCount)",
            "Playlists: \(library.playlistCount)",
            "Mode: \(library.readOnly ? "Read-only" : "Read-write")",
        ]
        if let version = library.dbVersion { lines.append("Schema version: \(version)") }
        lines.append("Loaded in \(library.loadMs) ms")
        return lines
    }

    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        return String(
            format: "%04d-%02d-%02d %02d:%02d %@%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, sign,
            abs(offset) / 3600, abs(offset) % 3600 / 60)
    }
}

/// The Report a Problem window's model.
@MainActor @Observable
final class BugReportModel {
    let backend: any BackendProtocol
    /// The library summary and why there is none, read when the report is made.
    private let library: @MainActor () -> (summary: LibrarySummary?, note: String?)
    @ObservationIgnored var now: () -> Date = { Date() }
    /// Puts text on the pasteboard; replaced in tests.
    @ObservationIgnored var copy: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// Shows a file selected in the Finder; replaced in tests.
    @ObservationIgnored var revealFile: (URL) -> Void = { revealInFileViewer([$0]) }

    private(set) var report: DiagnosticsReport?
    private(set) var isLoading = false
    /// Set by Copy Report, for the button to say so.
    private(set) var copied = false
    private(set) var message: String?

    init(backend: any BackendProtocol, library: @escaping @MainActor () -> (summary: LibrarySummary?, note: String?)) {
        self.backend = backend
        self.library = library
    }

    var text: String { report?.text() ?? "" }
    var canRevealLog: Bool { report?.system.logPath != nil }

    /// Reads the diagnostics again (the window opens on a fresh one each time it is shown).
    func refresh() async {
        isLoading = true
        copied = false
        async let system = backend.systemReport()
        async let health = backend.audioHealth()
        let (s, h) = await (system, health)
        let lib = library()
        report = DiagnosticsReport(system: s, health: h, library: lib.summary, libraryNote: lib.note, generated: now())
        isLoading = false
    }

    func copyReport() {
        guard report != nil else { return }
        copy(text)
        copied = true
        message = "Report copied. It has not been sent anywhere."
    }

    func revealLog() {
        guard let path = report?.system.logPath else {
            message = L10n.t("No application log was found.")
            return
        }
        revealFile(URL(fileURLWithPath: path))
    }
}

/// The window's id, for `openWindow` and the Help menu.
enum BugReportScene {
    static let id = "report"
}

struct BugReportView: View {
    let model: BugReportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a Problem").font(.title2.bold())
            Text("This is what rbxport knows about this computer and this session. Nothing is sent: copy it into an email or an issue yourself. The log may include library paths and track titles.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let report = model.report {
                HStack(alignment: .top, spacing: 32) {
                    ReportLines(lines: report.systemLines)
                    ReportLines(lines: report.libraryLines)
                    Spacer(minLength: 0)
                }
                .textSelection(.enabled)
                .accessibilityIdentifier("report-summary")
                Text("Application log (latest file)").font(.headline)
                ScrollView {
                    Text(report.system.logTail)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .defaultScrollAnchor(.bottom)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .accessibilityIdentifier("report-log")
            } else {
                ProgressView("Reading diagnostics\u{2026}").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                Button("Reveal Log") { model.revealLog() }.disabled(!model.canRevealLog)
                Button(model.copied ? "Copied" : "Copy Report") { model.copyReport() }
                    .keyboardShortcut(.defaultAction).disabled(model.report == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
        .task { await model.refresh() }
    }
}

/// A heading and the lines under it.
private struct ReportLines: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line).font(index == 0 ? .callout.bold() : .callout.monospaced())
            }
        }
    }
}
