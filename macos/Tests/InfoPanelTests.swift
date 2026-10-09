import Foundation
import Testing

@testable import rbxport

@MainActor
@Suite(.scratchDefaults)
struct InfoPanelModelTests {
    private func defaults() -> UserDefaults { scratchDefaults(prefix: "rbxport-info") }

    private func make(_ backend: MockBackend = MockBackend(trackCount: 50)) -> (InfoPanelModel, MockBackend, ArtworkService) {
        let artwork = ArtworkService(backend: backend, settle: .zero)
        let model = InfoPanelModel(backend: backend, artwork: artwork, defaults: defaults())
        return (model, backend, artwork)
    }

    @Test func nothingIsFetchedWhileTheTabIsClosed() async {
        let (model, backend, _) = make()
        model.selectionChanged(["3"], row: nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await backend.detailCalls.isEmpty)
        model.setActive(true)
        #expect(await eventually { model.details?.id == "3" })
        #expect(await backend.detailCalls == ["3"])
    }

    @Test func noneAndSeveralSelectedAreEmptyStates() async {
        let (model, backend, _) = make()
        model.setActive(true)
        #expect(model.subject == .none)
        model.selectionChanged(["1", "2", "3"], row: nil)
        #expect(model.subject == .several(3))
        #expect(model.details == nil)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await backend.detailCalls.isEmpty)
        model.selectionChanged([], row: nil)
        #expect(model.subject == .none)
    }

    @Test func selectingATrackFetchesItsRecord() async {
        let (model, backend, _) = make()
        model.setActive(true)
        model.selectionChanged(["7"], row: nil)
        #expect(model.subject == .track("7"))
        #expect(await eventually { model.details?.title == "Track 006" })
        #expect(await backend.detailCalls == ["7"])
        #expect(!model.isLoading)
    }

    @Test func aLateReplyForAnEarlierTrackIsDropped() async {
        let (model, backend, _) = make()
        await backend.setDetail(MockBackend.details(track: 0), delay: .milliseconds(200))
        model.setActive(true)
        model.selectionChanged(["1"], row: nil)  // slow
        model.selectionChanged(["2"], row: nil)  // fast
        #expect(await eventually { model.details?.id == "2" })
        // Let the slow reply for "1" arrive; it must not replace the record for "2".
        try? await Task.sleep(for: .milliseconds(350))
        #expect(model.details?.id == "2")
        #expect(model.subject == .track("2"))
    }

    @Test func aReplyHandedInByHandIsCheckedAgainstTheSubject() {
        let (model, _, _) = make()
        model.setActive(true)
        model.selectionChanged(["2"], row: nil)
        // Wrong track, and a stale token: both ignored.
        model.receive(.success(MockBackend.details(track: 0)), for: "1", token: 0)
        model.receive(.success(MockBackend.details(track: 4)), for: "2", token: -1)
        #expect(model.details == nil)
    }

    @Test func aLibraryChangeFetchesTheRecordAgainWithoutBlankingIt() async {
        let (model, backend, _) = make()
        model.setActive(true)
        model.selectionChanged(["4"], row: nil)
        #expect(await eventually { model.details != nil })
        let before = await backend.detailCalls.count
        var changed = MockBackend.details(track: 3)
        changed = TrackDetails(
            id: changed.id, title: "Renamed", artist: changed.artist, album: changed.album, albumArtist: "", originalArtist: "",
            composer: "", remixer: "", lyricist: "", genre: "", label: "", key: "", comment: "", mixName: "", message: "",
            color: "0", rating: 0, bpmX100: 0, durationSec: 0, year: 0, trackNumber: 0, discNumber: 0, playCount: 0,
            fileType: 0, fileSize: 0, bitrate: 0, sampleRate: 0, bitDepth: 0, dateCreated: "", releaseDate: "", path: "",
            hotCueAutoLoad: false, publish: false, hasArtwork: false, myTags: [])
        await backend.setDetail(changed)
        model.libraryChanged()
        #expect(model.details?.title == "Track 003")  // still showing the old record meanwhile
        #expect(await eventually { model.details?.title == "Renamed" })
        #expect(await backend.detailCalls.count == before + 1)
    }

    @Test func aTrackThatHasGoneShowsAnError() async {
        let (model, _, _) = make(MockBackend(trackCount: 5))
        model.setActive(true)
        model.selectionChanged(["999"], row: nil)
        #expect(await eventually { model.errorMessage != nil })
        #expect(model.details == nil)
        #expect(model.errorMessage == "That track is no longer in the library.")
    }

    @Test func artworkLoadsForATrackThatHasIt() async {
        let backend = MockBackend(trackCount: 5)
        var d = MockBackend.details(track: 1)
        d = TrackDetails(
            id: d.id, title: d.title, artist: d.artist, album: d.album, albumArtist: "", originalArtist: "", composer: "",
            remixer: "", lyricist: "", genre: "", label: "", key: "", comment: "", mixName: "", message: "", color: "0",
            rating: 0, bpmX100: 0, durationSec: 0, year: 0, trackNumber: 0, discNumber: 0, playCount: 0, fileType: 0,
            fileSize: 0, bitrate: 0, sampleRate: 0, bitDepth: 0, dateCreated: "", releaseDate: "", path: "",
            hotCueAutoLoad: false, publish: false, hasArtwork: true, myTags: [])
        await backend.setDetail(d)
        await backend.setArtwork(pngData(edge: 64), for: d.id)
        let (model, _, _) = make(backend)
        model.setActive(true)
        model.selectionChanged([d.id], row: nil)
        #expect(await eventually { model.artwork != nil })
        // Moving on clears it at once.
        model.selectionChanged(["4"], row: nil)
        #expect(model.artwork == nil)
    }

    @Test func lookupsAreFetchedOnceTheInfoTabIsShown() async {
        let (model, backend, _) = make()
        model.setActive(true)
        model.selectionChanged(["2"], row: nil)
        #expect(await eventually { model.details != nil })
        #expect(await backend.lookupCalls == 0)
        model.tab = .info
        #expect(await eventually { model.lookups != nil })
        #expect(model.myTagNames == ["t1": "Peak"])
        #expect(await backend.lookupCalls == 1)
    }

    @Test func theChosenTabIsRemembered() {
        let d = defaults()
        let backend = MockBackend()
        let first = InfoPanelModel(backend: backend, artwork: ArtworkService(backend: backend), defaults: d)
        first.tab = .artwork
        let second = InfoPanelModel(backend: backend, artwork: ArtworkService(backend: backend), defaults: d)
        #expect(second.tab == .artwork)
    }
}

@MainActor
@Suite(.scratchDefaults)
struct InfoPanelAppModelTests {
    @Test func theOpenStateIsPersisted() {
        let store = isolatedStore()
        let first = AppModel(backend: MockBackend(), layoutStore: store)
        #expect(!first.infoPanelOpen)
        first.infoPanelOpen = true
        let second = AppModel(backend: MockBackend(), layoutStore: store)
        #expect(second.infoPanelOpen)
        second.infoPanelOpen = false
        #expect(!AppModel(backend: MockBackend(), layoutStore: store).infoPanelOpen)
    }

    @Test func showInformationOpensThePanelOnTheSelection() async {
        let backend = MockBackend(trackCount: 20)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        await model.pager.settle()
        _ = model.pager.row(at: 0)
        await model.pager.settle()
        model.tableSelectionChanged(IndexSet(integer: 0), keepingUnloaded: false)
        model.runTrackMenu(.showInformation)
        #expect(model.infoPanelOpen)
        #expect(await eventually { model.info.details != nil })
        #expect(model.info.subject == .track(model.selectedIDs.first ?? ""))
    }

    @Test func aLibraryChangeReloadsTheOpenPanel() async {
        let backend = MockBackend(trackCount: 20)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        _ = model.pager.row(at: 0)
        await model.pager.settle()
        model.infoPanelOpen = true
        model.tableSelectionChanged(IndexSet(integer: 0), keepingUnloaded: false)
        #expect(await eventually { model.info.details != nil })
        let before = await backend.detailCalls.count
        await backend.changeLibrary(trackCount: 20)
        #expect(await eventually { await backend.detailCalls.count > before })
    }

    @Test func rowSizeAndPaletteArePersisted() {
        let store = isolatedStore()
        let model = AppModel(backend: MockBackend(), layoutStore: store)
        #expect(model.rowSize == .standard)
        #expect(model.waveformPalette == .bands)
        model.rowSize = .large
        model.waveformPalette = .colour
        let again = AppModel(backend: MockBackend(), layoutStore: store)
        #expect(again.rowSize == .large)
        #expect(again.waveformPalette == .colour)
        #expect(again.rowHeight == RowSize.large.height)
    }
}

@Suite(.scratchDefaults)
struct InfoFormatTests {
    private func details(
        fileType: UInt32 = 11, size: UInt64 = 47_300_000, rate: UInt32 = 44_100, bitrate: UInt32 = 1411,
        path: String = "/Music/a.wav", plays: UInt32 = 4
    ) -> TrackDetails {
        var d = MockBackend.details(track: 0)
        d = TrackDetails(
            id: d.id, title: "T", artist: "A", album: "Al", albumArtist: "AA", originalArtist: "", composer: "C", remixer: "",
            lyricist: "", genre: "House", label: "L", key: "Am", comment: "hi", mixName: "", message: "", color: "3", rating: 4,
            bpmX100: 12_800, durationSec: 266, year: 2021, trackNumber: 2, discNumber: 0, playCount: plays,
            fileType: fileType, fileSize: size, bitrate: bitrate, sampleRate: rate, bitDepth: 16,
            dateCreated: "2026-09-06", releaseDate: "2020-01-31", path: path, hotCueAutoLoad: true, publish: false,
            hasArtwork: false, myTags: ["t1", "gone"])
        return d
    }

    @Test func fileTypesAreLabelledLikeRekordbox() {
        #expect(InfoFormat.fileType(1) == "MP3 File")
        #expect(InfoFormat.fileType(4) == "M4A File")
        #expect(InfoFormat.fileType(6) == "M4A File")
        #expect(InfoFormat.fileType(5) == "FLAC File")
        #expect(InfoFormat.fileType(11) == "WAV File")
        #expect(InfoFormat.fileType(12) == "AIFF File")
        #expect(InfoFormat.fileType(0) == "")
        #expect(InfoFormat.fileType(99) == "")
    }

    @Test func summaryFactsAreInTheCapturedOrder() {
        let facts = InfoFormat.summaryFacts(row: nil, details: details())
        #expect(facts.map(\.label) == [
            "Time", "File Type", "Size", "Date Created", "Sample Rate", "Bitrate", "DJ Play Count", "Location",
        ])
        #expect(facts.map(\.value) == [
            "04:26", "WAV File", "45.1 MB", "9/6/26", "44100 Hz", "1411 kbps", "4", "/Music/a.wav",
        ])
    }

    @Test func blankValuesKeepTheirRows() {
        let facts = InfoFormat.summaryFacts(row: nil, details: details(size: 0, rate: 0, bitrate: 0))
        #expect(facts.count == 8)
        #expect(facts[2].value == "" && facts[4].value == "" && facts[5].value == "")
    }

    @Test func beforeTheRecordArrivesOnlyTheRowsTimeIsShown() {
        let row = MockBackend.row(track: 0, position: 1)
        let facts = InfoFormat.summaryFacts(row: row, details: nil)
        #expect(facts[0].value == "03:20")
        #expect(facts.dropFirst().allSatisfy { $0.value.isEmpty })
        // A record that belongs to another track is never shown.
        let other = MockBackend.details(track: 5)
        #expect(InfoFormat.summaryFacts(row: row, details: other)[1].value == "")
    }

    @Test func sizesUseGigabytesFromOneGig() {
        #expect(InfoFormat.size(1_610_612_736) == "1.5 GB")
        #expect(InfoFormat.size(0) == "")
    }

    @Test func theInfoTabShowsEveryField() {
        let sections = InfoFormat.infoSections(details(), myTagNames: ["t1": "Peak"])
        let all = Dictionary(uniqueKeysWithValues: sections.flatMap(\.facts).map { ($0.label, $0.value) })
        #expect(all["Track Title"] == "T")
        #expect(all["Album Artist"] == "AA")
        #expect(all["BPM"] == "128.00")
        #expect(all["Key"] == "Am")
        #expect(all["Year"] == "2021")
        #expect(all["Disc Number"] == "")  // zero is blank
        #expect(all["Release Date"] == "1/31/20")
        #expect(all["Rating"] == "\u{2605}\u{2605}\u{2605}\u{2605}")
        #expect(all["Color"] == "Orange")
        #expect(all["My Tag"] == "Peak")  // unknown ids are skipped
        #expect(all["Auto load HotCue on CDJ/XDJ"] == "Yes")
        #expect(all["Publish track information"] == "No")
        #expect(all["Bit Depth"] == "16 bit")
        #expect(sections.map(\.title) == ["Track", "Musical", "Library", "File"])
    }

    @Test func colourNamesFollowTheIDs() {
        #expect(InfoFormat.colorName("1") == "Pink")
        #expect(InfoFormat.colorName("8") == "Purple")
        #expect(InfoFormat.colorName("0") == "")
        #expect(InfoFormat.colorName("") == "")
        #expect(InfoFormat.colorName("x") == "")
    }
}
