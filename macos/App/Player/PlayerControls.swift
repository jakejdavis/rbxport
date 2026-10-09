import AppKit
import Foundation

// Pure logic behind slice 3b's controls: zoom, beat jump, loops, the hot cue pad state machine,
// cue lookups, key transposition, detail-waveform geometry and the keyboard map. Nothing here
// touches the engine or a view, so all of it is unit tested.

// MARK: - Zoom

/// How many bars the detail waveform shows (ported from `ZOOM_STEPS` in `lib/player.ts`).
enum DetailZoom {
    static let steps: [Double] = [0.25, 0.5, 1, 2, 4, 8, 12, 16, 32, 64]
    static let `default` = 12.0

    /// One step along, clamped at either end. Negative zooms in (fewer bars). A value that is not a
    /// step starts from the default.
    static func step(_ bars: Double, direction: Int) -> Double {
        let at = steps.firstIndex(of: bars) ?? steps.firstIndex(of: `default`)!
        return steps[min(max(at + direction, 0), steps.count - 1)]
    }

    /// The nearest step to a stored value, so a corrupt preference cannot break the zoom.
    static func clamped(_ bars: Double) -> Double {
        guard bars.isFinite else { return `default` }
        return steps.min(by: { abs($0 - bars) < abs($1 - bars) }) ?? `default`
    }

    /// At the widest step only the bar lines are drawn; every beat would be a picket fence.
    static func showsEveryBeat(_ bars: Double) -> Bool { bars < (steps.last ?? 64) }

    static func label(_ bars: Double) -> String {
        bars < 1 ? String(format: "%g", bars) : String(Int(bars))
    }
}

/// Turns a stream of wheel events into zoom steps: a mouse notch always steps, a trackpad's
/// travel accumulates and each step is followed by a cooldown. Ported from `createWheelZoomGate`.
struct WheelZoomGate {
    static let stepPx = 100.0
    static let cooldownMs = 150.0
    static let idleMs = 250.0

    private var travel = 0.0
    private var lastEvent = -Double.infinity
    private var lastStep = -Double.infinity

    /// -1 zooms in, 1 zooms out, 0 no step yet. `deltaPx` is browser-style: negative is up.
    mutating func feed(deltaPx: Double, nowMs: Double) -> Int {
        guard deltaPx != 0, deltaPx.isFinite else { return 0 }
        if nowMs - lastEvent > Self.idleMs { travel = 0 }
        lastEvent = nowMs
        if travel != 0, (travel > 0) != (deltaPx > 0) { travel = 0 }
        if abs(deltaPx) >= Self.stepPx {
            travel = 0
            lastStep = nowMs
            return deltaPx > 0 ? 1 : -1
        }
        if nowMs - lastStep < Self.cooldownMs { return 0 }
        travel += deltaPx
        if abs(travel) < Self.stepPx { return 0 }
        let direction = travel > 0 ? 1 : -1
        travel = 0
        lastStep = nowMs
        return direction
    }
}

// MARK: - Beat jump

/// A beat-jump size as the menu lists it (`JUMP_SIZES` in `lib/player.ts`).
struct JumpSize: Equatable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    /// Beats per press. Zero is the fine nudge, which is a time and not a length.
    var beats: Double

    static let all: [JumpSize] = [
        JumpSize(id: "fine", label: "Fine", beats: 0),
        JumpSize(id: "4beats", label: "4Beats", beats: 4),
        JumpSize(id: "8beats", label: "8Beats", beats: 8),
        JumpSize(id: "16beats", label: "16Beats", beats: 16),
        JumpSize(id: "8bars", label: "8Bars", beats: 32),
        JumpSize(id: "16bars", label: "16Bars", beats: 64),
        JumpSize(id: "32bars", label: "32Bars", beats: 128),
    ]
    static let `default` = all[1]

    /// The size with that id, or the default.
    static func byID(_ id: String?) -> JumpSize { all.first { $0.id == id } ?? .default }

    /// The step of a Fine press, in seconds: a CDJ's fine search.
    static let fineSeconds = 0.01
}

enum BeatJump {
    /// Where a jump lands, in ms, clamped to the track. Counted on the grid so it stays on the
    /// beat; Fine is a flat 10 ms.
    static func target(
        fromMs: Double, direction: Int, size: JumpSize, grid: BeatGrid, bpmX100: Double, durationMs: Double
    ) -> Double {
        let sign = direction >= 0 ? 1.0 : -1.0
        let raw: Double
        if size.beats == 0 {
            raw = fromMs + sign * JumpSize.fineSeconds * 1000
        } else {
            raw = grid.jumpTarget(fromMs: fromMs, beats: sign * size.beats, bpmX100: bpmX100) ?? fromMs
        }
        return min(max(raw, 0), max(durationMs, 0))
    }
}

// MARK: - Loops

/// The auto-loop lengths in beats, and halving and doubling them.
enum LoopLength {
    static let sizes: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32]
    static let `default` = 4.0
    static let minimum = 0.25
    static let maximum = 32.0

    static func halved(_ beats: Double) -> Double { max(minimum, beats / 2) }
    static func doubled(_ beats: Double) -> Double { min(maximum, beats * 2) }

    /// `1/4`, `1/2`, `1`, `2`... as the AU button prints it.
    static func label(_ beats: Double) -> String {
        switch beats {
        case 0.25: "1/4"
        case 0.5: "1/2"
        default: String(Int(beats))
        }
    }

    /// The beat count a loop key stands for: 4 to 9 are 1 to 32 beats.
    static func beats(forDigit digit: Int) -> Double? {
        let map: [Int: Double] = [4: 1, 5: 2, 6: 4, 7: 8, 8: 16, 9: 32]
        return map[digit]
    }
}

/// The deck's loop as the engine reports it.
struct DeckLoop: Equatable, Sendable {
    var inMs: Double
    var outMs: Double
    var active: Bool

    static func from(_ t: DeckTick, sampleRate: UInt32) -> DeckLoop? {
        guard sampleRate > 0, t.loopOutFrames > t.loopInFrames else { return nil }
        let rate = Double(sampleRate)
        return DeckLoop(
            inMs: Double(t.loopInFrames) / rate * 1000, outMs: Double(t.loopOutFrames) / rate * 1000, active: t.looping)
    }
}

// MARK: - Hot cue pads

/// A cue marker on the track, from the library: a hot cue (with a letter), a memory cue, or a loop.
struct DeckCue: Equatable, Sendable, Identifiable {
    var id: String
    var positionMs: Double
    /// Where a loop ends; 0 for a plain cue.
    var outMs: Double
    /// `A`...`P` for a hot cue, empty for a memory cue.
    var letter: String
    var memory: Bool
    var colour: RGB?
    var comment: String = ""

    /// rekordbox's default hot cue green, for a cue with no colour of its own.
    static let defaultHotColour = RGB(hex: 0x3CEB50)
    /// The red of a memory cue's head.
    static let memoryColour = RGB(hex: 0xEA3323)

    var isLoop: Bool { outMs > positionMs }
    var drawColour: RGB { colour ?? (memory ? Self.memoryColour : Self.defaultHotColour) }

    init(id: String = "", positionMs: Double, outMs: Double = 0, letter: String = "", memory: Bool, colour: RGB? = nil, comment: String = "") {
        self.id = id
        self.positionMs = positionMs
        self.outMs = outMs
        self.letter = letter
        self.memory = memory
        self.colour = colour
        self.comment = comment
    }

    init(_ cue: Cue) {
        self.init(
            id: cue.id, positionMs: Double(cue.positionMs), outMs: Double(cue.outMs), letter: cue.letter,
            memory: cue.memory, colour: cue.colour.flatMap(RGB.init(hexString:)), comment: cue.comment)
    }

    /// A cue made from a browser row's hot cue (the deck shows these until the full list arrives).
    init(_ hot: HotCue) {
        self.init(
            id: "", positionMs: Double(hot.positionMs), letter: hot.slot, memory: false,
            colour: hot.color.flatMap(RGB.init(hexString:)))
    }
}

enum CueLookup {
    /// Within this of a memory cue counts as being on it.
    static let toleranceMs = 20.0
    /// The pads: A to H.
    static let padLetters = ["A", "B", "C", "D", "E", "F", "G", "H"]

    /// The hot cue in a slot, or nil when the pad is empty. The earlier one wins a doubled slot.
    static func hot(_ cues: [DeckCue], letter: String) -> DeckCue? {
        cues.filter { !$0.memory && $0.letter == letter }.min { $0.positionMs < $1.positionMs }
    }

    static func memory(_ cues: [DeckCue]) -> [DeckCue] {
        cues.filter(\.memory).sorted { $0.positionMs < $1.positionMs }
    }

    /// The nth memory cue from the start, one-based.
    static func memory(_ cues: [DeckCue], number: Int) -> DeckCue? {
        let all = memory(cues)
        return number >= 1 && number <= all.count ? all[number - 1] : nil
    }

    /// The first memory cue after the playhead, by more than the tolerance.
    static func nextMemory(_ cues: [DeckCue], positionMs: Double) -> DeckCue? {
        memory(cues).first { $0.positionMs > positionMs + toleranceMs }
    }

    /// The last memory cue before the playhead.
    static func previousMemory(_ cues: [DeckCue], positionMs: Double) -> DeckCue? {
        memory(cues).last { $0.positionMs < positionMs - toleranceMs }
    }
}

/// What a hot cue pad does, as on a CDJ. Pressed while playing: jump there and keep playing.
/// Pressed while paused: play from the cue for as long as the pad is held, and on release go back
/// and pause. A pad never moves the cue point. (Setting, clearing and recolouring pads are
/// library writes and wait for Phase 4.)
struct PadMachine: Equatable, Sendable {
    /// The pad that is holding the deck playing from a pause.
    private(set) var heldLetter: String?
    private var returnMs = 0.0

    mutating func press(letter: String, cueMs: Double, playing: Bool) -> [CueMachine.Action] {
        if playing {
            heldLetter = nil
            return [.seek(cueMs)]
        }
        heldLetter = letter
        returnMs = cueMs
        return [.seek(cueMs), .play]
    }

    mutating func release() -> [CueMachine.Action] {
        guard heldLetter != nil else { return [] }
        heldLetter = nil
        return [.seek(returnMs), .pause]
    }

    /// PLAY or CUE pressed while a pad is held takes the deck over: releasing does nothing.
    mutating func latch() { heldLetter = nil }
}

// MARK: - Key transposition

enum KeyTranspose {
    private static let minors = ["Abm", "Ebm", "Bbm", "Fm", "Cm", "Gm", "Dm", "Am", "Em", "Bm", "F#m", "Dbm"]
    private static let majors = ["B", "F#", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E"]
    private static let notes = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let naturals: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    /// `2A` to `Ebm`; empty for anything else.
    static func fromCamelot(_ code: String) -> String {
        let text = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = text.last, letter == "A" || letter == "B", let n = Int(text.dropLast()), (1...12).contains(n) else {
            return ""
        }
        return (letter == "A" ? minors : majors)[n - 1]
    }

    /// A key shifted by semitones, in the notation it came in (Camelot stays Camelot).
    static func transpose(_ key: String, semitones: Int) -> String {
        guard semitones % 12 != 0 else { return key }
        let classical = fromCamelot(key)
        let name = (classical.isEmpty ? key : classical).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\u{266F}", with: "#").replacingOccurrences(of: "\u{266D}", with: "b")
        var chars = Array(name)
        guard let root = chars.first, let natural = naturals[root] else { return key }
        chars.removeFirst()
        var pitch = natural
        if chars.first == "#" { pitch += 1; chars.removeFirst() } else if chars.first == "b" { pitch -= 1; chars.removeFirst() }
        let minor = chars == ["m"]
        guard chars.isEmpty || minor else { return key }
        let shifted = notes[((pitch + semitones) % 12 + 12) % 12] + (minor ? "m" : "")
        if !classical.isEmpty {
            let code = CellFormat.camelot(shifted)
            return code.isEmpty ? key : code
        }
        return shifted
    }
}

// MARK: - Detail waveform geometry

enum DetailGeometry {
    /// `PWV3`/`PWV5`/`PWV7` run at 150 columns a second.
    static let columnsPerSecond = 150.0
    /// Device pixels per tile.
    static let tileWidth = 1024

    /// How many seconds of the track the strip shows: `bars` bars of four beats at the file's BPM.
    /// An unknown tempo shows 8 percent of the track, as the React player does.
    static func spanSeconds(bars: Double, bpmX100: Double, durationSec: Double) -> Double {
        guard bpmX100 > 0, durationSec > 0 else { return max(durationSec * 0.08, 1) }
        let seconds = bars * 4 * 60 / (bpmX100 / 100)
        // Never more than the whole track, never so small that rounding collapses it.
        return min(durationSec, max(seconds, durationSec * 1e-4))
    }

    /// A drag of `dx` points moves the playhead by this much: the record follows the hand, so
    /// dragging right goes back in time. The window's span sets the rate.
    static func dragSeconds(dx: Double, width: Double, spanSeconds: Double) -> Double {
        guard width > 0, dx.isFinite else { return 0 }
        return -(dx / width) * spanSeconds
    }

    /// A drag that moves no more than this is a click, not a scrub.
    static let clickSlop = 3.0

    /// The tiles (of `tileWidth` device pixels) a window centred on `position` needs, plus
    /// `margin` either side, clamped to the track.
    static func visibleTiles(
        position: Double, pixelsPerSecond pps: Double, viewWidthPx: Double, duration: Double, margin: Int = 1,
        tileWidth: Int = DetailGeometry.tileWidth
    ) -> ClosedRange<Int>? {
        guard pps > 0, viewWidthPx > 0, duration > 0 else { return nil }
        let t = Double(tileWidth)
        let left = position * pps - viewWidthPx / 2
        let right = position * pps + viewWidthPx / 2
        let lastTile = Int(((duration * pps) / t).rounded(.down))
        let first = max(Int((left / t).rounded(.down)) - margin, 0)
        let last = min(Int((right / t).rounded(.down)) + margin, lastTile)
        return first <= last ? first...last : nil
    }

    /// Where the scrolling content's origin sits so `position` is under the centre of the view.
    static func contentOffset(position: Double, pixelsPerSecond pps: Double, viewWidth: Double) -> Double {
        viewWidth / 2 - position * pps
    }

    /// The origin correction (ms) for a detail waveform whose first attack includes an encoder's
    /// leading samples while the beat grid and decoder do not. Only for the unambiguous
    /// start-of-file case (a near-zero first beat, a short run of silent columns, then an
    /// attack); a track with an intro before its first beat returns zero.
    static func originMs(firstBeatMs: Double?, bytes: Data, stride: Int) -> Double {
        guard let firstBeatMs, firstBeatMs >= 0, firstBeatMs <= 100, stride > 0 else { return 0 }
        let columns = bytes.count / stride
        var first = -1
        for column in 0..<min(columns, 16) {
            let start = bytes.startIndex + column * stride
            if bytes[start..<(start + stride)].contains(where: { $0 != 0 }) {
                first = column
                break
            }
        }
        if first <= 0 { return 0 }
        let attackMs = (Double(first) + 0.5) / columnsPerSecond * 1000
        let correction = attackMs - firstBeatMs
        return correction > 0 && correction <= 50 ? correction : 0
    }
}

extension WaveformPalette {
    /// The scrolling-detail tag for this palette.
    var detailKind: WaveformKind {
        switch self {
        case .bands: .bandsDetail
        case .mono: .monoDetail
        case .colour: .colourDetail
        }
    }

    /// Bytes per column of the detail tag.
    var detailStride: Int {
        switch self {
        case .bands: 3
        case .mono: 1
        case .colour: 2
        }
    }
}

// MARK: - Phrases

enum PhraseKind: String, CaseIterable, Sendable {
    case intro, verse, bridge, chorus, up, up2, up3, down, outro

    /// Which colour a phrase label takes: matched on what rekordbox writes, so UP 1, UP 2 and
    /// UP 3 are separate colours and an unknown label still gets a block rather than a gap.
    static func of(label: String) -> PhraseKind {
        let text = label.trimmingCharacters(in: .whitespaces).uppercased()
        if text.hasPrefix("UP") { return text.contains("3") ? .up3 : text.contains("2") ? .up2 : .up }
        if text.hasPrefix("DOWN") { return .down }
        if text.hasPrefix("CHORUS") { return .chorus }
        if text.hasPrefix("INTRO") { return .intro }
        if text.hasPrefix("OUT") { return .outro }
        if text.hasPrefix("VERSE") { return .verse }
        if text.hasPrefix("BRIDGE") { return .bridge }
        return .verse
    }

    var colour: RGB {
        switch self {
        case .intro: RGB(hex: 0xB83F1D)
        case .up: RGB(hex: 0x8138F6)
        case .up2: RGB(hex: 0x6B36F6)
        case .up3: RGB(hex: 0x5534F5)
        case .chorus: RGB(hex: 0x4EA730)
        case .down: RGB(hex: 0x95753A)
        case .outro: RGB(hex: 0x6886AB)
        case .verse: RGB(hex: 0x2F6FBF)
        case .bridge: RGB(hex: 0x7A4FA8)
        }
    }
}

/// A phrase laid out as a fraction of the track.
struct PhraseSpan: Equatable, Sendable {
    var label: String
    var kind: PhraseKind
    var from: Double
    var to: Double

    /// Each phrase runs to the start of the next, the last to the end of the track. One with no
    /// resolved time is placed from its beat where the tempo is known and dropped where it is not.
    static func spans(_ phrases: [Phrase], totalMs: Double, beatMs: Double) -> [PhraseSpan] {
        guard totalMs > 0 else { return [] }
        let placed: [(label: String, ms: Double)] = phrases.compactMap { phrase in
            if let t = phrase.timeMs { return (phrase.label, Double(t)) }
            return beatMs > 0 ? (phrase.label, Double(Int(phrase.beat) - 1) * beatMs) : nil
        }.sorted { $0.ms < $1.ms }
        return placed.enumerated().compactMap { i, phrase in
            let end = i + 1 < placed.count ? placed[i + 1].ms : totalMs
            let span = PhraseSpan(
                label: phrase.label, kind: .of(label: phrase.label), from: min(max(phrase.ms / totalMs, 0), 1),
                to: min(max(end / totalMs, 0), 1))
            return span.to > span.from ? span : nil
        }
    }
}

// MARK: - Keys

/// What a key means to a deck: A as typed, B with Shift. The Player group of
/// `src/lib/shortcuts.ts`: cue writes (1 to 3 set, Command-1 to 3 clear, M store, X delete) and
/// the grid shift keys (Command-arrows) go through the core's write gate.
enum PlayerKeyAction: Equatable, Hashable, Sendable {
    case togglePlay
    case cueDown, cueUp
    case quantize
    case memoryPrevious, memoryNext
    case memoryNumber(Int)
    /// M and X: store the cue point (or the active loop) and delete the memory cue under the playhead.
    case memoryStore, memoryDelete
    /// Command-1 to 3: Clear Hot Cue A to C.
    case hotCueClear(String)
    /// Command-Left and Command-Right shift the grid; Command-Option-\\ aligns it to the playhead.
    case gridShift(Int), gridAlign
    case hotCueDown(String), hotCueUp
    case loopIn, loopOut, reloop
    case beatLoop(Double)
    case loopHalve, loopDouble
    case jump(Int)
    /// Zoom the detail waveform: -1 in, 1 out. Native addition (the React player has the wheel and buttons).
    case zoom(Int)
    case masterTempo, tempoReset, bpmUp, bpmDown
    /// F1: BEAT SYNC (the two-deck layout).
    case beatSync
    case metronomeSound
    /// A mixer kill button (unbound until the Keyboard pane gives it a key).
    case kill(MixerBand)
    /// Consumed with no effect: an auto-repeat of a one-shot key, or a key whose action needs a write.
    case swallow
}

/// An event's key, as the monitor reads it.
struct KeyChord: Equatable, Sendable {
    /// `charactersIgnoringModifiers`, lower-cased, for printable keys; empty for special ones.
    var character: String
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
}

/// What a key press does, once the binding table has been asked.
enum KeyEffect: Equatable, Sendable {
    case deck(Deck, PlayerKeyAction)
    case master(MasterKey)
}

/// The decks' and the master's keys: the part of the binding table the one key monitor owns. The
/// chords are in `BindingTable` (with the person's overrides); this adds the rules around them:
/// an idle deck, auto-repeat, key-up, and text fields.
enum PlayerKeymap {
    // Virtual key codes of the keys with no stable character.
    static let space: UInt16 = 49
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let f1: UInt16 = 122, f2: UInt16 = 120, f3: UInt16 = 99, f6: UInt16 = 97, f7: UInt16 = 98
    static let f9: UInt16 = 101, f10: UInt16 = 109, f11: UInt16 = 103, f12: UInt16 = 111

    /// What a held key repeats: stepping keys. Every other key is a one-shot.
    private static func repeats(_ action: PlayerKeyAction) -> Bool {
        switch action {
        case .jump, .tempoReset, .bpmUp, .bpmDown, .gridShift, .memoryPrevious, .memoryNext: true
        default: false
        }
    }

    /// An idle deck still answers Space, CUE and the metronome's sound key.
    private static func worksIdle(_ action: PlayerKeyAction) -> Bool {
        switch action {
        case .togglePlay, .cueDown, .metronomeSound: true
        default: false
        }
    }

    /// What `chord` does, or nil to pass it on. `loaded` says whether a deck has a track;
    /// `typing` means a text field has focus; deck B's keys do nothing outside the two-deck layout.
    static func resolve(
        _ chord: KeyChord, isUp: Bool, isRepeat: Bool, typing: Bool, loaded: (Deck) -> Bool, twoDecks: Bool,
        keymap: Keymap = Keymap()
    ) -> KeyEffect? {
        let c = Chord(chord)
        guard let binding = keymap.binding(for: c, owner: .deck) else { return nil }
        let plain = !c.command && !c.option && !c.control
        switch binding.command {
        case .master(let key):
            return isUp || typing ? nil : .master(key)
        case .player(let deck, let action):
            if deck == .b && !twoDecks { return nil }
            if isUp {
                // Releasing CUE or a pad is honoured whatever has the focus now.
                switch action {
                case .cueDown: return .deck(deck, .cueUp)
                case .hotCueDown: return .deck(deck, .hotCueUp)
                case .togglePlay: return typing ? nil : .deck(deck, .swallow)
                default: return typing || !loaded(deck) || !plain ? nil : .deck(deck, .swallow)
                }
            }
            if typing { return nil }
            if !loaded(deck) && !worksIdle(action) { return nil }
            if isRepeat && !repeats(action) { return .deck(deck, .swallow) }
            return .deck(deck, action)
        default:
            return nil
        }
    }
}
