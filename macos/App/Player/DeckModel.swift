import AppKit
import Observation
import QuartzCore

/// What a deck shows about its track. Built from a table row (which the load came from) or, for
/// a track that is not in a loaded page, from its details.
struct DeckTrack: Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    var key: String
    var bpmX100: UInt32
    var durationSec: UInt32
    var hasArtwork: Bool
    var artworkHue: Double
    var analysed: Bool
    var memoryCues: [UInt32]

    init(row: Row) {
        id = row.id
        title = row.title
        artist = row.artist
        key = row.key
        bpmX100 = row.bpmX100
        durationSec = row.durationSec
        hasArtwork = row.hasArtwork
        artworkHue = Double(row.artworkHue)
        analysed = row.analysed != 0
        memoryCues = row.memoryCues
    }

    init(details d: TrackDetails) {
        id = d.id
        title = d.title
        artist = d.artist
        key = d.key
        bpmX100 = d.bpmX100
        durationSec = d.durationSec
        hasArtwork = d.hasArtwork
        artworkHue = 0
        analysed = true
        memoryCues = []
    }
}

/// One deck: what is loaded, where the playhead is, the transport, the tempo. Fed by the
/// engine's ticks and load results; drives the engine through `PlaybackEngine`.
@MainActor @Observable
final class DeckModel {
    enum Phase: Equatable {
        case empty
        case loading
        case ready
        case failed(String)
    }

    enum TimeMode: String, Sendable { case elapsed, remaining }

    let deck: Deck

    private(set) var track: DeckTrack?
    private(set) var phase: Phase = .empty
    private(set) var loadID: UInt64 = 0
    /// The last tick (or local seek) the playhead is extrapolated from.
    private(set) var anchor = Anchor.none
    private(set) var totalFrames: UInt64 = 0
    private(set) var cue = CueMachine()
    private(set) var tempo = 1.0
    private(set) var masterTempo = false
    private(set) var artwork: NSImage?
    private(set) var overview: CGImage?

    var tempoRange: TempoRange {
        didSet { if tempoRange != oldValue { defaults.set(tempoRange.rawValue, forKey: key("tempoRange")) } }
    }
    var timeMode: TimeMode {
        didSet { if timeMode != oldValue { defaults.set(timeMode.rawValue, forKey: key("timeMode")) } }
    }

    /// The drawn playhead's easing state; drawing must not invalidate views.
    @ObservationIgnored let display = DisplayClock()
    @ObservationIgnored private let playback: any PlaybackEngine
    @ObservationIgnored private let waveforms: WaveformService?
    @ObservationIgnored private let artworks: ArtworkService?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private var nextLoadID: UInt64 = 0
    /// After a local seek, ticks of the old generation are ignored until the engine confirms.
    @ObservationIgnored private var landing: (generation: UInt32, until: TimeInterval)?
    @ObservationIgnored private var playWhenReady = false
    @ObservationIgnored private var resumeAt: Double?
    @ObservationIgnored private var overviewTicket: WaveformService.Ticket?
    @ObservationIgnored private var overviewKey: WaveformService.Key?
    @ObservationIgnored private var artworkTicket: ArtworkService.Ticket?

    /// How long after a seek an old position is still ignored.
    static let landingSeconds = 0.5

    init(
        deck: Deck, playback: any PlaybackEngine, waveforms: WaveformService? = nil, artworks: ArtworkService? = nil,
        defaults: UserDefaults = .standard, now: @escaping () -> TimeInterval = CACurrentMediaTime
    ) {
        self.deck = deck
        self.playback = playback
        self.waveforms = waveforms
        self.artworks = artworks
        self.defaults = defaults
        self.now = now
        let prefix = deck == .a ? "deckA" : "deckB"
        tempoRange = defaults.string(forKey: "\(prefix).tempoRange").flatMap(TempoRange.init) ?? .six
        timeMode = defaults.string(forKey: "\(prefix).timeMode").flatMap(TimeMode.init) ?? .elapsed
    }

    private func key(_ name: String) -> String { "\(deck == .a ? "deckA" : "deckB").\(name)" }

    // MARK: Derived

    var isLoaded: Bool { phase == .ready }
    var isPlaying: Bool { anchor.playing }
    var isBusy: Bool { phase == .loading }

    /// The track's length: the engine's, once loaded; the library's until then.
    var durationSeconds: Double {
        if totalFrames > 0, anchor.sampleRate > 0 { return Double(totalFrames) / Double(anchor.sampleRate) }
        return Double(track?.durationSec ?? 0)
    }

    /// Where the playhead is `time`, in seconds, extrapolated from the last tick.
    func position(at time: TimeInterval) -> Double {
        min(max(display.position(of: anchor, at: time), 0), max(durationSeconds, 0))
    }

    /// The file's BPM times the tempo, as rekordbox displays it.
    var playingBpmX100: Double { PlayerFormat.playingBpmX100(base: track?.bpmX100 ?? 0, tempo: tempo) }

    // MARK: Loading

    func load(_ newTrack: DeckTrack) {
        let wasPlaying = anchor.playing
        nextLoadID += 1
        loadID = nextLoadID
        track = newTrack
        phase = .loading
        anchor = .none
        totalFrames = 0
        landing = nil
        playWhenReady = wasPlaying
        resumeAt = nil
        display.reset()
        cue = CueMachine(cueMs: Double(newTrack.memoryCues.min() ?? 0))
        overview = nil
        overviewKey = nil
        waveforms?.cancel(overviewTicket)
        overviewTicket = nil
        requestArtwork(for: newTrack)
        playback.load(deck: deck, trackID: newTrack.id, loadID: loadID)
    }

    func unload() {
        playback.unload(deck: deck)
        track = nil
        phase = .empty
        anchor = .none
        totalFrames = 0
        landing = nil
        artwork = nil
        overview = nil
        overviewKey = nil
        waveforms?.cancel(overviewTicket)
        overviewTicket = nil
        loadID = 0
    }

    /// Starts playing as soon as the track is ready (for a deck that was playing when a new
    /// track was loaded onto it, and for the dev launch hook).
    func playWhenLoaded() {
        if phase == .ready { play() } else { playWhenReady = true }
    }

    /// The output was dropped and rebuilt: put the track back where it was.
    func reloadAfterReset() {
        guard let track, phase == .ready || phase == .loading else { return }
        let position = position(at: now())
        let wasPlaying = anchor.playing
        load(track)
        resumeAt = position
        playWhenReady = wasPlaying
    }

    func handle(deckEvent e: DeckEvent) {
        guard e.loadId == loadID, loadID != 0 else { return }
        if let message = e.message {
            phase = .failed(message)
            playWhenReady = false
            return
        }
        phase = .ready
        totalFrames = e.totalFrames
        anchor = Anchor(frames: 0, at: now(), sampleRate: e.sampleRate, playing: false, generation: 0, rate: tempo)
        // The engine keeps its own settings across loads; make sure they are the ones shown.
        playback.setTempo(deck: deck, tempo: Float(tempo))
        playback.setMasterTempo(deck: deck, on: masterTempo)
        if let at = resumeAt {
            resumeAt = nil
            seek(toSeconds: at)
        }
        if playWhenReady {
            playWhenReady = false
            play()
        }
    }

    /// One deck's half of a tick.
    func apply(tick t: DeckTick, sampleRate: UInt32, at time: TimeInterval) {
        guard loadID != 0, t.loadId == loadID, t.loaded else { return }
        if phase == .loading { phase = .ready }
        totalFrames = t.totalFrames
        if let landing {
            if t.generation == landing.generation && time < landing.until { return }
            self.landing = nil
        }
        let next = Anchor(
            frames: t.frames, at: time, sampleRate: sampleRate, playing: t.playing, generation: t.generation,
            rate: Double(t.tempo))
        if next != anchor { anchor = next }
    }

    // MARK: Transport

    func togglePlay() {
        guard isLoaded else { return }
        if anchor.playing { pause() } else { play() }
    }

    func play() {
        guard isLoaded else { return }
        cue.latch()
        rebase(playing: true)
        playback.play(deck: deck)
    }

    func pause() {
        guard isLoaded else { return }
        cue.latch()
        rebase(playing: false)
        playback.pause(deck: deck)
    }

    /// CUE went down (or the C key).
    func cuePressed() {
        guard isLoaded else { return }
        run(cue.press(playing: anchor.playing, positionMs: position(at: now()) * 1000))
    }

    /// CUE came up.
    func cueReleased() { run(cue.release()) }

    private func run(_ actions: [CueMachine.Action]) {
        for action in actions {
            switch action {
            case .seek(let ms): seek(toSeconds: ms / 1000)
            case .pause:
                rebase(playing: false)
                playback.pause(deck: deck)
            case .play:
                rebase(playing: true)
                playback.play(deck: deck)
            }
        }
    }

    /// Moves the playhead; the engine confirms with its next tick.
    func seek(toSeconds seconds: Double) {
        guard isLoaded else { return }
        let target = min(max(seconds, 0), durationSeconds)
        landing = (anchor.generation, now() + Self.landingSeconds)
        var next = anchor
        if next.sampleRate > 0 { next.frames = Int64((target * Double(next.sampleRate)).rounded()) }
        next.at = now()
        anchor = next
        playback.seek(deck: deck, ms: target * 1000)
    }

    func seek(toFraction fraction: Double) {
        seek(toSeconds: min(max(fraction, 0), 1) * durationSeconds)
    }

    /// Re-anchors at the current position so a change of state does not move the playhead.
    private func rebase(playing: Bool? = nil, rate: Double? = nil) {
        let time = now()
        var next = anchor
        if next.sampleRate > 0 { next.frames = Int64((anchor.extrapolate(at: time) * Double(next.sampleRate)).rounded()) }
        next.at = time
        if let playing { next.playing = playing }
        if let rate { next.rate = rate }
        anchor = next
    }

    // MARK: Tempo

    func setTempo(_ value: Double) {
        let clamped = min(max(value, TempoRange.minTempo), TempoRange.maxTempo)
        rebase(rate: clamped)
        tempo = clamped
        playback.setTempo(deck: deck, tempo: Float(clamped))
    }

    /// The fader moved to `position`, -1 (slow end) to 1 (fast end).
    func setFader(_ position: Double) { setTempo(tempoRange.tempo(forFader: position)) }

    func nudgeTempo(steps: Int) { setTempo((tempo + Double(steps) * TempoRange.step).rounded(toPlaces: 3)) }

    func resetTempo() { setTempo(1) }

    func cycleTempoRange() { tempoRange = tempoRange.next }

    func setMasterTempo(_ on: Bool) {
        masterTempo = on
        playback.setMasterTempo(deck: deck, on: on)
    }

    func toggleMasterTempo() { setMasterTempo(!masterTempo) }

    func toggleTimeMode() { timeMode = timeMode == .elapsed ? .remaining : .elapsed }

    // MARK: Images

    private func requestArtwork(for track: DeckTrack) {
        artworks?.cancel(artworkTicket)
        artworkTicket = nil
        artwork = nil
        guard track.hasArtwork, let artworks else { return }
        let id = track.id
        artworkTicket = artworks.request(id: id, pixels: 256) { [weak self] image in
            guard let self, self.track?.id == id else { return }
            self.artworkTicket = nil
            self.artwork = image
        }
    }

    /// Asks for the overview bitmap at this size; the view calls it whenever its size, palette or
    /// the track changes. A request that matches the last one is ignored.
    func requestOverview(palette: WaveformPalette, pixelWidth: Int, pixelHeight: Int, scale: CGFloat) {
        guard let track, track.analysed, let waveforms, pixelWidth > 0, pixelHeight > 0 else { return }
        let style = WaveformService.Style(
            palette: palette, pixelWidth: pixelWidth, pixelHeight: pixelHeight, topInset: 0, bottomInset: 0)
        let wanted = WaveformService.Key(id: track.id, style: style)
        guard wanted != overviewKey else { return }
        waveforms.cancel(overviewTicket)
        overviewKey = wanted
        let id = track.id
        overviewTicket = waveforms.request(id: id, style: style, scale: scale) { [weak self] image in
            guard let self, self.track?.id == id, self.overviewKey == wanted else { return }
            self.overviewTicket = nil
            if let image { self.overview = image }
        }
    }
}

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (self * scale).rounded() / scale
    }
}
