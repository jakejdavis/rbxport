import Foundation
import Testing

@testable import rbxport

@MainActor
@Suite(.scratchDefaults)
struct LibraryToolsTests {
    private func missing(_ n: Int) -> [MissingTrack] {
        (1...n).map { MissingTrack(id: String($0), title: "Gone \($0)", artist: "A", path: "/old/gone\($0).mp3") }
    }

    private func make(_ stub: StubDialogs, _ backend: MockBackend) -> MissingFilesModel {
        MissingFilesModel(backend: backend, dialogs: { stub.dialogs })
    }

    @Test func theMissingListCountsExactlyAndSaysWhenNothingIsMissing() async {
        let backend = MockBackend(trackCount: 5)
        await backend.setProtectLibrary(false)
        let stub = StubDialogs()
        let model = make(stub, backend)
        await backend.setMissing(missing(3))
        await model.scan()
        #expect(model.total == 3 && model.tracks.count == 3)
        #expect(model.summary == "3 tracks cannot be found.")
        await backend.setMissing(missing(1))
        await model.scan()
        #expect(model.summary == "1 track cannot be found.")
        await backend.setMissing([])
        await model.scan()
        #expect(model.summary == "Every track\u{2019}s file is where the library expects it.")
    }

    @Test func locatingATrackRelocatesItAndRescans() async {
        let backend = MockBackend(trackCount: 5)
        await backend.setProtectLibrary(false)
        let stub = StubDialogs()
        let model = make(stub, backend)
        await backend.setMissing(missing(3))
        await model.scan()
        // Cancelling leaves the list alone.
        await model.locate(model.tracks[0])
        #expect(await backend.relocations.isEmpty && model.total == 3)
        stub.file = URL(fileURLWithPath: "/new/gone1.mp3")
        await model.locate(model.tracks[0])
        let relocations = await backend.relocations
        #expect(relocations.count == 1 && relocations[0].id == "1" && relocations[0].path == "/new/gone1.mp3")
        #expect(model.total == 2)
        #expect(model.message == "Located Gone 1." && !model.failed)
    }

    @Test func aRefusedRelocateKeepsTheListAndShowsTheCoresWords() async {
        let backend = MockBackend(trackCount: 5)
        await backend.setProtectLibrary(false)
        let stub = StubDialogs()
        let model = make(stub, backend)
        await backend.setMissing(missing(2))
        await model.scan()
        stub.file = URL(fileURLWithPath: "/new/x.mp3")
        await backend.setProtectLibrary(true)
        await model.locate(model.tracks[0])
        #expect(model.failed && model.message == MockBackend.protectedMessage)
        #expect(model.total == 2)
    }

    @Test func autoRelocateSearchesTheChosenFolderAndReports() async {
        let backend = MockBackend(trackCount: 5)
        await backend.setProtectLibrary(false)
        let stub = StubDialogs()
        let model = make(stub, backend)
        await backend.setMissing(missing(4))
        await model.scan()
        await model.autoRelocate()
        #expect(await backend.autoRelocateFolders.isEmpty, "cancelled")
        stub.folder = URL(fileURLWithPath: "/Volumes/Music")
        await backend.setAutoRelocate(RelocateReport(relocated: 3, unresolved: 1))
        await model.autoRelocate()
        #expect(await backend.autoRelocateFolders == [["/Volumes/Music"]])
        #expect(model.message == "3 relocated, 1 not found in the search folder.")
        #expect(model.total == 1)
        await backend.setAutoRelocate(RelocateReport(relocated: 1, unresolved: 0))
        await model.autoRelocate()
        #expect(model.message == "1 relocated.")
    }

    @Test func duplicatesSummariseAndRemovalAsksFirst() async {
        let backend = MockBackend(trackCount: 5)
        await backend.setProtectLibrary(false)
        let stub = StubDialogs()
        let model = DuplicatesModel(backend: backend, dialogs: { stub.dialogs })
        await model.scan()
        #expect(model.summary == "No two tracks share a title and an artist.")
        let group = DuplicateGroup(
            title: "Intro", artist: "A",
            tracks: [
                DuplicateTrack(id: "1", path: "/m/a.mp3", durationSec: 200, present: true),
                DuplicateTrack(id: "2", path: "/m/b.mp3", durationSec: 201, present: false),
                DuplicateTrack(id: "3", path: "/m/c.mp3", durationSec: 202, present: true),
            ])
        await backend.setDuplicates([group])
        await model.scan()
        #expect(model.summary == "1 title with more than one copy, 2 extra copies in all.")
        #expect(model.groups.count == 1)

        stub.confirms = false
        await model.remove(group.tracks[1], of: group)
        #expect(stub.confirmed.last?.message == "Remove this copy of Intro from the collection?")
        #expect(await backend.removedTracks.isEmpty)
        stub.confirms = true
        await model.remove(group.tracks[1], of: group)
        #expect(await backend.removedTracks == ["2"])
        #expect(model.summary == "1 title with more than one copy, 1 extra copy in all.")
        await model.remove(group.tracks[0], of: model.groups[0])
        #expect(model.summary == "No two tracks share a title and an artist.")
    }

    @Test func theAppModelOpensBothSheets() async {
        let model = AppModel(backend: MockBackend(trackCount: 5), layoutStore: isolatedStore())
        model.openMissingFiles()
        model.openDuplicates()
        #expect(model.missingFiles != nil && model.duplicates != nil)
    }
}
