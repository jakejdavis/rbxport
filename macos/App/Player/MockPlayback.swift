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
    }

    init() { (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self) }

    var calls: [Call] { lock.withLock { $0.calls } }

    /// Whether a load reports itself ready (`true`) or is left for the test to answer.
    func setAutoLoad(_ on: Bool) { lock.withLock { $0.autoLoad = on } }
    func failLoads(with message: String?) { lock.withLock { $0.failLoads = message } }
    func failPreviews(with message: String?) { lock.withLock { $0.previewError = message } }
    func setPreview(_ state: PreviewState) { lock.withLock { $0.preview = state } }

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
    func state() -> PlaybackTick { Self.makeTick(a: Self.emptyDeck, b: Self.emptyDeck, sampleRate: 0) }

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
