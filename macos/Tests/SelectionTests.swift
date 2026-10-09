import Foundation
import Testing

@testable import rbxport

@MainActor
@Suite(.scratchDefaults)
struct SelectionTests {
    private func ready(_ backend: MockBackend = MockBackend(trackCount: 300)) async -> AppModel {
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        return model
    }

    private func load(_ model: AppModel, rowAt index: Int) async {
        _ = model.pager.row(at: index)
        await model.pager.settle()
    }

    @Test func loadedRowsMapToIdsAtOnce() async {
        let model = await ready()
        await load(model, rowAt: 0)
        model.tableSelectionChanged(IndexSet(0..<5), keepingUnloaded: false)
        #expect(model.selectedIDs == ["1", "2", "3", "4", "5"])
        #expect(model.selectionSummary != nil)
        model.tableSelectionChanged(IndexSet(integer: 2), keepingUnloaded: false)
        #expect(model.selectedIDs == ["3"])
        #expect(model.selectionAnchor == "3")
        #expect(model.selectionSummary == nil)  // one track has no summary
    }

    @Test func unloadedRangesAreResolvedByTheBackend() async {
        let backend = MockBackend(trackCount: 300)
        let model = await ready(backend)
        await load(model, rowAt: 0)  // page 0 only
        model.tableSelectionChanged(IndexSet(10..<200), keepingUnloaded: false)
        #expect(model.selectedIDs.count == 118)  // the loaded part right away
        await model.settleSelection()
        #expect(model.selectedIDs.count == 190)
        #expect(model.selectedIDs.contains("11") && model.selectedIDs.contains("200"))
        let calls = await backend.idRangeCalls
        #expect(calls.count == 1)
        #expect(calls.first?.from == 128 && calls.first?.to == 199)
    }

    @Test func selectAllOnAnUnloadedViewFetchesEveryId() async {
        let backend = MockBackend(trackCount: 300)
        let model = await ready(backend)
        model.tableSelectionChanged(IndexSet(0..<300), keepingUnloaded: false)
        await model.settleSelection()
        #expect(model.selectedIDs.count == 300)
        let calls = await backend.idRangeCalls
        #expect(calls.map(\.from) == [0] && calls.map(\.to) == [299])
    }

    @Test func aStaleResolutionDoesNotOverwriteANewerSelection() async {
        let model = await ready()
        model.tableSelectionChanged(IndexSet(0..<300), keepingUnloaded: false)
        await load(model, rowAt: 0)
        model.tableSelectionChanged(IndexSet(integer: 1), keepingUnloaded: false)
        await model.settleSelection()
        #expect(model.selectedIDs == ["2"])
    }

    @Test func selectionSurvivesSortingAndIsRestoredAsPagesLoad() async {
        let model = await ready()
        await load(model, rowAt: 0)
        model.tableSelectionChanged(IndexSet(0..<3), keepingUnloaded: false)
        model.sort(by: .title, descending: true)
        #expect(await eventually { model.opened?.generation == 2 })
        #expect(model.selectedIDs == ["1", "2", "3"])
        // Descending, tracks 1...3 are the last three rows; they map once that page loads.
        #expect(model.selectedIndexes(in: 0..<300).isEmpty)
        await load(model, rowAt: 299)
        #expect(model.selectedIndexes(in: 256..<300) == IndexSet(297..<300))
        model.recomputeSelectionSummary()
        #expect(model.selectionSummary?.totalled == 3)
    }

    @Test func anAdditiveChangeKeepsTracksThatAreNotLoaded() async {
        let model = await ready()
        await load(model, rowAt: 0)
        model.tableSelectionChanged(IndexSet(0..<3), keepingUnloaded: false)
        model.sort(by: .title, descending: true)
        #expect(await eventually { model.opened?.generation == 2 })
        await load(model, rowAt: 299)
        // Cmd-click row 299 (track 1): the unloaded {2, 3} stay... but they are loaded now, and not in the table.
        model.tableSelectionChanged(IndexSet(integer: 299), keepingUnloaded: true)
        #expect(model.selectedIDs == ["1"])

        // Before they load, an additive click keeps what it cannot see.
        let second = await ready()
        await load(second, rowAt: 0)
        second.tableSelectionChanged(IndexSet(0..<3), keepingUnloaded: false)
        second.sort(by: .title, descending: true)
        #expect(await eventually { second.opened?.generation == 2 })
        second.tableSelectionChanged(IndexSet(integer: 5), keepingUnloaded: true)
        await second.settleSelection()
        #expect(second.selectedIDs == ["1", "2", "3", "295"])
        second.tableSelectionChanged(IndexSet(integer: 5), keepingUnloaded: false)
        await second.settleSelection()
        #expect(second.selectedIDs == ["295"])
    }

    @Test func choosingAnotherSourceClearsTheSelection() async {
        let model = await ready()
        await load(model, rowAt: 0)
        model.tableSelectionChanged(IndexSet(0..<3), keepingUnloaded: false)
        model.selectedNodeID = "pl:10"
        #expect(model.selectedIDs.isEmpty)
        #expect(await eventually { model.opened?.generation == 2 })
    }

    @Test func theSummaryTotalsLoadedRowsAndAdmitsWhenPartial() async {
        let model = await ready()
        await load(model, rowAt: 0)
        model.tableSelectionChanged(IndexSet(0..<3), keepingUnloaded: false)
        let whole = model.selectionSummary
        #expect(whole?.count == 3)
        #expect(whole?.seconds == 600)  // 3 x 200 s
        #expect(whole?.bytes == 3_003_000)
        #expect(whole?.isPartial == false)
        #expect(whole?.text == "3 tracks \u{00B7} 10 minutes \u{00B7} 2.9 MB")

        model.tableSelectionChanged(IndexSet(0..<200), keepingUnloaded: false)
        await model.settleSelection()
        let partial = model.selectionSummary
        #expect(partial?.count == 200 && partial?.totalled == 128)
        #expect(partial?.isPartial == true)
        #expect(partial?.text.hasSuffix("(loaded rows only)") == true)

        await load(model, rowAt: 150)
        model.recomputeSelectionSummary()
        #expect(model.selectionSummary?.isPartial == false)
        #expect(model.selectionSummary?.seconds == 200 * 200)
    }

    @Test func loadToDeckIsAHook() async {
        let model = await ready()
        var loaded: [String] = []
        model.onLoadToDeck = { loaded.append($0) }
        model.loadToDeck(trackID: "42")
        #expect(loaded == ["42"])
    }
}
