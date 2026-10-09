import Foundation

// Pure playback logic: the playhead clock, the CDJ cue state machine, tempo ranges and time
// formatting. Nothing here touches the engine or the UI, so all of it is unit tested.

// MARK: - Playhead clock (ported from src/lib/clock.ts)

/// The deck's position as of the last tick, enough to extrapolate where it is now.
struct Anchor: Equatable, Sendable {
    var frames: Int64 = 0
    /// Arrival time of the tick, in `CACurrentMediaTime` seconds.
    var at: TimeInterval = 0
    var sampleRate: UInt32 = 0
    var playing = false
    /// Bumped by the engine on every load and seek: a new generation snaps the playhead.
    var generation: UInt32 = 0
    /// How fast the deck runs against real time (its tempo).
    var rate: Double = 1

    static let none = Anchor()

    /// Seconds into the track, `now` seconds on the same clock as `at`. Never backwards.
    func extrapolate(at now: TimeInterval) -> Double {
        guard sampleRate > 0 else { return 0 }
        let base = Double(frames) / Double(sampleRate)
        guard playing else { return base }
        return base + max(0, now - at) * rate
    }

    /// An anchor standing still at `seconds`: a seek owns the playhead until the engine confirms.
    func pinned(at seconds: Double, now: TimeInterval) -> Anchor {
        var copy = self
        if sampleRate > 0 { copy.frames = Int64((seconds * Double(sampleRate)).rounded()) }
        copy.at = now
        copy.playing = false
        return copy
    }
}

enum PlayheadClock {
    /// A correction larger than this is a seek, a load or a nudge rather than drift.
    static let snapSeconds = 0.25
    /// How quickly a small correction is absorbed (about 150 ms to close a gap).
    static let easeMs = 50.0

    /// The position to draw, easing towards `target` from `shown`. Advances with playback first
    /// and eases only the remaining clock correction: easing the moving position itself adds a
    /// permanent lag.
    static func follow(shown: Double, target: Double, sinceMs: Double, advance: Double = 0) -> Double {
        let predicted = shown + advance
        let gap = target - predicted
        if abs(gap) > snapSeconds || sinceMs <= 0 { return target }
        return predicted + gap * (1 - exp(-sinceMs / easeMs))
    }
}

/// The per-display-frame state of one deck's drawn playhead. Not observed: drawing it must not
/// invalidate the views that draw it.
final class DisplayClock {
    private var shown = 0.0
    private var lastNow: TimeInterval?
    private var generation: UInt32 = 0

    /// The position to draw at `now`, advancing the clock. Paused decks draw exactly.
    func position(of anchor: Anchor, at now: TimeInterval) -> Double {
        let target = anchor.extrapolate(at: now)
        defer { lastNow = now }
        guard anchor.playing else {
            shown = target
            lastNow = nil
            return target
        }
        if anchor.generation != generation {
            generation = anchor.generation
            shown = target
            return target
        }
        guard let last = lastNow, now > last else {
            if lastNow == nil { shown = target }
            return shown
        }
        let dt = now - last
        shown = PlayheadClock.follow(shown: shown, target: target, sinceMs: dt * 1000, advance: dt * anchor.rate)
        return shown
    }

    func reset() {
        shown = 0
        lastNow = nil
    }
}

// MARK: - CDJ cue

/// What CUE does, as on a CDJ. Press while playing: back to the cue point and pause. Press
/// while paused on the cue point: play for as long as it is held, and on release go back and
/// pause. Press while paused anywhere else: that is the new cue point.
struct CueMachine: Equatable, Sendable {
    /// Within this of the cue point counts as being on it.
    static let toleranceMs = 20.0

    enum Action: Equatable, Sendable {
        case seek(Double)
        case pause
        case play
    }

    var cueMs = 0.0
    /// The deck is playing only because CUE is held on the cue point.
    private(set) var held = false

    mutating func press(playing: Bool, positionMs: Double) -> [Action] {
        if playing {
            held = false
            return [.seek(cueMs), .pause]
        }
        if abs(positionMs - cueMs) <= Self.toleranceMs {
            held = true
            return [.play]
        }
        cueMs = max(0, positionMs)
        return []
    }

    mutating func release() -> [Action] {
        guard held else { return [] }
        held = false
        return [.seek(cueMs), .pause]
    }

    /// PLAY pressed while CUE is held latches the deck playing: releasing CUE then does nothing.
    mutating func latch() { held = false }
}

// MARK: - Tempo

/// How far the tempo fader reaches either side of the file's own speed.
enum TempoRange: String, CaseIterable, Sendable {
    case six, ten, sixteen, wide

    /// The percentage either side: `down` below 100 %, `up` above.
    var ends: (down: Double, up: Double) {
        switch self {
        case .six: (6, 6)
        case .ten: (10, 10)
        case .sixteen: (16, 16)
        case .wide: (50, 100)
        }
    }

    var label: String {
        switch self {
        case .six: "\u{00B1}6"
        case .ten: "\u{00B1}10"
        case .sixteen: "\u{00B1}16"
        case .wide: "WIDE"
        }
    }

    var next: TempoRange {
        let all = TempoRange.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// The fader's position for a tempo: -1 at the slow end, 1 at the fast end, 0 at the
    /// file's own speed. Past the end is the end.
    func fader(forTempo tempo: Double) -> Double {
        let pct = (tempo - 1) * 100
        let at = pct >= 0 ? pct / ends.up : pct / ends.down
        return min(max(at, -1), 1)
    }

    /// The tempo at a fader position, the inverse of `fader(forTempo:)`.
    func tempo(forFader at: Double) -> Double {
        let clamped = min(max(at, -1), 1)
        let pct = clamped >= 0 ? clamped * ends.up : clamped * ends.down
        return 1 + pct / 100
    }

    static let minTempo = 0.5
    static let maxTempo = 2.0
    /// One step of the fader's arrow keys and the BPM keys.
    static let step = 0.001
}

// MARK: - Formatting

enum PlayerFormat {
    /// `MM:SS` and tenths, as rekordbox prints them: minutes padded to two digits. A negative
    /// input keeps its sign on the main part.
    static func splitTime(_ seconds: Double) -> (main: String, tenths: String) {
        let safe = seconds.isFinite ? abs(seconds) : 0
        let whole = Int(safe.rounded(.down))
        let tenths = Int(((safe - Double(whole)) * 10).rounded(.down))
        let main = String(format: "%02d:%02d", whole / 60, whole % 60)
        return ((seconds < 0 ? "\u{2212}" : "") + main, String(tenths))
    }

    /// The elapsed readout, `MM:SS.t`.
    static func elapsed(_ seconds: Double) -> String {
        let t = splitTime(max(seconds, 0))
        return "\(t.main).\(t.tenths)"
    }

    /// The remaining readout, `-MM:SS.t`: floor(total x 10) less the elapsed tenths, so it
    /// reads zero at the end and the two never disagree by a tenth.
    static func remaining(total: Double, position: Double) -> String {
        let tenths = max(Int((total * 10).rounded(.down)) - Int((max(position, 0) * 10).rounded(.down)), 0)
        let t = splitTime(Double(tenths / 10))
        return "-\(t.main).\(tenths % 10)"
    }

    /// `128.00`. Blank for no BPM.
    static func bpm(x100: Double) -> String {
        guard x100.isFinite, x100 > 0 else { return "" }
        return String(format: "%.2f", x100 / 100)
    }

    /// The BPM the deck plays at: the file's BPM times the tempo, in x100.
    static func playingBpmX100(base: UInt32, tempo: Double) -> Double { Double(base) * tempo }

    /// `+2.5%`, `-0.4%`, `0.0%`.
    static func tempoPercent(_ tempo: Double) -> String {
        let pct = (tempo - 1) * 100
        if abs(pct) < 0.05 { return "0.0%" }
        return String(format: "%+.1f%%", pct)
    }
}
