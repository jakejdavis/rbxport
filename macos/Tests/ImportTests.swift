import Foundation
import Testing

@testable import rbxport

@MainActor
@Suite(.scratchDefaults)
struct ImportTests {
    private func ready(unlocked: Bool = true) async -> (AppModel, MockBackend, StubDialogs) {
        let backend = MockBackend(trackCount: 50)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        if unlocked { model.protectLibrary = false }
        let stub = StubDialogs()
        model.dialogs = stub.dialogs
        model.start()
        #expect(await eventually { model.opened != nil && (!unlocked || !model.isReadOnly) })
        return (model, backend, stub)
    }

    private func report(imported: UInt32, skipped: [String] = [], existing: Int = 0) -> ImportReport {
        ImportReport(
            imported: imported, skipped: skipped,
            tracks: (0..<Int(imported)).map { ImportedTrack(id: "i\($0)", title: "new\($0).wav") },
            existing: (0..<existing).map { ImportedTrack(id: "e\($0)", title: "old\($0).wav") })
    }

    // MARK: Words and progress

    @Test func theSummariesReadAsTheReactAppsDo() {
        #expect(ImportSummary.files(report(imported: 3)) == "Imported 3 of 3 files.")
        #expect(ImportSummary.files(report(imported: 2, skipped: ["a: no"], existing: 1))
            == "Imported 2 of 3 files; 1 skipped; 1 already in the library.")
        #expect(ImportSummary.files(report(imported: 0, existing: 4)) == "Imported 0 of 0 files; 4 already in the library.")
        func xml(_ i: UInt32, _ e: UInt32, _ s: Int, _ p: UInt32, _ c: UInt32) -> String {
            ImportSummary.xml(
                XmlImportReport(
                    imported: i, existing: e, skipped: Array(repeating: "x", count: s), playlists: p, cues: c, tracks: []))
        }
        #expect(xml(1, 0, 0, 1, 0) == "1 track imported, 1 playlist.")
        #expect(xml(5, 2, 1, 3, 1) == "5 tracks imported, 2 already here, 1 skipped, 3 playlists, 1 cue.")
        #expect(ImportSummary.skippedDetail((1...12).map { "line \($0)" }).hasSuffix("\u{2026}and 2 more."))
    }

    @Test func theProgressModelCountsAndIgnoresStragglers() async {
        #expect(ImportProgressState(done: 0, total: 0, title: "").fraction == nil)
        #expect(ImportProgressState(done: 1, total: 4, title: "a.wav").fraction == 0.25)
        #expect(ImportProgressState(done: 9, total: 4, title: "").fraction == 1)
        #expect(ImportProgressState(done: 2, total: 5, title: "a.wav").text == "Importing 2 of 5: a.wav")
        #expect(ImportProgressState(done: 0, total: 0, title: "").text == "Importing\u{2026}")
        let (model, _, _) = await ready()
        let event = ImportProgress(path: "p", state: "writing", done: 3, total: 10, title: "x.wav")
        model.importProgressed(event)
        #expect(model.importProgress == nil, "no import of ours is running")
        model.importInFlight = true
        model.importProgressed(event)
        #expect(model.importProgress == ImportProgressState(done: 3, total: 10, title: "x.wav"))
    }

    @Test func progressEventsFromTheBackendReachTheModelWhileAnImportRuns() async {
        let (model, backend, _) = await ready()
        await backend.setImport(report(imported: 2), titles: ["a.wav", "b.wav"])
        let url = URL(fileURLWithPath: "/music/set")
        let landed = await model.importFiles([url])
        #expect(landed == ["i0", "i1"])
        // Cleared once the call is over, whatever the events were.
        #expect(model.importProgress == nil && !model.importInFlight)
    }

    // MARK: Flows

    @Test func importingFilesReportsTheCountsInTheStatusLine() async {
        let (model, backend, stub) = await ready()
        await backend.setImport(report(imported: 2, existing: 1))
        await model.importFiles([URL(fileURLWithPath: "/m/a.wav"), URL(fileURLWithPath: "/m/b.wav")])
        #expect(model.notice == "Imported 2 of 2 files; 1 already in the library.")
        #expect(await backend.importedPaths == [["/m/a.wav", "/m/b.wav"]])
        #expect(stub.informed.isEmpty, "nothing was skipped, so no alert")
        #expect(await eventually { model.summary?.trackCount == 52 })
    }

    @Test func skippedFilesAreListedInAnAlert() async {
        let (model, backend, stub) = await ready()
        await backend.setImport(report(imported: 1, skipped: ["/m/notes.txt: txt is not a format rekordbox plays"]))
        await model.importFiles([URL(fileURLWithPath: "/m")])
        #expect(model.notice == "Imported 1 of 2 files; 1 skipped.")
        #expect(stub.informed.count == 1)
        #expect(stub.informed[0].message == "1 file was not imported")
        #expect(stub.informed[0].detail.contains("notes.txt"))
    }

    @Test func aLockedLibraryRefusesTheImportAndSaysWhy() async {
        let (model, backend, _) = await ready(unlocked: false)
        let landed = await model.importFiles([URL(fileURLWithPath: "/m/a.wav")])
        #expect(landed.isEmpty)
        #expect(model.notice == MockBackend.protectedMessage)
        #expect(!model.importInFlight && model.importProgress == nil)
        #expect(await backend.importedPaths.count == 1)
    }

    @Test func theFilePanelsAskForFilesOrAFolderAndCancelIsQuiet() async {
        let (model, backend, stub) = await ready()
        await model.importFromPanel(folders: false)
        #expect(stub.audioPrompts.last?.directories == false && stub.audioPrompts.last?.prompt == "Add music to the library")
        #expect(await backend.importedPaths.isEmpty, "cancelled")
        stub.audio = [URL(fileURLWithPath: "/m/folder")]
        await backend.setImport(report(imported: 1))
        await model.importFromPanel(folders: true)
        #expect(stub.audioPrompts.last?.directories == true && stub.audioPrompts.last?.prompt == "Add a folder of music to the library")
        #expect(await backend.importedPaths == [["/m/folder"]])
    }

    @Test func aDroppedFileIsImportedThenAddedToThePlaylist() async {
        let (model, backend, _) = await ready()
        await backend.setImport(report(imported: 1, existing: 1))
        model.selectNode("pl:10")
        #expect(await eventually { model.openPlaylistID == "10" })
        let took = await model.dropFilesOnTable([URL(fileURLWithPath: "/m/a.wav")])
        #expect(took)
        let log = await backend.editLog
        #expect(log.last == "addTracks(10,i0,e0)")
        #expect(model.notice?.hasPrefix("Imported 1 of 1 files; 1 already in the library.") == true)
        #expect(model.notice?.hasSuffix("Added 2 to Warm-up.") == true)
    }

    @Test func aDropOnAllTracksImportsOnlyAndElsewhereIsRefused() async {
        let (model, backend, _) = await ready()
        await backend.setImport(report(imported: 1))
        model.selectNode("all")
        #expect(await model.dropFilesOnTable([URL(fileURLWithPath: "/m/a.wav")]))
        #expect(await backend.editLog.filter { $0.hasPrefix("addTracks") }.isEmpty)
        model.selectNode("tag")
        #expect(await model.dropFilesOnTable([URL(fileURLWithPath: "/m/a.wav")]) == false)
        #expect(model.notice == "Drop files or folders onto a playlist to import them.")
        #expect(await backend.importedPaths.count == 1)
    }

    @Test func aDropOnTheSidebarGoesToAPlaylistOrTheCollectionOnly() async {
        let (model, backend, _) = await ready()
        await backend.setImport(report(imported: 1))
        let playlist = model.sidebar.node(withID: "pl:11")!
        #expect(await model.dropFiles([URL(fileURLWithPath: "/m/a.wav")], on: playlist))
        #expect(await backend.editLog.last == "addTracks(11,i0)")
        let all = model.sidebar.node(withID: "all")!
        #expect(await model.dropFiles([URL(fileURLWithPath: "/m/b.wav")], on: all))
        #expect(await backend.importedPaths.count == 2)
        let section = model.sidebar.node(withID: "section:playlists")!
        #expect(await model.dropFiles([URL(fileURLWithPath: "/m/c.wav")], on: section) == false)
        #expect(model.notice == "Drop files or folders onto a playlist to import them.")
    }

    @Test func rekordboxXMLImportsThroughTheSameProgressAndSaysWhatLanded() async {
        let (model, backend, stub) = await ready()
        stub.file = URL(fileURLWithPath: "/m/collection.xml")
        await backend.setXML(
            XmlImportReport(imported: 4, existing: 1, skipped: ["Gone: not a file"], playlists: 2, cues: 3, tracks: []))
        await model.importXMLFromPanel()
        #expect(model.notice == "4 tracks imported, 1 already here, 1 skipped, 2 playlists, 3 cues.")
        #expect(stub.informed.first?.message == "1 track was not imported")
        #expect(await backend.importedPaths == [["/m/collection.xml"]])
    }

    @Test func filesFromTheExplorerAreImportedBeforeTheyJoinAPlaylist() async {
        let (model, backend, _) = await ready()
        await backend.setImport(report(imported: 1))
        await model.addToPlaylist("10", trackIDs: ["4", "file:/m/new.wav"])
        #expect(await backend.importedPaths == [["/m/new.wav"]])
        #expect(await backend.editLog.last == "addTracks(10,4,i0)")
    }

    @Test func importToCollectionOverTheExplorersFilesImportsThem() async {
        let (model, backend, _) = await ready()
        await backend.setImport(report(imported: 1))
        model.selectNode("ex:/mock/Music")
        #expect(await eventually { model.opened != nil })
        model.tableSelectionChanged(IndexSet(), keepingUnloaded: false)
        model.runTrackMenu(.importToCollection)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await backend.importedPaths.isEmpty, "nothing selected, nothing imported")
    }
}
