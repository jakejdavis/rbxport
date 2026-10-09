import AppKit
import Foundation
import SwiftUI

// MARK: - Chord

/// One key with its modifiers, spelt as the React app stores it (`KeyChord` in `shortcuts.ts`):
/// `key` is a character (lower case) or a name such as `ArrowLeft`, `Enter`, `F9` or ` `;
/// `command` is `metaKey`. An empty key is an unbound binding.
struct Chord: Hashable, Codable, Sendable {
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    static let unbound = Chord("")
    var isUnbound: Bool { key.isEmpty }

    /// React's field names, so a stored override reads back in either app.
    private enum CodingKeys: String, CodingKey {
        case key, command = "metaKey", shift = "shiftKey", option = "altKey", control = "ctrlKey"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = try c.decode(String.self, forKey: .key)
        self.init(
            key, command: try c.decodeIfPresent(Bool.self, forKey: .command) ?? false,
            shift: try c.decodeIfPresent(Bool.self, forKey: .shift) ?? false,
            option: try c.decodeIfPresent(Bool.self, forKey: .option) ?? false,
            control: try c.decodeIfPresent(Bool.self, forKey: .control) ?? false)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        if command { try c.encode(true, forKey: .command) }
        if shift { try c.encode(true, forKey: .shift) }
        if option { try c.encode(true, forKey: .option) }
        if control { try c.encode(true, forKey: .control) }
    }

    /// Stored overrides, checked as React's `chords()` does: a key of at most 32 characters and
    /// booleans for the rest; anything else is dropped.
    static func sanitisedOverrides(_ json: String?) -> [String: Chord] {
        guard let data = json?.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: Chord] = [:]
        for (id, value) in raw {
            guard let entry = value as? [String: Any], let key = entry["key"] as? String, key.count <= 32 else { continue }
            out[id] = Chord(
                key, command: entry["metaKey"] as? Bool == true, shift: entry["shiftKey"] as? Bool == true,
                option: entry["altKey"] as? Bool == true, control: entry["ctrlKey"] as? Bool == true)
        }
        return out
    }

    // MARK: From an event

    /// Virtual key codes with a fixed name, whatever the layout.
    private static let named: [UInt16: String] = [
        49: " ", 36: "Enter", 76: "Enter", 53: "Escape", 51: "Backspace", 117: "Delete", 48: "Tab",
        123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// What Shift turns the number row and the punctuation keys into (US layout), back to the key.
    private static let unshifted: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "?": "/", "_": "-", "+": "=", ":": ";", "|": "\\", "<": ",", ">": ".", "\"": "'", "{": "[", "}": "]", "~": "`",
    ]

    /// The chord an event is: Shift undone on the character, so Shift-1 is `1` with shift.
    init(_ event: KeyChord) {
        let flags = event.modifiers.intersection([.command, .control, .option, .shift])
        let key: String
        if let name = Self.named[event.keyCode] {
            key = name
        } else if event.character.count == 1 {
            key = flags.contains(.shift) ? (Self.unshifted[event.character] ?? event.character) : event.character
        } else {
            key = ""
        }
        self.init(
            key, command: flags.contains(.command), shift: flags.contains(.shift), option: flags.contains(.option),
            control: flags.contains(.control))
    }

    init(event: NSEvent) {
        self.init(
            KeyChord(
                character: event.charactersIgnoringModifiers?.lowercased() ?? "", keyCode: event.keyCode,
                modifiers: event.modifierFlags))
    }

    // MARK: Display

    private static let glyphs: [String: String] = [
        " ": "Space", "Enter": "\u{21A9}", "Escape": "\u{238B}", "Backspace": "\u{232B}", "Delete": "\u{2326}", "Tab": "\u{21E5}",
        "ArrowLeft": "\u{2190}", "ArrowRight": "\u{2192}", "ArrowUp": "\u{2191}", "ArrowDown": "\u{2193}",
        "Home": "\u{2196}", "End": "\u{2198}", "PageUp": "\u{21DE}", "PageDown": "\u{21DF}",
    ]

    /// `\u{21E7}\u{2318}F`, as a Mac prints a key equivalent.
    var display: String {
        guard !isUnbound else { return "None" }
        var text = ""
        if control { text += "\u{2303}" }
        if option { text += "\u{2325}" }
        if shift { text += "\u{21E7}" }
        if command { text += "\u{2318}" }
        return text + (Self.glyphs[key] ?? key.uppercased())
    }

    // MARK: To SwiftUI

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "": return nil
        case " ": return .space
        case "Enter": return .return
        case "Escape": return .escape
        case "Backspace": return .delete
        case "Delete": return .deleteForward
        case "Tab": return .tab
        case "ArrowLeft": return .leftArrow
        case "ArrowRight": return .rightArrow
        case "ArrowUp": return .upArrow
        case "ArrowDown": return .downArrow
        case "Home": return .home
        case "End": return .end
        case "PageUp": return .pageUp
        case "PageDown": return .pageDown
        default:
            if key.count == 1, let first = key.first { return KeyEquivalent(first) }
            if key.hasPrefix("F"), let n = Int(key.dropFirst()), (1...12).contains(n),
                let scalar = UnicodeScalar(NSF1FunctionKey + n - 1)
            {
                return KeyEquivalent(Character(scalar))
            }
            return nil
        }
    }

    var modifiers: EventModifiers {
        var out: EventModifiers = []
        if command { out.insert(.command) }
        if shift { out.insert(.shift) }
        if option { out.insert(.option) }
        if control { out.insert(.control) }
        return out
    }

    /// The menu shortcut for this chord, or nil when unbound.
    var shortcut: KeyboardShortcut? {
        keyEquivalent.map { KeyboardShortcut($0, modifiers: modifiers) }
    }
}

// MARK: - Commands

/// Who acts on a binding.
enum KeyOwner: Sendable {
    /// The one local key monitor: the decks, the master level.
    case deck
    /// A browser's own `keyDown` (the track table).
    case table
    /// A menu item's key equivalent.
    case menu
    /// The system or a control does it; listed, not rebindable.
    case system
}

/// Where a binding applies. Two bindings may share a key only when their scopes cannot both be live.
enum KeyScope: Sendable {
    case global, table, sidebar

    func overlaps(_ other: KeyScope) -> Bool { self == other || self == .global || other == .global }
}

enum BindingGroup: Int, CaseIterable, Sendable {
    case browse, playerA, playerB, general, menu

    var title: String {
        switch self {
        case .browse: "Browse"
        case .playerA: "Player A"
        case .playerB: "Player B"
        case .general: "General"
        case .menu: "Menu"
        }
    }
}

enum TableKey: Hashable, Sendable {
    case loadToDeck(Deck), clearSearch, toTop, toBottom, pageUp, pageDown
}

enum MasterKey: Hashable, Sendable { case volumeUp, volumeDown, mute }

/// A menu item that has a key equivalent.
enum MenuKey: String, Hashable, CaseIterable, Sendable {
    case find, analyse, importTracks, importFolder, newPlaylist, newFolder, syncManager
    case showFilter, showPlayer, showInformation
    case layoutOne, layoutTwo, layoutSimple, layoutBrowser
}

enum KeyCommand: Hashable, Sendable {
    case player(Deck, PlayerKeyAction)
    case master(MasterKey)
    case table(TableKey)
    case menu(MenuKey)
    /// Done by the system or a control; the name says what.
    case system(String)
}

// MARK: - KeyBinding table

struct KeyBinding: Identifiable, Sendable {
    let id: String
    let group: BindingGroup
    let label: String
    let chord: Chord
    let command: KeyCommand
    let owner: KeyOwner
    let scope: KeyScope
    /// A second key for something already bound; not listed in the pane, not rebindable.
    var alias = false
    var rebindable: Bool { owner != .system && !alias }
}


/// The shortcuts, ported from `BINDINGS` in `src/lib/shortcuts.ts`, for what the native app does.
/// A row the app has no feature for is left out rather than drawn dead.
enum BindingTable {
    static let all: [KeyBinding] = build()

    private static func build() -> [KeyBinding] {
        var rows: [KeyBinding] = []
        func add(
            _ id: String, _ group: BindingGroup, _ label: String, _ chord: Chord, _ command: KeyCommand,
            owner: KeyOwner, scope: KeyScope = .global, alias: Bool = false
        ) {
            rows.append(KeyBinding(id: id, group: group, label: label, chord: chord, command: command, owner: owner, scope: scope, alias: alias))
        }

        // Browse
        add("focusSearch", .browse, "Search", Chord("f", command: true), .menu(.find), owner: .menu)
        add("clearSearch", .browse, "Clear Search", Chord("Escape"), .table(.clearSearch), owner: .table, scope: .table)
        add("selectAll", .browse, "Select All", Chord("a", command: true), .system("selectAll"), owner: .system)
        add("moveUp", .browse, "Cursor Up", Chord("ArrowUp"), .system("moveUp"), owner: .system, scope: .table)
        add("moveDown", .browse, "Cursor Down", Chord("ArrowDown"), .system("moveDown"), owner: .system, scope: .table)
        add("extendUp", .browse, "Extend Selection Up", Chord("ArrowUp", shift: true), .system("extendUp"), owner: .system, scope: .table)
        add("extendDown", .browse, "Extend Selection Down", Chord("ArrowDown", shift: true), .system("extendDown"), owner: .system, scope: .table)
        add("pageUp", .browse, "Page Up", Chord("PageUp"), .table(.pageUp), owner: .table, scope: .table)
        add("pageDown", .browse, "Page Down", Chord("PageDown"), .table(.pageDown), owner: .table, scope: .table)
        add("toTop", .browse, "Cursor to Top", Chord("Home"), .table(.toTop), owner: .table, scope: .table)
        add("toBottom", .browse, "Cursor to Bottom", Chord("End"), .table(.toBottom), owner: .table, scope: .table)
        add("toTop.arrow", .browse, "Cursor to Top", Chord("ArrowUp", command: true), .table(.toTop), owner: .table, scope: .table, alias: true)
        add("toBottom.arrow", .browse, "Cursor to Bottom", Chord("ArrowDown", command: true), .table(.toBottom), owner: .table, scope: .table, alias: true)
        add("analyseSelection", .browse, "Analyze Track", Chord("a", command: true, shift: true), .menu(.analyse), owner: .menu)
        add("loadPlayer1", .browse, "Load on Player 1", Chord("Enter"), .table(.loadToDeck(.a)), owner: .table, scope: .table)
        add("loadPlayer2", .browse, "Load on Player 2", Chord("Enter", shift: true), .table(.loadToDeck(.b)), owner: .table, scope: .table)
        add("removeSelected", .browse, "Remove from Playlist", Chord("Backspace"), .system("remove"), owner: .system, scope: .table)
        add("rename", .browse, "Rename Playlist", Chord("Enter"), .system("rename"), owner: .system, scope: .sidebar)

        // The decks: A as typed, B with Shift (React derives B's rows the same way).
        struct Row {
            let id: String
            let label: String
            let chord: Chord
            let action: PlayerKeyAction
            var bToo = true
            /// Unbound by default on deck B (the preset gives B no clears for its first pads).
            var bUnbound = false
            var unbound = false
        }
        var rows_: [Row] = [
            Row(id: "playPause", label: "Play/Pause", chord: Chord(" "), action: .togglePlay),
            Row(id: "quantize", label: "Quantize", chord: Chord("q"), action: .quantize),
            Row(id: "cue", label: "Cue", chord: Chord("c"), action: .cueDown),
            Row(id: "memoryCue", label: "Memory Cue", chord: Chord("m"), action: .memoryStore),
            Row(id: "loopIn", label: "Loop In", chord: Chord("i"), action: .loopIn),
            Row(id: "loopOut", label: "Loop Out", chord: Chord("o"), action: .loopOut),
            Row(id: "reloop", label: "Exit/Reloop", chord: Chord("r"), action: .reloop),
        ]
        for digit in 4...9 {
            if let beats = LoopLength.beats(forDigit: digit) {
                let name = beats < 1 ? "\(LoopLength.label(beats))" : "\(Int(beats))"
                rows_.append(Row(id: "beatLoop\(name)", label: "\(LoopLength.label(beats)) Beat Loop", chord: Chord(String(digit)), action: .beatLoop(beats)))
            }
        }
        rows_ += [
            Row(id: "loopHalf", label: "Loop /2", chord: Chord("/"), action: .loopHalve),
            Row(id: "loopDouble", label: "Loop x2", chord: Chord("\\", option: true), action: .loopDouble),
        ]
        for (i, letter) in ["A", "B", "C"].enumerated() {
            rows_.append(Row(id: "hotCue\(letter)", label: "Set Hot Cue \(letter)", chord: Chord(String(i + 1)), action: .hotCueDown(letter)))
        }
        for (i, letter) in ["A", "B", "C"].enumerated() {
            rows_.append(Row(id: "clearHotCue\(letter)", label: "Clear Hot Cue \(letter)", chord: Chord(String(i + 1), command: true), action: .hotCueClear(letter), bUnbound: true))
        }
        rows_ += [
            Row(id: "nextMemoryCue", label: "Call Next Memory Cue", chord: Chord("n"), action: .memoryNext),
            Row(id: "previousMemoryCue", label: "Call Previous Memory Cue", chord: Chord("b"), action: .memoryPrevious),
            Row(id: "deleteMemoryCue", label: "Delete Memory Cue", chord: Chord("x"), action: .memoryDelete),
            Row(id: "jumpForward", label: "Jump Forward", chord: Chord("ArrowRight"), action: .jump(1)),
            Row(id: "jumpBack", label: "Jump Reverse", chord: Chord("ArrowLeft"), action: .jump(-1)),
        ]
        for (i, key) in ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";"].enumerated() {
            rows_.append(Row(id: "callMemoryCue\(i + 1)", label: "Memory Cue \(i + 1)", chord: Chord(key), action: .memoryNumber(i + 1)))
        }
        rows_ += [
            Row(id: "metronomeSound", label: "Change Metronome sound", chord: Chord("F9"), action: .metronomeSound, bToo: false),
            Row(id: "sync", label: "SYNC", chord: Chord("F1"), action: .beatSync),
            Row(id: "masterTempo", label: "Master Tempo", chord: Chord("F2"), action: .masterTempo),
            Row(id: "tempoReset", label: "Tempo Reset", chord: Chord("F3"), action: .tempoReset),
            Row(id: "bpmUp", label: "BPM +", chord: Chord("F7"), action: .bpmUp),
            Row(id: "bpmDown", label: "BPM -", chord: Chord("F6"), action: .bpmDown),
            Row(id: "shiftGridLeft", label: "Shift Beatgrid left", chord: Chord("ArrowLeft", command: true), action: .gridShift(-1)),
            Row(id: "shiftGridRight", label: "Shift Beatgrid right", chord: Chord("ArrowRight", command: true), action: .gridShift(1)),
            Row(id: "shiftGridToCenter", label: "Shift Beatgrid to the center", chord: Chord("\\", command: true, option: true), action: .gridAlign),
            // Native additions: the detail waveform's zoom.
            Row(id: "zoomIn", label: "Zoom In", chord: Chord("="), action: .zoom(-1)),
            Row(id: "zoomOut", label: "Zoom Out", chord: Chord("-"), action: .zoom(1)),
        ]
        for letter in ["D", "E", "F", "G", "H"] {
            rows_.append(Row(id: "hotCue\(letter)", label: "Set Hot Cue \(letter)", chord: .unbound, action: .hotCueDown(letter), unbound: true))
        }
        for letter in ["D", "E", "F", "G", "H"] {
            rows_.append(Row(id: "clearHotCue\(letter)", label: "Clear Hot Cue \(letter)", chord: .unbound, action: .hotCueClear(letter), unbound: true))
        }
        for band in MixerBand.allCases {
            rows_.append(Row(id: "eqKill\(band.label.capitalized)", label: "\(band.label.capitalized) Kill", chord: .unbound, action: .kill(band), unbound: true))
        }

        for (deck, group) in [(Deck.a, BindingGroup.playerA), (.b, .playerB)] {
            for row in rows_ where deck == .a || row.bToo {
                var chord = row.chord
                if deck == .b { chord = row.bUnbound ? .unbound : Chord(chord.key, command: chord.command, shift: !chord.isUnbound, option: chord.option) }
                let id = deck == .a ? row.id : "b.\(row.id)"
                add(id, group, row.label, chord, .player(deck, row.action), owner: .deck)
            }
        }
        // The numpad's + zooms in too (a Shift-= on the main keys is deck B's).
        add("zoomIn.plus", .playerA, "Zoom In", Chord("+"), .player(.a, .zoom(-1)), owner: .deck, alias: true)

        // Master level (React: ⌘F12, ⌘F11, ⌘F10).
        add("volumeUp", .general, "Volume", Chord("F12", command: true), .master(.volumeUp), owner: .deck)
        add("volumeDown", .general, "Volume Down", Chord("F11", command: true), .master(.volumeDown), owner: .deck)
        add("mute", .general, "Mute", Chord("F10", command: true), .master(.mute), owner: .deck)

        // Menu items (React lists these without actions; here the menu reads this table).
        add("menu.import", .menu, "Import Track", Chord("o", command: true), .menu(.importTracks), owner: .menu)
        add("menu.importFolder", .menu, "Import Folder", Chord("o", command: true, shift: true), .menu(.importFolder), owner: .menu)
        add("menu.newPlaylist", .menu, "New Playlist", Chord("n", command: true, option: true), .menu(.newPlaylist), owner: .menu)
        add("menu.newFolder", .menu, "New Folder", Chord("n", command: true, shift: true, option: true), .menu(.newFolder), owner: .menu)
        add("menu.syncManager", .menu, "Sync Manager", Chord("y", command: true, shift: true), .menu(.syncManager), owner: .menu)
        add("menu.showFilter", .menu, "Show Track Filter", Chord("f", command: true, option: true), .menu(.showFilter), owner: .menu)
        add("menu.showPlayer", .menu, "Show Player", Chord("p", command: true, option: true), .menu(.showPlayer), owner: .menu)
        add("menu.info", .menu, "Information Window", Chord("i", command: true), .menu(.showInformation), owner: .menu)
        add("menu.layout-one", .menu, "1 Player", Chord("7", command: true), .menu(.layoutOne), owner: .menu)
        add("menu.layout-two", .menu, "2 Players", Chord("8", command: true), .menu(.layoutTwo), owner: .menu)
        add("menu.layout-simple", .menu, "Simple Player", Chord("9", command: true), .menu(.layoutSimple), owner: .menu)
        add("menu.layout-browser", .menu, "Full Browser", Chord("0", command: true), .menu(.layoutBrowser), owner: .menu)
        // The ones the system menus own.
        add("menu.settings", .menu, "Settings", Chord(",", command: true), .system("settings"), owner: .system)
        add("menu.undo", .menu, "Undo", Chord("z", command: true), .system("undo"), owner: .system)
        add("menu.redo", .menu, "Redo", Chord("z", command: true, shift: true), .system("redo"), owner: .system)
        add("menu.fullscreen", .menu, "Enter Full Screen", Chord("f", command: true, control: true), .system("fullscreen"), owner: .system)
        return rows
    }

    static let byID: [String: KeyBinding] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

// MARK: - Keymap

/// Why a chord cannot go on a binding.
enum AssignIssue: Equatable, Sendable {
    /// The row is the system's or an alias.
    case notRebindable
    /// macOS or the standard Edit and Window commands keep this key.
    case reserved
    /// A menu key without Command or Control would take the key from every text field.
    case menuNeedsModifier
}

/// The table with the person's own keys applied.
struct Keymap: Sendable {
    let overrides: [String: Chord]
    private let index: [Chord: [Int]]

    init(overrides: [String: Chord] = [:]) {
        self.overrides = overrides.filter { BindingTable.byID[$0.key] != nil }
        var index: [Chord: [Int]] = [:]
        for (i, binding) in BindingTable.all.enumerated() {
            let chord = self.overrides[binding.id] ?? binding.chord
            if !chord.isUnbound { index[chord, default: []].append(i) }
        }
        self.index = index
    }

    /// The chord a binding answers to now.
    func chord(for id: String) -> Chord {
        overrides[id] ?? BindingTable.byID[id]?.chord ?? .unbound
    }

    func isChanged(_ id: String) -> Bool { overrides[id] != nil }

    /// The binding a chord asks for, among those with this owner. The first in table order wins.
    func binding(for chord: Chord, owner: KeyOwner, scope: KeyScope = .global) -> KeyBinding? {
        guard let hits = index[chord] else { return nil }
        for i in hits {
            let binding = BindingTable.all[i]
            if binding.owner == owner, binding.scope.overlaps(scope) { return binding }
        }
        return nil
    }

    /// The menu shortcut of a menu key (nil when the person unbound it).
    func shortcut(for key: MenuKey) -> KeyboardShortcut? {
        guard let binding = BindingTable.all.first(where: { $0.command == .menu(key) }) else { return nil }
        return chord(for: binding.id).shortcut
    }

    // MARK: Editing

    /// Chords no binding may take.
    static let reserved: Set<Chord> = [
        Chord("q", command: true), Chord("w", command: true), Chord("h", command: true), Chord("h", command: true, option: true),
        Chord("m", command: true), Chord("c", command: true), Chord("v", command: true), Chord("x", command: true),
        Chord("Tab", command: true), Chord("`", command: true), Chord(" ", command: true), Chord(",", command: true),
        Chord("z", command: true), Chord("z", command: true, shift: true), Chord("a", command: true),
        Chord("f", command: true, control: true),
    ]

    func issue(assigning chord: Chord, to id: String) -> AssignIssue? {
        guard let binding = BindingTable.byID[id], binding.rebindable else { return .notRebindable }
        if chord.isUnbound { return nil }
        if Self.reserved.contains(chord) { return .reserved }
        if binding.owner == .menu, !chord.command, !chord.control { return .menuNeedsModifier }
        return nil
    }

    /// The other bindings that already answer to `chord` where `id` would apply.
    func conflicts(assigning chord: Chord, to id: String) -> [KeyBinding] {
        guard let binding = BindingTable.byID[id], !chord.isUnbound, let hits = index[chord] else { return [] }
        return hits.map { BindingTable.all[$0] }.filter { $0.id != id && $0.scope.overlaps(binding.scope) }
    }

    /// The overrides after giving `chord` to `id`: as React's `assignChord`, any rebindable binding
    /// that had the chord is unbound, not swapped, and the preset chord clears the override.
    /// Returns nil when the chord is refused (see `issue`).
    func assigning(_ chord: Chord, to id: String) -> [String: Chord]? {
        guard issue(assigning: chord, to: id) == nil, let binding = BindingTable.byID[id] else { return nil }
        var next = overrides
        for other in conflicts(assigning: chord, to: id) where other.rebindable {
            next[other.id] = .unbound
        }
        if chord == binding.chord { next.removeValue(forKey: id) } else { next[id] = chord }
        return next
    }

    func resetting(_ id: String) -> [String: Chord] {
        var next = overrides
        next.removeValue(forKey: id)
        return next
    }

    /// Bindings that cannot all be had as the preset says: for tests of the table itself.
    static func duplicates(in rows: [KeyBinding] = BindingTable.all) -> [(KeyBinding, KeyBinding)] {
        var out: [(KeyBinding, KeyBinding)] = []
        for (i, a) in rows.enumerated() where !a.chord.isUnbound {
            for b in rows[(i + 1)...] where a.chord == b.chord && a.scope.overlaps(b.scope) { out.append((a, b)) }
        }
        return out
    }
}
