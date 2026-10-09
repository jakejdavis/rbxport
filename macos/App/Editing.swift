import AppKit
import Foundation

// MARK: - Pasteboard

extension NSPasteboard.PasteboardType {
    /// Track ids dragged out of the table, one pasteboard item per row.
    static let rbxportTracks = NSPasteboard.PasteboardType("com.rbxport.track-ids")
    /// Track ids offered for export to a device. Unlike `rbxportTracks` this is present whether or not
    /// the library may be edited: exporting writes the stick, not the library.
    static let rbxportExportTracks = NSPasteboard.PasteboardType("com.rbxport.export-track-ids")
    /// A playlist's core id, dragged out of the source list to a device.
    static let rbxportExportPlaylist = NSPasteboard.PasteboardType("com.rbxport.export-playlist")
    /// A source-list node (playlist or folder) dragged inside the outline.
    static let rbxportSidebarNode = NSPasteboard.PasteboardType("com.rbxport.sidebar-node")

    /// The track ids a drag offers a device, in row order.
    @MainActor static func exportTrackIDs(from pasteboard: NSPasteboard) -> [String] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .rbxportExportTracks) }.filter { !$0.isEmpty }
    }

    /// The track ids a drag carries, in row order. Empty placeholders (rows that were not loaded) are dropped.
    @MainActor static func trackIDs(from pasteboard: NSPasteboard) -> [String] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .rbxportTracks) }.filter { !$0.isEmpty }
    }
}

// MARK: - Source-list editing helpers

extension SidebarNode {
    /// Playlists, smart playlists and folders can be renamed, moved and deleted.
    var isEditableItem: Bool {
        switch kind {
        case .folder, .playlist, .smartPlaylist: true
        default: false
        }
    }

    /// The id the core knows this item by (`pl:12` is `12`).
    var libraryID: String? { isEditableItem ? String(id.dropFirst(3)) : nil }
}

/// A playlist a track can be added to.
struct PlaylistTarget: Equatable, Sendable {
    /// The core's id.
    let id: String
    /// `Folder › Playlist`.
    let title: String
}

/// Where a dragged source-list item would land.
@MainActor
struct SidebarDropPlan {
    /// What the core is told: the parent's id (`root` for the top level) and the index among its
    /// children with the moved item lifted out.
    let parentID: String
    let index: Int
    /// What the outline draws: the parent row and the index counting every child it shows.
    let outlineParent: SidebarNode
    let outlineIndex: Int
}

extension SidebarModel {
    /// The playlists and folders directly under `parent` (the Playlists section skips All Tracks).
    func libraryChildren(of parent: SidebarNode) -> [SidebarNode] {
        parent.children.filter { $0.isEditableItem }
    }

    /// The parent id a new item made "near" `node` goes under: a folder takes it inside, a
    /// playlist beside it, anything else at the top level.
    func parentID(forNewItemNear node: SidebarNode?) -> String {
        guard let node else { return "root" }
        if node.kind == .folder { return node.libraryID ?? "root" }
        if node.isEditableItem, let parent = node.parent, parent.kind == .folder { return parent.libraryID ?? "root" }
        return "root"
    }

    /// The id Sort Items is given for a node: a folder's own, or `root` for the Playlists heading.
    func sortParentID(for node: SidebarNode) -> String? {
        if node.kind == .section(.playlists) { return "root" }
        return node.kind == .folder ? node.libraryID : nil
    }

    /// Every ordinary playlist (smart ones take no hand-picked tracks), labelled with its folders.
    func playlistTargets() -> [PlaylistTarget] {
        var out: [PlaylistTarget] = []
        func walk(_ nodes: [SidebarNode], path: [String]) {
            for node in nodes {
                switch node.kind {
                case .folder: walk(node.children, path: path + [node.name])
                case .playlist:
                    if let id = node.libraryID { out.append(PlaylistTarget(id: id, title: (path + [node.name]).joined(separator: " \u{203A} "))) }
                default: break
                }
            }
        }
        walk(section(.playlists).children, path: [])
        return out
    }

    /// Whether `ancestor` is `node` or contains it.
    func contains(_ ancestor: SidebarNode, _ node: SidebarNode) -> Bool {
        var cursor: SidebarNode? = node
        while let current = cursor {
            if current === ancestor { return true }
            cursor = current.parent
        }
        return false
    }

    /// Where dragging `node` onto `target` (an item, or nil for the outline's root) at the
    /// outline's `childIndex` (-1: on the item itself) would put it, or nil when it cannot go:
    /// not a movable row, not a playlist folder or the Playlists heading, a folder into itself
    /// or one of its own descendants, or nowhere (same place).
    func movePlan(dragging node: SidebarNode, onto target: SidebarNode?, childIndex: Int) -> SidebarDropPlan? {
        guard node.isEditableItem, let target else { return nil }
        let parent: SidebarNode
        var position: Int  // among the parent's library children, before lifting `node` out
        switch target.kind {
        case .section(.playlists), .folder:
            parent = target
            let kids = libraryChildren(of: parent)
            if childIndex < 0 {
                position = kids.count
            } else {
                // The outline counts every child; All Tracks (first in the section) is not one of ours.
                let hidden = parent.children.prefix(childIndex).filter { !$0.isEditableItem }.count
                position = min(max(childIndex - hidden, 0), kids.count)
            }
        case .playlist, .smartPlaylist:
            // Dropped on a playlist: just below it, in its parent.
            guard childIndex < 0, let above = target.parent else { return nil }
            parent = above
            position = (libraryChildren(of: parent).firstIndex { $0 === target } ?? 0) + 1
        default:
            return nil
        }
        guard !contains(node, parent) else { return nil }
        let kids = libraryChildren(of: parent)
        var index = position
        if node.parent === parent, let current = kids.firstIndex(where: { $0 === node }) {
            if current < index { index -= 1 }
            if index == current { return nil }
        }
        // The outline's index for the same spot: count the rows ahead of it, hidden ones too.
        let shown = parent.children
        let aheadOfPosition = kids.prefix(position)
        let outlineIndex: Int
        if let last = aheadOfPosition.last, let at = shown.firstIndex(where: { $0 === last }) {
            outlineIndex = at + 1
        } else {
            outlineIndex = shown.prefix { !$0.isEditableItem }.count
        }
        return SidebarDropPlan(
            parentID: parent.kind == .folder ? (parent.libraryID ?? "root") : "root", index: index,
            outlineParent: parent, outlineIndex: outlineIndex)
    }
}

// MARK: - Reordering rows

/// The new order of a playlist when rows are dragged to a drop line.
enum ReorderPlan {
    /// `all` is the view's ids in order, `carried` the dragged ones, `insertionRow` the row the
    /// drop line sits above (`all.count` for the end). The carried rows keep their view order and
    /// land where the line is counted against the rows that stay.
    static func order(all: [String], carried: [String], insertionRow: Int) -> [String] {
        let moving = Set(carried)
        let line = min(max(insertionRow, 0), all.count)
        let leading = all.prefix(line).filter { !moving.contains($0) }
        let trailing = all.suffix(from: line).filter { !moving.contains($0) }
        return leading + all.filter { moving.contains($0) } + trailing
    }
}

// MARK: - The model's editing commands

extension AppModel {
    var isReadOnly: Bool { summary?.readOnly ?? true }
    var canEdit: Bool { !isReadOnly }
    var canUndo: Bool { editHistory.canUndo && canEdit }
    var canRedo: Bool { editHistory.canRedo && canEdit }
    var undoMenuTitle: String { editHistory.undoLabel.map { "\(L10n.t("Undo")) \($0)" } ?? L10n.t("Undo") }
    var redoMenuTitle: String { editHistory.redoLabel.map { "\(L10n.t("Redo")) \($0)" } ?? L10n.t("Redo") }

    /// Runs one edit. A refusal or failure lands verbatim in the status line; nil comes back.
    @discardableResult
    func performEdit<T>(_ work: @MainActor () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch {
            notice = describe(error)
            return nil
        }
    }

    // MARK: Gate

    func applyProtection() async {
        await backend.setProtectLibrary(protectLibrary)
        await refreshSummary()
    }

    func refreshSummary() async {
        if let fresh = try? await backend.summary(), fresh != summary { summary = fresh }
    }

    func startReadOnlyPolling() {
        pollTask?.cancel()
        guard let interval = readOnlyPollInterval else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                if self.phase == .ready { await self.refreshSummary() }
            }
        }
    }

    // MARK: Undo and redo

    /// Edit > Undo / Redo. A text field being edited (a rename, the search box) keeps its own
    /// history; otherwise the library's.
    func performHistoryCommand(redo: Bool) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, let manager = text.undoManager,
            redo ? manager.canRedo : manager.canUndo
        {
            if redo { manager.redo() } else { manager.undo() }
            return
        }
        Task { await stepHistory(redo: redo) }
    }

    func stepHistory(redo: Bool) async {
        let label = redo ? editHistory.redoLabel : editHistory.undoLabel
        let done = await performEdit { redo ? try await backend.redo() : try await backend.undo() }
        if done != nil { notice = "\(redo ? "Redid" : "Undid") \(label ?? "the edit")." }
    }

    // MARK: Playlists and folders

    /// File > New Playlist, the tree menu. The new row is selected and ready to be named.
    func createPlaylist(near node: SidebarNode?, name: String = "New Playlist", beginRename: Bool = true) async {
        let parent = sidebar.parentID(forNewItemNear: node)
        guard let id = await performEdit({ try await backend.createPlaylist(name: name, parent: parent) }) else { return }
        await reveal(nodeID: "pl:\(id)", rename: beginRename)
    }

    func createFolder(near node: SidebarNode?, name: String = "New Folder", beginRename: Bool = true) async {
        let parent = sidebar.parentID(forNewItemNear: node)
        guard let id = await performEdit({ try await backend.createFolder(name: name, parent: parent) }) else { return }
        await reveal(nodeID: "pf:\(id)", rename: beginRename)
    }

    /// Reloads the tree, selects the new row and starts its rename.
    private func reveal(nodeID: String, rename: Bool) async {
        await refresh(selectFirst: false)
        guard sidebar.canSelect(nodeID) else { return }
        selectedNodeID = nodeID
        if rename { sidebar.renameRequest = nodeID }
    }

    func rename(_ node: SidebarNode, to proposed: String) async {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = node.libraryID, !name.isEmpty, name != node.name else { return }
        if await performEdit({ try await backend.renamePlaylist(id: id, name: name) }) != nil {
            notice = "Renamed to \(name)."
        }
    }

    func delete(_ node: SidebarNode) async {
        guard let id = node.libraryID else { return }
        let name = node.name
        if await performEdit({ try await backend.deletePlaylist(id: id) }) != nil { notice = "Deleted \(name)." }
    }

    func sortItems(_ node: SidebarNode) async {
        guard let parent = sidebar.sortParentID(for: node) else { return }
        if await performEdit({ try await backend.sortChildren(parent: parent) }) != nil { notice = "Sorted \(node.name)." }
    }

    func move(_ node: SidebarNode, to plan: SidebarDropPlan) async {
        guard let id = node.libraryID else { return }
        await performEdit { try await backend.movePlaylist(id: id, parent: plan.parentID, index: UInt32(plan.index)) }
    }

    // MARK: Smart playlists

    func newSmartPlaylist(near node: SidebarNode?) {
        smartEditor = SmartEditorModel(
            mode: .create(parent: sidebar.parentID(forNewItemNear: node)), name: L10n.t("Untitled Intelligent List"),
            rule: SmartRule(logic: .all, conditions: []))
        loadMyTags(for: smartEditor)
    }

    func editSmartPlaylist(_ node: SidebarNode) async {
        guard node.kind == .smartPlaylist, let id = node.libraryID else { return }
        guard let rule = await performEdit({ try await backend.smartRule(playlistID: id) }) else { return }
        smartEditor = SmartEditorModel(mode: .edit(id: id), name: node.name, rule: rule)
        loadMyTags(for: smartEditor)
    }

    private func loadMyTags(for editor: SmartEditorModel?) {
        guard let editor else { return }
        let backend = backend
        Task { [weak editor] in
            if let lookups = try? await backend.trackLookups() { editor?.myTags = lookups.myTagCategories }
        }
    }

    /// OK in the editor sheet. The sheet stays open, with the message, when the core refuses.
    func saveSmartEditor(_ editor: SmartEditorModel) async {
        editor.error = nil
        do {
            switch editor.mode {
            case .create(let parent):
                let id = try await backend.createSmartPlaylist(name: editor.trimmedName, parent: parent, rule: editor.rule)
                smartEditor = nil
                await reveal(nodeID: "pl:\(id)", rename: false)
            case .edit(let id):
                if editor.readOnlyRules {
                    if editor.trimmedName != editor.originalName {
                        _ = try await backend.renamePlaylist(id: id, name: editor.trimmedName)
                    }
                } else {
                    _ = try await backend.saveSmartPlaylist(playlistID: id, name: editor.trimmedName, rule: editor.rule)
                }
                smartEditor = nil
            }
        } catch {
            editor.error = describe(error)
            notice = describe(error)
        }
    }

    // MARK: Tracks in playlists

    /// The playlist the open view lists, when it is an ordinary one.
    var openPlaylistID: String? {
        guard let id = selectedNodeID, let node = sidebar.node(withID: id), node.kind == .playlist else { return nil }
        return node.libraryID
    }

    func addToPlaylist(_ playlistID: String, trackIDs: [String]) async {
        guard !trackIDs.isEmpty else { return }
        let name = sidebar.node(withID: "pl:\(playlistID)")?.name ?? "the playlist"
        // Files the Explorer lists are imported first, as the React app does.
        guard let trackIDs = await collectionIDs(for: trackIDs), !trackIDs.isEmpty else { return }
        guard let added = await performEdit({ try await backend.addTracksToPlaylist(playlistID: playlistID, trackIDs: trackIDs) })
        else { return }
        notice = added == 0 ? "Already in \(name)." : "Added \(added) track\(added == 1 ? "" : "s") to \(name)."
    }

    /// The selection, in the view's order where rows are loaded.
    var orderedSelection: [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        pager.forEachLoadedRow { _, row in
            if selectedIDs.contains(row.id), seen.insert(row.id).inserted { ordered.append(row.id) }
        }
        return ordered + selectedIDs.subtracting(seen).sorted()
    }

    func addSelectionToPlaylist(_ playlistID: String) async {
        await addToPlaylist(playlistID, trackIDs: orderedSelection)
    }

    /// Remove from Playlist, and the Delete key in a playlist view. No confirmation (it is undoable).
    func removeSelectionFromPlaylist() async {
        guard let playlist = openPlaylistID, !selectedIDs.isEmpty else { return }
        let ids = orderedSelection
        if await performEdit({ try await backend.removeTracksFromPlaylist(playlistID: playlist, trackIDs: ids) }) != nil {
            notice = "Removed \(ids.count) track\(ids.count == 1 ? "" : "s")."
        }
    }

    /// Rows may be dragged to reorder only in a playlist shown in its own order: sorted by #
    /// ascending, no search, no filter, and the library open for editing.
    var canReorderRows: Bool {
        openPlaylistID != nil && canEdit && sortKey == .trackNo && !descending && query.isEmpty
            && !(filterBarOpen && filterState.isNarrowing)
    }

    var canRemoveFromPlaylist: Bool { openPlaylistID != nil && canEdit && !selectedIDs.isEmpty }

    /// Moves the dragged tracks to the drop line above `insertionRow` of the open playlist.
    func reorderRows(carried: [String], insertionRow: Int) async {
        guard canReorderRows, let playlist = openPlaylistID, let opened, opened.handle.len > 0 else { return }
        let backend = backend
        let viewID = opened.handle.viewId
        let last = opened.handle.len - 1
        guard let all = await performEdit({ try await backend.viewIDsInRange(viewID: viewID, from: 0, to: last) }) else { return }
        let order = ReorderPlan.order(all: all, carried: carried, insertionRow: insertionRow)
        guard order != all else { return }
        await performEdit { try await backend.reorderPlaylist(playlistID: playlist, trackIDs: order) }
    }

    // MARK: Menu commands

    func runTreeMenu(_ command: MenuCommand, on node: SidebarNode) {
        switch command {
        case .createPlaylist: Task { await createPlaylist(near: node) }
        case .createFolder: Task { await createFolder(near: node) }
        case .createSmartPlaylist: newSmartPlaylist(near: node)
        case .editSmartPlaylist: Task { await editSmartPlaylist(node) }
        case .rename: sidebar.renameRequest = node.id
        case .delete: Task { await delete(node) }
        case .sortItems: Task { await sortItems(node) }
        default: break
        }
    }

    // MARK: Developer hooks

    /// The source-list row that is selected.
    var selectedSidebarNode: SidebarNode? { selectedNodeID.flatMap { sidebar.node(withID: $0) } }

    /// `RBXPORT_OPEN_SMART_EDITOR=1`: the editor with a sample rule. Nothing is written.
    func openDemoSmartEditor() {
        let rule = SmartRule(
            logic: .all,
            conditions: [
                SmartCondition(property: "bpm", operator: "3", left: "126", right: "", unit: ""),
                SmartCondition(property: "genre", operator: "8", left: "House", right: "", unit: ""),
                SmartCondition(property: "stockDate", operator: "6", left: "3", right: "", unit: "week"),
            ])
        smartEditor = SmartEditorModel(mode: .create(parent: "root"), name: "Big Room Hits", rule: rule)
    }

    /// `RBXPORT_DEMO_EDIT=metadata|missing|duplicates`: Phase 4b screenshots. They write (metadata,
    /// duplicates) and so run only against a fixture, which `runDemoEdit` has already checked.
    func runMetadataDemo(_ name: String) async {
        let spec = ViewSpec(
            source: .collection, sort: .trackNo, descending: false, query: "", searchField: .all,
            filter: TrackFilter(bpm: nil, keys: nil, ratings: nil, colors: nil))
        guard let handle = try? await backend.openView(spec),
            let ids = try? await backend.viewIDsInRange(viewID: handle.viewId, from: 0, to: 9), ids.count >= 6
        else { return }
        switch name {
        case "metadata":
            _ = await performEdit { try await backend.setTrackRating(ids: [ids[0], ids[1]], stars: 4) }
            _ = await performEdit { try await backend.setTrackRating(ids: [ids[2]], stars: 2) }
            _ = await performEdit { try await backend.setTrackColor(ids: [ids[0]], color: 5) }
            _ = await performEdit { try await backend.setTrackColor(ids: [ids[2]], color: 2) }
            _ = await performEdit { try await backend.setTrackComment(ids: [ids[0]], comment: "Warm-up opener, long intro") }
            _ = await performEdit { try await backend.setTrackField(ids: [ids[1]], field: .genre, value: "Deep House") }
            _ = await performEdit { try await backend.addToTagList(ids: [ids[3], ids[4]]) }
            notice = L10n.t("Comment saved.")
            info.tab = .info
            infoPanelOpen = true
        case "duplicates":
            _ = await performEdit { try await backend.setTrackField(ids: [ids[1], ids[2]], field: .title, value: "Track 000") }
            openDuplicates()
        default:
            openMissingFiles()
        }
    }

    /// `RBXPORT_DEMO_EDIT=create-playlist`: makes a folder, a filled playlist and a smart
    /// playlist, for screenshots. It writes, so it runs only against a generated fixture.
    func runDemoEdit(_ name: String) async {
        guard await backend.isFixtureLibrary() else {
            notice = "Demo edits only run against a fixture library."
            return
        }
        // The setting is not touched: the hook opens the gate for this run only.
        await backend.setProtectLibrary(false)
        await refreshSummary()
        switch name {
        case "create-playlist": break
        case "cues":
            await runCueDemo()
            return
        case "metadata", "missing", "duplicates":
            await runMetadataDemo(name)
            return
        default: return
        }
        guard let folder = await performEdit({ try await backend.createFolder(name: "Sets", parent: "root") }),
            let playlist = await performEdit({ try await backend.createPlaylist(name: "Demo Mix", parent: "root") })
        else { return }
        _ = folder
        let spec = ViewSpec(
            source: .collection, sort: .trackNo, descending: false, query: "", searchField: .all,
            filter: TrackFilter(bpm: nil, keys: nil, ratings: nil, colors: nil))
        if let handle = try? await backend.openView(spec),
            let ids = try? await backend.viewIDsInRange(viewID: handle.viewId, from: 0, to: 5)
        {
            _ = await performEdit { try await backend.addTracksToPlaylist(playlistID: playlist, trackIDs: ids) }
        }
        let rule = SmartRule(
            logic: .all,
            conditions: [SmartCondition(property: "rating", operator: "3", left: "2", right: "", unit: "")])
        _ = await performEdit { try await backend.createSmartPlaylist(name: "Four Stars Up", parent: "root", rule: rule) }
        await reveal(nodeID: "pl:\(playlist)", rename: false)
    }
}

extension AppModel {
    /// Fixture-only screenshot hook (`RBXPORT_DEMO_EDIT=cues`): analyses the first track, loads it
    /// onto deck A and sets hot cues A and B, a memory cue and a memory loop through the gate.
    func runCueDemo() async {
        guard await backend.isFixtureLibrary() else { return }
        let spec = ViewSpec(
            source: .collection, sort: .trackNo, descending: false, query: "", searchField: .all,
            filter: TrackFilter(bpm: nil, keys: nil, ratings: nil, colors: nil))
        guard let handle = try? await backend.openView(spec),
            let id = try? await backend.viewIDsInRange(viewID: handle.viewId, from: 0, to: 0).first
        else { return }
        player.load(trackID: id, row: nil)
        analysis.enqueue([AnalysisItem(id: id, title: "Demo track")])
        await analysis.waitUntilDrained()
        if let failure = analysis.failed.first {
            notice = "Demo analysis failed: \(failure.reason)"
            return
        }
        _ = await eventuallyLoaded()
        let backend = backend
        _ = await performEdit { try await backend.addCue(trackID: id, slot: .hot(letter: "A"), positionMs: 4_000) }
        _ = await performEdit { try await backend.addCue(trackID: id, slot: .hot(letter: "B"), positionMs: 12_000) }
        _ = await performEdit { try await backend.addCue(trackID: id, slot: .memory, positionMs: 8_000) }
        _ = await performEdit { try await backend.addLoop(trackID: id, slot: .memory, inMs: 16_000, outMs: 20_000, beats: 8) }
        notice = "Demo: analysed, 2 hot cues, a memory cue and a memory loop."
    }

    private func eventuallyLoaded() async -> Bool {
        for _ in 0..<100 {
            if player.deckA.isLoaded { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
