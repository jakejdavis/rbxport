import Foundation
import Testing

@testable import rbxport

@MainActor
struct SidebarTests {
    private func node(_ id: String, _ name: String, _ kind: NodeKind, _ depth: UInt32, open: Bool? = nil, count: UInt32? = nil)
        -> TreeNode
    {
        TreeNode(id: id, name: name, kind: kind, depth: depth, expanded: open, childCount: count)
    }

    /// All Tracks, a playlist folder with one playlist and one smart playlist in it, and the
    /// histories: a year, a month, and a session in it (plus a session straight under the year).
    private var flat: [TreeNode] {
        [
            node("all", "All Tracks", .allTracks, 0, count: 100),
            node("playlists", "Playlists", .collection, 0, open: true, count: 3),
            node("1", "Sets", .folder, 1, open: true, count: 2),
            node("2", "Warm-up", .playlist, 2, count: 20),
            node("3", "Peak", .smartPlaylist, 2),
            node("4", "Loose", .playlist, 1, count: 4),
            node("histories", "Histories", .histories, 0, open: true, count: 3),
            node("10", "2026", .historyFolder, 1, open: true),
            node("11", "October", .historyFolder, 2, open: false),
            node("12", "Friday night", .history, 3, count: 30),
            node("13", "Rehearsal", .history, 2, count: 8),
        ]
    }

    private func sidebar(_ backend: MockBackend = MockBackend(), store: ColumnLayoutStore = isolatedStore()) -> SidebarModel {
        let model = SidebarModel(backend: backend, defaults: store.defaults)
        model.setLibraryTree(flat)
        return model
    }

    @Test func sectionsComeInOrderAndHideWhenEmpty() {
        let model = sidebar()
        #expect(model.visibleSections.map(\.name) == ["Playlists", "Histories", "Explorer", "Devices", "Tag List"])
        model.setLibraryTree([node("all", "All Tracks", .allTracks, 0, count: 0)])
        #expect(model.visibleSections.map(\.name) == ["Playlists", "Explorer", "Devices", "Tag List"])
    }

    @Test func playlistsNestUnderTheirFoldersWithKindPrefixedIDs() {
        let playlists = sidebar().section(.playlists)
        #expect(playlists.children.map(\.id) == ["all", "pf:1", "pl:4"])
        let sets = playlists.children[1]
        #expect(sets.kind == .folder)
        #expect(sets.children.map(\.id) == ["pl:2", "pl:3"])
        #expect(sets.children.map(\.kind) == [.playlist, .smartPlaylist])
        #expect(sets.children[0].parent === sets)
        #expect(playlists.children[0].kind == .allTracks)
    }

    @Test func historiesNestYearMonthSessionAndMonthsStartCollapsed() {
        let model = sidebar()
        let year = model.section(.histories).children[0]
        #expect(year.kind == .historyFolder)
        #expect(year.children.map(\.id) == ["hi:11", "hi:13"])
        let month = year.children[0]
        #expect(month.kind == .historyFolder)
        #expect(month.children.map(\.kind) == [.history])
        #expect(model.isExpanded(year))
        #expect(!model.isExpanded(month))
        #expect(model.isExpanded(model.section(.histories)))
        // Sessions are leaves.
        #expect(!month.children[0].isExpandable)
    }

    @Test func idsResolveToSources() {
        #expect(SidebarNode.source(forID: "all") == .collection)
        #expect(SidebarNode.source(forID: "pl:2") == .playlist(id: "2"))
        #expect(SidebarNode.source(forID: "pf:1") == .playlistFolder(id: "1"))
        #expect(SidebarNode.source(forID: "hi:12") == .history(id: "12"))
        #expect(SidebarNode.source(forID: "ex:/Users/me/Music") == .folder(path: "/Users/me/Music"))
        #expect(SidebarNode.source(forID: "tag") == .tagList)
        #expect(SidebarNode.source(forID: "section:playlists") == nil)
        #expect(SidebarNode.source(forID: "dev:abc") == nil)
    }

    @Test func headingsDevicesAndNotesAreNotSelectable() {
        let model = sidebar()
        #expect(!model.section(.playlists).isSelectable)
        #expect(!model.section(.devices).children[0].isSelectable)  // "No devices"
        #expect(model.canSelect("pl:2"))
        #expect(model.canSelect("tag"))
        #expect(model.canSelect("ex:/anywhere"))  // not loaded yet, still restorable
        #expect(!model.canSelect("pl:999"))
    }

    @Test func expansionDefaultsComeFromTheCoreAndUserTogglesPersist() {
        let store = isolatedStore()
        let model = sidebar(store: store)
        let sets = model.node(withID: "pf:1")!
        #expect(model.isExpanded(sets))  // the core opens top-level folders
        model.setExpanded(sets, false)
        model.setExpanded(model.section(.histories), false)

        let restored = sidebar(store: store)  // a new launch over the same defaults
        #expect(!restored.isExpanded(restored.node(withID: "pf:1")!))
        #expect(!restored.isExpanded(restored.section(.histories)))
        #expect(restored.isExpanded(restored.section(.playlists)))
    }

    @Test func childCountsAreAPreferenceDefaultingOff() {
        let store = isolatedStore()
        let model = sidebar(store: store)
        #expect(!model.showChildCounts)
        let before = model.version
        model.showChildCounts = true
        #expect(model.version > before)
        #expect(sidebar(store: store).showChildCounts)
        #expect(model.node(withID: "pl:2")!.showsCount)
        #expect(!model.node(withID: "pl:3")!.showsCount)  // an intelligent playlist has no count
    }

    @Test func devicesAreListed() async {
        let backend = MockBackend()
        let model = sidebar(backend)
        let stick = Device(
            name: "DJ STICK", path: "/Volumes/DJ STICK", totalBytes: 100, freeBytes: 50, fileSystem: "exfat",
            removable: true, volumeId: "vol-1", export: nil)
        await backend.setDevices([stick])
        await model.refreshDevices()
        let devices = model.section(.devices).children
        #expect(devices.map(\.name) == ["DJ STICK"])
        #expect(devices[0].kind == .device)
        await backend.setDevices([])
        await model.refreshDevices()
        #expect(model.section(.devices).children.map(\.name) == ["No devices"])
    }

    // MARK: Explorer

    @Test func explorerRootsLoadTheirChildrenOnlyWhenAsked() async {
        let backend = MockBackend()
        await backend.setExplorer(
            roots: [ExplorerRoot(name: "Music", path: "/m")],
            folders: ["/m": ExplorerChildren(names: ["House", "Techno"], total: 2), "/m/House": ExplorerChildren(names: ["Deep"], total: 1)])
        let model = sidebar(backend)
        model.setExplorerRoots(try! await backend.explorerRoots())
        let music = model.section(.explorer).children[0]
        #expect(music.kind == .explorerRoot)
        #expect(music.isExpandable)  // not read yet: it may have subfolders
        #expect(await backend.explorerChildrenCalls.isEmpty)

        var reloaded: [String] = []
        model.onNodeReloaded = { reloaded.append($0.id) }
        await model.loadChildren(of: music)
        #expect(music.children.map(\.id) == ["ex:/m/House", "ex:/m/Techno"])
        #expect(music.children[0].kind == .explorerFolder)
        #expect(reloaded == ["ex:/m"])
        #expect(await backend.explorerChildrenCalls == ["/m"])

        // Once read, a second request does nothing.
        await model.loadChildren(of: music)
        #expect(await backend.explorerChildrenCalls == ["/m"])

        // A folder with no subfolders loses its disclosure triangle after it is read.
        let techno = music.children[1]
        await model.loadChildren(of: techno)
        #expect(!techno.isExpandable)
    }

    @Test func aCappedFolderShowsHowManyAreNotShown() async {
        let backend = MockBackend()
        await backend.setExplorer(
            roots: [ExplorerRoot(name: "Big", path: "/big")],
            folders: ["/big": ExplorerChildren(names: ["a", "b"], total: 2_002)])
        let model = sidebar(backend)
        model.setExplorerRoots(try! await backend.explorerRoots())
        let big = model.section(.explorer).children[0]
        await model.loadChildren(of: big)
        #expect(big.children.map(\.name) == ["a", "b", "2000 more folders not shown"])
        let note = big.children[2]
        #expect(note.kind == .note)
        #expect(!note.isSelectable)
        #expect(SidebarNode.source(forID: note.id) == nil)
    }

    @Test func expandedExplorerFoldersReloadAtStartup() async {
        let store = isolatedStore()
        let backend = MockBackend()
        await backend.setExplorer(
            roots: [ExplorerRoot(name: "Music", path: "/m")],
            folders: ["/m": ExplorerChildren(names: ["House"], total: 1), "/m/House": ExplorerChildren(names: ["Deep"], total: 1)])
        let first = sidebar(backend, store: store)
        first.setExplorerRoots(try! await backend.explorerRoots())
        let music = first.section(.explorer).children[0]
        await first.loadChildren(of: music)
        first.setExpanded(music, true)
        first.setExpanded(music.children[0], true)

        let second = sidebar(backend, store: store)
        second.setExplorerRoots(try! await backend.explorerRoots())
        await second.restoreExplorer()
        let house = second.node(withID: "ex:/m/House")
        #expect(house?.childrenLoaded == true)
        #expect(house?.children.map(\.id) == ["ex:/m/House/Deep"])
    }

    @Test func selectingADirectoryOpensAFolderViewInTheFolderContext() async {
        let backend = MockBackend()
        await backend.setExplorer(roots: [ExplorerRoot(name: "Music", path: "/m")], folders: [:])
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        model.selectNode("ex:/m")
        #expect(await eventually { model.opened?.generation == 2 })
        #expect(await backend.openedSpecs.last?.source == .folder(path: "/m"))
        #expect(model.context == .folder)
    }
}

@MainActor
struct SidebarSelectionTests {
    @Test func selectionAndExpansionSurviveARelaunch() async {
        let store = isolatedStore()
        let first = AppModel(backend: MockBackend(), layoutStore: store)
        first.start()
        #expect(await eventually { first.opened != nil })
        first.selectNode("pl:11")
        #expect(await eventually { first.opened?.generation == 2 })
        first.sidebar.setExpanded(first.sidebar.section(.playlists), false)

        let backend = MockBackend()
        let second = AppModel(backend: backend, layoutStore: store)
        #expect(second.selectedNodeID == "pl:11")  // available before the library loads
        second.start()
        #expect(await eventually { second.opened != nil })
        #expect(second.selectedNodeID == "pl:11")
        #expect(await backend.openedSpecs.first?.source == .playlist(id: "11"))
        #expect(!second.sidebar.isExpanded(second.sidebar.section(.playlists)))
    }

    @Test func aSelectionThatNoLongerExistsFallsBackToAllTracks() async {
        let store = isolatedStore()
        store.defaults.set("pl:404", forKey: SidebarModel.Keys.selected)
        let model = AppModel(backend: MockBackend(), layoutStore: store)
        model.start()
        #expect(await eventually { model.opened != nil })
        #expect(model.selectedNodeID == "all")
    }

    @Test func aRestoredExplorerFolderOpensBeforeItsParentsAreRead() async {
        let store = isolatedStore()
        store.defaults.set("ex:/m/House", forKey: SidebarModel.Keys.selected)
        let backend = MockBackend()
        let model = AppModel(backend: backend, layoutStore: store)
        model.start()
        #expect(await eventually { model.opened != nil })
        #expect(await backend.openedSpecs.first?.source == .folder(path: "/m/House"))
    }
}
