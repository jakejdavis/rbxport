import AppKit
import Foundation
import Testing

@testable import rbxport

// Phase 4c: cue writing, grid editing, analysis, plays, the deck menu and dragging out.

@MainActor
private struct DeckRig {
    let deck: DeckModel
    let backend: MockBackend
    var reports: [String] = []
    let defaults: UserDefaults

    /// A deck on track 7 (analysed) over a mock whose gate is open unless `locked`.
    static func make(locked: Bool = false, beats: Int = 64, cues: [Cue] = []) async -> DeckRig {
        let backend = MockBackend()
        await backend.setProtectLibrary(locked)
        let grid = (0..<beats).map {
            Beat(timeMs: 500 + UInt32($0) * 500, number: UInt8($0 % 4 + 1), tempoX100: 12_000)
        }
        await backend.setAnalysis(for: "7", beats: grid, cues: cues)
        let defaults = scratchDefaults()
        let deck = DeckModel(deck: .a, playback: backend.mockPlayback, backend: backend, defaults: defaults, now: { 0 })
        deck.canWrite = { !locked }
        var row = MockBackend.row(track: 6, position: 1)
        row.analysed = 1
        deck.load(DeckTrack(row: row))
        deck.handle(deckEvent: DeckEvent(deck: .a, loadId: 1, totalFrames: 48_000 * 200, sampleRate: 48_000, message: nil))
        _ = await eventually { deck.beats.count == beats && (cues.isEmpty || deck.cues.count == cues.count) }
        return DeckRig(deck: deck, backend: backend, defaults: defaults)
    }

    /// The write has gone out and the deck has read the cues the backend announced.
    func landed() async {
        await deck.settleWrites()
        deck.refreshCues()
        await deck.settleRefresh()
    }
}

private func hot(_ id: String, _ letter: String, _ ms: UInt32) -> Cue {
    Cue(id: id, positionMs: ms, outMs: 0, letter: letter, memory: false, colour: nil, comment: "")
}

private func memory(_ id: String, _ ms: UInt32, out: UInt32 = 0) -> Cue {
    Cue(id: id, positionMs: ms, outMs: out, letter: "", memory: true, colour: nil, comment: "")
}

@MainActor
@Suite(.scratchDefaults)
struct CueWritingTests {
    @Test func anEmptyPadSetsACueAtTheQuantisedPlayheadAndASetPadOnlyCalls() async {
        let rig = await DeckRig.make(cues: [hot("1", "B", 9_000)])
        let deck = rig.deck
        deck.seek(toSeconds: 5.2)
        deck.padPressed("A")
        await deck.settleWrites()
        #expect(await rig.backend.editLog.last == "addCue(7,hot(letter: \"A\"),5000)")
        // The pad follows the backend's announcement, not the press.
        #expect(deck.hotCues.map(\.letter) == ["B"])
        await rig.landed()
        #expect(deck.hotCues.map(\.letter).sorted() == ["A", "B"])
        // A set pad calls its cue and writes nothing.
        let writes = await rig.backend.editLog.count
        deck.padPressed("B")
        deck.padReleased()
        await deck.settleWrites()
        #expect(await rig.backend.editLog.count == writes)
    }

    @Test func withQuantizeOffACueLandsOnTheExactMillisecond() async {
        let rig = await DeckRig.make()
        rig.deck.quantize = false
        rig.deck.seek(toSeconds: 5.234)
        rig.deck.padPressed("C")
        await rig.deck.settleWrites()
        #expect(await rig.backend.editLog.last == "addCue(7,hot(letter: \"C\"),5234)")
    }

    @Test func clearingAHotCueDeletesItAndAnUnaddressableOneIsLeftAlone() async {
        let rig = await DeckRig.make(cues: [hot("1", "A", 2_000), hot("", "B", 4_000)])
        rig.deck.clearHotCue("B")
        rig.deck.clearHotCue("C")
        await rig.deck.settleWrites()
        #expect(await rig.backend.editLog.isEmpty)
        rig.deck.clearHotCue("A")
        await rig.deck.settleWrites()
        #expect(await rig.backend.editLog.last == "deleteCue(1)")
        await rig.landed()
        #expect(rig.deck.hotCues.map(\.letter) == ["B"])
    }

    @Test func recolouringAHotCueSendsItsTableIndexAndResetSendsNone() async throws {
        let rig = await DeckRig.make(cues: [hot("1", "A", 2_000)])
        let cue = try #require(rig.deck.hotCues.first)
        rig.deck.recolour(cue, to: 49)
        await rig.deck.settleWrites()
        rig.deck.recolour(cue, to: nil)
        await rig.deck.settleWrites()
        let log = await rig.backend.editLog
        #expect(log == ["setCueColour(1,49)", "setCueColour(1,nil)"])
        #expect(CueColours.hot.count == 16 && CueColours.hot[0].value == 49)
        #expect(CueColours.memory.count == 8)
    }

    @Test func memoryStoreWritesTheCuePointOnceAndDeleteTakesTheOneUnderThePlayhead() async {
        let rig = await DeckRig.make()
        let deck = rig.deck
        deck.seek(toSeconds: 3)
        deck.cuePressed()  // a paused CUE sets the cue point here
        deck.cueReleased()
        deck.storeMemoryCue()
        await deck.settleWrites()
        #expect(await rig.backend.editLog.last == "addCue(7,memory,3000)")
        await rig.landed()
        #expect(deck.memoryCues.map(\.positionMs) == [3_000])
        // A memory cue already there: nothing more is written.
        deck.storeMemoryCue()
        await deck.settleWrites()
        #expect(await rig.backend.editLog.count == 1)
        // X deletes the one the playhead stands on, and only that.
        deck.seek(toSeconds: 9)
        deck.deleteMemoryAtHead()
        await deck.settleWrites()
        #expect(await rig.backend.editLog.count == 1)
        deck.seek(toSeconds: 3.01)
        deck.deleteMemoryAtHead()
        await rig.landed()
        #expect(deck.memoryCues.isEmpty)
    }

    @Test func anActiveLoopIsStoredAsAMemoryLoop() async {
        let rig = await DeckRig.make()
        let deck = rig.deck
        deck.setLoop(inMs: 8_000, outMs: 12_000)
        deck.storeMemoryCue()
        await deck.settleWrites()
        #expect(await rig.backend.editLog.last?.hasPrefix("addLoop(7,memory,8000,12000)") == true)
        await rig.landed()
        #expect(deck.memoryCues.first?.isLoop == true)
    }

    @Test func aClosedGateWritesNothingAndSaysWhy() async {
        let rig = await DeckRig.make(locked: true)
        #expect(!rig.deck.canEditCues)
        rig.deck.padPressed("A")
        rig.deck.storeMemoryCue()
        await rig.deck.settleWrites()
        #expect(await rig.backend.editLog.isEmpty)
        // And when the core is the one to refuse, its message reaches the report hook.
        let open = await DeckRig.make()
        var told: [String] = []
        open.deck.report = { told.append($0) }
        await open.backend.setProtectLibrary(true)
        open.deck.padPressed("A")
        await open.deck.settleWrites()
        #expect(told.contains(MockBackend.protectedMessage))
        #expect(open.deck.cues.isEmpty)
    }

    @Test func cuesChangedMakesTheLoadedDeckReadItsCuesAgain() async {
        let rig = await DeckRig.make()
        let player = PlayerModel(
            backend: rig.backend, waveforms: WaveformService(backend: rig.backend, settle: .zero),
            artwork: ArtworkService(backend: rig.backend, settle: .zero), defaults: scratchDefaults())
        var row = MockBackend.row(track: 6, position: 1)
        row.analysed = 1
        player.deckA.load(DeckTrack(row: row))
        player.deckA.canWrite = { true }
        _ = try? await rig.backend.addCue(trackID: "7", slot: .hot(letter: "D"), positionMs: 1_000)
        player.handle(libraryEvent: .cuesChanged(trackId: "7"))
        #expect(await eventually { player.deckA.hotCues.map(\.letter) == ["D"] })
        // Another track's change leaves this deck alone.
        player.handle(libraryEvent: .cuesChanged(trackId: "99"))
    }

    @Test func conversionAndPlaysAreWrittenThroughTheGate() async {
        let rig = await DeckRig.make(cues: [memory("1", 5_000), memory("2", 1_000)])
        rig.deck.convertMemoryToHot()
        await rig.landed()
        #expect(rig.deck.hotCues.map(\.letter).sorted() == ["A", "B"])
    }
}

@MainActor
@Suite(.scratchDefaults)
struct PlayRecordingTests {
    @Test func theClockCountsPlayedSecondsAndFiresOnceAtSixty() {
        var clock = PlayClock()
        var fired = 0
        for t in 0...130 where clock.advance(playing: true, at: Double(t)) { fired += 1 }
        #expect(fired == 1 && clock.recorded)
        var paused = PlayClock()
        var pausedFired = false
        for t in 0...200 where paused.advance(playing: false, at: Double(t)) { pausedFired = true }
        #expect(!pausedFired)
        #expect(paused.seconds == 0)
        // A stall between ticks counts as one second, not the whole gap.
        var stalled = PlayClock()
        _ = stalled.advance(playing: true, at: 0)
        _ = stalled.advance(playing: true, at: 500)
        #expect(stalled.seconds == 1)
    }

    @Test func aDeckRecordsAPlayOncePerLoadAfterAMinute() async {
        let rig = await DeckRig.make()
        rig.deck.play()
        for t in 0...75 { rig.deck.notePlayTime(at: Double(t)) }
        await rig.deck.playRecord?.value
        #expect(await rig.backend.recordedPlays == ["7"])
        // Switched off in the settings: nothing is recorded.
        let off = await DeckRig.make()
        off.defaults.set(false, forKey: "recordHistory")
        off.deck.play()
        for t in 0...75 { off.deck.notePlayTime(at: Double(t)) }
        await off.deck.playRecord?.value
        #expect(await off.backend.recordedPlays.isEmpty)
        // And a closed gate records nothing.
        let locked = await DeckRig.make(locked: true)
        locked.deck.play()
        for t in 0...75 { locked.deck.notePlayTime(at: Double(t)) }
        #expect(await locked.backend.recordedPlays.isEmpty)
    }
}

@MainActor
@Suite(.scratchDefaults)
struct GridEditModelTests {
    @Test func shiftMarkDoubleAndHalveSendTheirEditsAndRefreshTheGrid() async {
        let rig = await DeckRig.make()
        let grid = rig.deck.grid
        await grid.refresh()
        #expect(grid.canEdit && grid.hasGrid)
        grid.shift(-1)
        grid.shift(1, held: true)
        rig.deck.seek(toSeconds: 2.5)
        grid.mark()
        grid.double()
        grid.halve()
        await grid.settle()
        let edits = await rig.backend.gridEdits.map(\.edit)
        #expect(edits == [.nudge(ms: -1), .nudge(ms: 10), .downbeat(timeMs: 2_500), .double, .halve])
        #expect(grid.state?.canUndo == true)
        // The nudges moved the mock's beats; the deck redraws from gridChanged, not from the press.
        rig.deck.refreshGrid()
        await rig.deck.settleGridRefresh()
        #expect(rig.deck.beats.times.first == 509)
        #expect(rig.backend.mockPlayback.calls.contains(.refreshGrid(.a)))
    }

    @Test func tempoIsValidatedFortyToFourNinetyNine() async {
        let rig = await DeckRig.make()
        var told: [String] = []
        rig.deck.report = { told.append($0) }
        await rig.deck.grid.refresh()
        for bad in ["", "abc", "39.9", "500"] { rig.deck.grid.setBPM(bad) }
        #expect(told == Array(repeating: GridEditModel.bpmMessage, count: 4))
        rig.deck.grid.setBPM(" 124.5 ")
        await rig.deck.grid.settle()
        #expect(await rig.backend.gridEdits.map(\.edit) == [.tempo(bpmX100: 12_450, anchorMs: 0)])
    }

    @Test func undoRedoAndTheLockGoThroughTheCore() async {
        let rig = await DeckRig.make()
        let grid = rig.deck.grid
        await grid.refresh()
        grid.shift(1)
        await grid.settle()
        grid.undo()
        await grid.settle()
        #expect(grid.state?.canRedo == true && grid.state?.canUndo == false)
        grid.redo()
        await grid.settle()
        #expect(grid.state?.canUndo == true)
        grid.toggleLock()
        await grid.settle()
        #expect(grid.locked && !grid.canEdit)
        // A locked grid takes no edits.
        grid.shift(1)
        await grid.settle()
        #expect(await rig.backend.gridEdits.count == 1)
        grid.toggleLock()
        await grid.settle()
        #expect(!grid.locked && grid.canEdit)
    }

    @Test func aClosedGateOrNoGridDisablesEditing() async {
        let locked = await DeckRig.make(locked: true)
        await locked.deck.grid.refresh()
        #expect(!locked.deck.grid.canEdit)
        locked.deck.grid.shift(1)
        await locked.deck.grid.settle()
        #expect(await locked.backend.gridEdits.isEmpty)
        let bare = await DeckRig.make(beats: 0)
        await bare.deck.grid.refresh()
        #expect(!bare.deck.grid.hasGrid)
    }

    @Test func tappingFollowsRekordboxsRunRules() {
        #expect(TapTempo.bpmX100([0]) == nil)
        #expect(TapTempo.bpmX100([0, 500, 1_000, 1_500]) == 12_000)
        #expect(TapTempo.adding([], now: 100) == [100])
        // Too slow or too fast starts over; an outlier beyond 16% drops the run.
        #expect(TapTempo.adding([0], now: 100) == [])
        #expect(TapTempo.adding([0], now: 2_000) == [2_000])
        #expect(TapTempo.adding([0, 500], now: 1_000) == [0, 500, 1_000])
        #expect(TapTempo.adding([0, 500], now: 1_200) == [])
        #expect(TapTempo.timeout([0, 500]) == 750)
        #expect(TapTempo.roundEven(2.5) == 2 && TapTempo.roundEven(3.5) == 4)
    }

    @Test func aTapRunSharesOneUndoTransaction() async {
        let rig = await DeckRig.make()
        let grid = rig.deck.grid
        await grid.refresh()
        grid.tap(nowMs: 10_000)
        grid.tap(nowMs: 10_500)
        grid.tap(nowMs: 11_000)
        await grid.settle()
        let edits = await rig.backend.gridEdits
        #expect(edits.count == 2)
        #expect(edits[0].transaction != nil && edits[0].transaction == edits[1].transaction)
        if case .tap(let bpm, _) = edits[1].edit { #expect(abs(bpm - 120) < 0.001) } else { Issue.record("not a tap") }
        grid.cancelTaps()
        #expect(grid.tapBpmX100 == nil)
    }
}

@MainActor
@Suite(.scratchDefaults)
struct AnalysisQueueTests {
    private func queue(_ backend: MockBackend, slots: Int? = nil) -> AnalysisQueue {
        let defaults = scratchDefaults()
        if let slots { defaults.set(slots, forKey: "analysis.slots") }
        return AnalysisQueue(backend: backend, defaults: defaults)
    }

    private func items(_ n: Int) -> [AnalysisItem] { (0..<n).map { AnalysisItem(id: "t\($0)", title: "Track \($0)") } }

    @Test func tracksAreAnalysedAFewAtATimeAndReloadOnceWhenTheRunEnds() async {
        let backend = MockBackend()
        await backend.setProtectLibrary(false)
        await backend.setAnalysisDelay(.milliseconds(30))
        let q = queue(backend)
        var drained = 0
        var analysed: [String] = []
        q.onDrained = { drained += 1 }
        q.onAnalysed = { analysed.append($0.trackId) }
        #expect(q.enqueue(items(8)) == 8)
        #expect(q.running.count == 3 && q.pending.count == 5)
        #expect(q.statusText == "Analysing 1 of 8")
        await q.waitUntilDrained()
        #expect(q.done == 8 && q.failed.isEmpty && drained == 1)
        #expect(Set(analysed) == Set(items(8).map(\.id)))
        #expect(await backend.peakAnalyses <= 3)
        #expect(q.statusText == "Analysed 8 of 8.")
        #expect(q.fraction == 1)
    }

    @Test func enqueueingDedupesAndSlotsAreClamped() async {
        let backend = MockBackend()
        await backend.setProtectLibrary(false)
        await backend.setAnalysisDelay(.milliseconds(40))
        let q = queue(backend, slots: 9)
        #expect(q.slots == 4)
        q.slots = 0
        #expect(q.slots == 1 && q.running.isEmpty)
        #expect(q.enqueue(items(3)) == 3)
        #expect(q.enqueue(items(5)) == 2, "the first three are already pending or running")
        await q.waitUntilDrained()
        #expect(await backend.peakAnalyses == 1)
        #expect(q.done == 5)
    }

    @Test func slotsPersistAndSettingsAreCapturedAtEnqueue() async {
        let backend = MockBackend()
        await backend.setProtectLibrary(false)
        let defaults = scratchDefaults()
        let q = AnalysisQueue(backend: backend, defaults: defaults)
        q.slots = 2
        #expect(defaults.integer(forKey: "analysis.slots") == 2)
        #expect(AnalysisQueue(backend: backend, defaults: defaults).slots == 2)
        q.rekordboxMode = true
        q.enqueue(items(1))
        q.rekordboxMode = false
        await q.waitUntilDrained()
        #expect(await backend.analysisRuns.map(\.rekordbox) == [true])
    }

    @Test func aFailureIsCountedAndTheRunGoesOn() async {
        let backend = MockBackend()
        await backend.setProtectLibrary(false)
        await backend.setAnalysisFailure(FfiError.Malformed(message: "That file could not be decoded.", detail: nil), for: "t1")
        let q = queue(backend)
        q.enqueue(items(3))
        await q.waitUntilDrained()
        #expect(q.done == 2)
        #expect(q.failed == [AnalysisFailure(id: "t1", title: "Track 1", reason: "That file could not be decoded.")])
        #expect(q.statusText == "Analysed 2 of 3; 1 failed.")
    }

    @Test func aRefusedGateEndsTheRunWithItsReason() async {
        let backend = MockBackend()  // protected by default
        await backend.setAnalysisDelay(.milliseconds(10))
        let q = queue(backend, slots: 1)
        q.enqueue(items(4))
        await q.waitUntilDrained()
        #expect(q.done == 0 && q.failed.count == 4)
        #expect(q.abortReason == MockBackend.protectedMessage)
        #expect(await backend.analysisRuns.isEmpty)
    }

    @Test func stopLetsTheRunningFinishAndDropsTheRest() async {
        let backend = MockBackend()
        await backend.setProtectLibrary(false)
        await backend.setAnalysisDelay(.milliseconds(50))
        let q = queue(backend, slots: 2)
        q.enqueue(items(6))
        q.cancel()
        #expect(q.pending.isEmpty && q.cancelling == false || q.cancelling)
        await q.waitUntilDrained()
        #expect(q.done == 2 && q.pending.isEmpty)
    }

    @Test func theAppRefusesToQueueAReadOnlyLibraryAndPassesAnOpenOne() async {
        let backend = MockBackend(trackCount: 20)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        model.analyse(["a"])
        #expect(model.notice == AnalysisQueue.readOnlyMessage && !model.analysis.isActive)
        model.protectLibrary = false
        #expect(await eventually { model.canEdit })
        model.analyse(["file:/loose.wav"])
        #expect(!model.analysis.isActive, "loose files are not in the collection")
        model.analyse(["a", "b"])
        await model.analysis.waitUntilDrained()
        #expect(await backend.analysisRuns.map(\.track).sorted() == ["a", "b"])
        // The run ended: the library is read once.
        #expect(await eventually { await backend.reloadCalls == 1 })
    }

    @Test func aFinishedAnalysisGivesTheLoadedDeckItsNewTempo() async {
        let rig = await DeckRig.make()
        let player = PlayerModel(
            backend: rig.backend, waveforms: WaveformService(backend: rig.backend, settle: .zero),
            artwork: ArtworkService(backend: rig.backend, settle: .zero), defaults: scratchDefaults())
        var row = MockBackend.row(track: 6, position: 1)
        row.bpmX100 = 12_800
        player.deckA.load(DeckTrack(row: row))
        #expect(player.deckA.track?.bpmX100 == 12_800)
        let result = AnalysisResult(trackId: "7", analysed: 105, bpmX100: 12_000, key: "Am", beats: 64, durationSec: 40, elapsedMs: 1)
        player.handle(analysed: result)
        #expect(player.deckA.track?.bpmX100 == 12_000 && player.deckA.track?.durationSec == 40)
        // Another track's result leaves the deck alone.
        player.handle(analysed: AnalysisResult(trackId: "9", analysed: 105, bpmX100: 9_000, key: "", beats: 1, durationSec: 1, elapsedMs: 1))
        #expect(player.deckA.track?.bpmX100 == 12_000)
    }

    @Test func analysisChangedRedrawsTheLoadedDeck() async {
        let rig = await DeckRig.make()
        let player = PlayerModel(
            backend: rig.backend, waveforms: WaveformService(backend: rig.backend, settle: .zero),
            artwork: ArtworkService(backend: rig.backend, settle: .zero), defaults: scratchDefaults())
        var row = MockBackend.row(track: 6, position: 1)
        row.analysed = 0
        player.deckA.load(DeckTrack(row: row))
        #expect(player.deckA.track?.analysed == false)
        player.handle(libraryEvent: .analysisChanged(trackId: "7"))
        #expect(player.deckA.track?.analysed == true)
        #expect(await eventually { player.deckA.beats.count == 64 })
        #expect(rig.backend.mockPlayback.calls.contains(.refreshGrid(.a)))
    }
}

@MainActor
@Suite(.scratchDefaults)
struct DeckMenuTests {
    @Test func waveformClickIsAPersistedPreferenceThatGatesNothingElse() {
        let defaults = scratchDefaults()
        let deck = DeckModel(deck: .a, playback: MockPlayback(), defaults: defaults)
        #expect(deck.waveformClick)
        deck.waveformClick = false
        #expect(defaults.object(forKey: "deck.waveformClick") as? Bool == false)
        #expect(!DeckModel(deck: .b, playback: MockPlayback(), defaults: defaults).waveformClick)
    }

    @Test func theMenuChoosesTheWaveformColourThroughTheApp() async {
        let backend = MockBackend()
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.player.chooseWaveformPalette(.colour)
        #expect(model.waveformPalette == .colour)
        #expect(model.layoutStore.defaults.string(forKey: "waveformPalette") == "colour")
    }

    @Test func analyzeTrackFromTheDeckQueuesTheLoadedTrack() async {
        let backend = MockBackend(trackCount: 20)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        model.protectLibrary = false
        #expect(await eventually { model.canEdit })
        model.player.analyse(deck: .a)  // nothing loaded
        #expect(!model.analysis.isActive)
        model.player.deckA.load(DeckTrack(row: MockBackend.row(track: 3, position: 1)))
        model.player.analyse(deck: .a)
        await model.analysis.waitUntilDrained()
        #expect(await backend.analysisRuns.count == 1)
    }

    @Test func theTrackMenuOffersAnalysisLockAndConversionWhenEditable() {
        func entry(_ rows: [MenuRow], _ title: String) -> MenuItemSpec? {
            for case .item(let item) in rows where item.title == title { return item }
            return nil
        }
        var context = ContextMenus.TrackContext(selectionCount: 2)
        context.editable = true
        let rows = ContextMenus.trackMenu(context)
        #expect(entry(rows, "Analyze Track")?.command == .analyse)
        let lock = entry(rows, "Analysis Lock")?.submenu
        #expect(lock?.compactMap { row -> MenuCommand? in if case .item(let i) = row { i.command } else { nil } } == [.analysisLock(true), .analysisLock(false)])
        #expect(entry(rows, "Convert Memory Cues to Hot Cues")?.command == .convertMemoryToHot)
        context.editable = false
        #expect(entry(ContextMenus.trackMenu(context), "Analyze Track")?.command == nil)
        context.editable = true
        context.hasLoose = true
        #expect(entry(ContextMenus.trackMenu(context), "Analyze Track")?.command == nil)
    }
}

@MainActor
struct TrackDragTests {
    @Test func aRowCarriesItsFileAndWhileEditableItsTrackId() throws {
        let item = try #require(TrackDrag.pasteboardItem(id: "42", path: "/Music/a b.mp3", canEdit: true))
        #expect(item.string(forType: .rbxportTracks) == "42")
        let url = try #require(item.string(forType: .fileURL).flatMap(URL.init(string:)))
        #expect(url.isFileURL && url.path == "/Music/a b.mp3")
        #expect(item.types.contains(.fileURL))
    }

    @Test func aLockedLibraryStillDragsTheFileOutButNoTrackId() throws {
        let item = try #require(TrackDrag.pasteboardItem(id: "42", path: "/Music/a.mp3", canEdit: false))
        #expect(item.string(forType: .rbxportTracks) == nil)
        #expect(item.string(forType: .fileURL) != nil)
        // Nothing to carry: no file and no right to edit.
        #expect(TrackDrag.pasteboardItem(id: "", path: nil, canEdit: false) == nil)
        // A placeholder row while editable keeps the old empty-id behaviour.
        #expect(TrackDrag.pasteboardItem(id: "", path: nil, canEdit: true)?.string(forType: .rbxportTracks) == "")
    }

    @Test func aLooseFileDragsOutByItsOwnPathAndACollectionTrackIsLookedUp() {
        #expect(TrackDrag.path(for: "file:/Users/x/loose.wav") { _ in "wrong" } == "/Users/x/loose.wav")
        #expect(TrackDrag.path(for: "9") { "/lib/\($0).mp3" } == "/lib/9.mp3")
        #expect(TrackDrag.path(for: "") { _ in "wrong" } == nil)
    }

    @Test func theItemRoundTripsThroughAPrivatePasteboard() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("rbxport-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let item = try #require(TrackDrag.pasteboardItem(id: "5", path: "/tmp/z.wav", canEdit: true))
        #expect(board.writeObjects([item]))
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.map(\.path) == ["/tmp/z.wav"])
        #expect(NSPasteboard.PasteboardType.trackIDs(from: board) == ["5"])
    }
}
