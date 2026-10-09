import AppKit
import Foundation
import UniformTypeIdentifiers

/// Where an import has got to, for the status bar.
struct ImportProgressState: Equatable, Sendable {
    var done: UInt32
    var total: UInt32
    /// The file being worked on (empty for an XML import).
    var title: String

    /// 0...1, or nil when the total is not known yet.
    var fraction: Double? { total > 0 ? min(Double(done) / Double(total), 1) : nil }

    var text: String {
        let count = total > 0 ? "Importing \(done) of \(total)" : "Importing"
        return title.isEmpty ? "\(count)\u{2026}" : "\(count): \(title)"
    }
}

/// The words after an import, ported from the React app so both say the same thing.
enum ImportSummary {
    static func files(_ report: ImportReport) -> String {
        let total = Int(report.imported) + report.skipped.count
        let already = report.existing.isEmpty ? "" : "; \(report.existing.count) already in the library"
        return report.skipped.isEmpty
            ? "Imported \(report.imported) of \(total) files\(already)."
            : "Imported \(report.imported) of \(total) files; \(report.skipped.count) skipped\(already)."
    }

    static func xml(_ report: XmlImportReport) -> String {
        func plural(_ n: UInt32, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        let parts = [
            "\(plural(report.imported, "track")) imported",
            report.existing > 0 ? "\(report.existing) already here" : "",
            report.skipped.isEmpty ? "" : "\(report.skipped.count) skipped",
            plural(report.playlists, "playlist"),
            report.cues > 0 ? plural(report.cues, "cue") : "",
        ].filter { !$0.isEmpty }
        return parts.joined(separator: ", ") + "."
    }

    /// The lines an alert lists for what was skipped (the first ten).
    static func skippedDetail(_ lines: [String]) -> String {
        let shown = lines.prefix(10).joined(separator: "\n")
        return lines.count > 10 ? shown + "\n\u{2026}and \(lines.count - 10) more." : shown
    }
}

extension AppModel {
    static let dropRefusal = "Drop files or folders onto a playlist to import them."

    /// A status-bar progress event from the core. Ignored when no import of ours is running.
    func importProgressed(_ progress: ImportProgress) {
        guard importInFlight else { return }
        importProgress = ImportProgressState(done: progress.done, total: progress.total, title: progress.title)
    }

    /// Imports files and folders, and puts what landed (and what was already there) into
    /// `playlistID` when one is given. Returns the tracks that are now in the library.
    @discardableResult
    func importFiles(_ urls: [URL], thenAddTo playlistID: String? = nil) async -> [String] {
        guard !urls.isEmpty, !importInFlight else { return [] }
        importInFlight = true
        importProgress = ImportProgressState(done: 0, total: 0, title: "")
        notice = urls.count == 1 ? "Importing 1 item\u{2026}" : "Importing \(urls.count) items\u{2026}"
        defer {
            importInFlight = false
            importProgress = nil
        }
        let paths = urls.map(\.path)
        let backend = backend
        guard let report = await performEdit({ try await backend.importFiles(paths: paths) }) else { return [] }
        var landed = report.tracks.map(\.id) + report.existing.map(\.id)
        var message = ImportSummary.files(report)
        if let playlistID, !landed.isEmpty {
            let name = sidebar.node(withID: "pl:\(playlistID)")?.name ?? "the playlist"
            if let added = await performEdit({ try await backend.addTracksToPlaylist(playlistID: playlistID, trackIDs: landed) }) {
                message += added == 0 ? " Already in \(name)." : " Added \(added) to \(name)."
            }
        }
        var seen = Set<String>()
        landed = landed.filter { seen.insert($0).inserted }
        notice = message
        if !report.skipped.isEmpty {
            await dialogs.inform(
                "\(report.skipped.count) file\(report.skipped.count == 1 ? " was" : "s were") not imported",
                ImportSummary.skippedDetail(report.skipped))
        }
        return landed
    }

    /// File > Import > Track and Folder.
    func importFromPanel(folders: Bool) async {
        let urls = await dialogs.chooseAudio(
            folders ? L10n.t("Add a folder of music to the library") : L10n.t("Add music to the library"), folders)
        await importFiles(urls)
    }

    /// File > Import > rekordbox XML.
    func importXMLFromPanel() async {
        guard let url = await dialogs.chooseFile("Choose a rekordbox XML collection", [.xml]) else { return }
        await importXML(url)
    }

    func importXML(_ url: URL) async {
        guard !importInFlight else { return }
        importInFlight = true
        importProgress = ImportProgressState(done: 0, total: 0, title: "")
        notice = "Importing \(url.lastPathComponent)\u{2026}"
        defer {
            importInFlight = false
            importProgress = nil
        }
        let backend = backend
        guard let report = await performEdit({ try await backend.importXML(path: url.path) }) else { return }
        notice = ImportSummary.xml(report)
        if !report.skipped.isEmpty {
            await dialogs.inform(
                "\(report.skipped.count) track\(report.skipped.count == 1 ? " was" : "s were") not imported",
                ImportSummary.skippedDetail(report.skipped))
        }
    }

    // MARK: Loose files

    /// Import To Collection over files the Explorer lists.
    func importSelectionToCollection() async {
        let paths = orderedSelection.filter(Self.isLoose).map { String($0.dropFirst("file:".count)) }
        await importFiles(paths.map { URL(fileURLWithPath: $0) })
    }

    /// Ids the core can add to a playlist: loose files are imported first, as the React app does.
    /// Nil when the import was refused.
    func collectionIDs(for ids: [String]) async -> [String]? {
        let loose = ids.filter(Self.isLoose)
        guard !loose.isEmpty else { return ids }
        let landed = await importFiles(loose.map { URL(fileURLWithPath: String($0.dropFirst("file:".count))) })
        let imported = ids.filter { !Self.isLoose($0) } + landed
        return imported
    }

    // MARK: Finder drops

    /// Files dropped on the track table: onto a playlist's view they are imported and added;
    /// onto All Tracks only imported; anywhere else refused.
    func dropFilesOnTable(_ urls: [URL]) async -> Bool {
        if let playlist = openPlaylistID {
            await importFiles(urls, thenAddTo: playlist)
            return true
        }
        if selectedNodeID == "all" {
            await importFiles(urls)
            return true
        }
        notice = Self.dropRefusal
        return false
    }

    /// Files dropped on a source-list row.
    func dropFiles(_ urls: [URL], on node: SidebarNode) async -> Bool {
        switch node.kind {
        case .playlist:
            guard let id = node.libraryID else { return false }
            await importFiles(urls, thenAddTo: id)
            return true
        case .allTracks:
            await importFiles(urls)
            return true
        default:
            notice = Self.dropRefusal
            return false
        }
    }
}

extension AppModel {
    /// File > Missing File Manager.
    func openMissingFiles() {
        missingFiles = MissingFilesModel(backend: backend, dialogs: { [weak self] in self?.dialogs ?? .live })
    }

    /// File > Find Duplicates.
    func openDuplicates() {
        duplicates = DuplicatesModel(backend: backend, dialogs: { [weak self] in self?.dialogs ?? .live })
    }
}
