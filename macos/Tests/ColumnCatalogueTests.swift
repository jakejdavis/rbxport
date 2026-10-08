import Foundation
import Testing

@testable import rbxport

struct ColumnCatalogueTests {
    @Test func theCatalogueHasAllFortyColumns() {
        #expect(ColumnCatalogue.all.count == 40)
        #expect(Set(ColumnCatalogue.all.map(\.id)).count == 40)
        #expect(ColumnID.allCases.count == 40)
        for id in ColumnID.allCases { #expect(ColumnCatalogue.spec(for: id).id == id) }
    }

    @Test func extraColumnsAreTheTwentyTwoTheCoreCanFill() {
        #expect(ColumnCatalogue.all.filter { $0.extra != nil }.count == 22)
        #expect(ColumnCatalogue.spec(for: .size).extra == .size)
        #expect(ColumnCatalogue.spec(for: .djPlayCount).extra == .djPlayCount)
        #expect(ColumnCatalogue.spec(for: .title).extra == nil)
    }

    @Test func sortabilityMatchesTheReactCatalogue() {
        let unsortable = ColumnCatalogue.all.filter { !$0.sortable }.map(\.id)
        #expect(Set(unsortable) == [.attr, .preview, .artwork, .hotCue, .myTag, .cloud])
        #expect(ColumnCatalogue.spec(for: .key).sortKey(for: .classic) == .key)
        #expect(ColumnCatalogue.spec(for: .key).sortKey(for: .camelot) == .keyCamelot)
        #expect(ColumnCatalogue.spec(for: .djPlayCount).sortKey == .playCount)
    }

    @Test func widthsAndAlignmentAreTransplanted() {
        let title = ColumnCatalogue.spec(for: .title)
        #expect(title.label == "Track Title" && title.width == 387)
        #expect(ColumnCatalogue.spec(for: .bpm).rightAligned)
        #expect(!ColumnCatalogue.spec(for: .artist).rightAligned)
        #expect(ColumnCatalogue.spec(for: .publishTrackInfo).label == "Publish track information")
    }

    @Test func theMenuOrderCoversEverythingButTheFixedColumn() {
        #expect(ColumnCatalogue.menuOrder.count == 39)
        #expect(Set(ColumnCatalogue.menuOrder) == Set(ColumnID.allCases).subtracting([.trackNo]))
        #expect(ColumnCatalogue.menuOrder.first == .attr)
        #expect(ColumnCatalogue.required == [.trackNo, .title])
    }

    @Test func defaultsDifferByContext() {
        #expect(ColumnLayout.defaults(for: .collection).order.count == 12)
        #expect(ColumnLayout.defaults(for: .playlist) == .defaults(for: .collection))
        #expect(ColumnLayout.defaults(for: .history) == .defaults(for: .collection))
        let folder = ColumnLayout.defaults(for: .folder)
        #expect(folder.order.contains(.fileName) && folder.order.contains(.album))
        #expect(folder.width(of: .preview) == 200)
        #expect(ColumnLayout.defaults(for: .collection).width(of: .preview) == 128)
        #expect(ColumnLayout.defaults(for: .collection).shown.first == .trackNo)
    }

    @Test func sanitisingDropsUnknownRepeatedAndFixedColumns() {
        let layout = ColumnLayout.sanitised(
            order: ["artist", "bogus", "trackNo", "artist", "bpm"], widths: nil, for: .collection)
        // The title returns at its catalogue place, before the artist.
        #expect(layout.order == [.title, .artist, .bpm])
    }

    @Test func sanitisingClampsWidthsAndIgnoresUnknownKeys() {
        let layout = ColumnLayout.sanitised(
            order: ["title"], widths: ["title": 5, "artist": 5000, "bogus": 100, "bpm": .nan], for: .collection)
        #expect(layout.widths == [.title: 32, .artist: 1200])
    }

    @Test func sanitisingAnEmptyOrAbsentLayoutFallsBackToTheContextDefault() {
        #expect(ColumnLayout.sanitised(order: [], widths: nil, for: .folder) == .defaults(for: .folder))
        #expect(ColumnLayout.sanitised(order: ["bogus"], widths: nil, for: .collection) == .defaults(for: .collection))
        #expect(ColumnLayout.sanitised(order: nil, widths: nil, for: .history) == .defaults(for: .history))
    }

    @Test func togglingPlacesAColumnWhereTheCatalogueWouldAndProtectsTheRequired() {
        let base = ColumnLayout.defaults(for: .collection)
        let withAlbum = base.toggling(.album)
        #expect(withAlbum.order.contains(.album))
        #expect(withAlbum.toggling(.album) == base)
        #expect(base.toggling(.title) == base)
        #expect(base.toggling(.trackNo) == base)
        // Size sits after Label in the catalogue, so it goes there.
        let withSize = base.toggling(.size)
        let label = withSize.order.firstIndex(of: .label)!
        #expect(withSize.order[label + 1] == .size)
    }

    @Test func extraColumnsFollowTheShownOnes() {
        var layout = ColumnLayout.defaults(for: .collection)
        #expect(layout.extraColumns.isEmpty)
        layout = layout.toggling(.composer).toggling(.bitrate)
        #expect(Set(layout.extraColumns) == [.composer, .bitrate])
    }

    @Test func aLayoutRoundTripsThroughTheStore() {
        let store = isolatedStore()
        #expect(store.load(.playlist) == .defaults(for: .playlist))
        let layout = ColumnLayout.defaults(for: .playlist).toggling(.genre).resized(.title, to: 500)
        store.save(layout, for: .playlist)
        #expect(store.load(.playlist) == layout)
        #expect(store.load(.collection) == .defaults(for: .collection))  // per context
        store.reset(.playlist)
        #expect(store.load(.playlist) == .defaults(for: .playlist))
    }

    @Test func aDamagedStoredLayoutIsRepaired() {
        let store = isolatedStore()
        store.defaults.set(["order": ["artist", "nonsense"], "widths": ["artist": 99999]], forKey: "columns.collection")
        let layout = store.load(.collection)
        #expect(layout.order == [.title, .artist])
        #expect(layout.widths == [.artist: 1200])
    }

    @Test func resizingClamps() {
        let layout = ColumnLayout.defaults(for: .collection)
        #expect(layout.resized(.title, to: 3).width(of: .title) == 32)
        #expect(layout.resized(.title, to: 9999).width(of: .title) == 1200)
        #expect(layout.width(of: .title) == 387)
    }

    @Test func theSortCycleGoesAscendingDescendingOff() {
        var state: (key: SortKey, descending: Bool) = (.trackNo, false)
        state = SortCycle.next(current: state, clicked: .title)
        #expect(state == (.title, false))
        state = SortCycle.next(current: state, clicked: .title)
        #expect(state == (.title, true))
        state = SortCycle.next(current: state, clicked: .title)
        #expect(state == (.trackNo, false))
        // Another column restarts at ascending.
        state = SortCycle.next(current: (.title, true), clicked: .artist)
        #expect(state == (.artist, false))
        // `#` is already the view order, so it just reverses.
        state = SortCycle.next(current: (.trackNo, false), clicked: .trackNo)
        #expect(state == (.trackNo, true))
        state = SortCycle.next(current: state, clicked: .trackNo)
        #expect(state == (.trackNo, false))
    }

    @Test func sizingMeasuresTheContentAndClamps() {
        var short = MockBackend.row(track: 1, position: 1)
        short.title = "Hi"
        var long = short
        long.title = String(repeating: "A long title ", count: 8)
        let narrow = ColumnSizer.width(for: .title, rows: [short], keyStyle: .classic)
        let wide = ColumnSizer.width(for: .title, rows: [short, long], keyStyle: .classic)
        #expect(wide > narrow)
        #expect(narrow >= 32 && wide <= 1200)
        var huge = short
        huge.title = String(repeating: "W", count: 2000)
        #expect(ColumnSizer.width(for: .title, rows: [huge], keyStyle: .classic) == 1200)
        // Drawn columns keep their catalogue width.
        #expect(ColumnSizer.width(for: .attr, rows: [short], keyStyle: .classic) == 67)
        #expect(ColumnSizer.width(for: .rating, rows: [short], keyStyle: .classic) == 101)
    }
}
