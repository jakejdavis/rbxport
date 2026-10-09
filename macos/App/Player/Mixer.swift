import Foundation
import Observation

// The mixer, the master level and the limiter. The engine owns the sound; these models hold
// what the interface shows and send every change down. None of the setters opens the audio
// output (the engine remembers the values and applies them when it opens), and a model that
// is built later reads the engine's state back instead of resetting it (the React strip reset
// the crossfader on every mount).

// MARK: - Channel strip

enum MixerBand: Int, CaseIterable, Sendable {
    case low, mid, high

    var label: String { ["LOW", "MID", "HIGH"][rawValue] }

    var eq: EqBand {
        switch self {
        case .low: .low
        case .mid: .mid
        case .high: .high
        }
    }
}

/// One deck's strip: trim, the three band knobs and the three kills.
struct ChannelStrip: Equatable, Sendable {
    /// 0 to 2, up to +6 dB; 1 is unity.
    static let trimRange = 0.0...2.0
    static let trimStep = 0.05
    static let bandRange = 0.0...1.0
    static let bandStep = 0.05
    /// A vertical drag of this many points sweeps the whole range.
    static let dragPoints = 120.0

    var trim = 1.0
    var bands = [0.5, 0.5, 0.5]
    var kills = [false, false, false]

    init() {}

    init(_ state: ChannelState) {
        trim = Double(state.trim)
        bands = [Double(state.low), Double(state.mid), Double(state.high)]
        kills = [state.killLow, state.killMid, state.killHigh]
    }

    /// `-∞dB` at zero, else decibels to one place (`trimLabel` in `MixerStrip.tsx`).
    static func trimLabel(_ trim: Double) -> String {
        trim <= 0 ? "-\u{221E}dB" : String(format: "%.1fdB", 20 * log10(trim))
    }

    /// The value after dragging `dy` points up from `start` over a range of `span`.
    static func dragged(from start: Double, dy: Double, span: Double) -> Double {
        start + dy / dragPoints * span
    }

    static func clampedTrim(_ value: Double) -> Double {
        value.isFinite ? min(max(value, trimRange.lowerBound), trimRange.upperBound) : 1
    }

    static func clampedBand(_ value: Double) -> Double {
        value.isFinite ? min(max(value, bandRange.lowerBound), bandRange.upperBound) : 0.5
    }
}

enum Crossfader {
    static let centre = 0.5
    static let step = 0.05
    /// Within this many points of the middle of the travel the fader snaps to the centre.
    static let detentPoints = 3.0

    static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : centre
    }

    /// The fader value for a pointer at `fraction` (0 to 1) of a track `length` points long:
    /// the detent holds the middle.
    static func value(forFraction fraction: Double, length: Double) -> Double {
        let value = clamped(fraction)
        return abs(value - centre) * length <= detentPoints ? centre : value
    }

    /// One arrow-key step, kept on the 0.05 grid so repeated steps return to exactly 0.5.
    static func nudged(_ value: Double, by steps: Int) -> Double {
        clamped(((value + Double(steps) * step) * 100).rounded() / 100)
    }
}

@MainActor @Observable
final class MixerModel {
    private(set) var a = ChannelStrip()
    private(set) var b = ChannelStrip()
    private(set) var crossfade = Crossfader.centre

    @ObservationIgnored private let playback: any PlaybackEngine

    /// Reads the engine's mixer rather than assuming its defaults.
    init(playback: any PlaybackEngine) {
        self.playback = playback
        refresh()
    }

    /// Takes the engine's state (after a reset, or when the strip first appears).
    func refresh() {
        let state = playback.mixer()
        a = ChannelStrip(state.a)
        b = ChannelStrip(state.b)
        crossfade = Double(state.crossfade)
    }

    func strip(_ deck: Deck) -> ChannelStrip { deck == .a ? a : b }

    private func edit(_ deck: Deck, _ change: (inout ChannelStrip) -> Void) {
        if deck == .a { change(&a) } else { change(&b) }
    }

    // MARK: Trim

    func setTrim(_ deck: Deck, _ value: Double) {
        let trim = ChannelStrip.clampedTrim(value)
        edit(deck) { $0.trim = trim }
        playback.setChannelTrim(deck: deck, trim: Float(trim))
    }

    /// Arrow keys: up is louder.
    func nudgeTrim(_ deck: Deck, steps: Int) {
        setTrim(deck, ((strip(deck).trim + Double(steps) * ChannelStrip.trimStep) * 100).rounded() / 100)
    }

    func resetTrim(_ deck: Deck) { setTrim(deck, 1) }

    // MARK: Bands and kills

    func setBand(_ deck: Deck, _ band: MixerBand, _ value: Double) {
        let position = ChannelStrip.clampedBand(value)
        edit(deck) { $0.bands[band.rawValue] = position }
        playback.setChannelBand(deck: deck, band: band.eq, position: Float(position))
    }

    func nudgeBand(_ deck: Deck, _ band: MixerBand, steps: Int) {
        setBand(deck, band, ((strip(deck).bands[band.rawValue] + Double(steps) * ChannelStrip.bandStep) * 100).rounded() / 100)
    }

    func resetBand(_ deck: Deck, _ band: MixerBand) { setBand(deck, band, 0.5) }

    func toggleKill(_ deck: Deck, _ band: MixerBand) {
        let killed = !strip(deck).kills[band.rawValue]
        edit(deck) { $0.kills[band.rawValue] = killed }
        playback.setChannelKill(deck: deck, band: band.eq, killed: killed)
    }

    // MARK: Crossfader

    func setCrossfade(_ value: Double) {
        let position = Crossfader.clamped(value)
        crossfade = position
        playback.setCrossfade(Float(position))
    }

    /// A drag along a track `length` points long, the pointer at `fraction` of it.
    func dragCrossfade(toFraction fraction: Double, length: Double) {
        setCrossfade(Crossfader.value(forFraction: fraction, length: length))
    }

    /// Arrow keys: up (or right) moves towards B.
    func nudgeCrossfade(steps: Int) { setCrossfade(Crossfader.nudged(crossfade, by: steps)) }

    func resetCrossfade() { setCrossfade(Crossfader.centre) }
}

// MARK: - Master level

/// The master knob's scale (`src/lib/volume.ts`): 0 to 10 on a taper that is 40 dB across the
/// last decade, 10 being a decibel under full, and 11 past the notch at +2 dB.
enum MasterScale {
    static let top = 10.0
    static let full = 11.0
    static let topDb = -1.0
    static let fullDb = 2.0
    static var fullGain: Double { pow(10, fullDb / 20) }
    /// The engine's default: the knob at 10.
    static var defaultGain: Double { pow(10, topDb / 20) }

    static func db(forReading reading: Double) -> Double {
        guard reading > 0 else { return -.infinity }
        if reading >= full { return fullDb }
        return topDb + 40 * log10(min(reading, top) / top)
    }

    static func gain(forReading reading: Double) -> Double {
        let db = db(forReading: reading)
        return db.isFinite ? min(pow(10, db / 20), fullGain) : 0
    }

    static func reading(forGain gain: Double) -> Double {
        guard gain > 0 else { return 0 }
        let db = 20 * log10(min(gain, fullGain))
        if db > topDb + 0.05 { return full }
        return min(top * pow(10, (db - topDb) / 40), top)
    }

    static func label(_ reading: Double) -> String { String(Int(min(max(reading, 0), full).rounded())) }
}

@MainActor @Observable
final class MasterModel {
    /// React's `rbl.master-level.v1`: the linear gain.
    static let key = "rbl.master-level.v1"

    private(set) var gain: Double

    @ObservationIgnored private let playback: any PlaybackEngine
    @ObservationIgnored private let defaults: UserDefaults

    /// Pushes the remembered level to the engine at once. Opens nothing.
    init(playback: any PlaybackEngine, defaults: UserDefaults) {
        self.playback = playback
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.key) as? Double
        gain = stored.flatMap { $0.isFinite ? min(max($0, 0), MasterScale.fullGain) : nil } ?? MasterScale.defaultGain
        playback.setMasterLevel(Float(gain))
    }

    var reading: Double { MasterScale.reading(forGain: gain) }

    func setReading(_ reading: Double) {
        gain = MasterScale.gain(forReading: min(max(reading, 0), MasterScale.full))
        defaults.set(gain, forKey: Self.key)
        playback.setMasterLevel(Float(gain))
    }
}

// MARK: - Limiter

/// The master limiter's settings (`src/store/useLimiter.ts`): remembered between sessions as
/// `rbl.limiter.v1`, pushed at launch so the first thing played has it, and shown as the
/// engine clamped them.
struct LimiterSettings: Codable, Equatable, Sendable {
    static let inputGainRange = -24.0...24.0
    static let ceilingRange = -12.0...0.0
    static let releaseRange = 10.0...1000.0
    static let inputGainStep = 0.1
    static let ceilingStep = 0.1
    static let releaseStep = 10.0

    var enabled = false
    var inputGainDb = -4.0
    var ceilingDb = 0.0
    var releaseMs = 250.0

    init() {}

    init(enabled: Bool, inputGainDb: Double, ceilingDb: Double, releaseMs: Double) {
        self.enabled = enabled
        self.inputGainDb = inputGainDb
        self.ceilingDb = ceilingDb
        self.releaseMs = releaseMs
    }

    init(_ limiter: Limiter) {
        self.init(
            enabled: limiter.enabled, inputGainDb: Double(limiter.inputGainDb), ceilingDb: Double(limiter.ceilingDb),
            releaseMs: Double(limiter.releaseMs))
    }

    var ffi: Limiter {
        Limiter(enabled: enabled, inputGainDb: Float(inputGainDb), ceilingDb: Float(ceilingDb), releaseMs: Float(releaseMs))
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    /// Every number inside its range; a non-finite one falls back to the default.
    func sanitised() -> LimiterSettings {
        let defaults = LimiterSettings()
        return LimiterSettings(
            enabled: enabled,
            inputGainDb: Self.clamp(inputGainDb, Self.inputGainRange, fallback: defaults.inputGainDb),
            ceilingDb: Self.clamp(ceilingDb, Self.ceilingRange, fallback: defaults.ceilingDb),
            releaseMs: Self.clamp(releaseMs, Self.releaseRange, fallback: defaults.releaseMs))
    }

    func isClose(to other: LimiterSettings) -> Bool {
        enabled == other.enabled && abs(inputGainDb - other.inputGainDb) < 1e-3 && abs(ceilingDb - other.ceilingDb) < 1e-3
            && abs(releaseMs - other.releaseMs) < 1e-3
    }

    /// A stored value made safe: missing, malformed or half-written falls back to the defaults.
    static func decode(_ text: String?) -> LimiterSettings {
        struct Partial: Decodable {
            var enabled: Bool?
            var inputGainDb: Double?
            var ceilingDb: Double?
            var releaseMs: Double?
        }
        guard let data = text?.data(using: .utf8), let partial = try? JSONDecoder().decode(Partial.self, from: data) else {
            return LimiterSettings()
        }
        let d = LimiterSettings()
        return LimiterSettings(
            enabled: partial.enabled ?? d.enabled, inputGainDb: partial.inputGainDb ?? d.inputGainDb,
            ceilingDb: partial.ceilingDb ?? d.ceilingDb, releaseMs: partial.releaseMs ?? d.releaseMs
        ).sanitised()
    }

    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

@MainActor @Observable
final class LimiterModel {
    static let key = "rbl.limiter.v1"

    private(set) var settings: LimiterSettings

    @ObservationIgnored private let playback: any PlaybackEngine
    @ObservationIgnored private let defaults: UserDefaults

    /// Pushes the remembered settings to the engine at once. Opens nothing.
    init(playback: any PlaybackEngine, defaults: UserDefaults) {
        self.playback = playback
        self.defaults = defaults
        settings = LimiterSettings.decode(defaults.string(forKey: Self.key))
        push()
    }

    /// Changes any of the settings; the rest is kept.
    func set(_ change: (inout LimiterSettings) -> Void) {
        var next = settings
        change(&next)
        settings = next.sanitised()
        defaults.set(settings.encoded, forKey: Self.key)
        push()
    }

    /// Sends the settings and takes back what the engine made of them.
    private func push() {
        let applied = LimiterSettings(playback.setLimiter(settings.ffi))
        // Through a Float, a value like -4.1 comes back as -4.0999999: only a real clamp counts.
        guard !applied.isClose(to: settings) else { return }
        settings = applied
        defaults.set(applied.encoded, forKey: Self.key)
    }
}
