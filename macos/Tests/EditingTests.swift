import Foundation
import Testing

@testable import rbxport

@MainActor
@Suite(.scratchDefaults)
struct EditingTests {
    private func node(_ id: String, _ name: String, _ kind: NodeKind, _ depth: UInt32, open: Bool? = nil, count: UInt32? = nil)
        -> TreeNode
    {
        TreeNode(id: id, name: name, kind: kind, depth: depth, expanded: open, childCount: count)
    }

    /// All Tracks; Sets (folder) holding Warm-up and Peak (smart); Loose; Zebra.
    private var tree: [TreeNode] {
        [
            node("all", "All Tracks", .allTracks, 0, count: 50),
            node("playlists", "Playlists", .collection, 0, open: true, count: 5),
            node("1", "Sets", .folder, 1, open: true, count: 2),
            node("2", "Warm-up", .playlist, 2, count: 0),
            node("3", "Peak", .smartPlaylist, 2),
            node("4", "Loose", .playlist, 1, count: 0),
            node("5", "Zebra", .playlist, 1, count: 0),
        ]
    }

    /// A started model over a mock. `unlocked` turns Library Protection off before the load.
    private func ready(unlocked: Bool = true, tracks: Int = 50) async -> (AppModel, MockBackend) {
        let backend = MockBackend(trackCount: tracks, nodes: tree)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        if unlocked { model.protectLibrary = false }
        model.start()
        #expect(await eventually { model.opened != nil })
        return (model, backend)
    }

    private func node(_ model: AppModel, _ id: String) -> SidebarNode { model.sidebar.node(withID: id)! }

    // MARK: The gate

    @Test func libraryProtectionIsOnByDefaultAndTheCoreRefusesWithItsOwnMessage() async {
        let (model, backend) = await ready(unlocked: false)
        #expect(model.protectLibrary)
        #expect(model.isReadOnly && !model.canEdit)
        await model.createPlaylist(near: nil)
        #expect(model.notice == MockBackend.protectedMessage)
        #expect(await backend.currentNodes.count == 7)
        #expect(model.sidebar.renameRequest == nil)
    }

    @Test func turningProtectionOffPushesTheSettingAndOpensTheGate() async {
        let (model, backend) = await ready(unlocked: false)
        model.protectLibrary = false
        #expect(await eventually { !model.isReadOnly })
        #expect(await backend.protectCalls == [true, false])
        #expect(model.layoutStore.defaults.object(forKey: PrefKeys.protectLibrary) as? Bool == false)
        model.protectLibrary = true
        #expect(await eventually { model.isReadOnly })
    }

    @Test func aRunningRekordboxClosesTheGateAndThePollNoticesIt() async {
        let backend = MockBackend(trackCount: 10, nodes: tree)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.protectLibrary = false
        model.readOnlyPollInterval = .milliseconds(30)
        model.start()
        #expect(await eventually { model.opened != nil && !model.isReadOnly })
        await backend.setRekordboxRunning(true)
        #expect(await eventually { model.isReadOnly })
        await model.createFolder(near: nil)
        #expect(model.notice == MockBackend.runningMessage)
        await backend.setRekordboxRunning(false)
        #expect(await eventually { !model.isReadOnly })
        model.pollTask?.cancel()
    }

    // MARK: Creating

    @Test func aNewPlaylistIsSelectedAndStartsRenaming() async {
        let (model, backend) = await ready()
        await model.createPlaylist(near: nil)
        #expect(model.selectedNodeID == "pl:100")
        #expect(model.sidebar.renameRequest == "pl:100")
        #expect(node(model, "pl:100").name == "New Playlist")
        #expect(await backend.editLog == ["createPlaylist(New Playlist,root)"])
    }

    @Test func aNewItemGoesInsideAFolderAndBesideAPlaylist() async {
        let (model, backend) = await ready()
        await model.createFolder(near: node(model, "pf:1"), name: "Inside")
        await model.createPlaylist(near: node(model, "pl:2"), name: "Sibling")
        await model.createPlaylist(near: node(model, "pl:4"), name: "Top")
        await model.createPlaylist(near: model.sidebar.section(.playlists), name: "Also top")
        #expect(await backend.editLog.map { $0.split(separator: ",").last.map(String.init) ?? "" } == ["1)", "1)", "root)", "root)"])
        #expect(node(model, "pf:100").parent === node(model, "pf:1"))
        #expect(node(model, "pl:101").parent === node(model, "pf:1"))
        #expect(node(model, "pl:102").parent === model.sidebar.section(.playlists))
    }

    @Test func aRefusedCreationDoesNotSelectAnything() async {
        let (model, backend) = await ready()
        await backend.setFailure(.Malformed(message: "no playlist or folder 99", detail: nil))
        await model.createPlaylist(near: nil)
        #expect(model.notice == "no playlist or folder 99")
        #expect(model.selectedNodeID == "all")
        #expect(model.sidebar.renameRequest == nil)
    }

    // MARK: Rename and delete

    @Test func renameTrimsSkipsNoOpsAndAnnounces() async {
        let (model, backend) = await ready()
        let loose = node(model, "pl:4")
        await model.rename(loose, to: "   ")
        await model.rename(loose, to: "Loose")
        #expect(await backend.editLog.isEmpty)
        await model.rename(loose, to: "  Closer  ")
        #expect(await backend.editLog == ["renamePlaylist(4,Closer)"])
        #expect(model.notice == "Renamed to Closer.")
        #expect(await eventually { model.sidebar.node(withID: "pl:4")?.name == "Closer" })
    }

    @Test func deletingTheSelectedPlaylistFallsBackToAllTracks() async {
        let (model, _) = await ready()
        model.selectedNodeID = "pl:4"
        #expect(await eventually { model.opened?.generation == 2 })
        await model.delete(node(model, "pl:4"))
        #expect(model.notice == "Deleted Loose.")
        #expect(await eventually { model.sidebar.node(withID: "pl:4") == nil && model.selectedNodeID == "all" })
    }

    @Test func deletingAFolderTakesItsContentsAndUndoBringsThemBack() async {
        let (model, _) = await ready()
        await model.delete(node(model, "pf:1"))
        #expect(await eventually { model.sidebar.node(withID: "pl:2") == nil })
        #expect(model.editHistory.undoLabel == "Delete Playlist")
        await model.stepHistory(redo: false)
        #expect(await eventually { model.sidebar.node(withID: "pl:2") != nil })
        #expect(model.notice == "Undid Delete Playlist.")
        #expect(model.editHistory.canRedo)
    }

    @Test func sortItemsIsOneUndoStep() async {
        let (model, backend) = await ready()
        await model.sortItems(model.sidebar.section(.playlists))
        #expect(await backend.currentNodes.filter { $0.depth == 1 }.map(\.name) == ["Loose", "Sets", "Zebra"])
        #expect(model.notice == "Sorted Playlists.")
        #expect(await eventually { model.editHistory.undoLabel == "Sort Items" })
        await model.stepHistory(redo: false)
        #expect(await backend.currentNodes.filter { $0.depth == 1 }.map(\.name) == ["Sets", "Loose", "Zebra"])
        // Only folders and the Playlists heading sort.
        #expect(model.sidebar.sortParentID(for: node(model, "pl:4")) == nil)
        #expect(model.sidebar.sortParentID(for: node(model, "pf:1")) == "1")
    }

    // MARK: Undo menu state

    @Test func theUndoMenuNamesTheEditAndFollowsTheGate() async {
        let (model, _) = await ready()
        #expect(model.undoMenuTitle == "Undo" && !model.canUndo)
        await model.rename(node(model, "pl:4"), to: "Renamed")
        #expect(await eventually { model.editHistory.canUndo })
        #expect(model.undoMenuTitle == "Undo Rename Playlist" && model.canUndo)
        await model.stepHistory(redo: false)
        #expect(await eventually { model.editHistory.canRedo })
        #expect(model.redoMenuTitle == "Redo Rename Playlist" && model.canRedo && model.undoMenuTitle == "Undo")
        // The same history under a closed gate: the items are off.
        model.protectLibrary = true
        #expect(await eventually { model.isReadOnly })
        #expect(!model.canUndo && !model.canRedo)
        await model.stepHistory(redo: true)
        #expect(model.notice == MockBackend.protectedMessage)
    }

    // MARK: Dragging in the source list

    @Test func aFolderCannotBeDroppedIntoItselfOrItsDescendants() async {
        let (model, _) = await ready()
        let sets = node(model, "pf:1")
        let sidebar = model.sidebar
        #expect(sidebar.movePlan(dragging: sets, onto: sets, childIndex: -1) == nil)
        #expect(sidebar.movePlan(dragging: sets, onto: sets, childIndex: 0) == nil)
        #expect(sidebar.movePlan(dragging: sets, onto: node(model, "pl:2"), childIndex: -1) == nil)
    }

    @Test func onlyPlaylistsAndFoldersMoveAndOnlyOntoFoldersOrThePlaylistsHeading() async {
        let (model, _) = await ready()
        let sidebar = model.sidebar
        let playlists = sidebar.section(.playlists)
        #expect(sidebar.movePlan(dragging: playlists.children[0], onto: playlists, childIndex: 1) == nil)  // All Tracks
        #expect(sidebar.movePlan(dragging: node(model, "pl:4"), onto: sidebar.section(.tagList), childIndex: -1) == nil)
        #expect(sidebar.movePlan(dragging: node(model, "pl:4"), onto: nil, childIndex: 0) == nil)
        let plan = sidebar.movePlan(dragging: node(model, "pl:4"), onto: node(model, "pf:1"), childIndex: -1)
        #expect(plan?.parentID == "1" && plan?.index == 2)
    }

    @Test func dropIndexesIgnoreAllTracksAndLiftTheMovedItemOut() async {
        let (model, _) = await ready()
        let sidebar = model.sidebar
        let playlists = sidebar.section(.playlists)
        // Children shown: All Tracks, Sets, Loose, Zebra. Dropping Zebra above Sets (outline index 1).
        let top = sidebar.movePlan(dragging: node(model, "pl:5"), onto: playlists, childIndex: 1)
        #expect(top?.parentID == "root" && top?.index == 0 && top?.outlineIndex == 1)
        // Loose above Zebra (outline index 3) is where it already is.
        #expect(sidebar.movePlan(dragging: node(model, "pl:4"), onto: playlists, childIndex: 3) == nil)
        #expect(sidebar.movePlan(dragging: node(model, "pl:4"), onto: playlists, childIndex: 2) == nil)
        // Sets below Zebra: counted with Sets lifted out, it is index 2 of the two that stay.
        let end = sidebar.movePlan(dragging: node(model, "pf:1"), onto: playlists, childIndex: 4)
        #expect(end?.parentID == "root" && end?.index == 2)
        // Before every child: the hidden All Tracks row is not ours.
        let first = sidebar.movePlan(dragging: node(model, "pl:5"), onto: playlists, childIndex: 0)
        #expect(first?.index == 0)
    }

    @Test func droppingOnAPlaylistPutsTheItemBelowIt() async {
        let (model, _) = await ready()
        let plan = model.sidebar.movePlan(dragging: node(model, "pl:5"), onto: node(model, "pl:2"), childIndex: -1)
        #expect(plan?.parentID == "1" && plan?.index == 1)
        #expect(plan?.outlineParent === node(model, "pf:1"))
        // A smart playlist is also a place to sit below.
        let below = model.sidebar.movePlan(dragging: node(model, "pl:5"), onto: node(model, "pl:3"), childIndex: -1)
        #expect(below?.index == 2)
    }

    @Test func movingThroughTheModelReachesTheCore() async {
        let (model, backend) = await ready()
        let plan = model.sidebar.movePlan(dragging: node(model, "pl:5"), onto: node(model, "pf:1"), childIndex: -1)!
        await model.move(node(model, "pl:5"), to: plan)
        #expect(await backend.editLog == ["movePlaylist(5,1,2)"])
        #expect(await eventually { model.sidebar.node(withID: "pl:5")?.parent === model.sidebar.node(withID: "pf:1") })
        // The core still refuses a cycle it is asked for.
        let sets = node(model, "pf:1")
        let bad = SidebarDropPlan(parentID: "2", index: 0, outlineParent: sets, outlineIndex: 0)
        await model.move(sets, to: bad)
        #expect(model.notice == "that would put a folder inside itself" || model.notice == "no playlist or folder 2")
    }

    // MARK: Tracks and playlists

    @Test func addToPlaylistOffersOrdinaryPlaylistsWithTheirFolders() async {
        let (model, _) = await ready()
        #expect(
            model.sidebar.playlistTargets() == [
                PlaylistTarget(id: "2", title: "Sets \u{203A} Warm-up"), PlaylistTarget(id: "4", title: "Loose"),
                PlaylistTarget(id: "5", title: "Zebra"),
            ])
    }

    @Test func addingTracksReportsHowManyWereNew() async {
        let (model, backend) = await ready()
        await model.addToPlaylist("4", trackIDs: ["1", "2"])
        #expect(model.notice == "Added 2 tracks to Loose.")
        await model.addToPlaylist("4", trackIDs: ["2"])
        #expect(model.notice == "Already in Loose.")
        await model.addToPlaylist("4", trackIDs: ["2", "3"])
        #expect(model.notice == "Added 1 track to Loose.")
        #expect(await backend.members(of: "4") == ["1", "2", "3"])
        #expect(await eventually { model.sidebar.node(withID: "pl:4")?.childCount == 3 })
    }

    @Test func addingToASmartPlaylistIsRefusedByTheCore() async {
        let (model, _) = await ready()
        await model.addToPlaylist("3", trackIDs: ["1"])
        #expect(model.notice == "no playlist 3")
    }

    @Test func theTrackMenuAddsToAPlaylistOnlyWhenEditing() async {
        let (model, _) = await ready()
        _ = model.pager.row(at: 0)
        await model.pager.settle()
        model.tableSelectionChanged(IndexSet(0..<2), keepingUnloaded: false)
        let rows = ContextMenus.trackMenu(model.trackMenuContext())
        let add = rows.compactMap { row -> MenuItemSpec? in if case .item(let i) = row, i.title == "Add To Playlist" { i } else { nil } }.first!
        #expect(add.isEnabled)
        let commands: [MenuCommand?] = (add.submenu ?? []).map { row in
            if case .item(let item) = row { item.command } else { nil }
        }
        #expect(commands == [.addToPlaylist("2"), .addToPlaylist("4"), .addToPlaylist("5")])
        // Closed gate, or no selection: greyed.
        let locked = ContextMenus.trackMenu(.init(selectionCount: 2, editable: false, playlists: model.sidebar.playlistTargets()))
        #expect(locked.compactMap { if case .item(let i) = $0, i.title == "Add To Playlist" { i } else { nil } }.first?.isEnabled == false)
    }

    @Test func removeFromPlaylistIsLiveOnlyInAnOrdinaryPlaylistWhileEditing() {
        let live = ContextMenus.trackMenu(.init(selectionCount: 1, editable: true, inPlaylist: true))
        let item = live.compactMap { row -> MenuItemSpec? in if case .item(let i) = row, i.title == "Remove from Playlist" { i } else { nil } }.first
        #expect(item?.command == .removeFromPlaylist)
        for context in [
            ContextMenus.TrackContext(selectionCount: 1, editable: false, inPlaylist: true),
            ContextMenus.TrackContext(selectionCount: 1, editable: true, inPlaylist: false),
            ContextMenus.TrackContext(selectionCount: 0, editable: true, inPlaylist: true),
        ] {
            let rows = ContextMenus.trackMenu(context)
            let entry = rows.compactMap { row -> MenuItemSpec? in if case .item(let i) = row, i.title == "Remove from Playlist" { i } else { nil } }.first
            #expect(entry?.isEnabled == false)
        }
    }

    @Test func removingTheSelectionFromAPlaylistAnnouncesAndRefreshes() async {
        let (model, backend) = await ready()
        await backend.setMembers(["1", "2", "3", "4"], of: "4")
        model.selectedNodeID = "pl:4"
        #expect(await eventually { model.opened?.handle.len == 4 })
        _ = model.pager.row(at: 0)
        await model.pager.settle()
        model.tableSelectionChanged(IndexSet([1, 2]), keepingUnloaded: false)
        #expect(model.selectedIDs == ["2", "3"] && model.canRemoveFromPlaylist)
        await model.removeSelectionFromPlaylist()
        #expect(model.notice == "Removed 2 tracks.")
        #expect(await backend.members(of: "4") == ["1", "4"])
        #expect(await eventually { model.opened?.handle.len == 2 })
        #expect(model.editHistory.undoLabel == "Remove Tracks from Playlist")
    }

    @Test func theDeleteKeyInAProtectedLibraryShowsTheCoresMessage() async {
        let (model, backend) = await ready(unlocked: false)
        await backend.setMembers(["1", "2"], of: "4")
        model.selectedNodeID = "pl:4"
        #expect(await eventually { model.opened?.handle.len == 2 })
        _ = model.pager.row(at: 0)
        await model.pager.settle()
        model.tableSelectionChanged(IndexSet([0]), keepingUnloaded: false)
        #expect(!model.canRemoveFromPlaylist)
        await model.removeSelectionFromPlaylist()
        #expect(model.notice == MockBackend.protectedMessage)
        #expect(await backend.members(of: "4") == ["1", "2"])
    }

    // MARK: Reordering

    @Test func reorderIsAllowedOnlyInAPlaylistShownInItsOwnOrder() async {
        let (model, _) = await ready()
        #expect(!model.canReorderRows)  // All Tracks
        model.selectedNodeID = "pl:4"
        #expect(await eventually { model.opened?.generation == 2 })
        #expect(model.canReorderRows)
        model.sort(by: .title, descending: false)
        #expect(!model.canReorderRows)
        model.sort(by: .trackNo, descending: true)
        #expect(!model.canReorderRows)
        model.sort(by: .trackNo, descending: false)
        #expect(model.canReorderRows)
        model.query = "Track"
        #expect(!model.canReorderRows)
        model.query = ""
        model.selectedNodeID = "pl:3"  // a smart playlist
        #expect(!model.canReorderRows)
        model.selectedNodeID = "pl:4"
        model.protectLibrary = true
        #expect(await eventually { !model.canReorderRows })
    }

    @Test func aFilterThatNarrowsTheViewBlocksReordering() async {
        let (model, _) = await ready()
        model.selectedNodeID = "pl:4"
        #expect(await eventually { model.opened?.generation == 2 })
        model.filterBarOpen = true
        #expect(model.canReorderRows)  // open but nothing picked
        model.filterState.rating.enabled = true
        #expect(!model.canReorderRows)
    }

    @Test func theReorderPlanCountsTheDropLineAgainstTheRowsThatStay() {
        let all = ["a", "b", "c", "d", "e"]
        #expect(ReorderPlan.order(all: all, carried: ["d"], insertionRow: 1) == ["a", "d", "b", "c", "e"])
        #expect(ReorderPlan.order(all: all, carried: ["b"], insertionRow: 5) == ["a", "c", "d", "e", "b"])
        #expect(ReorderPlan.order(all: all, carried: ["b", "d"], insertionRow: 0) == ["b", "d", "a", "c", "e"])
        // The line below a carried row sits where the row was.
        #expect(ReorderPlan.order(all: all, carried: ["b"], insertionRow: 2) == all)
        // Carried rows keep their view order whatever order the pasteboard held them in.
        #expect(ReorderPlan.order(all: all, carried: ["e", "a"], insertionRow: 3) == ["b", "c", "a", "e", "d"])
        #expect(ReorderPlan.order(all: all, carried: [], insertionRow: 2) == all)
    }

    @Test func reorderingSendsTheFullNewOrderAndSkipsANoOp() async {
        let (model, backend) = await ready()
        await backend.setMembers(["1", "2", "3", "4"], of: "4")
        model.selectedNodeID = "pl:4"
        #expect(await eventually { model.opened?.handle.len == 4 })
        await model.reorderRows(carried: ["4"], insertionRow: 1)
        #expect(await backend.members(of: "4") == ["1", "4", "2", "3"])
        await model.reorderRows(carried: ["1"], insertionRow: 0)  // already first
        #expect(await backend.editLog.filter { $0.hasPrefix("reorder") }.count == 1)
    }

    @Test func aRefusedReorderAlsoLeavesTheOrderAlone() async {
        let (model, backend) = await ready()
        await backend.setMembers(["1", "2", "3"], of: "4")
        model.selectedNodeID = "pl:4"
        #expect(await eventually { model.opened?.handle.len == 3 })
        model.protectLibrary = true
        #expect(await eventually { model.isReadOnly })
        await model.reorderRows(carried: ["3"], insertionRow: 0)
        #expect(await backend.members(of: "4") == ["1", "2", "3"])
        #expect(await backend.editLog.isEmpty)  // never reached the core: the rows were not draggable
    }

    // MARK: Library changes

    @Test func theSelectionSurvivesAnEditThatReloadsTheLibrary() async {
        let (model, _) = await ready()
        _ = model.pager.row(at: 0)
        await model.pager.settle()
        model.tableSelectionChanged(IndexSet([3, 4]), keepingUnloaded: false)
        let before = model.selectedIDs
        await model.createFolder(near: nil, beginRename: false)
        #expect(await eventually { model.sidebar.node(withID: "pf:100") != nil })
        // The new folder is selected (a different source) and then the old one comes back by id.
        model.selectedNodeID = "all"
        #expect(model.selectedIDs.isEmpty)
        model.tableSelectionChanged(IndexSet([3, 4]), keepingUnloaded: false)
        #expect(model.selectedIDs == before)
        await model.rename(node(model, "pl:4"), to: "Elsewhere")
        #expect(await eventually { model.sidebar.node(withID: "pl:4")?.name == "Elsewhere" })
        #expect(model.selectedIDs == before)
    }

    @Test func editHistoryEventsUpdateTheMenuState() async {
        let (model, _) = await ready()
        await model.handle(
            .editHistoryChanged(
                history: EditHistory(generation: 9, canUndo: true, canRedo: false, undoLabel: "Move Playlist", redoLabel: nil)))
        #expect(model.undoMenuTitle == "Undo Move Playlist" && model.canUndo)
    }

    // MARK: Tree menu

    @Test func theTreeMenuEntriesGoLiveWhileEditing() {
        func live(_ kind: SidebarNode.Kind, _ editable: Bool) -> [String] {
            (ContextMenus.treeMenu(for: kind, editable: editable) ?? []).compactMap {
                if case .item(let i) = $0, i.isEnabled { i.title } else { nil }
            }
        }
        #expect(live(.folder, false).isEmpty)
        #expect(
            live(.folder, true) == [
                "Create New Playlist", "Create New Folder", "Create New Intelligent Playlist", "Rename Folder", "Delete Folder", "Sort Items",
            ])
        #expect(live(.smartPlaylist, true).contains("Edit Intelligent Playlist"))
        #expect(!live(.playlist, true).contains("Edit Intelligent Playlist"))
        #expect(live(.playlist, true).contains("Rename Playlist") && live(.playlist, true).contains("Delete Playlist"))
        // The file export never depended on the gate.
        #expect(live(.playlist, false) == ["Export a playlist to a file"])
        #expect(live(.section(.playlists), true) == ["Create New Playlist", "Create New Folder", "Create New Intelligent Playlist"])
    }

    @Test func menuCommandsReachTheModel() async {
        let (model, backend) = await ready()
        model.runTreeMenu(.rename, on: node(model, "pl:4"))
        #expect(model.sidebar.renameRequest == "pl:4")
        model.runTreeMenu(.createFolder, on: node(model, "pf:1"))
        #expect(await eventually { await backend.editLog.contains("createFolder(New Folder,1)") })
        model.runTreeMenu(.delete, on: node(model, "pl:5"))
        #expect(await eventually { await backend.editLog.contains("deletePlaylist(5)") })
    }

    @Test func demoEditsRefuseToRunWithoutAFixture() async {
        let (model, backend) = await ready()
        await backend.setIsFixture(false)
        await model.runDemoEdit("create-playlist")
        #expect(await backend.editLog.isEmpty)
        #expect(model.notice == "Demo edits only run against a fixture library.")
        #expect(await backend.protectCalls.allSatisfy { !$0 })  // the hook never opened or closed the gate itself
    }
}
