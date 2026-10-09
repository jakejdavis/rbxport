import Foundation
import Testing

@testable import rbxport

@MainActor
@Suite(.scratchDefaults)
struct PreferencesStoreTests {
    private func store(_ defaults: UserDefaults? = nil) -> (PreferencesStore, UserDefaults) {
        let d = defaults ?? scratchDefaults(prefix: "rbxport-prefs")
        return (PreferencesStore(defaults: d), d)
    }

    // MARK: Defaults and sanitising

    @Test func anEmptyStoreHasReactsDefaults() {
        let (s, d) = store()
        #expect(s.keyDisplay == .classic && s.waveformColor == .bands && !s.playlistCounts && s.waveformClick)
        #expect(s.sampleRate == 48_000 && s.bufferSize == 512 && s.metronomeSound == 2)
        #expect(s.analysisMode == .rbxport && s.concurrentTracks == 3)
        #expect(s.djWaveformColor == .threeBand && s.djWaveformPosition == .center && s.djOverview == .half && s.djKeyDisplay == .classic)
        #expect(s.linkInterface == nil && !s.autoJoinLink && s.linkKeySort == .musical)
        #expect(s.protectLibrary && s.recordHistory && s.quantizeBeat == .whole && s.syncType == .beat && s.syncDoubleHalf)
        #expect(!s.deleteUnlistedMusic && !s.maximumCompatibility && s.conversionFormat == .wav)
        #expect(s.importButtonCues && s.importButtonHistory && !s.importButtonSettings)
        #expect(s.keyboardOverrides.isEmpty)
        // Reading writes nothing.
        #expect(d.object(forKey: PrefKeys.keyDisplay) == nil && d.object(forKey: PrefKeys.protectLibrary) == nil)
    }

    @Test func aBadStoredValueComesBackAsTheDefault() {
        let d = scratchDefaults(prefix: "rbxport-prefs")
        d.set("sideways", forKey: PrefKeys.keyDisplay)
        d.set(12345, forKey: PrefKeys.sampleRate)
        d.set(100, forKey: PrefKeys.bufferSize)
        d.set(9, forKey: PrefKeys.concurrentTracks)
        d.set("yes", forKey: PrefKeys.protectLibrary)
        d.set("1/3", forKey: PrefKeys.quantizeBeat)
        d.set("flac", forKey: PrefKeys.conversionFormat)
        d.set("", forKey: PrefKeys.linkInterface)
        d.set("{not json", forKey: PrefKeys.keyboardOverrides)
        let (s, _) = store(d)
        #expect(s.keyDisplay == .classic && s.sampleRate == 48_000 && s.bufferSize == 512 && s.concurrentTracks == 3)
        #expect(s.protectLibrary)
        #expect(s.quantizeBeat == .whole && s.conversionFormat == .wav && s.linkInterface == nil)
        #expect(s.keyboardOverrides.isEmpty)
    }

    @Test func goodStoredValuesAreKept() {
        let d = scratchDefaults(prefix: "rbxport-prefs")
        d.set("alphanumeric", forKey: PrefKeys.keyDisplay)
        d.set("rgb", forKey: PrefKeys.waveformColor)
        d.set(96_000, forKey: PrefKeys.sampleRate)
        d.set(1_024, forKey: PrefKeys.bufferSize)
        d.set("en7", forKey: PrefKeys.linkInterface)
        d.set(false, forKey: PrefKeys.protectLibrary)
        let (s, _) = store(d)
        #expect(s.keyDisplay == .camelot && s.waveformColor == .colour && s.sampleRate == 96_000 && s.bufferSize == 1_024)
        #expect(s.linkInterface == "en7" && !s.protectLibrary)
    }

    @Test func keyboardOverridesAreSanitisedLikeReact() {
        let json = """
            {"playPause":{"key":"p","metaKey":true},"mute":{"key":"x","shiftKey":"yes"},"long":{"key":"\(String(repeating: "k", count: 40))"},"bad":3,"gone":{"key":""}}
            """
        let d = scratchDefaults(prefix: "rbxport-prefs")
        d.set(json, forKey: PrefKeys.keyboardOverrides)
        let (s, _) = store(d)
        #expect(s.keyboardOverrides["playPause"] == Chord("p", command: true))
        // A non-boolean modifier is false; an over-long key and a non-object are dropped; an empty key is an unbound row.
        #expect(s.keyboardOverrides["mute"] == Chord("x"))
        #expect(s.keyboardOverrides["long"] == nil && s.keyboardOverrides["bad"] == nil)
        #expect(s.keyboardOverrides["gone"] == .unbound)
    }

    // MARK: Migration of the names earlier phases stored

    @Test func oldNamesMoveToReactsNamesWithoutDeletingTheOldOnes() {
        let d = scratchDefaults(prefix: "rbxport-prefs")
        d.set("camelot", forKey: PrefKeys.Legacy.keyStyle)
        d.set("mono", forKey: PrefKeys.Legacy.waveformPalette)
        d.set(true, forKey: PrefKeys.Legacy.childCounts)
        d.set(false, forKey: PrefKeys.Legacy.waveformClick)
        d.set(false, forKey: PrefKeys.Legacy.protectLibrary)
        d.set(false, forKey: PrefKeys.Legacy.recordHistory)
        d.set(2, forKey: PrefKeys.Legacy.slots)
        d.set(3, forKey: PrefKeys.Legacy.metronomeSound)
        let (s, _) = store(d)
        #expect(s.keyDisplay == .camelot && s.waveformColor == .mono && s.playlistCounts && !s.waveformClick)
        #expect(!s.protectLibrary && !s.recordHistory && s.concurrentTracks == 2 && s.metronomeSound == 3)
        // React's names now hold them...
        #expect(d.string(forKey: PrefKeys.keyDisplay) == "alphanumeric")
        #expect(d.string(forKey: PrefKeys.waveformColor) == "blue")
        #expect(d.object(forKey: PrefKeys.concurrentTracks) as? Int == 2)
        // ...and the old ones are still there.
        #expect(d.string(forKey: PrefKeys.Legacy.keyStyle) == "camelot")
        #expect(d.object(forKey: PrefKeys.Legacy.slots) as? Int == 2)
    }

    @Test func aReactNameWinsOverAnOldOne() {
        let d = scratchDefaults(prefix: "rbxport-prefs")
        d.set("camelot", forKey: PrefKeys.Legacy.keyStyle)
        d.set("classic", forKey: PrefKeys.keyDisplay)
        d.set(true, forKey: PrefKeys.Legacy.protectLibrary)
        d.set(false, forKey: PrefKeys.protectLibrary)
        let (s, _) = store(d)
        #expect(s.keyDisplay == .classic && !s.protectLibrary)
    }

    @Test func migrationRunsOnceAndLaterChangesStickToTheNewNames() {
        let d = scratchDefaults(prefix: "rbxport-prefs")
        d.set("camelot", forKey: PrefKeys.Legacy.keyStyle)
        let (first, _) = store(d)
        first.keyDisplay = .classic
        let (second, _) = store(d)
        #expect(second.keyDisplay == .classic)
    }

    @Test func theModelsFollowTheMigratedValues() {
        let d = scratchDefaults(prefix: "rbxport-prefs")
        d.set("colour", forKey: PrefKeys.Legacy.waveformPalette)
        d.set("camelot", forKey: PrefKeys.Legacy.keyStyle)
        d.set(true, forKey: PrefKeys.Legacy.childCounts)
        let model = AppModel(backend: MockBackend(trackCount: 0), layoutStore: ColumnLayoutStore(defaults: d))
        #expect(model.waveformPalette == .colour && model.keyStyle == .camelot && model.sidebar.showChildCounts)
    }

    // MARK: Writing

    @Test func everySettingWritesReactsKey() {
        struct Case {
            let key: String
            let set: (PreferencesStore) -> Void
            let expect: (UserDefaults) -> Bool
        }
        let cases: [Case] = [
            Case(key: PrefKeys.keyDisplay, set: { $0.keyDisplay = .camelot }, expect: { $0.string(forKey: PrefKeys.keyDisplay) == "alphanumeric" }),
            Case(key: PrefKeys.waveformColor, set: { $0.waveformColor = .colour }, expect: { $0.string(forKey: PrefKeys.waveformColor) == "rgb" }),
            Case(key: PrefKeys.playlistCounts, set: { $0.playlistCounts = true }, expect: { $0.bool(forKey: PrefKeys.playlistCounts) }),
            Case(key: PrefKeys.waveformClick, set: { $0.waveformClick = false }, expect: { $0.object(forKey: PrefKeys.waveformClick) as? Bool == false }),
            Case(key: PrefKeys.rowSize, set: { $0.rowSize = .large }, expect: { $0.string(forKey: PrefKeys.rowSize) == "large" }),
            Case(key: PrefKeys.sampleRate, set: { $0.sampleRate = 96_000 }, expect: { $0.integer(forKey: PrefKeys.sampleRate) == 96_000 }),
            Case(key: PrefKeys.bufferSize, set: { $0.bufferSize = 128 }, expect: { $0.integer(forKey: PrefKeys.bufferSize) == 128 }),
            Case(key: PrefKeys.metronomeSound, set: { $0.metronomeSound = 3 }, expect: { $0.integer(forKey: PrefKeys.metronomeSound) == 3 }),
            Case(key: PrefKeys.analysisMode, set: { $0.analysisMode = .rekordbox }, expect: { $0.string(forKey: PrefKeys.analysisMode) == "rekordbox" }),
            Case(key: PrefKeys.concurrentTracks, set: { $0.concurrentTracks = 4 }, expect: { $0.integer(forKey: PrefKeys.concurrentTracks) == 4 }),
            Case(key: PrefKeys.djWaveformColor, set: { $0.djWaveformColor = .threeBand; $0.djWaveformColor = .blue }, expect: { $0.string(forKey: PrefKeys.djWaveformColor) == "blue" }),
            Case(key: PrefKeys.djWaveformPosition, set: { $0.djWaveformPosition = .left }, expect: { $0.string(forKey: PrefKeys.djWaveformPosition) == "left" }),
            Case(key: PrefKeys.djOverview, set: { $0.djOverview = .full }, expect: { $0.string(forKey: PrefKeys.djOverview) == "full" }),
            Case(key: PrefKeys.djKeyDisplay, set: { $0.djKeyDisplay = .alphanumeric }, expect: { $0.string(forKey: PrefKeys.djKeyDisplay) == "alphanumeric" }),
            Case(key: PrefKeys.linkInterface, set: { $0.linkInterface = "en0" }, expect: { $0.string(forKey: PrefKeys.linkInterface) == "en0" }),
            Case(key: PrefKeys.autoJoinLink, set: { $0.autoJoinLink = true }, expect: { $0.bool(forKey: PrefKeys.autoJoinLink) }),
            Case(key: PrefKeys.linkKeySort, set: { $0.linkKeySort = .alphabetical }, expect: { $0.string(forKey: PrefKeys.linkKeySort) == "alphabetical" }),
            Case(key: PrefKeys.protectLibrary, set: { $0.protectLibrary = false }, expect: { $0.object(forKey: PrefKeys.protectLibrary) as? Bool == false }),
            Case(key: PrefKeys.recordHistory, set: { $0.recordHistory = false }, expect: { $0.object(forKey: PrefKeys.recordHistory) as? Bool == false }),
            Case(key: PrefKeys.quantizeBeat, set: { $0.quantizeBeat = .eighth }, expect: { $0.string(forKey: PrefKeys.quantizeBeat) == "1/8" }),
            Case(key: PrefKeys.syncType, set: { $0.syncType = .bpm }, expect: { $0.string(forKey: PrefKeys.syncType) == "bpm" }),
            Case(key: PrefKeys.syncDoubleHalf, set: { $0.syncDoubleHalf = false }, expect: { $0.object(forKey: PrefKeys.syncDoubleHalf) as? Bool == false }),
            Case(key: PrefKeys.deleteUnlistedMusic, set: { $0.deleteUnlistedMusic = true }, expect: { $0.bool(forKey: PrefKeys.deleteUnlistedMusic) }),
            Case(key: PrefKeys.maximumCompatibility, set: { $0.maximumCompatibility = true }, expect: { $0.bool(forKey: PrefKeys.maximumCompatibility) }),
            Case(key: PrefKeys.conversionFormat, set: { $0.conversionFormat = .mp3 }, expect: { $0.string(forKey: PrefKeys.conversionFormat) == "mp3" }),
            Case(key: PrefKeys.importButtonCues, set: { $0.importButtonCues = false }, expect: { $0.object(forKey: PrefKeys.importButtonCues) as? Bool == false }),
            Case(key: PrefKeys.importButtonHistory, set: { $0.importButtonHistory = false }, expect: { $0.object(forKey: PrefKeys.importButtonHistory) as? Bool == false }),
            Case(key: PrefKeys.importButtonSettings, set: { $0.importButtonSettings = true }, expect: { $0.bool(forKey: PrefKeys.importButtonSettings) }),
            Case(key: PrefKeys.ejectAfterSync, set: { $0.ejectAfterSync = true }, expect: { $0.bool(forKey: PrefKeys.ejectAfterSync) }),
        ]
        for c in cases {
            let (s, d) = store()
            var heard: [String] = []
            s.onChange { heard.append($0) }
            c.set(s)
            #expect(c.expect(d), "\(c.key) was not written")
            #expect(heard.contains(c.key), "\(c.key) was not announced")
            // And a new store reads it back.
            #expect(c.expect(PreferencesStore(defaults: d).defaults))
        }
    }

    @Test func settingAValueToWhatItAlreadyIsWritesNothing() {
        let (s, d) = store()
        var heard = 0
        s.onChange { _ in heard += 1 }
        s.keyDisplay = .classic
        s.sampleRate = 48_000
        #expect(heard == 0 && d.object(forKey: PrefKeys.keyDisplay) == nil)
    }

    @Test func resetPutsAPanesDefaultsBack() {
        let (s, d) = store()
        s.keyDisplay = .camelot
        s.playlistCounts = true
        s.sampleRate = 96_000
        s.protectLibrary = false
        s.quantizeBeat = .quarter
        s.deleteUnlistedMusic = true
        s.autoJoinLink = true
        s.keyboardOverrides = ["playPause": Chord("p")]
        s.reset(.view)
        #expect(s.keyDisplay == .classic && !s.playlistCounts && s.sampleRate == 96_000)
        s.reset(.audio)
        #expect(s.sampleRate == 48_000)
        s.reset(.advanced)
        #expect(s.protectLibrary && s.quantizeBeat == .whole)
        #expect(d.object(forKey: PrefKeys.protectLibrary) as? Bool == true)
        s.reset(.usbExport)
        #expect(!s.deleteUnlistedMusic)
        s.reset(.djSystem)
        #expect(!s.autoJoinLink)
        s.reset(.keyboard)
        #expect(s.keyboardOverrides.isEmpty && d.object(forKey: PrefKeys.keyboardOverrides) == nil)
        #expect(s.keymap.chord(for: "playPause") == Chord(" "))
    }

    // MARK: The panes' other homes

    @Test func theModelsWriteTheSameNamesThePanesDo() async {
        let d = scratchDefaults(prefix: "rbxport-prefs")
        let model = AppModel(backend: MockBackend(trackCount: 0), layoutStore: ColumnLayoutStore(defaults: d))
        model.keyStyle = .camelot
        model.rowSize = .compact
        model.waveformPalette = .mono
        model.protectLibrary = false
        model.sidebar.showChildCounts = true
        model.analysis.slots = 4
        model.player.audio.setSampleRate(44_100)
        model.player.audio.setBufferSize(256)
        model.player.deckA.waveformClick = false
        model.link.autoJoin = true
        model.link.keySort = .alphabetical
        model.exportPrefs.maximumCompatibility = true
        model.exportPrefs.conversionFormat = .aiff
        model.exportPrefs.importButtonSettings = true
        #expect(d.string(forKey: PrefKeys.keyDisplay) == "alphanumeric")
        #expect(d.string(forKey: PrefKeys.rowSize) == "compact")
        #expect(d.string(forKey: PrefKeys.waveformColor) == "blue")
        #expect(d.object(forKey: PrefKeys.protectLibrary) as? Bool == false)
        #expect(d.bool(forKey: PrefKeys.playlistCounts))
        #expect(d.integer(forKey: PrefKeys.concurrentTracks) == 4)
        #expect(d.integer(forKey: PrefKeys.sampleRate) == 44_100 && d.integer(forKey: PrefKeys.bufferSize) == 256)
        #expect(d.object(forKey: PrefKeys.waveformClick) as? Bool == false)
        #expect(d.bool(forKey: PrefKeys.autoJoinLink) && d.string(forKey: PrefKeys.linkKeySort) == "alphabetical")
        #expect(d.bool(forKey: PrefKeys.maximumCompatibility) && d.string(forKey: PrefKeys.conversionFormat) == "aiff")
        #expect(d.bool(forKey: PrefKeys.importButtonSettings))
    }

    @Test func aChangeInSettingsReachesTheModelsThatActOnIt() {
        let model = AppModel(backend: MockBackend(trackCount: 0), layoutStore: isolatedStore())
        model.prefs.concurrentTracks = 1
        #expect(model.analysis.slots == 1)
        model.prefs.playlistCounts = true
        #expect(model.sidebar.showChildCounts)
        model.prefs.sampleRate = 96_000
        #expect(model.player.audio.sampleRate == 96_000)
        model.prefs.metronomeSound = 3
        #expect(model.player.metronomeSound == 3)
        model.prefs.analysisMode = .rekordbox
        #expect(model.analysis.rekordboxMode)
        // Reset on the Audio pane takes the engine back too.
        model.prefs.reset(.audio)
        #expect(model.player.audio.sampleRate == 48_000 && model.player.metronomeSound == 2)
    }

    @Test func quantizeAndSyncPreferencesReachTheDecks() {
        let model = AppModel(backend: MockBackend(trackCount: 0), layoutStore: isolatedStore())
        let deck = model.player.deckA
        #expect(deck.prefs === model.prefs)
        model.prefs.quantizeBeat = .quarter
        #expect(QuantizeBeat.quarter.divisions == 4)
        model.prefs.recordHistory = false
        #expect(!deck.recordsHistory)
    }
}
