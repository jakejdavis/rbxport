import Foundation
import Observation
import QuartzCore

/// The browser's preview player: a click on a row's waveform plays the track from there on the
/// engine's separate preview deck. One preview at a time; a second click on the playing row, or
/// a click on another row, ends it (the other row starts).
@MainActor @Observable
final class PreviewModel {
    private(set) var trackID: String?
    private(set) var isPlaying = false
    /// The last error, for the status line.
    private(set) var error: String?

    @ObservationIgnored private let playback: any PlaybackEngine
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private var anchorMs = 0.0
    @ObservationIgnored private var anchorAt: TimeInterval = 0
    @ObservationIgnored private var durationMs = 0.0
    @ObservationIgnored private var token: UInt64 = 0
    @ObservationIgnored private var confirmed = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// Called whenever which row is previewing changes, for views that are not observing.
    @ObservationIgnored var onChange: (() -> Void)?

    /// How often the engine's position is read back to correct the extrapolation.
    static let pollInterval = Duration.milliseconds(100)

    init(playback: any PlaybackEngine, now: @escaping () -> TimeInterval = CACurrentMediaTime) {
        self.playback = playback
        self.now = now
    }

    /// A click on `trackID`'s waveform at `positionMs`.
    func click(trackID id: String, positionMs: Double, durationMs: Double) {
        if isPlaying && trackID == id {
            stop()
        } else {
            start(trackID: id, positionMs: positionMs, durationMs: durationMs)
        }
    }

    func start(trackID id: String, positionMs: Double, durationMs: Double) {
        token += 1
        trackID = id
        isPlaying = true
        error = nil
        confirmed = false
        anchorMs = positionMs
        anchorAt = now()
        self.durationMs = durationMs
        playback.previewPlay(trackID: id, positionMs: positionMs, token: token)
        startPolling()
        onChange?()
    }

    func stop() {
        guard isPlaying || trackID != nil else { return }
        token += 1
        poll?.cancel()
        poll = nil
        isPlaying = false
        trackID = nil
        confirmed = false
        playback.previewStop()
        onChange?()
    }

    /// The engine answered a start: it is playing, or it could not.
    func resolve(token answered: UInt64, error message: String?) {
        guard answered == token else { return }
        if let message {
            error = message
            isPlaying = false
            trackID = nil
            poll?.cancel()
            poll = nil
            onChange?()
            return
        }
        confirmed = true
        syncFromEngine()
    }

    /// Where the preview is `time`, or nil when `id` is not the track being previewed.
    func positionMs(of id: String, at time: TimeInterval) -> Double? {
        guard isPlaying, trackID == id else { return nil }
        let extrapolated = anchorMs + max(0, time - anchorAt) * 1000
        return durationMs > 0 ? min(extrapolated, durationMs) : extrapolated
    }

    private func syncFromEngine() {
        guard confirmed, isPlaying else { return }
        let state = playback.previewState()
        guard state.trackId == trackID else { return }
        if state.durationMs > 0 { durationMs = state.durationMs }
        if state.playing {
            anchorMs = state.positionMs
            anchorAt = now()
        } else {
            // It ran to the end, or something stopped it.
            isPlaying = false
            trackID = nil
            poll?.cancel()
            poll = nil
            onChange?()
        }
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                self.syncFromEngine()
            }
        }
    }

    /// Whether any poll is running, for tests.
    var isPolling: Bool { poll != nil }
}
