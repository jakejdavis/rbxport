import AppKit
import Foundation
import Testing

@testable import rbxport

@MainActor
@Suite(.scratchDefaults)
struct KeymapTests {
    private func store() -> PreferencesStore { PreferencesStore(defaults: scratchDefaults(prefix: "rbxport-keys")) }

    private func resolve(
        _ chord: Chord, _ map: Keymap = Keymap(), up: Bool = false, typing: Bool = false, two: Bool = true, loaded: Bool = true
    ) -> KeyEffect? {
        // Rebuild an event description the monitor would see.
        var mods: NSEvent.ModifierFlags = []
        if chord.command { mods.insert(.command) }
        if chord.shift { mods.insert(.shift) }
        if chord.option { mods.insert(.option) }
        let named: [String: UInt16] = [" ": 49, "ArrowLeft": 123, "Enter": 36, "F9": 101, "F12": 111]
        let raw = KeyChord(character: named[chord.key] == nil ? chord.key : "", keyCode: named[chord.key] ?? 0, modifiers: mods)
        return PlayerKeymap.resolve(
            raw, isUp: up, isRepeat: false, typing: typing, loaded: { _ in loaded }, twoDecks: two, keymap: map)
    }

    // MARK: The table

    @Test func noTwoBindingsShareAKeyWhereTheyCouldBothAct() {
        let clashes = Keymap.duplicates().map { "\($0.0.id) / \($0.1.id)" }
        #expect(clashes.isEmpty, Comment(rawValue: "\(clashes)"))
        #expect(Set(BindingTable.all.map(\.id)).count == BindingTable.all.count)
    }

    @Test func everyKeyHasExactlyOneOwner() {
        // For every chord, the live bindings in one scope belong to one owner: the monitor, the
        // table, a menu or the system never compete for the same key.
        var owners: [Chord: [KeyOwner]] = [:]
        for b in BindingTable.all where !b.chord.isUnbound && b.scope == .global { owners[b.chord, default: []].append(b.owner) }
        #expect(owners.values.allSatisfy { $0.count == 1 })
        #expect(BindingTable.byID["menu.info"]?.owner == .menu && BindingTable.byID["playPause"]?.owner == .deck)
    }

    @Test func menuKeysAlwaysCarryCommandOrControl() {
        for b in BindingTable.all where b.owner == .menu { #expect(b.chord.command || b.chord.control, "\(b.id)") }
    }

    @Test func theDeckRowsFollowReactsPreset() {
        let map = Keymap()
        #expect(map.chord(for: "playPause") == Chord(" "))
        #expect(map.chord(for: "b.playPause") == Chord(" ", shift: true))
        #expect(map.chord(for: "clearHotCueA") == Chord("1", command: true))
        #expect(map.chord(for: "b.clearHotCueA").isUnbound)
        #expect(map.chord(for: "b.metronomeSound").isUnbound && BindingTable.byID["b.metronomeSound"] == nil)
        #expect(map.chord(for: "eqKillLow").isUnbound && map.chord(for: "hotCueD").isUnbound)
    }

    // MARK: Events to chords

    @Test func eventsBecomeChordsWithShiftUndone() {
        func chord(_ c: String, _ code: UInt16 = 0, _ m: NSEvent.ModifierFlags = []) -> Chord { Chord(KeyChord(character: c, keyCode: code, modifiers: m)) }
        #expect(chord("!", 0, .shift) == Chord("1", shift: true))
        #expect(chord("q") == Chord("q"))
        #expect(chord("", 49) == Chord(" "))
        #expect(chord("\u{F702}", 123, .command) == Chord("ArrowLeft", command: true))
        #expect(chord("\\", 0, .option) == Chord("\\", option: true))
    }

    // MARK: Dispatch

    @Test func theDispatcherReadsTheTable() {
        #expect(resolve(Chord("q")) == .deck(.a, .quantize))
        #expect(resolve(Chord("q", shift: true)) == .deck(.b, .quantize))
        #expect(resolve(Chord("q", shift: true), two: false) == nil)
        #expect(resolve(Chord("F9")) == .deck(.a, .metronomeSound))
        #expect(resolve(Chord("F12", command: true)) == .master(.volumeUp))
    }

    @Test func overridesMoveAKey() {
        let map = Keymap(overrides: ["quantize": Chord("w"), "b.quantize": .unbound])
        #expect(resolve(Chord("w"), map) == .deck(.a, .quantize))
        #expect(resolve(Chord("q"), map) == nil)
        #expect(resolve(Chord("q", shift: true), map) == nil)
    }

    @Test func textFieldsKeepTheirKeys() {
        #expect(resolve(Chord("q"), typing: true) == nil)
        #expect(resolve(Chord(" "), typing: true) == nil)
        #expect(resolve(Chord("F12", command: true), typing: true) == nil)
        // A held CUE or pad is still let go.
        #expect(resolve(Chord("c"), up: true, typing: true) == .deck(.a, .cueUp))
        #expect(resolve(Chord("1"), up: true, typing: true) == .deck(.a, .hotCueUp))
    }

    @Test func unboundRowsMatchNothing() {
        #expect(resolve(.unbound) == nil)
        #expect(Keymap().binding(for: .unbound, owner: .deck) == nil)
    }

    // MARK: Conflicts and rebinding

    @Test func conflictsNameWhoHasTheKey() {
        let map = Keymap()
        #expect(map.conflicts(assigning: Chord("i", command: true), to: "playPause").map(\.id) == ["menu.info"])
        #expect(map.conflicts(assigning: Chord("z"), to: "playPause").isEmpty)
        // Browse keys of a table do not clash with the sidebar's.
        #expect(map.conflicts(assigning: Chord("Enter"), to: "rename").isEmpty)
    }

    @Test func assigningTakesTheKeyFromTheOldHolderAndPresetClearsTheOverride() {
        let map = Keymap()
        let next = map.assigning(Chord("q"), to: "cue")!
        #expect(next["cue"] == Chord("q") && next["quantize"] == .unbound)
        let again = Keymap(overrides: next).assigning(Chord("c"), to: "cue")!
        #expect(again["cue"] == nil)
        #expect(again["quantize"] == .unbound)
    }

    @Test func reservedBuiltInAndMenuKeysAreRefused() {
        let map = Keymap()
        #expect(map.issue(assigning: Chord("q", command: true), to: "playPause") == .reserved)
        #expect(map.issue(assigning: Chord("j"), to: "menu.info") == .menuNeedsModifier)
        #expect(map.issue(assigning: Chord("j", command: true), to: "menu.info") == nil)
        #expect(map.issue(assigning: Chord("j"), to: "moveUp") == .notRebindable)
        #expect(map.issue(assigning: Chord("j"), to: "toTop.arrow") == .notRebindable)
        #expect(map.assigning(Chord("j"), to: "menu.info") == nil)
    }

    @Test func aMenuShortcutFollowsItsOverride() {
        #expect(Keymap().shortcut(for: .showInformation)?.key == "i")
        let moved = Keymap(overrides: ["menu.info": Chord("j", command: true, shift: true)])
        #expect(moved.shortcut(for: .showInformation)?.key == "j")
        #expect(moved.shortcut(for: .showInformation)?.modifiers == [.command, .shift])
        #expect(Keymap(overrides: ["menu.info": .unbound]).shortcut(for: .showInformation) == nil)
    }

    @Test func theRebinderListensConfirmsAndResets() {
        let prefs = store()
        let r = KeyRebinder(prefs: prefs)
        r.begin("menu.syncManager")
        #expect(r.isListening)
        r.capture(Chord("Escape"))
        #expect(!r.isListening && prefs.keyboardOverrides.isEmpty)
        // A free key is taken at once.
        r.begin("quantize")
        r.capture(Chord("w"))
        #expect(prefs.keyboardOverrides["quantize"] == Chord("w"))
        // A key somebody has asks first, and cancelling changes nothing.
        r.begin("cue")
        r.capture(Chord("w"))
        #expect(r.pending?.holders == ["quantize"] && prefs.keyboardOverrides["cue"] == nil)
        r.confirmPending()
        #expect(prefs.keyboardOverrides["cue"] == Chord("w") && prefs.keyboardOverrides["quantize"] == .unbound)
        #expect(Keymap(overrides: prefs.keyboardOverrides).chord(for: "cue") == Chord("w"))
        // A refused key says why.
        r.begin("menu.info")
        r.capture(Chord("j"))
        #expect(r.message != nil && prefs.keyboardOverrides["menu.info"] == nil)
        // Delete unbinds; reset brings one back; reset all clears.
        r.begin("loopIn")
        r.capture(Chord("Backspace"))
        #expect(prefs.keyboardOverrides["loopIn"] == .unbound)
        r.reset("loopIn")
        #expect(prefs.keyboardOverrides["loopIn"] == nil)
        r.resetAll()
        #expect(prefs.keyboardOverrides.isEmpty)
        // The built-in rows do not listen.
        r.begin("moveUp")
        #expect(!r.isListening)
    }

    @Test func overridesSurviveARelaunch() {
        let d = scratchDefaults(prefix: "rbxport-keys")
        let a = PreferencesStore(defaults: d)
        a.keyboardOverrides = ["quantize": Chord("w", shift: true)]
        let b = PreferencesStore(defaults: d)
        #expect(b.keymap.chord(for: "quantize") == Chord("w", shift: true))
    }
}

@MainActor
@Suite(.scratchDefaults)
struct CommandStateTests {
    private func ready(unlocked: Bool = true) async -> AppModel {
        let model = AppModel(backend: MockBackend(trackCount: 20), layoutStore: isolatedStore())
        if unlocked { model.protectLibrary = false }
        model.start()
        #expect(await eventually { model.opened != nil })
        return model
    }

    @Test func aProtectedLibraryDisablesEverythingThatWrites() async {
        let model = await ready(unlocked: false)
        let s = model.menuState
        #expect(!s.importEnabled && !s.newItemEnabled && !s.analyseEnabled && !s.removeFromCollectionEnabled)
    }

    @Test func theSelectionDrivesTheTrackMenu() async {
        let model = await ready()
        #expect(model.menuState.importEnabled && model.menuState.newItemEnabled)
        #expect(!model.menuState.loadToDeckEnabled && !model.menuState.analyseEnabled && !model.menuState.showInFinderEnabled)
        model.tableSelectionChanged(IndexSet(integer: 1), keepingUnloaded: false)
        #expect(await eventually { model.menuState.hasSelection })
        #expect(model.menuState.loadToDeckEnabled && model.menuState.analyseEnabled && model.menuState.showInFinderEnabled)
        model.tableSelectionChanged(IndexSet([1, 2]), keepingUnloaded: false)
        #expect(await eventually { model.selectedIDs.count == 2 })
        #expect(!model.menuState.loadToDeckEnabled && model.menuState.analyseEnabled)
    }

    @Test func deckBFollowsTheLayout() async {
        let model = await ready()
        model.player.layout = .one
        #expect(!model.menuState.twoDecks && !model.menuState.deckBEnabled)
        model.player.layout = .two
        #expect(model.menuState.deckBEnabled && !model.menuState.deckALoaded)
    }

    @Test func undoFollowsTheHistoryAndTheGate() async {
        let model = await ready(unlocked: false)
        model.editHistory = EditHistory(generation: 1, canUndo: true, canRedo: false, undoLabel: "Rename", redoLabel: nil)
        #expect(!model.menuState.canUndo)
        model.protectLibrary = false
        #expect(await eventually { model.menuState.canUndo && !model.menuState.canRedo })
    }

    @Test func menuLayoutKeysComeFromTheTable() {
        #expect(PlayerLayout.allCases.map(\.menuKey) == [.layoutOne, .layoutTwo, .layoutSimple, .layoutBrowser])
        for layout in PlayerLayout.allCases { #expect(BindingTable.byID[layout.bindingID]?.command == .menu(layout.menuKey)) }
    }
}
