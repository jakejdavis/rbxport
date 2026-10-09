import Testing

@testable import rbxport

@MainActor
@Suite(.scratchDefaults)
struct AppModelTests {
    @Test func loadsSummaryTreeAndFirstView() async {
        let backend = MockBackend(trackCount: 300)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        #expect(model.phase == .ready)
        #expect(model.summary?.trackCount == 300)
        let playlists = model.sidebar.section(.playlists).children
        #expect(playlists.map(\.id) == ["all", "pl:10", "pl:11"])
        #expect(model.selectedNodeID == "all")
        #expect(model.opened?.handle.len == 300)
    }

    @Test func aFailedLoadShowsTheProblem() async {
        let model = AppModel(backend: MockBackend(failLoad: "database is locked"), layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.phase != .loading })
        #expect(model.phase == .failed("database is locked"))
        #expect(model.opened == nil)
    }

    @Test func selectingAPlaylistOpensItsSource() async {
        let backend = MockBackend()
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        model.selectedNodeID = "pl:10"
        #expect(await eventually { model.opened?.generation == 2 })
        let specs = await backend.openedSpecs
        #expect(specs.last?.source == .playlist(id: "10"))
    }

    @Test func sortingReopensTheView() async {
        let backend = MockBackend()
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        model.sort(by: .title, descending: true)
        #expect(await eventually { model.opened?.generation == 2 })
        let spec = await backend.openedSpecs.last
        #expect(spec?.sort == .title)
        #expect(spec?.descending == true)
    }

    @Test func searchingReopensWithTheQuery() async {
        let backend = MockBackend(trackCount: 300)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        model.query = "Track 29"
        #expect(await eventually { model.opened?.handle.len == 10 })
    }

    @Test func libraryChangedReloadsTreeSummaryAndView() async {
        let backend = MockBackend(trackCount: 300)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        // Select "Peak", then have the library change underneath: a new first node shifts positions.
        model.selectedNodeID = "pl:11"
        #expect(await eventually { model.opened?.generation == 2 })

        var changed = MockBackend.sampleTree
        changed.insert(
            TreeNode(id: "new", name: "New", kind: .playlist, depth: 1, expanded: nil, childCount: 1), at: 2)
        await backend.changeLibrary(trackCount: 50, nodes: changed)

        #expect(await eventually { model.summary?.trackCount == 50 })
        #expect(await eventually { model.opened?.handle.len == 50 && model.opened?.generation == 3 })
        // The selection followed the node ("Peak"), not the position.
        #expect(model.selectedNodeID == "pl:11")
        #expect(model.sidebar.section(.playlists).children.map(\.id) == ["all", "pl:new", "pl:10", "pl:11"])
        #expect(await backend.treeCalls == 2)
    }
}
