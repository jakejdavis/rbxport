import Foundation
import os

/// A scripted engine for unit tests and previews: records every call, and tests push events
/// (ticks, load results) through `send`. Loads answer themselves unless told not to.
final class MockPlayback: PlaybackEngine, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case load(Deck, String, UInt64)
        case unload(Deck)
        case play(Deck)
        case pause(Deck)
        case seek(Deck, Double)
        case tempo(Deck, Float)
        case masterTempo(Deck, Bool)
        case keyShift(Deck, Int8)
        case loop(Deck, Double, Double)
        case looping(Deck, Bool)
        case clearLoop(Deck)
        case scrubBegin(Deck)
        case scrubTo(Deck, Double)
        case scrubEnd(Deck)
        case metronome(Deck, Bool)
        case refreshGrid(Deck)
        case metronomeSound(UInt8)
        case playAfter(Deck, Double)
        case trim(Deck, Float)
        case band(Deck, EqBand, Float)
        case kill(Deck, EqBand, Bool)
        case crossfade(Float)
        case masterLevel(Float)
        case limiter(Limiter)
        case audioDevice(String?)
        case audioConfig(UInt32?, UInt32?)
        case previewPlay(String, Double, UInt64)
        case previewStop
    }

    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var calls: [Call] = []
        var autoLoad = true
        var totalFrames: UInt64 = 48_000 * 200
        var sampleRate: UInt32 = 48_000
        var failLoads: String?
        var previewError: String?
        var preview = PreviewState(trackId: nil, playing: false, positionMs: 0, durationMs: 0)
        var mixer = MockPlayback.defaultMixer
        var devices = AudioDevices(
            devices: [AudioDevice(id: "dev-1", name: "Built-in Output"), AudioDevice(id: "dev-2", name: "Studio Interface")],
            defaultId: "dev-1", chosenId: nil)
        /// A device or rate change drops the engine, as the real one does.
        var resetOnOutputChange = true
        var config: [UInt32?]?
    }

    static let defaultChannel = ChannelState(
        trim: 1, low: 0.5, mid: 0.5, high: 0.5, killLow: false, killMid: false, killHigh: false)
    static let defaultMixer = MixerSnapshot(a: defaultChannel, b: defaultChannel, crossfade: 0.5, isolator: false)

    init() { (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self) }

    var calls: [Call] { lock.withLock { $0.calls } }

    /// Whether a load reports itself ready (`true`) or is left for the test to answer.
    func setAutoLoad(_ on: Bool) { lock.withLock { $0.autoLoad = on } }
    func failLoads(with message: String?) { lock.withLock { $0.failLoads = message } }
    func failPreviews(with message: String?) { lock.withLock { $0.previewError = message } }
    func setPreview(_ state: PreviewState) { lock.withLock { $0.preview = state } }

    /// Seeds the mixer as the "engine" holds it, for the read-back (#4) tests.
    func setMixer(_ mixer: MixerSnapshot) { lock.withLock { $0.mixer = mixer } }
    func setResetOnOutputChange(_ on: Bool) { lock.withLock { $0.resetOnOutputChange = on } }

    func send(_ event: PlaybackEvent) { continuation.yield(event) }

    /// A tick for deck A, stamped `at`.
    func tick(
        deckA: DeckTick? = nil, deckB: DeckTick? = nil, sampleRate: UInt32 = 48_000, at: TimeInterval = 0
    ) {
        send(.tick(Self.makeTick(a: deckA ?? Self.emptyDeck, b: deckB ?? Self.emptyDeck, sampleRate: sampleRate), at: at))
    }

    static let emptyDeck = DeckTick(
        frames: 0, totalFrames: 0, generation: 0, playing: false, loaded: false, loadId: 0, tempo: 1,
        masterTempo: false, keyShift: 0, startInFrames: 0, loopInFrames: 0, loopOutFrames: 0, looping: false)

    static func makeTick(a: DeckTick, b: DeckTick, sampleRate: UInt32) -> PlaybackTick {
        PlaybackTick(
            a: a, b: b, sampleRate: sampleRate, peakLeft: 0, peakRight: 0, master: 1, reduction: 0, shiftsKey: true)
    }

    private func record(_ call: Call) { lock.withLock { $0.calls.append(call) } }

    func load(deck: Deck, trackID: String, loadID: UInt64) {
        record(.load(deck, trackID, loadID))
        let (auto, frames, rate, failure) = lock.withLock { ($0.autoLoad, $0.totalFrames, $0.sampleRate, $0.failLoads) }
        if let failure {
            send(.deck(DeckEvent(deck: deck, loadId: loadID, totalFrames: 0, sampleRate: 0, message: failure)))
        } else if auto {
            send(.deck(DeckEvent(deck: deck, loadId: loadID, totalFrames: frames, sampleRate: rate, message: nil)))
        }
    }

    func unload(deck: Deck) { record(.unload(deck)) }
    func play(deck: Deck) { record(.play(deck)) }
    func pause(deck: Deck) { record(.pause(deck)) }
    func seek(deck: Deck, ms: Double) { record(.seek(deck, ms)) }
    func setTempo(deck: Deck, tempo: Float) { record(.tempo(deck, tempo)) }
    func setMasterTempo(deck: Deck, on: Bool) { record(.masterTempo(deck, on)) }
    func setKeyShift(deck: Deck, semitones: Int8) { record(.keyShift(deck, semitones)) }
    func setLoop(deck: Deck, inMs: Double, outMs: Double) { record(.loop(deck, inMs, outMs)) }
    func setLooping(deck: Deck, on: Bool) { record(.looping(deck, on)) }
    func clearLoop(deck: Deck) { record(.clearLoop(deck)) }
    func scrubBegin(deck: Deck) { record(.scrubBegin(deck)) }
    func scrubTo(deck: Deck, ms: Double) { record(.scrubTo(deck, ms)) }
    func scrubEnd(deck: Deck) { record(.scrubEnd(deck)) }
    func setMetronome(deck: Deck, on: Bool) { record(.metronome(deck, on)) }
    func refreshMetronomeGrid(deck: Deck) { record(.refreshGrid(deck)) }
    func setMetronomeSound(_ sound: UInt8) { record(.metronomeSound(sound)) }
    func state() -> PlaybackTick { Self.makeTick(a: Self.emptyDeck, b: Self.emptyDeck, sampleRate: 0) }
    func playAfter(deck: Deck, delayMs: Double) { record(.playAfter(deck, delayMs)) }

    func mixer() -> MixerSnapshot { lock.withLock { $0.mixer } }

    private func edit(_ deck: Deck, _ change: (inout ChannelState) -> Void) {
        lock.withLockUnchecked { s in
            if deck == .a { change(&s.mixer.a) } else { change(&s.mixer.b) }
        }
    }

    func setChannelTrim(deck: Deck, trim: Float) {
        record(.trim(deck, trim))
        edit(deck) { $0.trim = trim }
    }

    func setChannelBand(deck: Deck, band: EqBand, position: Float) {
        record(.band(deck, band, position))
        edit(deck) {
            switch band {
            case .low: $0.low = position
            case .mid: $0.mid = position
            case .high: $0.high = position
            }
        }
    }

    func setChannelKill(deck: Deck, band: EqBand, killed: Bool) {
        record(.kill(deck, band, killed))
        edit(deck) {
            switch band {
            case .low: $0.killLow = killed
            case .mid: $0.killMid = killed
            case .high: $0.killHigh = killed
            }
        }
    }

    func setCrossfade(_ position: Float) {
        record(.crossfade(position))
        lock.withLock { $0.mixer.crossfade = position }
    }

    func setMasterLevel(_ level: Float) { record(.masterLevel(level)) }

    func setLimiter(_ limiter: Limiter) -> Limiter {
        record(.limiter(limiter))
        // The engine's own clamps.
        return Limiter(
            enabled: limiter.enabled, inputGainDb: min(max(limiter.inputGainDb, -24), 24),
            ceilingDb: min(max(limiter.ceilingDb, -12), 0), releaseMs: min(max(limiter.releaseMs, 10), 1000))
    }

    func audioDevices() -> AudioDevices { lock.withLock { $0.devices } }

    func setAudioDevice(_ id: String?) {
        record(.audioDevice(id))
        let reset = lock.withLock { s -> Bool in
            let changed = s.devices.chosenId != id
            s.devices.chosenId = id
            return changed && s.resetOnOutputChange
        }
        if reset { send(.reset) }
    }

    func setAudioConfig(sampleRate: UInt32?, bufferFrames: UInt32?) {
        record(.audioConfig(sampleRate, bufferFrames))
        // The first push (at launch) finds no engine to drop; a later change does.
        let reset = lock.withLock { s -> Bool in
            let next = [sampleRate, bufferFrames]
            defer { s.config = next }
            guard let previous = s.config else { return false }
            return previous != next && s.resetOnOutputChange
        }
        if reset { send(.reset) }
    }

    func previewPlay(trackID: String, positionMs: Double, token: UInt64) {
        record(.previewPlay(trackID, positionMs, token))
        let failure = lock.withLock { s -> String? in
            if s.previewError == nil {
                s.preview = PreviewState(trackId: trackID, playing: true, positionMs: positionMs, durationMs: 200_000)
            }
            return s.previewError
        }
        send(.previewResult(token: token, error: failure))
    }

    func previewStop() {
        record(.previewStop)
        lock.withLock { $0.preview.playing = false }
    }

    func previewState() -> PreviewState { lock.withLock { $0.preview } }
}
