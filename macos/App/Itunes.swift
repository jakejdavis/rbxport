import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// One row of the iTunes / Music playlist tree.
struct ItunesRow: Identifiable, Equatable {
    /// `itunes:<index>`, which the core takes back to name the playlist.
    let id: String
    let name: String
    let depth: Int
    let isFolder: Bool
    let trackCount: UInt32?
}

/// The iTunes / Music library browser: its playlists to tick and its tracks to look at, read-only.
/// Importing the ticked playlists goes through the core\u{2019}s write gate.
///
/// The XML is `Library.xml` from Music\u{2019}s "Share Library XML with other applications". React has no
/// preference for its path (it detects the usual place, or asks), and nor does this: the last file
/// chosen is remembered so the next launch opens it.
@MainActor @Observable
final class ItunesModel {
    static let pathKey = "itunes.libraryPath"
    static let nothingFound =
        "No iTunes or Music library was found. Turn on \u{201C}Share Library XML with other applications\u{201D} in Music, then choose the file."
    static let noPlaylists = "This iTunes library has no playlists."
    static let selectOne = "Select at least one iTunes playlist to import."

    private let backend: any BackendProtocol
    private let defaults: UserDefaults
    private let dialogs: @MainActor () -> Dialogs
    private let notify: @MainActor (String) -> Void
    private let busy: @MainActor (Bool) -> Void

    private(set) var library: ItunesLibrary?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var ticked: Set<String> = []
    private(set) var collapsed: Set<String> = []
    /// The playlist whose tracks are listed.
    private(set) var selectedID: String?
    private(set) var tracks: [ItunesTrack] = []
    private(set) var isImporting = false
    /// The last import\u{2019}s one-line summary.
    private(set) var resultLine: String?
    @ObservationIgnored private var started = false
    /// A fixture library is loaded: nothing is remembered, so a test run leaves no trace in the preferences.
    @ObservationIgnored private var isFixture = true
    @ObservationIgnored private var trackToken = 0

    init(
        backend: any BackendProtocol, defaults: UserDefaults, dialogs: @escaping @MainActor () -> Dialogs,
        notify: @escaping @MainActor (String) -> Void, busy: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.backend = backend
        self.defaults = defaults
        self.dialogs = dialogs
        self.notify = notify
        self.busy = busy
    }

    // MARK: Loading

    /// The first time the node is shown: the file chosen last time, else the usual place. Neither is
    /// looked at while a fixture library is loaded, so a test run never reads the real Music library.
    func openIfNeeded() async {
        guard !started else { return }
        started = true
        isFixture = await backend.isFixtureLibrary()
        guard !isFixture else { return }
        isLoading = true
        defer { isLoading = false }
        if let remembered = defaults.string(forKey: Self.pathKey), FileManager.default.fileExists(atPath: remembered),
            await read(path: remembered, remember: false)
        {
            return
        }
        if let found = try? await backend.itunesDefaultLibrary() { adopt(found, remember: true) }
    }

    /// Choose\u{2026} / Change\u{2026}: an open panel for the XML.
    func choose() async {
        guard !isImporting else { return }
        guard let url = await dialogs().chooseFile("Choose your iTunes or Music Library.xml", [.xml]) else { return }
        await load(path: url.path)
    }

    /// Reads the file at `path` and shows it; a bad file leaves the old library on screen.
    func load(path: String) async {
        started = true
        isFixture = await backend.isFixtureLibrary()
        isLoading = true
        defer { isLoading = false }
        await read(path: path, remember: true)
    }

    @discardableResult
    private func read(path: String, remember: Bool) async -> Bool {
        do {
            let read = try await backend.itunesLibrary(at: path)
            adopt(read, remember: remember)
            return true
        } catch {
            self.error = describe(error)
            return false
        }
    }

    private func adopt(_ read: ItunesLibrary, remember: Bool) {
        library = read
        error = nil
        ticked = []
        selectedID = nil
        tracks = []
        resultLine = nil
        // Folders start closed, as in React, so a big library opens short.
        collapsed = Set(read.tree.filter(\.isFolder).map(\.id))
        if remember, !isFixture, !read.path.isEmpty { defaults.set(read.path, forKey: Self.pathKey) }
    }

    // MARK: Tree

    private var allRows: [ItunesRow] {
        (library?.tree ?? []).map {
            ItunesRow(id: $0.id, name: $0.name, depth: Int($0.depth), isFolder: $0.isFolder, trackCount: $0.trackCount)
        }
    }

    /// The rows to draw: everything under a closed folder is left out.
    var rows: [ItunesRow] {
        var out: [ItunesRow] = []
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

    var playlistCount: Int { allRows.filter { !$0.isFolder }.count }

    /// The playlist ids under a folder row, in tree order.
    private func leaves(under row: ItunesRow) -> [String] {
        let all = allRows
        guard let start = all.firstIndex(of: row) else { return [] }
        var out: [String] = []
        for next in all[(start + 1)...] {
            if next.depth <= row.depth { break }
            if !next.isFolder { out.append(next.id) }
        }
        return out
    }

    func tickState(_ row: ItunesRow) -> TickState {
        guard row.isFolder else { return ticked.contains(row.id) ? .on : .off }
        let below = leaves(under: row)
        guard !below.isEmpty else { return .off }
        let count = below.filter { ticked.contains($0) }.count
        return count == 0 ? .off : (count == below.count ? .on : .mixed)
    }

    func toggle(_ row: ItunesRow) {
        guard !isImporting else { return }
        if row.isFolder {
            let below = leaves(under: row)
            if tickState(row) == .on { ticked.subtract(below) } else { ticked.formUnion(below) }
        } else if ticked.contains(row.id) {
            ticked.remove(row.id)
        } else {
            ticked.insert(row.id)
        }
    }

    func toggleCollapsed(_ row: ItunesRow) {
        if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
    }

    func tickAll() { ticked = Set(allRows.filter { !$0.isFolder }.map(\.id)) }
    func clearTicks() { ticked = [] }

    /// The ticked playlists in tree order, so they land filed as they are in iTunes.
    var selectedPlaylists: [String] { allRows.filter { !$0.isFolder && ticked.contains($0.id) }.map(\.id) }

    var selectionText: String {
        guard library != nil else { return L10n.t("No iTunes library") }
        return "\(selectedPlaylists.count) of \(playlistCount) playlists selected"
    }

    // MARK: Tracks

    /// Shows the tracks of a playlist; a folder shows none.
    func select(_ row: ItunesRow) async {
        selectedID = row.id
        trackToken += 1
        let token = trackToken
        guard !row.isFolder, let path = library?.path else {
            tracks = []
            return
        }
        do {
            let read = try await backend.itunesPlaylistTracks(path: path, nodeID: row.id)
            guard token == trackToken else { return }
            tracks = read
        } catch {
            guard token == trackToken else { return }
            tracks = []
            self.error = describe(error)
        }
    }

    // MARK: Import

    func canImport(canEdit: Bool) -> Bool { canEdit && !isImporting && !selectedPlaylists.isEmpty }

    /// SYNC: brings the ticked playlists, their folders and tracks into the collection. The gate
    /// refuses with its own words (Library Protection, rekordbox open), which land in the notice.
    @discardableResult
    func importSelected() async -> XmlImportReport? {
        guard !isImporting, let path = library?.path else { return nil }
        let ids = selectedPlaylists
        guard !ids.isEmpty else {
            notify(Self.selectOne)
            return nil
        }
        isImporting = true
        resultLine = nil
        busy(true)
        defer {
            isImporting = false
            busy(false)
        }
        do {
            let report = try await backend.importItunesSelected(path: path, ids: ids)
            let line = Self.summary(report)
            resultLine = line
            notify(line)
            ticked = []
            if !report.skipped.isEmpty {
                await dialogs().inform(
                    "\(report.skipped.count) track\(report.skipped.count == 1 ? " was" : "s were") not imported",
                    ImportSummary.skippedDetail(report.skipped))
            }
            return report
        } catch {
            let message = describe(error)
            resultLine = message
            notify(message)
            return nil
        }
    }

    /// "Imported 2 playlists from iTunes (3 tracks, 2 new)." as the React window says it.
    static func summary(_ report: XmlImportReport) -> String {
        let tracks = report.imported + report.existing
        let skipped = report.skipped.isEmpty ? "" : " \(report.skipped.count) skipped."
        return "Imported \(report.playlists) playlist\(report.playlists == 1 ? "" : "s") from iTunes (\(tracks) track\(tracks == 1 ? "" : "s"), \(report.imported) new).\(skipped)"
    }
}

// MARK: - App model

extension AppModel {
    /// Why Import is unavailable (Library Protection or a running rekordbox), or nil.
    var itunesLockedReason: String? {
        if protectLibrary { return "Editing is locked by Library Protection. Turn it off in Settings to import." }
        if !canEdit { return "Editing is locked while rekordbox is running. Quit rekordbox to import." }
        return nil
    }

    var isItunesSelected: Bool { selectedNodeID == SidebarModel.itunesID }

    /// File > Import > iTunes Library XML: choose the file, then browse it.
    func openItunesFromPanel() async {
        selectedNodeID = SidebarModel.itunesID
        await itunes.choose()
    }
}

// MARK: - View

struct ItunesPanelView: View {
    let model: ItunesModel
    let canEdit: Bool
    let lockedReason: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.library == nil {
                empty
            } else {
                HSplitView {
                    playlists.frame(minWidth: 240, idealWidth: 300, maxWidth: 480)
                    trackList.frame(minWidth: 320)
                }
            }
            Divider()
            footer
        }
        .task { await model.openIfNeeded() }
        .accessibilityIdentifier("itunes-panel")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.tv").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("iTunes / Music Library").font(.headline)
                Text(model.library.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? model.selectionText)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(model.library == nil ? L10n.t("Choose\u{2026}") : L10n.t("Change\u{2026}")) { Task { await model.choose() } }
                .disabled(model.isLoading || model.isImporting)
                .accessibilityIdentifier("itunes-choose")
        }
        .padding(10)
    }

    private var empty: some View {
        Group {
            if model.isLoading {
                ProgressView("Reading iTunes library\u{2026}")
            } else if let error = model.error {
                ContentUnavailableView("Couldn\u{2019}t read the iTunes library", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView("No iTunes library", systemImage: "music.note.tv", description: Text(ItunesModel.nothingFound))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playlists: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.selectionText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("All") { model.tickAll() }.buttonStyle(.link)
                Button("None") { model.clearTicks() }.buttonStyle(.link)
            }
            .padding(8)
            Divider()
            if model.rows.isEmpty {
                ContentUnavailableView("No playlists", systemImage: "music.note.list", description: Text(ItunesModel.noPlaylists))
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
                        Button { model.toggle(row) } label: { Image(systemName: tickSymbol(model.tickState(row))) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(row.name)
                            .accessibilityValue(
                                model.tickState(row) == .on ? "ticked" : (model.tickState(row) == .mixed ? "partly ticked" : "not ticked"))
                        Image(systemName: row.isFolder ? "folder" : "music.note").foregroundStyle(.secondary)
                        Text(row.name).lineLimit(1)
                        Spacer()
                        if let count = row.trackCount {
                            Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.leading, CGFloat(row.depth) * 14)
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                    .background(model.selectedID == row.id ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 4))
                    .onTapGesture { Task { await model.select(row) } }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("itunes-playlists")
            }
        }
    }

    private func tickSymbol(_ state: TickState) -> String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }

    private var trackList: some View {
        Group {
            if model.selectedID == nil {
                ContentUnavailableView("Select a playlist", systemImage: "music.note.list", description: Text("Its tracks are listed here. Nothing is imported until you tick playlists and press Import."))
            } else if model.tracks.isEmpty {
                ContentUnavailableView("No tracks", systemImage: "music.note")
            } else {
                Table(model.tracks) {
                    TableColumn("Title") { Text($0.title.isEmpty ? "Untitled" : $0.title).lineLimit(1) }
                    TableColumn("Artist") { Text($0.artist).lineLimit(1) }
                    TableColumn("Rating") { Text($0.rating == 0 ? "" : String(repeating: "\u{2605}", count: Int($0.rating))) }
                        .width(70)
                    TableColumn("File") {
                        Text($0.path.map { ($0 as NSString).lastPathComponent } ?? "No file")
                            .lineLimit(1).foregroundStyle($0.path == nil ? .secondary : .primary)
                    }
                }
                .accessibilityIdentifier("itunes-tracks")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.importSelected() }
            } label: {
                Label(model.isImporting ? L10n.t("Importing\u{2026}") : L10n.t("Import"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canImport(canEdit: canEdit))
            .help(lockedReason ?? "Import the ticked playlists into the collection")
            .accessibilityIdentifier("itunes-import")
            if let lockedReason, !canEdit {
                Text(lockedReason).font(.caption).foregroundStyle(.orange)
            } else if let line = model.resultLine {
                Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityIdentifier("itunes-result")
            }
            Spacer()
        }
        .padding(10)
    }
}
