import Foundation
import Testing

@testable import rbxport

@Suite(.scratchDefaults)
struct FilterStateTests {
    @Test func nothingTickedSendsNothing() {
        var state = FilterState()
        state.bpm.picked = [128]
        state.key.picked = ["Am"]
        #expect(!state.isNarrowing)
        #expect(state.wire().isEmpty)
    }

    @Test func onlyTickedNonEmptyColumnsAreSent() {
        var state = FilterState()
        state.bpm = FilterColumn(enabled: true, picked: [124, 128])
        state.tolerancePct = 3
        state.key = FilterColumn(enabled: true, picked: ["Am", "C"])
        state.rating = FilterColumn(enabled: true, picked: [])  // ticked at "All": no constraint
        state.color = FilterColumn(enabled: false, picked: ["Red"])  // picks kept, not sent
        let wire = state.wire()
        #expect(wire.bpm == BpmFilter(values: [124, 128], tolerancePct: 3, masterBpmX100: nil))
        #expect(wire.keys == ["Am", "C"])
        #expect(wire.ratings == nil)
        #expect(wire.colors == nil)
    }

    @Test func ratingsTravelAsBytes() {
        let state = FilterState(rating: FilterColumn(enabled: true, picked: [3, 5]))
        #expect(state.wire().ratings == Data([3, 5]))
    }

    @Test func aTickedBPMColumnAtAllNeedsAMasterToConstrain() {
        var state = FilterState()
        state.bpm.enabled = true
        #expect(state.wire().bpm == nil)
        #expect(state.wire(masterBPMx100: 12_800).bpm == BpmFilter(values: [], tolerancePct: 0, masterBpmX100: 12_800))
        #expect(state.wire(masterBPMx100: 0).bpm == nil)
    }

    @Test func clickPicksOneAndCommandClickToggles() {
        var column = FilterColumn<String>()
        column.pick("Am", toggle: false)
        column.pick("C", toggle: false)
        #expect(column.picked == ["C"])
        #expect(column.enabled)  // picking ticks the column
        column.pick("Am", toggle: true)
        #expect(column.picked == ["C", "Am"])
        column.pick("C", toggle: true)
        #expect(column.picked == ["Am"])
        column.pick(nil, toggle: false)  // "All"
        #expect(column.picked.isEmpty)
    }

    @Test func resetClearsEverything() {
        var state = FilterState()
        state.bpm.pick(120, toggle: false)
        state.tolerancePct = 2
        #expect(state.hasPicks)
        state.reset()
        #expect(state == FilterState())
        #expect(!state.hasPicks)
    }

    @Test func toleranceNeedsACentre() {
        var state = FilterState()
        #expect(!state.toleranceApplies(masterBPMx100: nil))
        state.bpm.picked = [128]
        #expect(state.toleranceApplies(masterBPMx100: nil))
        #expect(FilterState().toleranceApplies(masterBPMx100: 12_000))
    }

    @Test func keysSortInCamelotOrder() {
        let counted = ["Em", "C", "Abm", "Am", "G", "weird"].map { CountedKey(value: $0, count: 1) }
        // Abm 1A, Am 8A, Em 9A, C 8B, G 9B, then keys off the wheel.
        #expect(FilterKeyOrder.sorted(counted).map(\.value) == ["Abm", "Am", "C", "Em", "G", "weird"])
    }
}

@MainActor
@Suite(.scratchDefaults)
struct FilterModelTests {
    private func ready(_ backend: MockBackend, store: ColumnLayoutStore = isolatedStore()) async -> AppModel {
        let model = AppModel(backend: backend, layoutStore: store)
        model.start()
        #expect(await eventually { model.opened != nil })
        return model
    }

    @Test func openingTheBarFetchesValuesForTheSourceWithoutAFilter() async {
        let backend = MockBackend()
        let model = await ready(backend)
        #expect(await backend.filterValueSpecs.isEmpty)  // closed: nothing fetched
        model.filterState.bpm.pick(120, toggle: false)
        model.filterBarOpen = true
        #expect(await eventually { model.filterValues != nil })
        #expect(model.filterValues?.bpms.count == 2)
        let spec = await backend.filterValueSpecs.last
        #expect(spec?.source == .collection)
        #expect(spec?.filter.isEmpty == true)  // the filter itself is excluded
    }

    @Test func valuesRefetchWhenTheSourceOrQueryChangesButNotForSorts() async {
        let backend = MockBackend()
        let model = await ready(backend)
        model.filterBarOpen = true
        #expect(await eventually { model.filterValues != nil })
        #expect(await backend.filterValueSpecs.count == 1)

        model.sort(by: .title, descending: false)
        #expect(await eventually { model.opened?.generation == 2 })
        #expect(await backend.filterValueSpecs.count == 1)

        model.selectedNodeID = "pl:10"
        #expect(await eventually { await backend.filterValueSpecs.count == 2 })
        #expect(await backend.filterValueSpecs.last?.source == .playlist(id: "10"))

        model.query = "Track 1"
        #expect(await eventually { await backend.filterValueSpecs.count == 3 })
        #expect(await backend.filterValueSpecs.last?.query == "Track 1")

        await backend.changeLibrary(trackCount: 20)
        #expect(await eventually { await backend.filterValueSpecs.count == 4 })
    }

    @Test func picksReopenTheViewWithTheWireFilterWhileTheBarIsOpen() async {
        let backend = MockBackend()
        let model = await ready(backend)
        model.filterBarOpen = true
        model.filterState.key.pick("Am", toggle: false)
        #expect(await eventually { await backend.openedSpecs.last?.filter.keys == ["Am"] })

        // Closing the bar shows the whole list again; the picks are kept.
        model.filterBarOpen = false
        #expect(await eventually { await backend.openedSpecs.last?.filter.isEmpty == true })
        #expect(model.filterState.key.picked == ["Am"])
        model.filterBarOpen = true
        #expect(await eventually { await backend.openedSpecs.last?.filter.keys == ["Am"] })

        model.resetFilter()
        #expect(await eventually { await backend.openedSpecs.last?.filter.isEmpty == true })
    }

    @Test func onlyWhetherTheBarIsOpenIsPersisted() async {
        let store = isolatedStore()
        let first = await ready(MockBackend(), store: store)
        first.filterBarOpen = true
        first.filterState.key.pick("Am", toggle: false)
        let second = await ready(MockBackend(), store: store)
        #expect(second.filterBarOpen)
        #expect(second.filterState == FilterState())
    }
}
