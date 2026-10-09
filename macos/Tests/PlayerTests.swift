import AppKit
import Foundation
import Testing

@testable import rbxport

// MARK: - Pure logic

@Suite(.scratchDefaults)
struct PlayerLogicTests {
    @Test func anAnchorExtrapolatesAtItsRateAndNeverBackwards() {
        let anchor = Anchor(frames: 48_000, at: 10, sampleRate: 48_000, playing: true, generation: 1, rate: 1.5)
        #expect(anchor.extrapolate(at: 12) == 1 + 3)
        #expect(anchor.extrapolate(at: 9) == 1)  // a late tick must not rewind
        var paused = anchor
        paused.playing = false
        #expect(paused.extrapolate(at: 99) == 1)
        #expect(Anchor.none.extrapolate(at: 5) == 0)
    }

    @Test func followEasesSmallGapsAndSnapsLargeOnes() {
        // 40 ms of drift is closed gradually, not taken at once.
        let eased = PlayheadClock.follow(shown: 10, target: 10.04, sinceMs: 16, advance: 0)
        #expect(eased > 10 && eased < 10.04)
        // A seek is a snap.
        #expect(PlayheadClock.follow(shown: 10, target: 30, sinceMs: 16, advance: 0.016) == 30)
        // The first frame snaps.
        #expect(PlayheadClock.follow(shown: 0, target: 4, sinceMs: 0) == 4)
        // On target, it just advances.
        #expect(abs(PlayheadClock.follow(shown: 10, target: 10.016, sinceMs: 16, advance: 0.016) - 10.016) < 1e-9)
    }

    @Test func theDisplayClockTracksAPlayingAnchorAndSnapsOnANewGeneration() {
        let clock = DisplayClock()
        var anchor = Anchor(frames: 0, at: 0, sampleRate: 48_000, playing: true, generation: 1, rate: 1)
        #expect(clock.position(of: anchor, at: 0) == 0)
        var last = 0.0
        for i in 1...60 {
            let t = Double(i) / 60
            last = clock.position(of: anchor, at: t)
        }
        #expect(abs(last - 1) < 0.001)
        // A seek (new generation, new place) is taken at once.
        anchor = Anchor(frames: 48_000 * 100, at: 1, sampleRate: 48_000, playing: true, generation: 2, rate: 1)
        #expect(clock.position(of: anchor, at: 1.016) == 100.016)
        // Paused is exact.
        anchor.playing = false
        #expect(clock.position(of: anchor, at: 5) == 100)
    }

    @Test func cuePlayingGoesBackToTheCuePointAndPauses() {
        var cue = CueMachine(cueMs: 5_000)
        #expect(cue.press(playing: true, positionMs: 61_000) == [.seek(5_000), .pause])
        #expect(cue.release().isEmpty)
    }

    @Test func cuePausedElsewhereSetsTheCuePoint() {
        var cue = CueMachine(cueMs: 5_000)
        #expect(cue.press(playing: false, positionMs: 30_000).isEmpty)
        #expect(cue.cueMs == 30_000)
        #expect(cue.release().isEmpty)
    }

    @Test func cuePausedOnTheCuePointPlaysWhileHeldThenReturns() {
        var cue = CueMachine(cueMs: 5_000)
        // Within 20 ms counts as on the cue point.
        #expect(cue.press(playing: false, positionMs: 5_015) == [.play])
        #expect(cue.held)
        #expect(cue.release() == [.seek(5_000), .pause])
        #expect(!cue.held)
        // 21 ms away is somewhere else: it sets a new cue point.
        #expect(cue.press(playing: false, positionMs: 5_021).isEmpty)
        #expect(cue.cueMs == 5_021)
    }

    @Test func pressingPlayWhileCueIsHeldLatchesIt() {
        var cue = CueMachine(cueMs: 0)
        _ = cue.press(playing: false, positionMs: 0)
        cue.latch()
        #expect(cue.release().isEmpty)
    }

    @Test func tempoRangesMapTheFaderBothWays() {
        #expect(TempoRange.six.tempo(forFader: 1) == 1.06)
        #expect(TempoRange.six.tempo(forFader: -1) == 0.94)
        #expect(TempoRange.wide.tempo(forFader: 1) == 2.0)
        #expect(TempoRange.wide.tempo(forFader: -1) == 0.5)
        #expect(TempoRange.wide.tempo(forFader: 5) == 2.0)
        for range in TempoRange.allCases {
            for at in [-1.0, -0.4, 0, 0.25, 1] {
                #expect(abs(range.fader(forTempo: range.tempo(forFader: at)) - at) < 1e-9)
            }
        }
        #expect(TempoRange.six.fader(forTempo: 1.5) == 1)  // past the end is the end
        #expect(TempoRange.six.next == .ten && TempoRange.wide.next == .six)
        #expect(TempoRange.allCases.map(\.label) == ["\u{00B1}6", "\u{00B1}10", "\u{00B1}16", "WIDE"])
    }

    @Test func timeReadoutsMatchRekordbox() {
        #expect(PlayerFormat.elapsed(0) == "00:00.0")
        #expect(PlayerFormat.elapsed(65.97) == "01:05.9")
        #expect(PlayerFormat.elapsed(754.2) == "12:34.2")
        #expect(PlayerFormat.elapsed(-3) == "00:00.0")
        #expect(PlayerFormat.remaining(total: 200, position: 0) == "-03:20.0")
        #expect(PlayerFormat.remaining(total: 200, position: 17.34) == "-03:02.7")
        #expect(PlayerFormat.remaining(total: 200, position: 250) == "-00:00.0")
        #expect(PlayerFormat.splitTime(-62.5).main == "\u{2212}01:02")
        #expect(PlayerFormat.splitTime(.nan).main == "00:00")
        #expect(PlayerFormat.bpm(x100: 12_800) == "128.00")
        #expect(PlayerFormat.bpm(x100: 0) == "")
        #expect(PlayerFormat.playingBpmX100(base: 12_800, tempo: 1.05) == 13_440)
        #expect(PlayerFormat.tempoPercent(1.025) == "+2.5%")
        #expect(PlayerFormat.tempoPercent(0.96) == "-4.0%")
        #expect(PlayerFormat.tempoPercent(1.0001) == "0.0%")
    }

    @Test func keyBindingsAreSpaceAndHeldC() {
        func action(_ code: UInt16, _ char: String = "", up: Bool = false, repeating: Bool = false, typing: Bool = false, mods: NSEvent.ModifierFlags = [], loaded: Bool = true) -> PlayerKeyAction? {
            let effect = PlayerKeymap.resolve(
                KeyChord(character: char, keyCode: code, modifiers: mods), isUp: up, isRepeat: repeating,
                typing: typing, loaded: { _ in loaded }, twoDecks: false)
            if case .deck(.a, let action)? = effect { return action }
            return nil
        }
        #expect(action(49, " ") == .togglePlay)
        #expect(action(49, " ", repeating: true) == .swallow)
        #expect(action(49, " ", typing: true) == nil)
        #expect(action(8, "c") == .cueDown)
        #expect(action(8, "c", repeating: true) == .swallow)
        #expect(action(8, "c", up: true) == .cueUp)
        // CUE must be released even if focus moved to a text field meanwhile.
        #expect(action(8, "c", up: true, typing: true) == .cueUp)
        #expect(action(8, "c", mods: .command) == nil)  // copy
        #expect(action(8, "c", mods: .shift) == nil)  // deck B, a later slice
        #expect(action(0, "a", loaded: false) == nil)
    }
}

// MARK: - Deck and preview models against the mock engine

@MainActor
@Suite(.scratchDefaults)
struct DeckModelTests {
    final class Clock {
        var now = 100.0
    }

    func makeDeck(_ playback: MockPlayback, clock: Clock = Clock()) -> DeckModel {
        DeckModel(deck: .a, playback: playback, defaults: scratchDefaults(), now: { clock.now })
    }

    func track(_ id: String = "7", cues: [UInt32] = []) -> DeckTrack {
        var row = MockBackend.row(track: Int(id)! - 1, position: 1)
        row.memoryCues = cues
        return DeckTrack(row: row)
    }

    func deckEvent(_ loadID: UInt64, message: String? = nil) -> DeckEvent {
        DeckEvent(deck: .a, loadId: loadID, totalFrames: 48_000 * 200, sampleRate: 48_000, message: message)
    }

    func tick(
        frames: Int64, playing: Bool, generation: UInt32 = 1, loadID: UInt64 = 1, tempo: Float = 1
    ) -> DeckTick {
        DeckTick(
            frames: frames, totalFrames: 48_000 * 200, generation: generation, playing: playing, loaded: true,
            loadId: loadID, tempo: tempo, masterTempo: false, keyShift: 0, startInFrames: 0, loopInFrames: 0,
            loopOutFrames: 0, looping: false)
    }

    @Test func loadingTellsTheEngineAndWaitsForItsAnswer() {
        let playback = MockPlayback()
        playback.setAutoLoad(false)
        let deck = makeDeck(playback)
        deck.load(track("7", cues: [9_000, 4_000]))
        #expect(deck.phase == .loading)
        #expect(playback.calls == [.load(.a, "7", 1)])
        #expect(deck.cue.cueMs == 4_000)  // the first memory cue
        deck.togglePlay()  // not ready: nothing happens
        #expect(playback.calls.count == 1)
        deck.handle(deckEvent: deckEvent(1))
        #expect(deck.phase == .ready)
        #expect(deck.durationSeconds == 200)
        // A stale answer for an older load is ignored.
        deck.load(track("8"))
        deck.handle(deckEvent: deckEvent(1))
        #expect(deck.phase == .loading)
        deck.handle(deckEvent: deckEvent(2, message: "unsupported"))
        #expect(deck.phase == .failed("unsupported"))
    }

    @Test func ticksMoveThePlayheadAndOnlyForTheLoadedTrack() {
        let clock = Clock()
        let deck = makeDeck(MockPlayback(), clock: clock)
        deck.load(track())
        deck.handle(deckEvent: deckEvent(1))
        deck.apply(tick: tick(frames: 48_000 * 10, playing: true), sampleRate: 48_000, at: 100)
        #expect(deck.isPlaying)
        #expect(deck.anchor.extrapolate(at: 102) == 12)
        // A tick for another load (the old track still in the engine) is ignored.
        deck.apply(tick: tick(frames: 0, playing: false, loadID: 99), sampleRate: 48_000, at: 101)
        #expect(deck.isPlaying)
        deck.apply(tick: tick(frames: 48_000 * 12, playing: false), sampleRate: 48_000, at: 102)
        #expect(!deck.isPlaying)
        #expect(deck.position(at: 500) == 12)
    }

    @Test func playPauseIsOptimisticAndKeepsThePosition() {
        let playback = MockPlayback()
        let clock = Clock()
        let deck = makeDeck(playback, clock: clock)
        deck.load(track())
        deck.handle(deckEvent: deckEvent(1))
        deck.apply(tick: tick(frames: 48_000 * 5, playing: false), sampleRate: 48_000, at: 100)
        deck.togglePlay()
        #expect(deck.isPlaying)
        #expect(playback.calls.last == .play(.a))
        clock.now = 102
        #expect(deck.anchor.extrapolate(at: 102) == 7)
        deck.togglePlay()
        #expect(!deck.isPlaying)
        #expect(playback.calls.last == .pause(.a))
        #expect(deck.anchor.extrapolate(at: 200) == 7)
    }

    @Test func cdjCueThroughTheDeck() {
        let playback = MockPlayback()
        let clock = Clock()
        let deck = makeDeck(playback, clock: clock)
        deck.load(track("7", cues: [2_000]))
        deck.handle(deckEvent: deckEvent(1))
        playback.setAutoLoad(true)
        // Stopped at 0 (not on the cue point at 2 s): CUE sets the cue point where we are.
        deck.apply(tick: tick(frames: 48_000 * 30, playing: false), sampleRate: 48_000, at: 100)
        deck.cuePressed()
        #expect(deck.cue.cueMs == 30_000)
        deck.cueReleased()
        #expect(!playback.calls.contains(.play(.a)))
        // Pressed again on the cue point: plays while held, returns and pauses on release.
        deck.cuePressed()
        #expect(playback.calls.last == .play(.a))
        #expect(deck.isPlaying)
        clock.now = 103
        deck.cueReleased()
        #expect(Array(playback.calls.suffix(2)) == [.seek(.a, 30_000), .pause(.a)])
        #expect(!deck.isPlaying)
        #expect(deck.anchor.extrapolate(at: 300) == 30)
        // Playing: CUE goes back and pauses.
        deck.play()
        deck.cuePressed()
        #expect(Array(playback.calls.suffix(2)) == [.seek(.a, 30_000), .pause(.a)])
        #expect(!deck.isPlaying)
    }

    @Test func aSeekMovesTheHeadAtOnceAndIgnoresTheOldGenerationUntilItLands() {
        let playback = MockPlayback()
        let clock = Clock()
        let deck = makeDeck(playback, clock: clock)
        deck.load(track())
        deck.handle(deckEvent: deckEvent(1))
        deck.apply(tick: tick(frames: 48_000 * 10, playing: true, generation: 3), sampleRate: 48_000, at: 100)
        deck.seek(toFraction: 0.5)
        #expect(playback.calls.last == .seek(.a, 100_000))
        #expect(deck.anchor.extrapolate(at: 100) == 100)
        // A tick still carrying the old generation must not drag it back.
        deck.apply(tick: tick(frames: 48_000 * 10, playing: true, generation: 3), sampleRate: 48_000, at: 100.1)
        // Still running on from the seek (100 s plus a tenth), not back at the stale 10 s.
        #expect(abs(deck.anchor.extrapolate(at: 100.1) - 100.1) < 1e-9)
        // The engine's confirmation (new generation) is taken.
        deck.apply(tick: tick(frames: 48_000 * 100, playing: true, generation: 4), sampleRate: 48_000, at: 100.2)
        #expect(deck.anchor.generation == 4)
        // Seeks clamp to the track.
        deck.seek(toSeconds: 9_999)
        #expect(playback.calls.last == .seek(.a, 200_000))
    }

    @Test func tempoRangeMasterTempoAndReset() {
        let playback = MockPlayback()
        let deck = makeDeck(playback)
        deck.load(track())
        deck.handle(deckEvent: deckEvent(1))
        deck.setFader(1)  // ±6 by default
        #expect(abs(deck.tempo - 1.06) < 1e-9)
        #expect(playback.calls.last == .tempo(.a, 1.06))
        #expect(PlayerFormat.bpm(x100: deck.playingBpmX100) == String(format: "%.2f", Double(deck.track!.bpmX100) * 1.06 / 100))
        deck.cycleTempoRange()
        #expect(deck.tempoRange == .ten)
        deck.setTempo(9)
        #expect(deck.tempo == 2)  // clamped
        deck.toggleMasterTempo()
        #expect(deck.masterTempo)
        #expect(playback.calls.last == .masterTempo(.a, true))
        deck.resetTempo()
        #expect(deck.tempo == 1)
        // The engine is told the shown tempo again after a new load.
        deck.setTempo(1.03)
        deck.load(track("8"))
        deck.handle(deckEvent: deckEvent(2))
        #expect(playback.calls.contains(.tempo(.a, 1.03)))
    }

    @Test func aDeckThatWasPlayingKeepsPlayingTheNextTrack() {
        let playback = MockPlayback()
        let deck = makeDeck(playback)
        deck.load(track("7"))
        deck.handle(deckEvent: deckEvent(1))
        deck.play()
        deck.load(track("8"))
        deck.handle(deckEvent: deckEvent(2))
        #expect(playback.calls.last == .play(.a))
    }

    @Test func theTimeToggleSwitchesAndPersists() {
        let defaults = scratchDefaults()
        let deck = DeckModel(deck: .a, playback: MockPlayback(), defaults: defaults)
        #expect(deck.timeMode == .elapsed)
        deck.toggleTimeMode()
        deck.cycleTempoRange()
        let again = DeckModel(deck: .a, playback: MockPlayback(), defaults: defaults)
        #expect(again.timeMode == .remaining)
        #expect(again.tempoRange == .ten)
    }
}

@MainActor
@Suite(.scratchDefaults)
struct PlayerModelTests {
    func makePlayer() async -> (AppModel, MockBackend) {
        let backend = MockBackend(trackCount: 300)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        _ = await eventually { model.opened != nil }
        // Nothing but the table asks for rows; ask for the first page here.
        _ = model.pager.row(at: 0)
        _ = await eventually { model.pager.peek(at: 0) != nil }
        return (model, backend)
    }

    @Test func doubleClickOrReturnLoadsTheRowOntoDeckA() async {
        let (model, backend) = await makePlayer()
        _ = await eventually { model.pager.peek(at: 0) != nil }
        let row = model.pager.peek(at: 2)
        #expect(row != nil)
        model.loadToDeck(trackID: row!.id)
        #expect(model.player.deckA.track?.title == row!.title)
        #expect(model.player.deckA.phase == .loading)
        #expect(backend.mockPlayback.calls.contains(.load(.a, row!.id, 1)))
        // The mock answers the load; the pump delivers it.
        #expect(await eventually { model.player.deckA.phase == .ready })
        #expect(model.player.deckA.durationSeconds == 200)
    }

    @Test func theMenuLoadsTheSelectedTrackAndAFailureIsShown() async {
        let (model, backend) = await makePlayer()
        _ = await eventually { model.pager.peek(at: 0) != nil }
        model.tableSelectionChanged(IndexSet(integer: 1), keepingUnloaded: false)
        backend.mockPlayback.failLoads(with: "file is damaged")
        model.runTrackMenu(.loadToDeck(.a))
        #expect(await eventually { model.player.deckA.phase == .failed("file is damaged") })
        #expect(model.player.notice == "Could not load: file is damaged")
    }

    @Test func aTrackNotInALoadedPageIsLoadedFromItsDetails() async {
        let (model, backend) = await makePlayer()
        model.player.load(trackID: "250", row: nil)
        #expect(await eventually { model.player.deckA.track?.id == "250" })
        #expect(backend.mockPlayback.calls.contains(.load(.a, "250", 1)))
    }

    @Test func ticksFromTheEngineReachTheDecks() async {
        let (model, backend) = await makePlayer()
        _ = await eventually { model.pager.peek(at: 0) != nil }
        model.loadToDeck(trackID: model.pager.peek(at: 0)!.id)
        #expect(await eventually { model.player.deckA.phase == .ready })
        var a = DeckModelTests().tick(frames: 48_000 * 3, playing: true)
        a.loadId = 1
        backend.mockPlayback.tick(deckA: a, at: 50)
        #expect(await eventually { model.player.deckA.isPlaying })
        #expect(model.player.deckA.anchor.extrapolate(at: 51) == 4)
    }

    @Test func loadingStopsAPreview() async {
        let (model, backend) = await makePlayer()
        _ = await eventually { model.pager.peek(at: 0) != nil }
        model.player.preview.start(trackID: "1", positionMs: 1000, durationMs: 200_000)
        model.loadToDeck(trackID: model.pager.peek(at: 0)!.id)
        #expect(!model.player.preview.isPlaying)
        #expect(backend.mockPlayback.calls.contains(.previewStop))
    }
}

@MainActor
@Suite(.scratchDefaults)
struct PreviewModelTests {
    final class Clock {
        var now = 10.0
    }

    @Test func aClickPlaysFromThePointAndASecondClickStops() {
        let playback = MockPlayback()
        let clock = Clock()
        let preview = PreviewModel(playback: playback, now: { clock.now })
        var changes = 0
        preview.onChange = { changes += 1 }
        preview.click(trackID: "5", positionMs: 60_000, durationMs: 200_000)
        #expect(preview.isPlaying && preview.trackID == "5")
        #expect(playback.calls == [.previewPlay("5", 60_000, 1)])
        clock.now = 12
        #expect(preview.positionMs(of: "5", at: 12) == 62_000)
        #expect(preview.positionMs(of: "6", at: 12) == nil)
        #expect(preview.positionMs(of: "5", at: 10_000) == 200_000)  // clamped to the track
        preview.click(trackID: "5", positionMs: 90_000, durationMs: 200_000)
        #expect(!preview.isPlaying && preview.trackID == nil)
        #expect(playback.calls.last == .previewStop)
        #expect(preview.positionMs(of: "5", at: 12) == nil)
        #expect(changes == 2)
    }

    @Test func clickingAnotherRowSwitchesThePreview() {
        let playback = MockPlayback()
        let preview = PreviewModel(playback: playback, now: { 0 })
        preview.click(trackID: "5", positionMs: 1_000, durationMs: 200_000)
        preview.click(trackID: "6", positionMs: 2_000, durationMs: 100_000)
        #expect(preview.trackID == "6" && preview.isPlaying)
        #expect(playback.calls == [.previewPlay("5", 1_000, 1), .previewPlay("6", 2_000, 2)])
    }

    @Test func aFailedStartClearsThePreviewButAStaleAnswerIsIgnored() {
        let preview = PreviewModel(playback: MockPlayback(), now: { 0 })
        preview.start(trackID: "5", positionMs: 0, durationMs: 1_000)
        preview.start(trackID: "6", positionMs: 0, durationMs: 1_000)
        preview.resolve(token: 1, error: "old failure")
        #expect(preview.isPlaying && preview.trackID == "6")
        preview.resolve(token: 2, error: "The track could not be previewed.")
        #expect(!preview.isPlaying && preview.trackID == nil)
        #expect(preview.error == "The track could not be previewed.")
    }

    @Test func thePlayerShowsAPreviewFailure() async {
        let backend = MockBackend(trackCount: 10)
        backend.mockPlayback.failPreviews(with: "No file")
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        model.player.preview.click(trackID: "3", positionMs: 100, durationMs: 1_000)
        #expect(await eventually { model.player.notice == "Preview failed: No file" })
        #expect(!model.player.preview.isPlaying)
    }

    @Test func pollingFollowsTheEngineAndEndsAtTheEndOfTheTrack() async {
        let playback = MockPlayback()
        let preview = PreviewModel(playback: playback, now: { 0 })
        preview.start(trackID: "5", positionMs: 0, durationMs: 1_000)
        preview.resolve(token: 1, error: nil)
        #expect(preview.isPlaying)
        // The engine reports it ran out.
        playback.setPreview(PreviewState(trackId: "5", playing: false, positionMs: 1_000, durationMs: 1_000))
        #expect(await eventually { !preview.isPlaying })
        #expect(preview.trackID == nil)
    }

    @Test func clickPositionsMapToTimeOrToAHotCueBadge() {
        let band = CGRect(x: 3, y: 2, width: 200, height: 40)
        let cue = HotCue(slot: "A", positionMs: 50_000, color: nil)
        func ms(_ x: CGFloat, _ y: CGFloat, cues: [HotCue] = []) -> Double? {
            PreviewLayout.clickPositionMs(
                at: CGPoint(x: x, y: y), band: band, durationMs: 200_000, hotCues: cues, rowHeight: 44)
        }
        #expect(ms(103, 20) == 100_000)
        #expect(ms(-50, 20) == 0)  // clamped to the strip
        #expect(ms(999, 20) == 200_000)
        // On the badge (top rows, over its x): the cue's own time, not the click's.
        let badgeX = PreviewLayout.badgeX(positionMs: 50_000, durationMs: 200_000, band: band, size: 9)
        #expect(ms(badgeX + 2, band.maxY - 3, cues: [cue]) == 50_000)
        // Below the badge strip it is an ordinary click.
        #expect(ms(badgeX + 2, 10, cues: [cue]) != 50_000)
        #expect(PreviewLayout.clickPositionMs(at: .zero, band: band, durationMs: 0, hotCues: [], rowHeight: 44) == nil)
    }
}
