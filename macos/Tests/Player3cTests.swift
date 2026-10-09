import AppKit
import Foundation
import Testing

@testable import rbxport

// MARK: - Helpers

@MainActor
final class PlayerRig {
    final class Clock { var now = 100.0 }

    let backend: MockBackend
    let mock: MockPlayback
    let defaults: UserDefaults
    let clock = Clock()
    let player: PlayerModel

    init(defaults: UserDefaults? = nil, layout: PlayerLayout? = nil) {
        backend = MockBackend(trackCount: 20)
        mock = backend.mockPlayback
        // The rig answers loads itself (`load`), in order; a test turns this on to let the pump do it.
        mock.setAutoLoad(false)
        let defaults = defaults ?? scratchDefaults()
        self.defaults = defaults
        if let layout { defaults.set(layout.rawValue, forKey: PlayerLayout.key) }
        let clock = clock
        player = PlayerModel(
            backend: backend, waveforms: WaveformService(backend: backend, settle: .zero),
            artwork: ArtworkService(backend: backend, settle: .zero), defaults: defaults, now: { clock.now })
    }

    /// A row at `bpm` (x100), loaded onto `deck` and answered by the engine.
    func load(_ deck: Deck, track: Int = 6, bpmX100: UInt32 = 12_000, beats: Bool = true) {
        var row = MockBackend.row(track: track, position: 1)
        row.bpmX100 = bpmX100
        player.load(trackID: row.id, row: row, into: deck)
        let model = player.deck(deck)
        player.handle(.deck(DeckEvent(deck: deck, loadId: model.loadID, totalFrames: 48_000 * 200, sampleRate: 48_000, message: nil)))
        if beats { model.install(beats: Self.grid(bpmX100: bpmX100)) }
    }

    static func grid(bpmX100: UInt32, count: Int = 400) -> BeatGrid {
        let period = 60_000 * 100 / Double(bpmX100)
        return BeatGrid(
            beats: (0..<count).map {
                Beat(timeMs: UInt32(500 + Double($0) * period), number: UInt8($0 % 4 + 1), tempoX100: UInt16(bpmX100))
            })
    }

    /// `sameInstant`: stamped with the moment of the last tick, so a playing deck's extrapolated
    /// position is exactly `seconds` for a call made now.
    func tick(_ deck: Deck, seconds: Double, playing: Bool, sameInstant: Bool = false) {
        if !sameInstant { clock.now += 1 }
        let model = player.deck(deck)
        let t = DeckTick(
            frames: Int64(seconds * 48_000), totalFrames: 48_000 * 200, generation: UInt32(clock.now), playing: playing,
            loaded: true, loadId: model.loadID, tempo: Float(model.tempo), masterTempo: false, keyShift: 0,
            startInFrames: 0, loopInFrames: 0, loopOutFrames: 0, looping: false)
        model.apply(tick: t, sampleRate: 48_000, at: clock.now)
    }
}

// MARK: - Layouts

@MainActor
@Suite(.scratchDefaults)
struct LayoutTests {
    @Test func theFourLayoutsHaveReactsLabelsDeckCountsAndKeys() {
        #expect(PlayerLayout.allCases == [.one, .two, .simple, .browser])
        #expect(PlayerLayout.allCases.map(\.label) == ["1 PLAYER", "2 PLAYER", "SIMPLE PLAYER", "FULL BROWSER"])
        #expect(PlayerLayout.allCases.map(\.deckCount) == [1, 2, 1, 0])
        #expect(PlayerLayout.allCases.map(\.keyEquivalent) == ["7", "8", "9", "0"])
        #expect(PlayerLayout.allCases.map(\.isFullDeck) == [true, true, false, true])
    }

    @Test func theDefaultIsOneAndTheChoiceIsRemembered() {
        let rig = PlayerRig()
        #expect(rig.player.layout == .one)
        #expect(rig.player.panelOpen)
        rig.player.layout = .two
        #expect(rig.defaults.string(forKey: PlayerLayout.key) == "two")
        let again = PlayerRig(defaults: rig.defaults)
        #expect(again.player.layout == .two)
    }

    @Test func theFullBrowserHidesThePanelAndShowPlayerComesBackToTheLastLayout() {
        let rig = PlayerRig(layout: .simple)
        rig.player.layout = .browser
        #expect(!rig.player.panelOpen)
        rig.player.panelOpen = true
        #expect(rig.player.layout == .simple)
        // Remembered across a launch in the browser, too.
        rig.player.layout = .browser
        #expect(PlayerRig(defaults: rig.defaults).player.lastDeckLayout == .simple)
    }

    @Test func aPlayerHiddenBeforeLayoutsOpensInTheBrowser() {
        let defaults = scratchDefaults()
        defaults.set(false, forKey: "player.open")
        #expect(PlayerRig(defaults: defaults).player.layout == .browser)
    }

    @Test func aDevLaunchDoesNotRewriteThePreference() {
        let rig = PlayerRig()
        rig.player.persistsLayout = false
        rig.player.layout = .two
        #expect(rig.defaults.string(forKey: PlayerLayout.key) == nil)
    }

    @Test func panelHeightsAreKeptPerLayout() {
        let rig = PlayerRig()
        rig.player.currentPanelHeight = 400
        rig.player.layout = .two
        #expect(rig.player.currentPanelHeight == 480)
        rig.player.currentPanelHeight = 9_999
        #expect(rig.player.currentPanelHeight == PlayerModel.dualPanelHeightRange.upperBound)
        rig.player.layout = .simple
        rig.player.currentPanelHeight = 700
        #expect(rig.player.currentPanelHeight == PlayerModel.simplePanelHeight)
        rig.player.layout = .one
        #expect(rig.player.currentPanelHeight == 400)
    }
}

// MARK: - Deck B routing

@MainActor
@Suite(.scratchDefaults)
struct DeckBRoutingTests {
    @Test func loadingDeckBIsRefusedInTheOneDeckLayouts() {
        for layout in [PlayerLayout.one, .simple, .browser] {
            let rig = PlayerRig(layout: layout)
            let row = MockBackend.row(track: 3, position: 1)
            #expect(!rig.player.load(trackID: row.id, row: row, into: .b))
            #expect(rig.player.deckB.track == nil)
            #expect(rig.player.notice != nil)
            #expect(!rig.mock.calls.contains { if case .load(.b, _, _) = $0 { true } else { false } })
        }
        let two = PlayerRig(layout: .two)
        let row = MockBackend.row(track: 3, position: 1)
        #expect(two.player.load(trackID: row.id, row: row, into: .b))
        #expect(two.player.deckB.track?.id == row.id)
        #expect(two.mock.calls.contains(.load(.b, row.id, 1)))
        #expect(two.player.deckA.track == nil)
    }

    @Test func theMenuAndShiftReturnLoadOntoDeckB() async {
        let backend = MockBackend(trackCount: 300)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.player.layout = .two
        model.start()
        _ = await eventually { model.opened != nil }
        _ = model.pager.row(at: 0)
        _ = await eventually { model.pager.peek(at: 0) != nil }
        model.tableSelectionChanged(IndexSet(integer: 1), keepingUnloaded: false)
        model.runTrackMenu(.loadToDeck(.b))
        #expect(model.player.deckB.track?.id == model.pager.peek(at: 1)?.id)
        #expect(model.player.deckA.track == nil)
        // Shift-Return is the table's flag for the same thing.
        let id = model.pager.peek(at: 2)!.id
        model.loadToDeck(trackID: id, deck: .b)
        #expect(model.player.deckB.track?.id == id)
        // And the one-deck layout refuses it.
        model.player.layout = .one
        model.loadToDeck(trackID: model.pager.peek(at: 3)!.id, deck: .b)
        #expect(model.player.deckB.track?.id == id)
    }

    @Test func playerTwoIsALiveEntryInTheContextMenu() {
        func items(_ rows: [MenuRow]) -> [MenuItemSpec] { rows.compactMap { if case .item(let i) = $0 { i } else { nil } } }
        let rows = ContextMenus.trackMenu(.init(selectionCount: 1))
        let load = items(rows).first { $0.title == "Load" }!
        #expect(items(load.submenu!).map(\.command) == [.loadToDeck(.a), .loadToDeck(.b)])
    }

    private func chord(_ character: String, _ code: UInt16 = 0, _ mods: NSEvent.ModifierFlags = []) -> KeyChord {
        KeyChord(character: character, keyCode: code, modifiers: mods)
    }

    @Test func shiftIsDeckBInTheTwoDeckLayoutOnly() {
        let q = PlayerKeymap.route(chord("q", 0, .shift), twoDecks: true)
        #expect(q?.deck == .b && q?.chord.modifiers.isEmpty == true && q?.chord.character == "q")
        #expect(PlayerKeymap.route(chord("q"), twoDecks: true)?.deck == .a)
        #expect(PlayerKeymap.route(chord("q"), twoDecks: false)?.deck == .a)
        #expect(PlayerKeymap.route(chord("q", 0, .shift), twoDecks: false) == nil)
        // Shift with another modifier is nobody's: there are no Shift-Command hot cue clears for B.
        #expect(PlayerKeymap.route(chord("1", 0, [.shift, .command]), twoDecks: true) == nil)
    }

    @Test func shiftedNumbersAreBsHotCuesAndTheArrowsBsJump() {
        let one = PlayerKeymap.route(chord("!", 0, .shift), twoDecks: true)!
        #expect(one.deck == .b)
        #expect(PlayerKeymap.action(for: one.chord, isUp: false, isRepeat: false, typing: false, loaded: true) == .hotCueDown("A"))
        #expect(PlayerKeymap.action(for: one.chord, isUp: true, isRepeat: false, typing: false, loaded: true) == .hotCueUp)
        let arrow = PlayerKeymap.route(chord("", PlayerKeymap.right, .shift), twoDecks: true)!
        #expect(arrow.deck == .b)
        #expect(PlayerKeymap.action(for: arrow.chord, isUp: false, isRepeat: false, typing: false, loaded: true) == .jump(1))
        // Shift-Space plays B; F1 is BEAT SYNC.
        let space = PlayerKeymap.route(chord("", PlayerKeymap.space, .shift), twoDecks: true)!
        #expect(PlayerKeymap.action(for: space.chord, isUp: false, isRepeat: false, typing: false, loaded: false) == .togglePlay)
        #expect(PlayerKeymap.action(for: chord("", PlayerKeymap.f1), isUp: false, isRepeat: false, typing: false, loaded: true) == .beatSync)
    }

    @Test func keysPerformedOnBTouchOnlyDeckB() {
        let rig = PlayerRig(layout: .two)
        rig.load(.a, track: 5)
        rig.load(.b, track: 6)
        rig.player.perform(.quantize, on: .b)
        #expect(rig.player.deckA.quantize && !rig.player.deckB.quantize)
        rig.player.perform(.togglePlay, on: .b)
        #expect(rig.mock.calls.contains(.play(.b)) && !rig.mock.calls.contains(.play(.a)))
        rig.player.perform(.zoom(-1), on: .b)
        #expect(rig.player.deckB.zoomBars == 8 && rig.player.deckA.zoomBars == 12)
        rig.player.perform(.bpmUp, on: .b)
        #expect(rig.mock.calls.contains(.tempo(.b, 1.001)))
    }

    @Test func letGoOfCueReachesTheDeckItWentDownOn() {
        let rig = PlayerRig(layout: .two)
        rig.load(.b)
        rig.tick(.b, seconds: 0, playing: false)
        rig.player.perform(.cueDown, on: .b)
        #expect(rig.mock.calls.last == .play(.b))
        // Shift came up first, so the up arrives as deck A's key: it still releases B.
        rig.player.perform(.cueUp, on: .a)
        #expect(rig.mock.calls.suffix(2) == [.seek(.b, 0), .pause(.b)])
    }

    @Test func eachDeckKeepsItsOwnZoomAndTempoState() {
        let rig = PlayerRig(layout: .two)
        rig.load(.a)
        rig.load(.b)
        rig.player.deckA.setTempo(1.04)
        #expect(rig.player.deckB.tempo == 1)
        #expect(rig.defaults.object(forKey: "deckB.zoomBars") == nil)
        rig.player.deckB.setZoom(bars: 4)
        #expect(rig.defaults.double(forKey: "deckB.zoomBars") == 4)
        #expect(rig.player.deckA.zoomBars == 12)
    }

    @Test func eachDecksTicksReachOnlyThatDeck() {
        let rig = PlayerRig(layout: .two)
        rig.load(.a)
        rig.load(.b)
        rig.tick(.b, seconds: 30, playing: true)
        #expect(rig.player.deckB.isPlaying && !rig.player.deckA.isPlaying)
    }
}

// MARK: - DUAL CONTROL

@MainActor
@Suite(.scratchDefaults)
struct DualControlTests {
    @Test func offByDefaultEachDeckKeepsItsOwnZoomAndJump() {
        let rig = PlayerRig(layout: .two)
        #expect(!rig.player.dualControl)
        rig.player.deckA.setZoom(bars: 4)
        rig.player.deckA.jumpSize = JumpSize.all[2]
        #expect(rig.player.deckB.zoomBars == 12)
        #expect(rig.player.deckB.jumpSize == JumpSize.default)
    }

    @Test func onItLinksZoomAndJumpSizeBothWays() {
        let rig = PlayerRig(layout: .two)
        rig.player.dualControl = true
        rig.player.deckA.zoom(direction: -1)
        #expect(rig.player.deckB.zoomBars == rig.player.deckA.zoomBars && rig.player.deckA.zoomBars == 8)
        rig.player.deckB.setZoom(bars: 2)
        #expect(rig.player.deckA.zoomBars == 2)
        rig.player.deckB.jumpSize = JumpSize.all[3]
        #expect(rig.player.deckA.jumpSize == JumpSize.all[3])
        rig.player.deckA.jumpSize = JumpSize.all[1]
        #expect(rig.player.deckB.jumpSize == JumpSize.all[1])
        // The wheel reaches both through the same call.
        rig.player.deckA.zoom(direction: 1)
        #expect(rig.player.deckB.zoomBars == rig.player.deckA.zoomBars)
    }

    @Test func switchingItOnTakesDeckAsValuesAndOffUnlinks() {
        let rig = PlayerRig(layout: .two)
        rig.player.deckA.setZoom(bars: 16)
        rig.player.deckA.jumpSize = JumpSize.all[4]
        rig.player.deckB.setZoom(bars: 1)
        rig.player.dualControl = true
        #expect(rig.player.deckB.zoomBars == 16 && rig.player.deckB.jumpSize == JumpSize.all[4])
        rig.player.dualControl = false
        rig.player.deckA.setZoom(bars: 4)
        #expect(rig.player.deckB.zoomBars == 16)
    }

    @Test func theLinkIsPersistedAndLinkedZoomIsStoredPerDeck() {
        let rig = PlayerRig(layout: .two)
        rig.player.dualControl = true
        rig.player.deckA.setZoom(bars: 8)
        let again = PlayerRig(defaults: rig.defaults)
        #expect(again.player.dualControl)
        #expect(again.player.deckA.zoomBars == 8 && again.player.deckB.zoomBars == 8)
    }
}

// MARK: - Mixer

@MainActor
@Suite(.scratchDefaults)
struct MixerTests {
    @Test func theCrossfaderHasADetentAtTheCentre() {
        // 190 points of travel: within 3 points of the middle snaps.
        #expect(Crossfader.value(forFraction: 0.5 + 2.0 / 190, length: 190) == 0.5)
        #expect(Crossfader.value(forFraction: 0.5 - 3.0 / 190, length: 190) == 0.5)
        #expect(Crossfader.value(forFraction: 0.5 + 4.0 / 190, length: 190) > 0.5)
        #expect(Crossfader.value(forFraction: -1, length: 190) == 0)
        #expect(Crossfader.value(forFraction: 9, length: 190) == 1)
        #expect(Crossfader.value(forFraction: .nan, length: 190) == 0.5)
    }

    @Test func arrowKeysStepByAFiftiethOfTheTravelAndComeBackToExactlyCentre() {
        let mock = MockPlayback()
        let mixer = MixerModel(playback: mock)
        mixer.nudgeCrossfade(steps: 1)
        mixer.nudgeCrossfade(steps: 1)
        #expect(mixer.crossfade == 0.6)
        mixer.nudgeCrossfade(steps: -1)
        mixer.nudgeCrossfade(steps: -1)
        #expect(mixer.crossfade == 0.5)
        for _ in 0..<30 { mixer.nudgeCrossfade(steps: -1) }
        #expect(mixer.crossfade == 0)
        #expect(mock.calls.last == .crossfade(0))
    }

    @Test func aDoubleClickPutsTheCrossfaderBackAndADragSnaps() {
        let mock = MockPlayback()
        let mixer = MixerModel(playback: mock)
        mixer.setCrossfade(0.9)
        #expect(mock.calls.last == .crossfade(0.9))
        mixer.resetCrossfade()
        #expect(mixer.crossfade == 0.5 && mock.calls.last == .crossfade(0.5))
        mixer.dragCrossfade(toFraction: 0.505, length: 100)
        #expect(mixer.crossfade == 0.5)
        mixer.dragCrossfade(toFraction: 0.7, length: 100)
        #expect(mixer.crossfade == 0.7)
    }

    @Test func trimDragsArrowsAndResets() {
        let mock = MockPlayback()
        let mixer = MixerModel(playback: mock)
        // 120 points sweeps the 0 to 2 range: 60 points up from unity is +1.
        #expect(ChannelStrip.dragged(from: 1, dy: 60, span: 2) == 2)
        mixer.setTrim(.a, ChannelStrip.dragged(from: 1, dy: 90, span: 2))
        #expect(mixer.a.trim == 2)  // clamped
        mixer.setTrim(.b, -4)
        #expect(mixer.b.trim == 0)
        mixer.resetTrim(.b)
        #expect(mixer.b.trim == 1 && mock.calls.last == .trim(.b, 1))
        mixer.nudgeTrim(.a, steps: -1)
        #expect(abs(mixer.a.trim - 1.95) < 1e-9)
        #expect(ChannelStrip.trimLabel(0) == "-\u{221E}dB")
        #expect(ChannelStrip.trimLabel(1) == "0.0dB")
        #expect(ChannelStrip.trimLabel(2) == "6.0dB")
        #expect(ChannelStrip.trimLabel(0.5) == "-6.0dB")
    }

    @Test func bandsAndKillsGoToTheRightChannel() {
        let mock = MockPlayback()
        let mixer = MixerModel(playback: mock)
        mixer.setBand(.b, .high, 0.1)
        #expect(mixer.b.bands == [0.5, 0.5, 0.1] && mixer.a.bands == [0.5, 0.5, 0.5])
        #expect(mock.calls.last == .band(.b, .high, 0.1))
        mixer.resetBand(.b, .high)
        #expect(mixer.b.bands[2] == 0.5)
        mixer.toggleKill(.a, .low)
        #expect(mixer.a.kills == [true, false, false] && mock.calls.last == .kill(.a, .low, true))
        mixer.toggleKill(.a, .low)
        #expect(mixer.a.kills == [false, false, false] && mock.calls.last == .kill(.a, .low, false))
        mixer.nudgeBand(.a, .mid, steps: 2)
        #expect(abs(mixer.a.bands[1] - 0.6) < 1e-9)
    }

    @Test func theStripReadsTheEnginesStateInsteadOfResettingIt() {
        let mock = MockPlayback()
        var channel = MockPlayback.defaultChannel
        channel.trim = 1.5
        channel.killMid = true
        mock.setMixer(MixerSnapshot(a: channel, b: MockPlayback.defaultChannel, crossfade: 0.8, isolator: false))
        let mixer = MixerModel(playback: mock)
        #expect(mixer.crossfade == Double(Float(0.8)))
        #expect(mixer.a.trim == 1.5 && mixer.a.kills == [false, true, false])
        // Building the model sent nothing: the engine keeps what it had.
        #expect(mock.calls.isEmpty)
    }

    @Test func buildingThePlayerNeverResetsTheCrossfaderAndAResetRereadsTheMixer() {
        let rig = PlayerRig()
        rig.mock.setMixer(MixerSnapshot(a: MockPlayback.defaultChannel, b: MockPlayback.defaultChannel, crossfade: 0.25, isolator: false))
        let again = PlayerRig(defaults: rig.defaults)
        // (Each rig has its own mock; the point is that nothing is sent on launch.)
        #expect(!again.mock.calls.contains { if case .crossfade = $0 { true } else { false } })
        rig.player.handle(.reset)
        #expect(rig.player.mixer.crossfade == 0.25)
    }
}

// MARK: - Master level and limiter

@MainActor
@Suite(.scratchDefaults)
struct MasterAndLimiterTests {
    @Test func theKnobsTenIsMinusOneDecibelAndElevenIsPlusTwo() {
        #expect(abs(MasterScale.gain(forReading: 10) - 0.891_25) < 1e-4)
        #expect(abs(MasterScale.gain(forReading: 11) - 1.258_9) < 1e-3)
        #expect(MasterScale.gain(forReading: 0) == 0)
        #expect(MasterScale.reading(forGain: 0.891_250_9) > 9.99)
        #expect(MasterScale.reading(forGain: 1.2589) == 11)
        #expect(abs(MasterScale.reading(forGain: MasterScale.gain(forReading: 5)) - 5) < 1e-6)
        #expect(MasterScale.label(10.4) == "10" && MasterScale.label(99) == "11" && MasterScale.label(-1) == "0")
    }

    @Test func theMasterLevelIsPushedAtLaunchRememberedAndNeverOpensAnything() {
        let defaults = scratchDefaults()
        let mock = MockPlayback()
        let master = MasterModel(playback: mock, defaults: defaults)
        #expect(mock.calls == [.masterLevel(Float(MasterScale.defaultGain))])
        master.setReading(5)
        #expect(defaults.double(forKey: "rbl.master-level.v1") > 0)
        let again = MockPlayback()
        let reopened = MasterModel(playback: again, defaults: defaults)
        #expect(abs(reopened.reading - 5) < 1e-6)
        #expect(again.calls.count == 1)
    }

    @Test func limiterDefaultsMatchTheEngines() {
        let limiter = LimiterModel(playback: MockPlayback(), defaults: scratchDefaults())
        #expect(limiter.settings == LimiterSettings(enabled: false, inputGainDb: -4, ceilingDb: 0, releaseMs: 250))
    }

    @Test func limiterValuesAreClampedToTheSpecRanges() {
        let mock = MockPlayback()
        let limiter = LimiterModel(playback: mock, defaults: scratchDefaults())
        limiter.set {
            $0.inputGainDb = 99
            $0.ceilingDb = 5
            $0.releaseMs = 1
        }
        #expect(limiter.settings.inputGainDb == 24 && limiter.settings.ceilingDb == 0 && limiter.settings.releaseMs == 10)
        limiter.set {
            $0.inputGainDb = -99
            $0.ceilingDb = -99
            $0.releaseMs = 5_000
        }
        #expect(limiter.settings.inputGainDb == -24 && limiter.settings.ceilingDb == -12 && limiter.settings.releaseMs == 1_000)
        limiter.set { $0.inputGainDb = .nan }
        #expect(limiter.settings.inputGainDb == -4)
    }

    @Test func limiterSettingsArePersistedAsReactsJSONAndPushedAtLaunch() {
        let defaults = scratchDefaults()
        let first = MockPlayback()
        let limiter = LimiterModel(playback: first, defaults: defaults)
        limiter.set {
            $0.enabled = true
            $0.inputGainDb = -2.5
            $0.ceilingDb = -1
            $0.releaseMs = 120
        }
        let stored = defaults.string(forKey: "rbl.limiter.v1")
        #expect(stored == #"{"ceilingDb":-1,"enabled":true,"inputGainDb":-2.5,"releaseMs":120}"#)
        let second = MockPlayback()
        let again = LimiterModel(playback: second, defaults: defaults)
        #expect(again.settings == limiter.settings)
        // Pushed straight away, before anything plays.
        #expect(second.calls == [.limiter(Limiter(enabled: true, inputGainDb: -2.5, ceilingDb: -1, releaseMs: 120))])
    }

    @Test func aStoredValueThatIsHalfWrittenOrOutOfRangeFallsBackOrClamps() {
        #expect(LimiterSettings.decode(nil) == LimiterSettings())
        #expect(LimiterSettings.decode("not json") == LimiterSettings())
        #expect(LimiterSettings.decode(#"{"enabled":true}"#) == LimiterSettings(enabled: true, inputGainDb: -4, ceilingDb: 0, releaseMs: 250))
        let wild = LimiterSettings.decode(#"{"enabled":true,"inputGainDb":500,"ceilingDb":-80,"releaseMs":0}"#)
        #expect(wild.inputGainDb == 24 && wild.ceilingDb == -12 && wild.releaseMs == 10)
    }

    @Test func whatTheEngineReturnsIsWhatIsShown() {
        let defaults = scratchDefaults()
        defaults.set(#"{"enabled":true,"inputGainDb":1,"ceilingDb":-1,"releaseMs":100}"#, forKey: "rbl.limiter.v1")
        let mock = MockPlayback()
        let limiter = LimiterModel(playback: mock, defaults: defaults)
        #expect(limiter.settings.ceilingDb == -1)
        limiter.set { $0.ceilingDb = -3.3 }
        #expect(abs(limiter.settings.ceilingDb - -3.3) < 1e-9)  // a Float round trip is not a clamp
    }

    @Test func settingTheMasterLimiterOrMixerOnThePlayerSendsNoTransport() {
        // Everything pushed at launch is a setter the engine stores: no load, play or seek.
        let rig = PlayerRig()
        for call in rig.mock.calls {
            switch call {
            case .masterLevel, .limiter, .audioConfig, .metronomeSound: break
            default: Issue.record("launch sent \(call)")
            }
        }
        #expect(rig.mock.calls.contains { if case .masterLevel = $0 { true } else { false } })
        #expect(rig.mock.calls.contains { if case .limiter = $0 { true } else { false } })
    }
}

// MARK: - Audio settings

@MainActor
@Suite(.scratchDefaults)
struct AudioSettingsTests {
    @Test func theBufferCaptionPrintsSamplesAndMilliseconds() {
        #expect(AudioSettingsModel.caption(frames: 512, sampleRate: 48_000) == "512 samples (10.7 ms)")
        #expect(AudioSettingsModel.caption(frames: 64, sampleRate: 44_100) == "64 samples (1.5 ms)")
        #expect(AudioSettingsModel.caption(frames: 2_048, sampleRate: 96_000) == "2048 samples (21.3 ms)")
        #expect(AudioSettingsModel.bufferSizes == [64, 128, 256, 512, 1_024, 2_048])
        #expect(AudioSettingsModel.sampleRates == [44_100, 48_000, 88_200, 96_000])
    }

    @Test func defaultsAreFortyEightKilohertzAnd512Frames() {
        let mock = MockPlayback()
        let audio = AudioSettingsModel(playback: mock, defaults: scratchDefaults())
        #expect(audio.sampleRate == 48_000 && audio.bufferSize == 512)
        // Pushed at launch (stored by the engine, not opened).
        #expect(mock.calls == [.audioConfig(48_000, 512)])
    }

    @Test func choicesAreTheSystemDefaultByNameThenEachDevice() async {
        let audio = AudioSettingsModel(playback: MockPlayback(), defaults: scratchDefaults())
        #expect(audio.choices.map(\.title) == ["System default"])
        await audio.refresh()
        #expect(audio.choices.map(\.title) == ["System default \u{2014} Built-in Output", "Built-in Output", "Studio Interface"])
        #expect(audio.choices.map(\.id) == [nil, "dev-1", "dev-2"])
        #expect(audio.chosen == nil)
        audio.choose(device: "dev-2")
        #expect(audio.chosen == "dev-2")
        audio.choose(device: nil)
        #expect(audio.chosen == nil)
    }

    @Test func rateAndBufferAreValidatedRememberedAndSent() {
        let defaults = scratchDefaults()
        let mock = MockPlayback()
        let audio = AudioSettingsModel(playback: mock, defaults: defaults)
        audio.setBufferSize(1_024)
        audio.setSampleRate(96_000)
        audio.setBufferSize(100)  // not a stop
        audio.setSampleRate(12_345)
        #expect(audio.bufferSize == 1_024 && audio.sampleRate == 96_000)
        #expect(mock.calls.last == .audioConfig(96_000, 1_024))
        #expect(audio.bufferCaption == "1024 samples (10.7 ms)")
        let again = AudioSettingsModel(playback: MockPlayback(), defaults: defaults)
        #expect(again.sampleRate == 96_000 && again.bufferSize == 1_024)
        defaults.set(7, forKey: "audio.bufferSize")
        #expect(AudioSettingsModel(playback: MockPlayback(), defaults: defaults).bufferSize == 512)
    }

    @Test func aDeviceChangeReloadsTheLoadedTracksWhereTheyWere() async {
        let rig = PlayerRig(layout: .two)
        rig.load(.a, track: 5)
        rig.load(.b, track: 6)
        rig.tick(.a, seconds: 12, playing: false)
        rig.tick(.b, seconds: 40, playing: false)
        rig.mock.setAutoLoad(true)
        rig.player.start()
        defer { rig.player.stop() }
        let loads = { rig.mock.calls.filter { if case .load = $0 { true } else { false } }.count }
        #expect(loads() == 2)
        rig.player.audio.choose(device: "dev-2")
        #expect(rig.mock.calls.contains(.audioDevice("dev-2")))
        // The engine reports the drop; both decks load again and then seek back.
        #expect(await eventually { loads() == 4 })
        #expect(
            await eventually { rig.mock.calls.contains(.seek(.a, 12_000)) && rig.mock.calls.contains(.seek(.b, 40_000)) },
            "\(rig.mock.calls)")
    }

    @Test func launchingAndPushingTheSavedConfigDropsNothing() async {
        let rig = PlayerRig()
        rig.player.start()
        defer { rig.player.stop() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!rig.mock.calls.contains { if case .load = $0 { true } else { false } })
    }
}

// MARK: - Sync

@MainActor
@Suite(.scratchDefaults)
struct SyncTests {
    func deck(_ bpmX100: Double, tempo: Double = 1, playing: Bool = false, position: Double = 0) -> SyncDeck {
        SyncDeck(bpmX100: bpmX100, tempo: tempo, playing: playing, position: position, grid: PlayerRig.grid(bpmX100: UInt32(bpmX100)))
    }

    @Test func theFollowersTempoIsTheRatioOfTheTwoBpmsClamped() {
        #expect(abs(SyncLogic.tempoFor(leader: deck(12_000), follower: deck(10_000)) - 1.2) < 1e-9)
        // The leader's playing tempo counts, not the BPM on its file.
        #expect(abs(SyncLogic.tempoFor(leader: deck(12_000, tempo: 1.05), follower: deck(12_000)) - 1.05) < 1e-9)
        #expect(SyncLogic.tempoFor(leader: SyncDeck(bpmX100: 0), follower: deck(12_000)) == 1)
        #expect(SyncLogic.tempoFor(leader: deck(12_000), follower: SyncDeck(bpmX100: 0)) == 1)
        #expect(SyncLogic.tempoFor(leader: deck(30_000), follower: deck(5_000), doubleHalf: false) == 2)
    }

    @Test func aDoubleOrHalfBpmCountsAsAMatch() {
        // 140 next to a 70 is a match at twice the tempo, not the track at half speed.
        #expect(abs(SyncLogic.tempoFor(leader: deck(14_000), follower: deck(7_000), doubleHalf: true) - 1) < 1e-9)
        #expect(abs(SyncLogic.tempoFor(leader: deck(7_000), follower: deck(14_000)) - 1) < 1e-9)
        #expect(abs(SyncLogic.tempoFor(leader: deck(14_000), follower: deck(7_000), doubleHalf: false) - 2) < 1e-9)
        // Close ratios are left alone.
        #expect(abs(SyncLogic.tempoFor(leader: deck(12_800), follower: deck(12_000)) - 12_800.0 / 12_000) < 1e-9)
    }

    @Test func aBarIsFoundFromTheGridAndFallsBackToTheBpm() {
        let bar = SyncLogic.barAt(deck(12_000), 2.2)!
        #expect(abs(bar.start - 0.5) < 1e-9 && abs(bar.length - 2) < 1e-9)
        let bpmOnly = SyncDeck(bpmX100: 12_000)
        let fallback = SyncLogic.barAt(bpmOnly, 5)!
        #expect(abs(fallback.length - 2) < 1e-9 && abs(fallback.start - 4) < 1e-9)
        #expect(SyncLogic.barAt(SyncDeck(bpmX100: 0), 1) == nil)
    }

    @Test func nudgesTakeTheShortestWayToTheLeadersBarAndBeat() {
        // Same bar phase: nothing to do.
        #expect(abs(SyncLogic.nudgeFor(leader: deck(12_000, position: 3.0), follower: deck(12_000, position: 1.0))) < 1e-9)
        // The follower is half a bar... a quarter bar ahead of the leader: back by half a second.
        let nudge = SyncLogic.nudgeFor(leader: deck(12_000, position: 3.0), follower: deck(12_000, position: 1.5))
        #expect(abs(nudge - -0.5) < 1e-9)
        // And by beat: a fifth of a second.
        let beat = SyncLogic.beatNudgeFor(leader: deck(12_000, position: 3.0), follower: deck(12_000, position: 1.2))
        #expect(abs(beat - -0.2) < 1e-9)
        // At most half a beat either way.
        let far = SyncLogic.beatNudgeFor(leader: deck(12_000, position: 3.0), follower: deck(12_000, position: 1.4))
        #expect(abs(far) <= 0.25 + 1e-9)
    }

    @Test func theWaitIsToTheLeadersNextBeatInRealTime() {
        #expect(abs(SyncLogic.beatWait(leader: deck(12_000, position: 3.1))! - 0.4) < 1e-9)
        // On a beat: the press was too late for it, so a whole beat.
        #expect(abs(SyncLogic.beatWait(leader: deck(12_000, position: 3.0))! - 0.5) < 1e-9)
        // A leader playing fast reaches it sooner.
        #expect(abs(SyncLogic.beatWait(leader: deck(12_000, tempo: 1.25, position: 3.1))! - 0.32) < 1e-9)
        #expect(SyncLogic.beatWait(leader: SyncDeck(bpmX100: 0)) == nil)
    }

    private func twoDecks(a: UInt32 = 12_000, b: UInt32 = 10_000) -> PlayerRig {
        let rig = PlayerRig(layout: .two)
        rig.load(.a, track: 5, bpmX100: a)
        rig.load(.b, track: 6, bpmX100: b)
        return rig
    }

    @Test func beatSyncMatchesTheTempoNowAndFollowsTheMasterWhileLit() {
        let rig = twoDecks()
        #expect(rig.player.syncMaster == .a)
        rig.tick(.b, seconds: 1.5, playing: false)
        rig.tick(.a, seconds: 3.0, playing: true, sameInstant: true)
        rig.player.beatSync(.b)
        #expect(rig.player.deckB.synced)
        #expect(abs(rig.player.deckB.tempo - 1.2) < 1e-9)
        #expect(rig.mock.calls.contains(.tempo(.b, 1.2)))
        // The bar is matched once, on the press: B (2.4 s bars at 100 BPM) is 5/12 of the way into
        // its bar and A a quarter of the way into its own, so B moves back 0.4 s.
        #expect(rig.mock.calls.contains { if case .seek(.b, let ms) = $0 { abs(ms - 1_100) < 1 } else { false } })
        // The master speeds up; the follower keeps pace.
        rig.player.deckA.setTempo(1.05)
        #expect(abs(rig.player.deckB.tempo - 1.26) < 1e-9)
        // Pressed again it lets go and stays where it was.
        rig.player.beatSync(.b)
        #expect(!rig.player.deckB.synced)
        rig.player.deckA.setTempo(1.0)
        #expect(abs(rig.player.deckB.tempo - 1.26) < 1e-9)
    }

    @Test func theMasterNeverFollowsAndChangingItClearsItsLight() {
        let rig = twoDecks()
        rig.player.beatSync(.a)
        #expect(!rig.player.deckA.synced)
        rig.player.beatSync(.b)
        #expect(rig.player.deckB.synced)
        rig.player.setSyncMaster(.b)
        #expect(rig.player.syncMaster == .b && !rig.player.deckB.synced)
        rig.player.beatSync(.a)
        #expect(rig.player.deckA.synced)
    }

    @Test func theDjsOwnTempoMoveOrResetPutsTheSyncLightOut() {
        let rig = twoDecks()
        rig.player.beatSync(.b)
        #expect(rig.player.deckB.synced)
        rig.player.deckB.nudgeTempo(steps: 1)
        #expect(!rig.player.deckB.synced)
        rig.player.beatSync(.b)
        rig.player.deckB.resetTempo()
        #expect(!rig.player.deckB.synced && rig.player.deckB.tempo == 1)
    }

    @Test func syncDoesNothingOutsideTheTwoDeckLayoutOrWithoutATrack() {
        let rig = PlayerRig(layout: .one)
        rig.load(.a)
        rig.player.beatSync(.b)
        #expect(!rig.player.deckB.synced)
        let two = PlayerRig(layout: .two)
        two.load(.a)
        two.player.beatSync(.b)  // B is empty
        #expect(!two.player.deckB.synced)
        // Leaving the layout puts the lights out.
        let both = twoDecks()
        both.player.beatSync(.b)
        both.player.layout = .one
        #expect(!both.player.deckB.synced)
    }

    @Test func playOnASyncedQuantizedDeckWaitsForTheMastersNextBeat() {
        let rig = twoDecks(a: 12_000, b: 12_000)
        rig.tick(.b, seconds: 1.12, playing: false)
        rig.tick(.a, seconds: 3.1, playing: true, sameInstant: true)
        rig.player.beatSync(.b)
        // BEAT SYNC moved B onto the leader's bar phase; move it off the beat again.
        rig.tick(.b, seconds: 1.12, playing: false, sameInstant: true)
        rig.player.togglePlay(.b)
        // B is put on its own nearest beat (1.0 s), then held 0.4 s for A's next beat.
        #expect(rig.mock.calls.contains { if case .seek(.b, let ms) = $0 { abs(ms - 1_000) < 1 } else { false } })
        let wait = rig.mock.calls.compactMap { call -> Double? in if case .playAfter(.b, let ms) = call { ms } else { nil } }
        #expect(wait.count == 1 && abs(wait[0] - 400) < 1e-6)
        #expect(!rig.mock.calls.contains(.play(.b)))
    }

    @Test func withQuantizeOffOrAStoppedMasterPlayJustPlays() {
        let rig = twoDecks(a: 12_000, b: 12_000)
        rig.tick(.a, seconds: 3.1, playing: false)
        rig.tick(.b, seconds: 1.0, playing: false)
        rig.player.beatSync(.b)
        rig.player.deckB.quantize = false
        rig.player.togglePlay(.b)
        #expect(rig.mock.calls.contains(.play(.b)))
        #expect(!rig.mock.calls.contains { if case .playAfter = $0 { true } else { false } })
    }
}

// MARK: - Per-deck meters

@MainActor
@Suite(.scratchDefaults)
struct ChannelMeterTests {
    func meters(a: Float, b: Float) -> Meters {
        Meters(rmsLeft: 0, rmsRight: 0, peakLeft: max(a, b), peakRight: max(a, b), master: 1, reduction: 0, deckAPeak: a, deckBPeak: b)
    }

    @Test func eachDeckReadsItsOwnPeakAndAStaleReadingIsSilence() {
        let rig = PlayerRig(layout: .two)
        rig.player.handle(.meters(meters(a: 0.5, b: 0.1)))
        #expect(rig.player.channelPeak(.a) == 0.5 && abs(rig.player.channelPeak(.b) - 0.1) < 1e-6)
        rig.clock.now += 0.5
        #expect(rig.player.channelPeak(.a) == 0 && rig.player.channelPeak(.b) == 0)
    }
}
