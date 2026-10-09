import Foundation
import Testing

@testable import rbxport

/// Scripted answers for the native panels, and a record of what was asked.
@MainActor
final class StubDialogs {
    var confirms = true
    var audio: [URL] = []
    var file: URL?
    var folder: URL?
    private(set) var confirmed: [(message: String, detail: String)] = []
    private(set) var informed: [(message: String, detail: String)] = []
    private(set) var audioPrompts: [(prompt: String, directories: Bool)] = []

    var dialogs: Dialogs {
        Dialogs(
            confirm: { [self] message, detail, _ in
                confirmed.append((message, detail))
                return confirms
            },
            chooseAudio: { [self] prompt, directories in
                audioPrompts.append((prompt, directories))
                return audio
            },
            chooseFile: { [self] _, _ in file },
            chooseFolder: { [self] _ in folder },
            inform: { [self] message, detail in informed.append((message, detail)) })
    }
}

@MainActor
@Suite(.scratchDefaults)
struct MetadataEditingTests {
    private func ready(unlocked: Bool = true, nodes: [TreeNode]? = nil) async -> (AppModel, MockBackend, StubDialogs) {
        let backend = MockBackend(trackCount: 50, nodes: nodes)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        if unlocked { model.protectLibrary = false }
        let stub = StubDialogs()
        model.dialogs = stub.dialogs
        model.start()
        #expect(await eventually { model.opened != nil && (!unlocked || !model.isReadOnly) })
        return (model, backend, stub)
    }

    /// Selects rows by index and waits for the ids of rows that are not loaded to arrive.
    private func select(_ model: AppModel, _ indexes: [Int]) async {
        model.tableSelectionChanged(IndexSet(indexes), keepingUnloaded: false)
        await model.settleSelection()
        #expect(await eventually { model.selectedIDs.count == indexes.count })
    }

    private func items(_ rows: [MenuRow]) -> [MenuItemSpec] {
        rows.compactMap { if case .item(let item) = $0 { item } else { nil } }
    }

    // MARK: Validation

    @Test func bpmAndNumbersAreCheckedBeforeARoundTrip() {
        for good in ["40", "128", " 499 ", "127.5"] { #expect(FieldCheck.problem(.bpm, good) == nil, "\(good)") }
        for bad in ["", "abc", "39.9", "500", "NaN", "inf", "-120"] {
            #expect(FieldCheck.problem(.bpm, bad) == "Enter a BPM from 40 to 499.", "\(bad)")
        }
        #expect(FieldCheck.problem(.year, "1999") == nil)
        #expect(FieldCheck.problem(.year, "19x9") == "19x9 is not a whole number")
        #expect(FieldCheck.problem(.playCount, "") != nil)
        #expect(FieldCheck.problem(.title, "anything at all") == nil)
        #expect(FieldCheck.problem(.title, "") == nil, "an empty title is the core's to judge")
    }

    @Test func theTableEditsTheColumnsTheReactTableDoes() {
        let targets: [ColumnID: CellTarget] = [
            .title: .field(.title), .artist: .field(.artist), .album: .field(.album), .genre: .field(.genre),
            .label: .field(.label), .bpm: .field(.bpm), .comment: .comment,
        ]
        for column in ColumnID.allCases { #expect(EditableCells.target(for: column) == targets[column], "\(column)") }
        #expect(!EditableCells.editsOnDoubleClick(.title), "double-click on the title still loads the track")
        #expect(EditableCells.editsOnDoubleClick(.comment) && EditableCells.editsOnDoubleClick(.bpm))
        #expect(!EditableCells.editsOnDoubleClick(.key))
    }

    @Test func aClickOnTheLitStarClearsTheRating() {
        #expect(RatingClick.result(current: 3, clicked: 3) == 0)
        #expect(RatingClick.result(current: 3, clicked: 5) == 5)
        #expect(RatingClick.result(current: 0, clicked: 1) == 1)
        #expect(RatingClick.message(0) == "Rating cleared." && RatingClick.message(4) == "Rated 4 of 5.")
    }

    @Test func starsAreFoundByTheirPositionInTheCell() {
        #expect(RatingCellView.star(atX: 1) == nil, "left of the stars")
        #expect(RatingCellView.star(atX: 5) == 1)
        #expect(RatingCellView.star(atX: 4 + RatingCellView.starWidthForTests * 4.5) == 5)
        #expect(RatingCellView.star(atX: 4 + RatingCellView.starWidthForTests * 5.5) == nil, "right of the fifth star")
    }

    // MARK: Cell edits

    @Test func aCommittedCellWritesThroughTheBackendAndSaysSo() async {
        let (model, backend, _) = await ready()
        #expect(await model.commitCell(trackID: "3", column: .title, text: "Renamed"))
        #expect(model.notice == "Track Title saved.")
        #expect(await backend.editLog == ["setTrackField(3,title,Renamed)"])
        #expect(await model.commitCell(trackID: "3", column: .comment, text: "warm"))
        #expect(model.notice == "Comment saved.")
        // The reload brings the new text back into the rows.
        #expect(await eventually { model.pager.row(at: 2)?.title == "Renamed" && model.pager.row(at: 2)?.comment == "warm" })
        #expect(model.editHistory.undoLabel == "Track Edit")
    }

    @Test func aBadBpmOrNumberNeverReachesTheBackend() async {
        let (model, backend, _) = await ready()
        #expect(await model.commitCell(trackID: "3", column: .bpm, text: "20") == false)
        #expect(model.notice == "Enter a BPM from 40 to 499.")
        #expect(await model.setField(.year, to: "soon", ids: ["3"]) == false)
        #expect(model.notice == "soon is not a whole number")
        #expect(await backend.editLog.isEmpty)
        #expect(await model.commitCell(trackID: "3", column: .bpm, text: "128"))
        #expect(model.notice == "BPM saved.")
        // A BPM edit is not undoable (the files change with the row).
        #expect(!model.editHistory.canUndo)
    }

    @Test func aColumnThatDoesNotEditIsIgnored() async {
        let (model, backend, _) = await ready()
        #expect(await model.commitCell(trackID: "3", column: .key, text: "Am") == false)
        #expect(await backend.editLog.isEmpty)
    }

    @Test func aLockedLibraryRefusesWithTheCoresOwnWords() async {
        let (model, backend, _) = await ready(unlocked: false)
        #expect(await model.commitCell(trackID: "3", column: .title, text: "x") == false)
        #expect(model.notice == MockBackend.protectedMessage)
        #expect(await model.setRating(3, ids: ["3"]) == false)
        #expect(model.notice == MockBackend.protectedMessage)
        #expect(!model.canEditTrack("3"))
        #expect(await backend.editLog.count == 2)
    }

    @Test func aLooseFileCannotBeEdited() async {
        let (model, backend, _) = await ready()
        #expect(!model.canEditTrack("file:/music/a.mp3") && model.canEditTrack("3"))
        for done in [
            await model.commitCell(trackID: "file:/m/a.mp3", column: .title, text: "x"),
            await model.setRating(2, ids: ["file:/m/a.mp3"]),
            await model.setColor(2, ids: ["file:/m/a.mp3"]),
            await model.setComment("x", ids: ["3", "file:/m/a.mp3"]),
        ] { #expect(!done) }
        #expect(model.notice == "That file is not in the collection. Import it first.")
        #expect(await backend.editLog.isEmpty)
    }

    // MARK: Ratings and colours

    @Test func starClicksSetAndClearTheRating() async {
        let (model, backend, _) = await ready()
        #expect(await model.clickStar(4, current: 0, id: "5"))
        #expect(model.notice == "Rated 4 of 5.")
        #expect(await model.clickStar(4, current: 4, id: "5"))
        #expect(model.notice == "Rating cleared.")
        #expect(await backend.editLog == ["setTrackRating(5,4)", "setTrackRating(5,0)"])
        #expect(await eventually { model.pager.row(at: 4)?.rating == 0 })
    }

    @Test func aRatingOfSixIsMalformedAndLeavesTheTrackAlone() async {
        let (model, backend, _) = await ready()
        #expect(await model.setRating(6, ids: ["5"]) == false)
        #expect(model.notice == "6 is not a rating between 0 and 5")
        #expect(await backend.meta["5"]?.rating == nil)
        #expect(model.editHistory.canUndo == false)
    }

    @Test func aColourIsCheckedAndOneUndoStepCoversTheWholeSelection() async {
        let (model, backend, _) = await ready()
        #expect(await model.setColor(9, ids: ["1"]) == false)
        #expect(model.notice == "9 is not a colour from 0 to 8.")
        #expect(await model.setColor(3, ids: ["1", "2", "3"]))
        #expect(model.notice == "Color saved.")
        #expect(await eventually { model.editHistory.canUndo })
        #expect(await model.setColor(0, ids: ["2"]))
        #expect(model.notice == "Color cleared.")
        await model.stepHistory(redo: false)
        await model.stepHistory(redo: false)
        let first = await backend.meta["1"]?.color
        let third = await backend.meta["3"]?.color
        #expect(first == nil && third == nil)
    }

    @Test func theColourMenuListsNoneAndEightDotsAndRunsOnTheSelection() async {
        let (model, backend, _) = await ready()
        await select(model, [0, 1])
        let rows = ContextMenus.trackMenu(model.trackMenuContext())
        let color = items(rows).first { $0.title == "Color" }!
        #expect(color.isEnabled)
        let entries = items(color.submenu!)
        #expect(entries.map(\.title) == ["None", "Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"])
        #expect(entries.map(\.colorDot) == (0...8).map { UInt8($0) })
        #expect(entries.map(\.command) == (0...8).map { MenuCommand.setColor(UInt8($0)) })
        model.runTrackMenu(.setColor(6))
        #expect(await eventually(timeout: .seconds(2)) { await backend.editLog.contains { $0.hasPrefix("setTrackColor(") } })
        #expect(await backend.editLog.last == "setTrackColor(1,2,6)")
    }

    @Test func theColourMenuIsGreyWhenLockedOrOverLooseFiles() {
        func color(_ context: ContextMenus.TrackContext) -> MenuItemSpec {
            items(ContextMenus.trackMenu(context)).first { $0.title == "Color" }!
        }
        #expect(!color(.init(selectionCount: 1, editable: false)).isEnabled)
        #expect(!color(.init(selectionCount: 0, editable: true)).isEnabled)
        #expect(!color(.init(selectionCount: 1, editable: true, hasLoose: true)).isEnabled)
        #expect(color(.init(selectionCount: 1, editable: true)).isEnabled)
    }

    // MARK: The info panel

    @Test func theInfoPanelEditsItsSingleTrackAndFollowsTheGate() async {
        let (model, backend, _) = await ready()
        #expect(model.info.editable)
        await select(model, [2])
        model.showInformation()
        model.info.tab = .info
        #expect(await eventually { model.info.details?.id == "3" })
        #expect(await model.info.edit(.rating(5)))
        #expect(await model.info.edit(.color(4)))
        #expect(await model.info.edit(.comment("loud")))
        #expect(await model.info.edit(.field(.genre, "Techno")))
        #expect(
            await backend.editLog == [
                "setTrackRating(3,5)", "setTrackColor(3,4)", "setTrackComment(3,loud)", "setTrackField(3,genre,Techno)",
            ])
        #expect(await eventually { model.info.details?.comment == "loud" && model.info.details?.rating == 5 })
        model.protectLibrary = true
        #expect(await eventually { !model.info.editable })
        #expect(await model.info.edit(.rating(1)) == false)
        #expect(model.notice == MockBackend.protectedMessage)
    }

    @Test func severalSelectedTracksTakeARatingTogether() async {
        let (model, backend, _) = await ready()
        #expect(await model.setRating(2, ids: ["1", "2", "3"]))
        #expect(await backend.editLog == ["setTrackRating(1,2,3,2)"])
        #expect(await eventually { model.editHistory.canUndo })
        await model.stepHistory(redo: false)
        #expect(await backend.meta["2"]?.rating == nil)
    }

    // MARK: Tag List, history, collection

    @Test func theTagListTakesAndGivesBackTracksAndItsOpenViewFollows() async {
        let (model, backend, _) = await ready()
        await select(model, [4, 5])
        await model.addSelectionToTagList()
        #expect(model.notice == "Added 2 tracks to the Tag List.")
        #expect(await backend.tagList == ["5", "6"])
        model.selectNode("tag")
        #expect(await eventually { model.opened?.handle.len == 2 })
        await select(model, [0])
        await model.removeSelectionFromTagList()
        #expect(model.notice == "Removed 1 track from the Tag List.")
        #expect(await eventually { model.opened?.handle.len == 1 })
        #expect(await backend.tagList == ["6"])
    }

    @Test func theTrackMenuOffersTheTagListHistoryAndCollectionEntries() {
        func live(_ context: ContextMenus.TrackContext) -> [String] {
            items(ContextMenus.trackMenu(context)).filter(\.isEnabled).map(\.title)
        }
        let plain = live(.init(selectionCount: 2, editable: true))
        for title in ["Add To Tag List", "Reload Tag", "Reset DJ Play Count", "Remove from Collection", "Color"] {
            #expect(plain.contains(title), "\(title)")
        }
        #expect(!plain.contains("Remove from History") && !plain.contains("Import To Collection"))
        #expect(live(.init(selectionCount: 1, editable: true, inHistory: true)).contains("Remove from History"))
        #expect(live(.init(selectionCount: 1, inTagList: true, editable: true)).contains("Remove from Tag List"))
        let loose = live(.init(selectionCount: 1, editable: true, hasLoose: true, allLoose: true))
        #expect(loose.contains("Import To Collection") && !loose.contains("Remove from Collection"))
        // Locked: the edits are greyed.
        let locked = live(.init(selectionCount: 2, editable: false))
        #expect(locked == ["Show information", "Show in Finder"])
    }

    @Test func resettingAPlayCountReloadingATagAndLeavingTheHistoryGoThroughTheBackend() async {
        let (model, backend, _) = await ready(
            nodes: MockBackend.sampleTree + [
                TreeNode(id: "histories", name: "Histories", kind: .histories, depth: 0, expanded: true, childCount: 1),
                TreeNode(id: "6", name: "2026", kind: .historyFolder, depth: 1, expanded: true, childCount: nil),
                TreeNode(id: "7", name: "HISTORY 2026-09-01", kind: .history, depth: 2, expanded: nil, childCount: 3),
            ])
        await select(model, [0, 1])
        await model.resetSelectionPlayCount()
        #expect(model.notice == "DJ Play Count reset on 2 tracks.")
        await model.reloadSelectionTags()
        #expect(model.notice == "Tags reloaded on 2 tracks.")
        // Remove from History needs a history view.
        await model.removeSelectionFromHistory()
        #expect(await backend.editLog.count == 2)
        model.selectNode("hi:7")
        #expect(model.openHistoryID == "7")
        #expect(await eventually { await model.opened?.handle.viewId == backend.latestViewID })
        await select(model, [0])
        await model.removeSelectionFromHistory()
        #expect(model.notice == "Removed 1 play from the history.")
        #expect(await backend.editLog.last == "removeFromHistory(7,1)")
    }

    @Test func removingFromTheCollectionAsksFirstAndIsPermanent() async {
        let (model, backend, stub) = await ready()
        _ = await model.setRating(3, ids: ["1"])
        #expect(await eventually { model.editHistory.canUndo })
        await select(model, [0, 1])
        stub.confirms = false
        await model.removeSelectionFromCollection()
        #expect(stub.confirmed.count == 1)
        #expect(stub.confirmed[0].message == "Remove 2 tracks from the collection?")
        #expect(stub.confirmed[0].detail == "This can\u{2019}t be undone. The files stay where they are.")
        #expect(await backend.removedTracks.isEmpty)

        stub.confirms = true
        await model.removeSelectionFromCollection()
        #expect(model.notice == "Removed 2 tracks from the collection.")
        #expect(await backend.removedTracks == ["1", "2"])
        // The undo history went with it.
        #expect(await eventually { !model.editHistory.canUndo })
        #expect(await eventually { model.opened?.handle.len == 48 })
    }
}
