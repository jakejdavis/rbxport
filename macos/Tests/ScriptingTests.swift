import AppKit
import Foundation
import Testing

@testable import rbxport

// AppleScript (Phase 6c). The mapping layer is tested on its own; the host runs against a
// MockBackend. Nothing here sends an Apple event, opens a socket or plays a sound.

// MARK: - Mapping

struct ScriptMappingTests {
    @Test func aRatingIsZeroToFiveStars() throws {
        #expect(try ScriptMapping.trackEdit(.rating, .int(4)) == .rating(4))
        #expect(try ScriptMapping.trackEdit(.rating, .int(0)) == .rating(0))
        for bad: ScriptValue in [.int(6), .int(-1), .text("5"), .real(2.5)] {
            let error = #expect(throws: ScriptError.self) { try ScriptMapping.trackEdit(.rating, bad) }
            #expect(error?.code == ScriptError.wrongTypeCode)
            #expect(error?.message == "A rating is 0 to 5 stars.")
        }
    }

    @Test func colorsMapBothWays() throws {
        #expect(ScriptCodes.colorID(fourCC("RCno")) == 0)
        #expect(ScriptCodes.colorID(fourCC("RCpu")) == 8)
        #expect(ScriptCodes.colorID(fourCC("nope")) == nil)
        #expect(try ScriptMapping.trackEdit(.color, .enumerator(fourCC("RCrd"))) == .color(2))
        #expect(try ScriptMapping.trackEdit(.color, .enumerator(ScriptCodes.colors[0])) == .color(0))
        #expect(throws: ScriptError.self) { try ScriptMapping.trackEdit(.color, .text("red")) }
        #expect(fourCC("RKpl") == 0x524B_706C)
    }

    @Test func fieldEditsAreCheckedBeforeAnythingIsWritten() throws {
        #expect(try ScriptMapping.trackEdit(.name, .text("New")) == .field(.title, "New"))
        #expect(try ScriptMapping.trackEdit(.bpm, .real(128)) == .field(.bpm, "128.00"))
        #expect(try ScriptMapping.trackEdit(.bpm, .int(130)) == .field(.bpm, "130.00"))
        #expect(try ScriptMapping.trackEdit(.year, .int(1999)) == .field(.year, "1999"))
        #expect(try ScriptMapping.trackEdit(.playCount, .int(0)) == .field(.playCount, "0"))
        #expect(try ScriptMapping.trackEdit(.comment, .text("hi")) == .comment("hi"))
        #expect(throws: ScriptError.self) { try ScriptMapping.trackEdit(.bpm, .real(0)) }
        #expect(throws: ScriptError.self) { try ScriptMapping.trackEdit(.year, .int(-3)) }
        #expect(throws: ScriptError.self) { try ScriptMapping.trackEdit(.artist, .int(3)) }
        for key in [TrackKey.duration, .location, .id, .dateAdded, .analysed, .bitRate, .sampleRate] {
            let error = #expect(throws: ScriptError.self) { try ScriptMapping.trackEdit(key, .text("x")) }
            #expect(error?.code == ScriptError.notModifiableCode)
        }
    }

    @Test func aTrackReadsBackAsTheLibraryHoldsIt() {
        var details = MockBackend.details(track: 6)
        details.bpmX100 = 12_850
        details.color = "2"
        var row = MockBackend.row(track: 6, position: 0)
        row.dateAdded = "2026-09-24"
        func value(_ key: TrackKey) -> ScriptValue { ScriptMapping.trackValue(details: details, row: row, key: key) }
        #expect(value(.id) == .text("7"))
        #expect(value(.name) == .text("Track 006"))
        #expect(value(.bpm) == .real(128.5))
        #expect(value(.color) == .enumerator(fourCC("RCrd")))
        #expect(value(.dateAdded) == .text("2026-09-24"))
        #expect(value(.analysed) == .bool(true))
        #expect(value(.location) == .file("/mock/audio/track-7.mp3"))
        #expect(value(.bitRate) == .int(320))
        details.path = ""
        #expect(value(.location) == .missing)
        details.color = "99"
        #expect(value(.color) == .enumerator(ScriptCodes.colors[0]))
    }

    @Test func idsAreReadWhetherWrittenAsTextOrNumber() {
        #expect(ScriptMapping.canonicalID(.text(" 42 ")) == "42")
        #expect(ScriptMapping.canonicalID(.int(7)) == "7")
        #expect(ScriptMapping.canonicalID(.real(9)) == "9")
        #expect(ScriptMapping.canonicalID(.real(9.5)) == nil)
        #expect(ScriptMapping.canonicalID(.text("abc")) == nil)
        #expect(ScriptMapping.canonicalID(.int(-1)) == nil)
    }

    @Test func everyDictionaryTrackKeyParses() throws {
        let sdef = try String(contentsOf: try #require(Bundle.main.url(forResource: "rbxport", withExtension: "sdef")), encoding: .utf8)
        let track = try #require(sdef.components(separatedBy: "<class name=\"track\"").dropFirst().first?.components(separatedBy: "</class>").first)
        let keys = track.components(separatedBy: "<cocoa key=\"").dropFirst().compactMap { $0.components(separatedBy: "\"").first }
        #expect(keys.count == 19)
        for key in keys { #expect(TrackKey.parse(key) != nil, "\(key) is in the dictionary but not read") }
    }

    @Test func everyDictionaryClassAndCommandHasAnObjectiveCClass() throws {
        let sdef = try String(contentsOf: try #require(Bundle.main.url(forResource: "rbxport", withExtension: "sdef")), encoding: .utf8)
        let names = sdef.components(separatedBy: "<cocoa class=\"").dropFirst().compactMap { $0.components(separatedBy: "\"").first }
        #expect(names.count == 12)
        for name in names { #expect(NSClassFromString(name) != nil, "\(name) is named by the dictionary") }
        // The application keys are methods Cocoa finds on NSApplication.
        for key in ["rbxTracks", "rbxPlaylists", "rbxDecks", "rbxDevices", "rbxLinkPlayers", "rbxSettings", "rbxLinkExport", "rbxRekordboxRunning"] {
            #expect(NSApplication.instancesRespond(to: Selector(key)), "\(key)")
        }
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSAppleScriptEnabled") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String == "rbxport.sdef")
    }
}

struct ScriptErrorTests {
    @Test func aBackendErrorKeepsItsMessageAndGetsAScriptErrorNumber() {
        let readOnly = ScriptError(FfiError.ReadOnly(message: "rekordbox is running.", detail: nil))
        #expect(readOnly == ScriptError(code: -10_003, message: "rekordbox is running."))
        #expect(ScriptError(FfiError.NotFound(message: "gone", detail: nil)).code == -1_728)
        #expect(ScriptError(FfiError.Malformed(message: "bad", detail: nil)).code == -10_000)
        #expect(ScriptError(FfiError.Internal(message: "boom", detail: nil)).message == "boom")
        #expect(ScriptError.wrongType("x").code == -1_703)
        #expect(ScriptError.missingParameter("x").code == -1_715)
    }
}

struct ScriptPlaylistTests {
    private func node(_ id: String, _ name: String, _ kind: NodeKind, _ depth: UInt32) -> TreeNode {
        TreeNode(id: id, name: name, kind: kind, depth: depth, expanded: kind == .folder ? true : nil, childCount: nil)
    }

    @Test func playlistsComeInTreeOrderWithTheirFolders() {
        let flat = [
            node("all", "All Tracks", .allTracks, 0), node("playlists", "Playlists", .collection, 0),
            node("1", "Sets", .folder, 1), node("2", "Warm-up", .playlist, 2), node("3", "Peak", .smartPlaylist, 2),
            node("4", "Loose", .playlist, 1), node("histories", "Histories", .histories, 0), node("9", "2026", .historyFolder, 1),
        ]
        let all = ScriptPlaylists.parse(flat)
        #expect(all.map(\.id) == ["1", "2", "3", "4"])
        #expect(all.map(\.parent) == [nil, "1", "1", nil])
        #expect(all.map(\.kind) == [ScriptCodes.kindFolder, ScriptCodes.kindPlaylist, ScriptCodes.kindSmart, ScriptCodes.kindPlaylist])
        #expect(ScriptPlaylists.children(of: nil, in: all).map(\.id) == ["1", "4"])
        #expect(ScriptPlaylists.children(of: "1", in: all).map(\.id) == ["2", "3"])
    }
}

// MARK: - Settings

@MainActor
@Suite(.scratchDefaults)
struct ScriptSettingsTests {
    private func store() -> PreferencesStore { PreferencesStore(defaults: scratchDefaults()) }

    @Test func settingsAreNamedByPaneAndFieldAndLeaveOutTheKeyboard() {
        let names = ScriptSettings.names
        for name in ["view.keyDisplay", "audio.bufferSize", "djSystem.linkInterface", "advanced.protectLibrary", "usbExport.conversionFormat"] {
            #expect(names.contains(name), "\(name)")
        }
        #expect(!names.contains { $0.hasPrefix("keyboard.") })
        #expect(Set(names).count == names.count)
        // Each is the store's own key, so a script and the Settings window share one value.
        for name in names where !name.hasPrefix("djSystem.linkInterface") {
            #expect(PrefKeysIndex.all.contains(name), "\(name)")
        }
    }

    @Test func aSettingRoundTripsThroughAScriptValue() throws {
        let store = store()
        #expect(ScriptSettings.value(of: "view.keyDisplay", in: store) == .text("classic"))
        try ScriptSettings.set("view.keyDisplay", to: .text("alphanumeric"), in: store)
        #expect(store.keyDisplay == .camelot)
        #expect(ScriptSettings.value(of: "view.keyDisplay", in: store) == .text("alphanumeric"))
        try ScriptSettings.set("audio.bufferSize", to: .int(1_024), in: store)
        try ScriptSettings.set("audio.sampleRate", to: .real(44_100), in: store)
        #expect(store.bufferSize == 1_024 && store.sampleRate == 44_100)
        try ScriptSettings.set("view.playlistCounts", to: .bool(true), in: store)
        #expect(ScriptSettings.value(of: "view.playlistCounts", in: store) == .bool(true))
        try ScriptSettings.set("djSystem.linkInterface", to: .text("en5"), in: store)
        #expect(ScriptSettings.value(of: "djSystem.linkInterface", in: store) == .text("en5"))
        try ScriptSettings.set("djSystem.linkInterface", to: .missing, in: store)
        #expect(ScriptSettings.value(of: "djSystem.linkInterface", in: store) == .missing)
    }

    @Test func aValueTheChoiceWouldNotKeepIsRefusedAndChangesNothing() {
        let store = store()
        let unknown = #expect(throws: ScriptError.self) { try ScriptSettings.set("view.nope", to: .bool(true), in: store) }
        #expect(unknown?.message == "There is no setting called view.nope.")
        #expect(unknown?.code == ScriptError.failedCode)
        let keyboard = #expect(throws: ScriptError.self) { try ScriptSettings.set("keyboard.overrides", to: .text("x"), in: store) }
        #expect(keyboard?.message == "There is no setting called keyboard.overrides.")
        let bad = #expect(throws: ScriptError.self) { try ScriptSettings.set("audio.bufferSize", to: .int(100), in: store) }
        #expect(bad?.message == "audio.bufferSize cannot be set to 100.")
        let text = #expect(throws: ScriptError.self) { try ScriptSettings.set("view.keyDisplay", to: .text("hex"), in: store) }
        #expect(text?.message == "view.keyDisplay cannot be set to \"hex\".")
        #expect(throws: ScriptError.self) { try ScriptSettings.set("view.playlistCounts", to: .int(1), in: store) }
        #expect(store.bufferSize == 512 && store.keyDisplay == .classic && !store.playlistCounts)
    }

    @Test func jsonTextMatchesTheWindowsMessages() {
        #expect(ScriptText.json(.list([.text("a"), .int(2), .bool(false), .missing])) == "[\"a\",2,false,null]")
        #expect(ScriptText.json(.real(512)) == "512")
        #expect(ScriptText.json(.real(0.5)) == "0.5")
    }
}

/// Every key `PrefKeys` stores, to check settings against.
private enum PrefKeysIndex {
    static let all: Set<String> = [
        PrefKeys.keyDisplay, PrefKeys.waveformColor, PrefKeys.playlistCounts, PrefKeys.waveformClick,
        PrefKeys.sampleRate, PrefKeys.bufferSize, PrefKeys.metronomeSound, PrefKeys.analysisMode, PrefKeys.concurrentTracks,
        PrefKeys.djWaveformColor, PrefKeys.djWaveformPosition, PrefKeys.djOverview, PrefKeys.djKeyDisplay, PrefKeys.linkInterface,
        PrefKeys.autoJoinLink, PrefKeys.linkKeySort, PrefKeys.protectLibrary, PrefKeys.recordHistory, PrefKeys.quantizeBeat,
        PrefKeys.syncType, PrefKeys.syncDoubleHalf, PrefKeys.deleteUnlistedMusic, PrefKeys.maximumCompatibility,
        PrefKeys.conversionFormat, PrefKeys.importButtonCues, PrefKeys.importButtonHistory, PrefKeys.importButtonSettings,
        PrefKeys.ejectAfterSync,
    ]
}

// MARK: - The host against a mock library

@MainActor
@Suite(.scratchDefaults, .serialized)
struct ScriptHostTests {
    private func node(_ id: String, _ name: String, _ kind: NodeKind, _ depth: UInt32, open: Bool? = nil) -> TreeNode {
        TreeNode(id: id, name: name, kind: kind, depth: depth, expanded: open, childCount: 0)
    }

    private var tree: [TreeNode] {
        [
            node("all", "All Tracks", .allTracks, 0), node("playlists", "Playlists", .collection, 0),
            node("1", "Sets", .folder, 1, open: true), node("2", "Warm-up", .playlist, 2), node("4", "Loose", .playlist, 1),
        ]
    }

    private func ready(unlocked: Bool = true) async -> (ScriptHost, MockBackend, AppModel) {
        let backend = MockBackend(trackCount: 20, nodes: tree)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        if unlocked { model.protectLibrary = false }
        model.start()
        #expect(await eventually { model.opened != nil })
        await backend.setMembers(["3", "1"], of: "2")
        return (ScriptHost(model: model), backend, model)
    }

    @Test func readsComeFromTheBackend() async throws {
        let (host, _, _) = await ready()
        #expect(try host.trackIDs().count == 20)
        #expect(try host.hasTrack("5") && !host.hasTrack("99"))
        #expect(try host.trackValue("5", .name) == .text("Track 004"))
        #expect(try host.trackValue("5", .id) == .text("5"))
        #expect(try host.trackValue("99", .name) == nil)
        #expect(try host.allPlaylistIDs() == ["1", "2", "4"])
        #expect(try host.childIDs(of: "1") == ["2"])
        #expect(try host.playlistTrackIDs("2") == ["3", "1"])
        #expect(try host.playlistTrackIDs("1") == [], "a folder has no tracks of its own")
        #expect(try host.playlist("2")?.parent == "1")
    }

    @Test func aSetGoesThroughTheGateAndIsReadBack() async throws {
        let (host, backend, _) = await ready()
        try host.setTrack("3", .rating, to: .int(5))
        try host.setTrack("3", .comment, to: .text("great"))
        try host.setTrack("3", .color, to: .enumerator(fourCC("RCbl")))
        try host.setTrack("3", .name, to: .text("Renamed"))
        #expect(try host.trackValue("3", .rating) == .int(5))
        #expect(try host.trackValue("3", .comment) == .text("great"))
        #expect(try host.trackValue("3", .color) == .enumerator(fourCC("RCbl")))
        #expect(try host.trackValue("3", .name) == .text("Renamed"))
        let log = await backend.editLog
        #expect(log.count == 4)
    }

    @Test func libraryProtectionRefusesAsNotModifiable() async throws {
        let (host, backend, _) = await ready(unlocked: false)
        let error = #expect(throws: ScriptError.self) { try host.setTrack("3", .rating, to: .int(5)) }
        #expect(error?.code == ScriptError.notModifiableCode)
        #expect(error?.message == MockBackend.protectedMessage)
        #expect(try host.trackValue("3", .rating) != .int(5))
        _ = backend
        // A value the dictionary refuses never reaches the gate.
        let wrong = #expect(throws: ScriptError.self) { try host.setTrack("3", .rating, to: .int(9)) }
        #expect(wrong?.code == ScriptError.wrongTypeCode)
    }

    @Test func aMissingTrackIsNoSuchObject() async throws {
        let (host, _, _) = await ready()
        let error = #expect(throws: ScriptError.self) { try host.setTrack("999", .rating, to: .int(2)) }
        #expect(error?.code == ScriptError.noSuchObjectCode)
    }

    @Test func playlistsAreMadeRenamedMovedAndDeleted() async throws {
        let (host, backend, _) = await ready()
        let made = try host.createPlaylist(name: "Fresh", kind: ScriptCodes.kindPlaylist, parent: "root", at: nil)
        #expect(await backend.currentNodes.contains { $0.id == made && $0.name == "Fresh" })
        let folder = try host.createPlaylist(name: nil, kind: ScriptCodes.kindFolder, parent: "root", at: nil)
        #expect(await backend.currentNodes.first { $0.id == folder }?.name == "New folder")
        let smart = #expect(throws: ScriptError.self) {
            try host.createPlaylist(name: "S", kind: ScriptCodes.kindSmart, parent: "root", at: nil)
        }
        #expect(smart?.code == ScriptError.failedCode)
        try host.renamePlaylist(made, to: "Renamed")
        #expect(try host.playlist(made)?.name == "Renamed")
        try host.movePlaylist(made, into: "1", at: nil)
        #expect(try host.playlist(made)?.parent == "1")
        try host.deletePlaylist(made)
        #expect(try host.playlist(made) == nil)
    }

    @Test func addAndRemoveRunThroughTheBackend() async throws {
        let (host, backend, _) = await ready()
        try host.requireRegularPlaylist("4")
        let folder = #expect(throws: ScriptError.self) { try host.requireRegularPlaylist("1") }
        #expect(folder?.message == "Tracks can only be added to or removed from a regular playlist.")
        try await host.addTracks(["5", "6"], to: "4")
        #expect(await backend.members(of: "4") == ["5", "6"])
        try await host.removeTracks(["5"], from: "4")
        #expect(await backend.members(of: "4") == ["6"])
    }

    @Test func addIsRefusedUnderProtection() async throws {
        let (host, _, _) = await ready(unlocked: false)
        do {
            try await host.addTracks(["5"], to: "4")
            Issue.record("expected a refusal")
        } catch let error as ScriptError {
            #expect(error.code == ScriptError.notModifiableCode)
        }
    }

    @Test func settingsSetThroughTheHostReachTheStoreAndTheGate() async throws {
        let (host, backend, model) = await ready(unlocked: false)
        #expect(host.settingValue("advanced.protectLibrary") == .bool(true))
        try host.setSetting("advanced.protectLibrary", to: .bool(false))
        #expect(!model.protectLibrary)
        #expect(await backend.protectCalls.last == false)
        let error = #expect(throws: ScriptError.self) { try host.setSetting("view.zzz", to: .bool(true)) }
        #expect(error?.code == ScriptError.failedCode)
    }

    @Test func playAndPauseNeedALoadedDeck() async throws {
        let (host, _, model) = await ready()
        let none = #expect(throws: ScriptError.self) { try host.setPlaying(deck: 1, true) }
        #expect(none?.message == "Deck 1 has no track loaded.")
        try await host.load(track: "3", onDeck: 1)
        #expect(host.reading(ofDeck: 1).currentTrack == "3")
        #expect(host.reading(ofDeck: 2).currentTrack == nil)
        try host.setPlaying(deck: 1, true)
        #expect(host.reading(ofDeck: 1).playing)
        try host.setPlaying(deck: 1, true)
        #expect(host.reading(ofDeck: 1).playing, "playing a playing deck does nothing")
        try host.setPlaying(deck: 1, false)
        #expect(!host.reading(ofDeck: 1).playing)
        #expect(host.reading(ofDeck: 1).duration == 200)
        #expect(model.player.deckA.isLoaded)
    }

    @Test func loadingOnADeckThatIsNotInTheLayoutIsRefused() async throws {
        let (host, _, model) = await ready()
        model.player.layout = .one
        do {
            try await host.load(track: "3", onDeck: 2)
            Issue.record("expected a refusal")
        } catch let error as ScriptError {
            #expect(error.message == "Deck 2 is not in this layout. Choose a layout with 2 players from the View menu.")
        }
        do {
            try await host.load(track: "999", onDeck: 1)
            Issue.record("expected a refusal")
        } catch let error as ScriptError {
            #expect(error.code == ScriptError.noSuchObjectCode)
        }
    }

    @Test func rekordboxRunningIsAskedOfTheSystem() async {
        let (host, _, _) = await ready()
        host.rekordboxRunning = { true }
        #expect(host.rekordboxRunning())
    }

    @Test func exportToAnUnknownDeviceIsRefused() async {
        let (host, _, _) = await ready()
        do {
            _ = try await host.export(playlist: "2", devicePath: "/Volumes/NOPE")
            Issue.record("expected a refusal")
        } catch let error as ScriptError {
            #expect(error.code == ScriptError.noSuchObjectCode)
        } catch {
            Issue.record("wrong error")
        }
    }
}

// MARK: - The Cocoa objects

@MainActor
@Suite(.scratchDefaults, .serialized)
struct ScriptingObjectsTests {
    private func install() async -> (ScriptHost, MockBackend) {
        let backend = MockBackend(trackCount: 12)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.protectLibrary = false
        model.start()
        _ = await eventually { model.opened != nil }
        let host = ScriptHost(model: model)
        ScriptHost.current = host
        return (host, backend)
    }

    @Test func aTrackAnswersTheDictionarysKeysThroughKVC() async throws {
        let (_, _) = await install()
        defer { ScriptHost.current = nil }
        let track = RbxTrack(id: "4")
        #expect(track.value(forKey: "name") as? String == "Track 003")
        #expect(track.value(forKey: "uniqueID") as? String == "4")
        #expect((track.value(forKey: "rbxBpm") as? NSNumber)?.doubleValue == 120.03)
        #expect((track.value(forKey: "rbxYear") as? NSNumber)?.intValue == 2020)
        #expect((track.value(forKey: "rbxColor") as? NSNumber)?.uint32Value == fourCC("RCno"))
        #expect((track.value(forKey: "rbxLocation") as? URL)?.path == "/mock/audio/track-4.mp3")
        #expect(RbxTrack(id: "400").value(forKey: "name") == nil, "a track that has gone is missing value")
    }

    @Test func aSetterWritesThroughTheHost() async throws {
        let (host, backend) = await install()
        defer { ScriptHost.current = nil }
        let track = RbxTrack(id: "4")
        track.setValue(NSNumber(value: 4), forKey: "rbxRating")
        #expect(try host.trackValue("4", .rating) == .int(4))
        // A colour arrives as its four-character code in a plain number.
        track.setValue(NSNumber(value: fourCC("RCgn")), forKey: "rbxColor")
        #expect(try host.trackValue("4", .color) == .enumerator(fourCC("RCgn")))
        #expect(await backend.editLog.count == 2)
    }

    @Test func applicationKeysListTheLibrary() async throws {
        let (_, _) = await install()
        defer { ScriptHost.current = nil }
        let app = NSApplication.shared
        #expect(app.rbxTracks.count == 12)
        #expect(app.rbxDecks.count == 2)
        #expect((app.rbxTracks.firstObject as? RbxTrack)?.id == "1")
        #expect(app.valueInRbxTracks(withUniqueID: "5" as NSString) is RbxTrack)
        #expect(app.valueInRbxTracks(withUniqueID: NSNumber(value: 5)) is RbxTrack)
        #expect(app.valueInRbxTracks(withUniqueID: "500" as NSString) == nil)
        #expect(app.rbxPlaylists.count == 2)
        #expect(app.rbxSettings.count == ScriptSettings.names.count)
        #expect(app.rbxLinkPlayers.count == 0)
        #expect(app.rbxLinkExport == false)
    }

    @Test func aSettingHandsBackADescriptorAndTakesAValue() async throws {
        let (host, _) = await install()
        defer { ScriptHost.current = nil }
        let setting = RbxSetting(name: "audio.bufferSize")
        let descriptor = try #require(setting.value(forKey: "rbxValue") as? NSAppleEventDescriptor)
        #expect(descriptor.int32Value == 512)
        setting.setValue(NSAppleEventDescriptor(int32: 256), forKey: "rbxValue")
        #expect(host.settingValue("audio.bufferSize") == .int(256))
        #expect(RbxSetting(name: "djSystem.linkInterface").value(forKey: "rbxValue") is NSAppleEventDescriptor)
    }

    @Test func valuesConvertBothWays() {
        #expect(ScriptingValues.value(NSNumber(value: true)) == .bool(true))
        #expect(ScriptingValues.value(NSNumber(value: 3)) == .int(3))
        #expect(ScriptingValues.value(NSNumber(value: 3.5)) == .real(3.5))
        #expect(ScriptingValues.value("x" as NSString) == .text("x"))
        #expect(ScriptingValues.value(["a", "b"] as NSArray) == .list([.text("a"), .text("b")]))
        #expect(ScriptingValues.value(nil) == .missing)
        let list = ScriptingValues.descriptor(.list([.bool(true), .int(2), .text("t"), .missing]))
        #expect(list.numberOfItems == 4)
        #expect(ScriptingValues.value(list) == .list([.bool(true), .int(2), .text("t"), .missing]))
        #expect(ScriptingValues.value(ScriptingValues.descriptor(.real(1.5))) == .real(1.5))
    }
}
