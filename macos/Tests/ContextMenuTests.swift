import Foundation
import Testing

@testable import rbxport

@MainActor
struct ContextMenuTests {
    private func items(_ rows: [MenuRow]) -> [MenuItemSpec] {
        rows.compactMap { if case .item(let item) = $0 { item } else { nil } }
    }

    private func titles(_ rows: [MenuRow]) -> [String] { items(rows).map(\.title) }

    @Test func theTrackMenuFollowsRekordboxOrder() {
        let rows = ContextMenus.trackMenu(.init(selectionCount: 1))
        #expect(
            titles(rows) == [
                "Load", "Import To Collection", "Analyze Track", "Analysis Lock", "Add To Playlist", "Add To Tag List",
                "Reload Tag", "Get Info from iTunes", "Track Type", "Export Track", "Auto Load Hot Cue",
                "Reset DJ Play Count", "Add New Analysis Data", "Convert Memory Cues to Hot Cues",
                "Remove from Playlist", "Remove from Collection", "Remove from History", "Show information",
                "Show in Finder", "Track information",
            ])
        #expect(rows.filter { $0 == .separator }.count == 7)
    }

    @Test func onlyShowInformationAndShowInFinderAreLive() {
        let live = items(ContextMenus.trackMenu(.init(selectionCount: 2))).filter(\.isEnabled)
        #expect(live.map(\.title) == ["Show information", "Show in Finder"])
        #expect(live.map(\.command) == [.showInformation, .showInFinder])
    }

    @Test func loadToPlayer1IsLiveForOneTrackAndPlayer2WaitsForTheDualDecks() {
        let rows = ContextMenus.trackMenu(.init(selectionCount: 1))
        let load = items(rows).first { $0.title == "Load" }!
        #expect(load.isEnabled)
        #expect(titles(load.submenu!) == ["Load track to player 1", "Load track to player 2"])
        #expect(items(load.submenu!).map(\.isEnabled) == [true, false])
        #expect(items(load.submenu!).first?.command == .loadToDeck(.a))
        let many = items(ContextMenus.trackMenu(.init(selectionCount: 2))).first { $0.title == "Load" }!
        #expect(!many.isEnabled)
    }

    @Test func withNothingSelectedEverythingIsGreyed() {
        #expect(items(ContextMenus.trackMenu(.init(selectionCount: 0))).allSatisfy { !$0.isEnabled })
    }

    @Test func theTagListAndExplorerAdjustTheMenu() {
        let tag = titles(ContextMenus.trackMenu(.init(selectionCount: 1, inTagList: true)))
        #expect(tag.contains("Remove from Tag List") && !tag.contains("Remove from Playlist"))
        let explorer = titles(ContextMenus.trackMenu(.init(selectionCount: 1, inExplorer: true)))
        #expect(!explorer.contains("Convert Memory Cues to Hot Cues"))
    }

    @Test func aPlaylistExportsToM3u8AndTxt() {
        let rows = ContextMenus.treeMenu(for: .playlist)!
        let export = items(rows).first { $0.title == "Export a playlist to a file" }!
        #expect(export.isEnabled)
        #expect(items(export.submenu!).map(\.title) == ["m3u8", "txt"])
        #expect(items(export.submenu!).map(\.command) == [.exportPlaylist(.m3u8), .exportPlaylist(.txt)])
        // Every other entry is an edit, greyed.
        let others = items(rows).filter { $0.title != "Export a playlist to a file" }
        #expect(others.allSatisfy { !$0.isEnabled })
        #expect(titles(rows).first == "Export Playlist")
    }

    @Test func aSmartPlaylistAddsItsEditorAndAFolderHasNoFileExport() {
        #expect(titles(ContextMenus.treeMenu(for: .smartPlaylist)!).contains("Edit Intelligent Playlist"))
        #expect(!titles(ContextMenus.treeMenu(for: .playlist)!).contains("Edit Intelligent Playlist"))
        let folder = ContextMenus.treeMenu(for: .folder)!
        #expect(titles(folder).first == "Export Folder")
        #expect(items(folder).allSatisfy { !$0.isEnabled })
    }

    @Test func menusExistOnlyWhereRekordboxHasThem() {
        #expect(ContextMenus.treeMenu(for: .section(.playlists)).map(titles) == ["Create New Playlist", "Create New Folder"])
        #expect(ContextMenus.treeMenu(for: .history) == nil)
        #expect(ContextMenus.treeMenu(for: .explorerFolder) == nil)
        #expect(ContextMenus.treeMenu(for: .allTracks) == nil)
    }

    // MARK: Commands

    @Test func showInFinderRevealsTheSelectedTracksFiles() async {
        let model = AppModel(backend: MockBackend(), layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        var revealed: [URL] = []
        model.reveal = { revealed = $0 }
        await model.revealInFinder(trackIDs: ["3", "7"])
        #expect(revealed.map(\.lastPathComponent) == ["track-3.mp3", "track-7.mp3"])
    }

    @Test func showInformationOpensTheInfoPanel() async {
        let model = AppModel(backend: MockBackend(), layoutStore: isolatedStore())
        #expect(!model.infoPanelOpen)
        model.runTrackMenu(.showInformation)
        #expect(model.infoPanelOpen)
    }

    @Test func exportingAPlaylistWritesThroughTheBackendAndSaysSo() async {
        let backend = MockBackend()
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        let url = URL(fileURLWithPath: "/tmp/out.txt")
        let count = await model.exportPlaylist(nodeID: "pl:10", to: url, format: .txt)
        #expect(count == 5)
        let export = await backend.exports.last
        #expect(export?.playlistID == "10" && export?.path == "/tmp/out.txt" && export?.format == .txt)
        #expect(model.notice == "Exported 5 tracks to out.txt.")
        // Only playlists export: a folder or history is refused before the backend.
        #expect(await model.exportPlaylist(nodeID: "pf:1", to: url, format: .m3u8) == nil)
        #expect(await backend.exports.count == 1)
    }

    @Test func theMenuTargetsTheSelectionAndSourceOfTheModel() async {
        let model = AppModel(backend: MockBackend(), layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        #expect(model.trackMenuContext() == .init(selectionCount: 0))
        model.selectNode("tag")
        #expect(model.trackMenuContext().inTagList)
        model.selectNode("ex:/m")
        #expect(model.trackMenuContext().inExplorer)
    }
}
