import Foundation
import Observation
import SwiftUI

// MARK: - Missing files

/// File > Missing File Manager: the tracks whose file is gone, with Locate and Auto Relocate.
@MainActor @Observable
final class MissingFilesModel: Identifiable {
    /// How many missing tracks the list shows (the count is exact).
    static let shown: UInt32 = 20
    static let allThere = "Every track\u{2019}s file is where the library expects it."

    private(set) var result: MissingTracks?
    private(set) var isScanning = false
    private(set) var isRelocating = false
    /// The last thing that happened, or why it failed.
    private(set) var message: String?
    private(set) var failed = false

    @ObservationIgnored private let backend: any BackendProtocol
    @ObservationIgnored private let dialogs: () -> Dialogs

    init(backend: any BackendProtocol, dialogs: @escaping () -> Dialogs) {
        self.backend = backend
        self.dialogs = dialogs
    }

    var total: UInt32 { result?.total ?? 0 }
    var tracks: [MissingTrack] { result?.tracks ?? [] }

    var summary: String {
        guard let result else { return "" }
        if result.total == 0 { return Self.allThere }
        return result.total == 1 ? "1 track cannot be found." : "\(result.total) tracks cannot be found."
    }

    func scan() async {
        isScanning = true
        defer { isScanning = false }
        do {
            result = try await backend.missingTracks(limit: Self.shown)
        } catch {
            message = describe(error)
            failed = true
        }
    }

    /// Locate...: choose the file for one track.
    func locate(_ track: MissingTrack) async {
        guard let url = await dialogs().chooseFile("Choose the file for this track", []) else { return }
        do {
            _ = try await backend.relocateTrack(id: track.id, path: url.path)
            message = "Located \(track.title.isEmpty ? url.lastPathComponent : track.title)."
            failed = false
        } catch {
            message = describe(error)
            failed = true
        }
        await scan()
    }

    /// Auto Relocate: choose a folder to search, and every missing track whose file name is there is pointed at it.
    func autoRelocate() async {
        guard let folder = await dialogs().chooseFolder("Choose a folder to search for moved files") else { return }
        isRelocating = true
        defer { isRelocating = false }
        do {
            let report = try await backend.autoRelocate(folders: [folder.path])
            message =
                report.unresolved == 0
                ? "\(report.relocated) relocated."
                : "\(report.relocated) relocated, \(report.unresolved) not found in the search folder."
            failed = false
        } catch {
            message = describe(error)
            failed = true
        }
        await scan()
    }
}

// MARK: - Duplicates

/// File > Find Duplicates: tracks that share a title and an artist.
@MainActor @Observable
final class DuplicatesModel: Identifiable {
    static let groupsShown: UInt32 = 20
    static let none = "No two tracks share a title and an artist."

    private(set) var result: Duplicates?
    private(set) var isScanning = false
    private(set) var message: String?
    private(set) var failed = false

    @ObservationIgnored private let backend: any BackendProtocol
    @ObservationIgnored private let dialogs: () -> Dialogs

    init(backend: any BackendProtocol, dialogs: @escaping () -> Dialogs) {
        self.backend = backend
        self.dialogs = dialogs
    }

    var groups: [DuplicateGroup] { result?.shown ?? [] }

    var summary: String {
        guard let result else { return "" }
        if result.groups == 0 { return Self.none }
        return "\(result.groups) title\(result.groups == 1 ? "" : "s") with more than one copy, \(result.extra) extra cop\(result.extra == 1 ? "y" : "ies") in all."
    }

    func scan() async {
        isScanning = true
        defer { isScanning = false }
        do {
            result = try await backend.findDuplicates(limit: Self.groupsShown)
        } catch {
            message = describe(error)
            failed = true
        }
    }

    /// Remove this copy from the collection, asked first. The file stays.
    func remove(_ track: DuplicateTrack, of group: DuplicateGroup) async {
        let confirmed = await dialogs().confirm(
            "Remove this copy of \(group.title) from the collection?",
            "This can\u{2019}t be undone. The file stays where it is.", "Remove")
        guard confirmed else { return }
        do {
            _ = try await backend.removeFromCollection(ids: [track.id])
            message = "Removed a copy of \(group.title)."
            failed = false
        } catch {
            message = describe(error)
            failed = true
        }
        await scan()
    }
}

// MARK: - Sheets

struct MissingFilesSheet: View {
    let model: MissingFilesModel
    let editable: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Missing files").font(.headline)
            Text(model.isScanning && model.result == nil ? L10n.t("Checking\u{2026}") : model.summary)
                .foregroundStyle(.secondary)
            if !model.tracks.isEmpty {
                List(model.tracks, id: \.id) { track in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title.isEmpty ? "Untitled" : track.title).lineLimit(1)
                            Text(track.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Locate\u{2026}") { Task { await model.locate(track) } }
                            .disabled(!editable)
                    }
                }
                .frame(minHeight: 160)
                .accessibilityIdentifier("missing-list")
                if model.total > UInt32(model.tracks.count) {
                    Text("Showing the first \(model.tracks.count).").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(model.failed ? Color.red : Color.secondary)
            }
            if !editable {
                Text("Editing is locked, so files cannot be relocated.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Auto Relocate\u{2026}") { Task { await model.autoRelocate() } }
                    .disabled(!editable || model.total == 0 || model.isRelocating)
                    .help("Choose a folder to search for the missing files by name")
                if model.isRelocating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Check Again") { Task { await model.scan() } }.disabled(model.isScanning)
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
        .task { await model.scan() }
    }
}

struct DuplicatesSheet: View {
    let model: DuplicatesModel
    let editable: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find duplicates").font(.headline)
            Text(model.isScanning && model.result == nil ? L10n.t("Looking\u{2026}") : model.summary)
                .foregroundStyle(.secondary)
            if !model.groups.isEmpty {
                List {
                    ForEach(Array(model.groups.enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group.tracks, id: \.id) { track in
                                HStack {
                                    Text("\(CellFormat.duration(track.durationSec)) \u{00B7} \(track.path)")
                                        .lineLimit(1).truncationMode(.middle)
                                    if !track.present { Text("(file missing)").foregroundStyle(.secondary) }
                                    Spacer()
                                    Button("Remove") { Task { await model.remove(track, of: group) } }
                                        .disabled(!editable)
                                }
                                .font(.callout)
                            }
                        } header: {
                            Text(group.artist.isEmpty ? group.title : "\(group.title) \u{2014} \(group.artist)")
                        }
                    }
                }
                .frame(minHeight: 200)
                .accessibilityIdentifier("duplicates-list")
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(model.failed ? Color.red : Color.secondary)
            }
            if !editable {
                Text("Editing is locked, so copies cannot be removed.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Find Again") { Task { await model.scan() } }.disabled(model.isScanning)
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 600)
        .task { await model.scan() }
    }
}
