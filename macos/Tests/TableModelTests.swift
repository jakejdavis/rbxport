import Foundation
import Testing

@testable import rbxport

@MainActor
@Suite(.scratchDefaults)
struct TableModelTests {
    private func ready(_ backend: MockBackend = MockBackend(trackCount: 300)) async -> AppModel {
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        return model
    }

    @Test func showingAnExtraColumnReopensTheViewWithIt() async {
        let backend = MockBackend()
        let model = await ready(backend)
        #expect(model.opened?.extraColumns == [.size])  // always asked for: the selection total
        model.toggleColumn(.composer)
        #expect(await eventually { model.opened?.generation == 2 })
        #expect(model.opened?.extraColumns == [.size, .composer])
        #expect(await backend.openedSpecs.count == 2)

        _ = model.pager.row(at: 0)
        await model.pager.settle()
        #expect(await backend.fetchExtras.last == [.size, .composer])
        #expect(model.pager.peek(at: 0)?.extra.composer == "Composer 0")
    }

    @Test func columnsThatNeedNoExtraFieldsDoNotReopen() async {
        let backend = MockBackend()
        let model = await ready(backend)
        model.toggleColumn(.genre)
        model.toggleColumn(.size)  // size is fetched anyway
        model.reorderColumns(model.layout.order.reversed())
        model.resizeColumn(.title, to: 500)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await backend.openedSpecs.count == 1)
        #expect(model.layout.width(of: .title) == 500)
    }

    @Test func layoutsPersistPerContext() async {
        let store = isolatedStore()
        let backend = MockBackend()
        let model = AppModel(backend: backend, layoutStore: store)
        model.start()
        #expect(await eventually { model.opened != nil })
        model.toggleColumn(.genre)
        #expect(store.load(.collection).order.contains(.genre))

        model.selectedNodeID = "pl:10"  // a playlist: its own layout
        #expect(await eventually { model.opened?.generation == 2 })
        #expect(model.context == .playlist)
        #expect(!model.layout.order.contains(.genre))

        model.selectedNodeID = "all"
        #expect(await eventually { model.context == .collection })
        #expect(model.layout.order.contains(.genre))
    }

    @Test func resetColumnsRestoresTheContextDefault() async {
        let model = await ready()
        model.toggleColumn(.composer)
        model.resizeColumn(.title, to: 700)
        #expect(await eventually { model.opened?.generation == 2 })
        model.resetColumns()
        #expect(model.layout == .defaults(for: .collection))
        #expect(await eventually { model.opened?.generation == 3 })
        #expect(model.layoutStore.load(.collection) == .defaults(for: .collection))
    }

    @Test func reorderingRejectsAMismatchedSet() async {
        let model = await ready()
        let before = model.layout
        model.reorderColumns([.title])
        #expect(model.layout == before)
        model.reorderColumns(before.order.reversed())
        #expect(model.layout.order == before.order.reversed())
    }

    @Test func headerClicksCycleTheSort() async {
        let backend = MockBackend()
        let model = await ready(backend)
        model.cycleSort(on: .title)
        #expect(await eventually { model.opened?.generation == 2 })
        model.cycleSort(on: .title)
        #expect(await eventually { model.opened?.generation == 3 })
        model.cycleSort(on: .title)
        #expect(await eventually { model.opened?.generation == 4 })
        let specs = await backend.openedSpecs
        #expect(specs.map(\.sort) == [.trackNo, .title, .title, .trackNo])
        #expect(specs.map(\.descending) == [false, false, true, false])
        model.cycleSort(on: .attr)  // cannot sort
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await backend.openedSpecs.count == 4)
    }

    @Test func camelotDisplayChangesTheKeySortAndPersists() async {
        let store = isolatedStore()
        let backend = MockBackend()
        let model = AppModel(backend: backend, layoutStore: store)
        #expect(model.keyStyle == .classic)
        model.start()
        #expect(await eventually { model.opened != nil })
        model.keyStyle = .camelot
        model.cycleSort(on: .key)
        #expect(await eventually { model.opened?.generation == 2 })
        #expect(await backend.openedSpecs.last?.sort == .keyCamelot)
        // Back to classic while sorted by key: the sort follows.
        model.keyStyle = .classic
        #expect(await eventually { model.opened?.generation == 3 })
        #expect(await backend.openedSpecs.last?.sort == .key)
        #expect(AppModel(backend: backend, layoutStore: store).keyStyle == .classic)
        model.keyStyle = .camelot
        #expect(AppModel(backend: backend, layoutStore: store).keyStyle == .camelot)
    }

    @Test func theSearchScopeIsSentWithTheQuery() async {
        let backend = MockBackend()
        let model = await ready(backend)
        model.searchField = .artist  // no query yet: nothing to redo
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await backend.openedSpecs.count == 1)
        model.query = "Track 1"
        #expect(await eventually { model.opened?.generation == 2 })
        #expect(await backend.openedSpecs.last?.searchField == .artist)
        model.searchField = .title
        #expect(await eventually { model.opened?.generation == 3 })
        #expect(await backend.openedSpecs.last?.searchField == .title)
        model.clearSearch()
        #expect(await eventually { model.opened?.generation == 4 })
        #expect(await backend.openedSpecs.last?.query == "")
    }

    @Test func theFindCommandRequestsFocus() async {
        let model = await ready()
        let before = model.searchFocusRequests
        model.focusSearch()
        #expect(model.searchFocusRequests == before + 1)
    }
}
