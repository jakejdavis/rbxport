import Foundation
import QuartzCore

/// What the engine reports, in the order it happened.
enum PlaybackEvent: Sendable {
    /// Both decks, about 10 times a second while anything sounds. `at` is `CACurrentMediaTime`
    /// when the tick reached Swift.
    case tick(PlaybackTick, at: TimeInterval)
    /// The master meters, about 30 times a second.
    case meters(Meters)
    /// A deck finished loading, or failed to (the message is set).
    case deck(DeckEvent)
    /// The engine was dropped for a device or rate change; the decks must be reloaded.
    case reset
    /// A transport call failed (the output could not be opened, a file went missing).
    case failure(String)
    /// The preview request `token` started playing, or failed with the message.
    case previewResult(token: UInt64, error: String?)
}

/// The decks and the preview player. Calls return at once: transport commands run in order on
/// a serial queue, and the preview's blocking file open runs on its own, so neither can stall
/// the main thread or each other. Results arrive on `events`.
protocol PlaybackEngine: Sendable {
    /// Ticks, meters and results. One consumer should iterate it.
    var events: AsyncStream<PlaybackEvent> { get }

    func load(deck: Deck, trackID: String, loadID: UInt64)
    func unload(deck: Deck)
    func play(deck: Deck)
    func pause(deck: Deck)
    func seek(deck: Deck, ms: Double)
    /// Remembered and applied when the engine opens: never opens the output.
    func setTempo(deck: Deck, tempo: Float)
    func setMasterTempo(deck: Deck, on: Bool)
    /// Semitones from the track's own key, applied when the engine opens if it is not yet.
    func setKeyShift(deck: Deck, semitones: Int8)
    /// A loop between two file positions (ms), switched on. A head past the out point goes back in.
    func setLoop(deck: Deck, inMs: Double, outMs: Double)
    /// RELOOP (back into the loop from its in point) and EXIT (out of it, the range kept).
    func setLooping(deck: Deck, on: Bool)
    func clearLoop(deck: Deck)
    /// A drag on the waveform: audio follows `scrubTo` until `scrubEnd`.
    func scrubBegin(deck: Deck)
    func scrubTo(deck: Deck, ms: Double)
    func scrubEnd(deck: Deck)
    /// A click on every beat of the deck's grid while it plays.
    func setMetronome(deck: Deck, on: Bool)
    /// Which click (1 to 3) both decks' metronomes make.
    func setMetronomeSound(_ sound: UInt8)
    /// Both decks now, for starting up and for after a reset.
    func state() -> PlaybackTick
    /// Starts a deck after `delayMs` of silence the audio callback counts: quantized play on a
    /// synced deck, held for the master's next beat.
    func playAfter(deck: Deck, delayMs: Double)

    // The mixer, master and limiter. Remembered and applied when the engine opens: none of
    // these opens the output.

    /// The mixer as the engine holds it, or as it will when it opens.
    func mixer() -> MixerSnapshot
    func setChannelTrim(deck: Deck, trim: Float)
    func setChannelBand(deck: Deck, band: EqBand, position: Float)
    func setChannelKill(deck: Deck, band: EqBand, killed: Bool)
    func setCrossfade(_ position: Float)
    /// The master level as a linear gain.
    func setMasterLevel(_ level: Float)
    /// Sets the limiter; what comes back is what the engine's clamping made of it.
    func setLimiter(_ limiter: Limiter) -> Limiter

    // The output. A change drops a live engine and a `.reset` event follows.

    func audioDevices() -> AudioDevices
    func setAudioDevice(_ id: String?)
    func setAudioConfig(sampleRate: UInt32?, bufferFrames: UInt32?)

    /// Plays a track from a position without loading it on a deck (pausing the decks).
    func previewPlay(trackID: String, positionMs: Double, token: UInt64)
    func previewStop()
    func previewState() -> PreviewState
}

/// Forwards the Rust ticker's callbacks into an `AsyncStream`.
final class PlaybackBridge: PlaybackListener, Sendable {
    let stream: AsyncStream<PlaybackEvent>
    let continuation: AsyncStream<PlaybackEvent>.Continuation

    init() {
        // Ticks are superseded by the next one, so a slow consumer only ever misses old ones.
        (stream, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    // Called on the ticker thread or an engine thread; yielding is thread-safe and non-blocking.
    func onTick(tick: PlaybackTick) { continuation.yield(.tick(tick, at: CACurrentMediaTime())) }
    func onMeters(meters: Meters) { continuation.yield(.meters(meters)) }
    func onDeckEvent(event: DeckEvent) { continuation.yield(.deck(event)) }
    func onReset() { continuation.yield(.reset) }

    deinit { continuation.finish() }
}

/// The Rust playback object behind the protocol.
final class RustPlayback: PlaybackEngine, @unchecked Sendable {
    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let playback: Playback
    /// Transport commands run here, in order.
    private let transport = DispatchQueue(label: "rbxport.playback.transport", qos: .userInteractive)
    /// Preview file opens block for up to ten seconds; they get their own queue.
    private let previews = DispatchQueue(label: "rbxport.playback.preview", qos: .userInitiated)

    init(playback: Playback, bridge: PlaybackBridge) {
        self.playback = playback
        events = bridge.stream
        continuation = bridge.continuation
    }

    func load(deck: Deck, trackID: String, loadID: UInt64) {
        transport.async { [playback, continuation] in
            do {
                try playback.load(deck: deck, trackId: trackID, loadId: loadID)
            } catch {
                continuation.yield(
                    .deck(DeckEvent(deck: deck, loadId: loadID, totalFrames: 0, sampleRate: 0, message: describe(error))))
            }
        }
    }

    func unload(deck: Deck) { transport.async { [playback] in playback.unload(deck: deck) } }

    func play(deck: Deck) {
        transport.async { [playback, continuation] in
            do { try playback.play(deck: deck) } catch { continuation.yield(.failure(describe(error))) }
        }
    }

    func pause(deck: Deck) { transport.async { [playback] in playback.pause(deck: deck) } }
    func seek(deck: Deck, ms: Double) { transport.async { [playback] in playback.seekMs(deck: deck, positionMs: ms) } }

    func setTempo(deck: Deck, tempo: Float) { transport.async { [playback] in playback.setTempo(deck: deck, tempo: tempo) } }

    func setMasterTempo(deck: Deck, on: Bool) {
        transport.async { [playback] in playback.setMasterTempo(deck: deck, on: on) }
    }

    func setKeyShift(deck: Deck, semitones: Int8) {
        transport.async { [playback] in playback.setKeyShift(deck: deck, semitones: semitones) }
    }
    func setLoop(deck: Deck, inMs: Double, outMs: Double) {
        transport.async { [playback] in playback.setLoop(deck: deck, inMs: inMs, outMs: outMs) }
    }
    func setLooping(deck: Deck, on: Bool) { transport.async { [playback] in playback.setLooping(deck: deck, on: on) } }
    func clearLoop(deck: Deck) { transport.async { [playback] in playback.clearLoop(deck: deck) } }
    func scrubBegin(deck: Deck) { transport.async { [playback] in playback.scrubBegin(deck: deck) } }
    func scrubTo(deck: Deck, ms: Double) { transport.async { [playback] in playback.scrubTo(deck: deck, positionMs: ms) } }
    func scrubEnd(deck: Deck) { transport.async { [playback] in playback.scrubEnd(deck: deck) } }
    func setMetronome(deck: Deck, on: Bool) { transport.async { [playback] in playback.setMetronome(deck: deck, on: on) } }

    func setMetronomeSound(_ sound: UInt8) {
        transport.async { [playback] in playback.setMetronomeSound(sound: sound, volume: .large) }
    }

    func state() -> PlaybackTick { playback.state() }

    func playAfter(deck: Deck, delayMs: Double) {
        transport.async { [playback, continuation] in
            do { try playback.playAfter(deck: deck, delayMs: delayMs) } catch { continuation.yield(.failure(describe(error))) }
        }
    }

    func mixer() -> MixerSnapshot { playback.mixer() }
    func setChannelTrim(deck: Deck, trim: Float) { transport.async { [playback] in playback.setChannelTrim(deck: deck, trim: trim) } }
    func setChannelBand(deck: Deck, band: EqBand, position: Float) {
        transport.async { [playback] in playback.setChannelBand(deck: deck, band: band, position: position) }
    }
    func setChannelKill(deck: Deck, band: EqBand, killed: Bool) {
        transport.async { [playback] in playback.setChannelKill(deck: deck, band: band, killed: killed) }
    }
    func setCrossfade(_ position: Float) { transport.async { [playback] in playback.setCrossfade(position: position) } }
    func setMasterLevel(_ level: Float) { transport.async { [playback] in playback.setMasterLevel(level: level) } }
    func setLimiter(_ limiter: Limiter) -> Limiter { playback.setLimiter(limiter: limiter) }

    func audioDevices() -> AudioDevices { playback.audioDevices() }
    func setAudioDevice(_ id: String?) { transport.async { [playback] in _ = playback.setAudioDevice(device: id) } }
    func setAudioConfig(sampleRate: UInt32?, bufferFrames: UInt32?) {
        transport.async { [playback] in _ = playback.setAudioConfig(sampleRate: sampleRate, bufferFrames: bufferFrames) }
    }

    func previewPlay(trackID: String, positionMs: Double, token: UInt64) {
        previews.async { [playback, continuation] in
            do {
                try playback.previewPlay(trackId: trackID, positionMs: positionMs)
                continuation.yield(.previewResult(token: token, error: nil))
            } catch {
                continuation.yield(.previewResult(token: token, error: describe(error)))
            }
        }
    }

    func previewStop() { playback.previewStop() }
    func previewState() -> PreviewState { playback.previewState() }
}
