import Testing

@testable import rbxport

@MainActor
struct AppModelTests {
    @Test func loadsSummaryTreeAndFirstView() async {
        let backend = MockBackend(trackCount: 300)
        let model = AppModel(backend: backend)
        model.start()
        #expect(await eventually { model.opened != nil })
        #expect(model.phase == .ready)
        #expect(model.summary?.trackCount == 300)
        #expect(model.tree.count == 2)  // All Tracks, and Playlists with its two children
        #expect(model.tree[1].children?.count == 2)
        #expect(model.selection == 0)
        #expect(model.opened?.handle.len == 300)
    }

    @Test func aFailedLoadShowsTheProblem() async {
        let model = AppModel(backend: MockBackend(failLoad: "database is locked"))
        model.start()
        #expect(await eventually { model.phase != .loading })
        #expect(model.phase == .failed("database is locked"))
        #expect(model.opened == nil)
    }

    @Test func selectingAPlaylistOpensItsSource() async {
        let backend = MockBackend()
        let model = AppModel(backend: backend)
        model.start()
        #expect(await eventually { model.opened != nil })
        let playlist = model.tree[1].children![0]
        model.selection = playlist.id
        #expect(await eventually { model.opened?.generation == 2 })
        let specs = await backend.openedSpecs
        #expect(specs.last?.source == .playlist(id: "10"))
    }

    @Test func sortingReopensTheView() async {
        let backend = MockBackend()
        let model = AppModel(backend: backend)
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
        let model = AppModel(backend: backend)
        model.start()
        #expect(await eventually { model.opened != nil })
        model.query = "Track 29"
        #expect(await eventually { model.opened?.handle.len == 10 })
    }

    @Test func libraryChangedReloadsTreeSummaryAndView() async {
        let backend = MockBackend(trackCount: 300)
        let model = AppModel(backend: backend)
        model.start()
        #expect(await eventually { model.opened != nil })
        // Select "Peak", then have the library change underneath: a new first node shifts positions.
        let peak = model.tree[1].children![1]
        model.selection = peak.id
        #expect(await eventually { model.opened?.generation == 2 })

        var changed = MockBackend.sampleTree
        changed.insert(
            TreeNode(id: "new", name: "New", kind: .playlist, depth: 0, expanded: nil, childCount: 1), at: 0)
        await backend.changeLibrary(trackCount: 50, nodes: changed)

        #expect(await eventually { model.summary?.trackCount == 50 })
        #expect(await eventually { model.opened?.handle.len == 50 && model.opened?.generation == 3 })
        // The selection followed the node ("Peak"), not the position.
        let selected = model.tree.flatMap { [$0] + ($0.children ?? []) }.first { $0.id == model.selection }
        #expect(selected?.node.id == "11")
        #expect(await backend.treeCalls == 2)
    }
}
