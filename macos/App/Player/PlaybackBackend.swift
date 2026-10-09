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
    /// Both decks now, for starting up and for after a reset.
    func state() -> PlaybackTick

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

    func state() -> PlaybackTick { playback.state() }

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
