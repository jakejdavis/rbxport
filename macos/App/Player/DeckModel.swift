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
    var rating = 0
    var memoryCues: [UInt32]
    var hotCues: [HotCue]

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
        rating = Int(row.rating)
        memoryCues = row.memoryCues
        hotCues = row.hotCues
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
        rating = Int(d.rating)
        memoryCues = []
        hotCues = []
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

    // Slice 3b: the analysis, cues, loop and the controls built on them.
    private(set) var beats = BeatGrid.empty
    /// Bumped when the grid changes, so drawn tiles know to redraw.
    private(set) var beatsVersion = 0
    /// Bumped when the track is analysed again, so the waveforms are asked for afresh.
    private(set) var analysisVersion = 0
    private(set) var cues: [DeckCue] = []
    private(set) var phrases: [PhraseSpan] = []
    private(set) var vocals = Data()
    /// The full-resolution waveform tag for the palette it was fetched in.
    private(set) var detailBytes: Data?
    private(set) var detailPalette: WaveformPalette?
    /// The loop as the engine reports it (or as just asked for, until the next tick).
    private(set) var loop: DeckLoop?
    /// Q: cue/loop points snap to the beat grid. On at every launch, like the React player.
    var quantize = true
    private(set) var loopLength = LoopLength.default
    /// A LOOP IN waiting for its OUT, in ms.
    private(set) var pendingLoopIn: Double?
    var jumpSize = JumpSize.default {
        didSet { if jumpSize != oldValue && !applyingLink { onJumpSizeChange?(jumpSize) } }
    }
    private(set) var keyShift = 0
    private(set) var shiftsKey = true
    private(set) var metronome = false
    private(set) var scrubbing = false
    /// The pad currently held (for the pad row to light it).
    private(set) var heldPad: String?

    var tempoRange: TempoRange {
        didSet { if tempoRange != oldValue { defaults.set(tempoRange.rawValue, forKey: key("tempoRange")) } }
    }
    /// Bars shown by the detail waveform. Persisted per deck.
    private(set) var zoomBars: Double {
        didSet { if zoomBars != oldValue { defaults.set(zoomBars, forKey: key("zoomBars")) } }
    }
    /// Deck menu: a click on the overview seeks. Persisted, shared by both decks.
    var waveformClick: Bool {
        didSet { if waveformClick != oldValue { defaults.set(waveformClick, forKey: "deck.waveformClick") } }
    }
    var timeMode: TimeMode {
        didSet { if timeMode != oldValue { defaults.set(timeMode.rawValue, forKey: key("timeMode")) } }
    }

    /// The drawn playhead's easing state; drawing must not invalidate views.
    @ObservationIgnored let display = DisplayClock()
    @ObservationIgnored let playback: any PlaybackEngine
    @ObservationIgnored private let waveforms: WaveformService?
    @ObservationIgnored private let artworks: ArtworkService?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let now: () -> TimeInterval
    @ObservationIgnored private var nextLoadID: UInt64 = 0
    /// After a local seek, ticks of the old generation are ignored until the engine confirms.
    @ObservationIgnored private var landing: (generation: UInt32, until: TimeInterval)?
    @ObservationIgnored private var playWhenReady = false
    @ObservationIgnored private var resumeAt: Double?
    @ObservationIgnored private var overviewTicket: WaveformService.Ticket?
    @ObservationIgnored private var overviewKey: WaveformService.Key?
    @ObservationIgnored private var artworkTicket: ArtworkService.Ticket?
    @ObservationIgnored let backend: (any BackendProtocol)?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var detailKey: String?
    @ObservationIgnored private var pad = PadMachine()
    // Slice 4c: library writes, wired by the player.
    /// Whether the library may be written to right now (the core's write gate).
    @ObservationIgnored var canWrite: () -> Bool = { false }
    /// Where a failed write is reported; an empty string clears the message.
    @ObservationIgnored var report: (String) -> Void = { _ in }
    @ObservationIgnored var cueWriteInFlight = false
    @ObservationIgnored var writeTask: Task<Void, Never>?
    @ObservationIgnored var cuesRefresh: Task<Void, Never>?
    @ObservationIgnored var gridRefresh: Task<Void, Never>?
    @ObservationIgnored var playRecord: Task<Void, Never>?
    @ObservationIgnored var playClock = PlayClock()
    /// Record a play into the history after a minute (Settings: record history; on by default).
    var recordsHistory: Bool { defaults.object(forKey: "recordHistory") as? Bool ?? true }
    /// The beat-grid editor for the loaded track.
    @ObservationIgnored lazy var grid = GridEditModel(deck: self)
    /// Ticks do not move the loop display until this, so a loop just set does not flicker.
    @ObservationIgnored private var loopHoldUntil: TimeInterval = 0
    /// Ticks do not move the playhead until this, after a scrub lets go.
    @ObservationIgnored private var tickHoldUntil: TimeInterval = 0
    @ObservationIgnored private var scrubResume = false
    @ObservationIgnored fileprivate var rawPhrases: [Phrase] = []

    // Sync and DUAL CONTROL (the two-deck layout). The player wires these.
    /// BEAT SYNC is lit: the deck follows the master's tempo.
    private(set) var synced = false
    /// Called when the zoom or the jump size changes on this deck, for DUAL CONTROL to mirror.
    @ObservationIgnored var onZoomChange: ((Double) -> Void)?
    @ObservationIgnored var onJumpSizeChange: ((JumpSize) -> Void)?
    /// Called when what a follower matches changes: this deck's tempo, or its track.
    @ObservationIgnored var onSyncInputChange: (() -> Void)?
    @ObservationIgnored private var applyingLink = false

    /// How long after a seek an old position is still ignored.
    static let landingSeconds = 0.5

    init(
        deck: Deck, playback: any PlaybackEngine, waveforms: WaveformService? = nil, artworks: ArtworkService? = nil,
        backend: (any BackendProtocol)? = nil, defaults: UserDefaults = .standard,
        now: @escaping () -> TimeInterval = CACurrentMediaTime
    ) {
        self.deck = deck
        self.playback = playback
        self.waveforms = waveforms
        self.artworks = artworks
        self.backend = backend
        self.defaults = defaults
        self.now = now
        let prefix = deck == .a ? "deckA" : "deckB"
        tempoRange = defaults.string(forKey: "\(prefix).tempoRange").flatMap(TempoRange.init) ?? .six
        timeMode = defaults.string(forKey: "\(prefix).timeMode").flatMap(TimeMode.init) ?? .elapsed
        waveformClick = defaults.object(forKey: "deck.waveformClick") as? Bool ?? true
        let storedZoom = defaults.object(forKey: "\(prefix).zoomBars") as? Double
        zoomBars = storedZoom.map(DetailZoom.clamped) ?? DetailZoom.default
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
        pad = PadMachine()
        heldPad = nil
        playClock.reset()
        cueWriteInFlight = false
        grid.trackChanged()
        resetAnalysis(for: newTrack)
        overview = nil
        overviewKey = nil
        waveforms?.cancel(overviewTicket)
        overviewTicket = nil
        requestArtwork(for: newTrack)
        playback.load(deck: deck, trackID: newTrack.id, loadID: loadID)
        onSyncInputChange?()
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
        playClock.reset()
        resetAnalysis(for: nil)
        grid.trackChanged()
        synced = false
        onSyncInputChange?()
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
        if keyShift != 0 { playback.setKeyShift(deck: deck, semitones: Int8(keyShift)) }
        if metronome { playback.setMetronome(deck: deck, on: true) }
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
    func apply(tick t: DeckTick, sampleRate: UInt32, at time: TimeInterval, shiftsKey canShift: Bool = true) {
        guard loadID != 0, t.loadId == loadID, t.loaded else { return }
        if phase == .loading { phase = .ready }
        notePlayTime(at: time)
        totalFrames = t.totalFrames
        if shiftsKey != canShift { shiftsKey = canShift }
        if time >= loopHoldUntil {
            let reported = DeckLoop.from(t, sampleRate: sampleRate)
            if reported != loop { loop = reported }
        }
        // A drag owns the playhead, and for a moment after it lets go.
        if scrubbing || time < tickHoldUntil { return }
        if let landing {
            if t.generation == landing.generation && time < landing.until { return }
            self.landing = nil
        }
        let next = Anchor(
            frames: t.frames, at: time, sampleRate: sampleRate, playing: t.playing, generation: t.generation,
            // A play held for the beat has not started: the head stays put until it does.
            rate: t.startInFrames > 0 ? 0 : Double(t.tempo))
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
        latchPad()
        rebase(playing: true)
        playback.play(deck: deck)
    }

    func pause() {
        guard isLoaded else { return }
        cue.latch()
        latchPad()
        rebase(playing: false)
        playback.pause(deck: deck)
    }

    /// CUE went down (or the C key).
    func cuePressed() {
        guard isLoaded else { return }
        latchPad()
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

    /// `bySync` is BEAT SYNC matching the master; any other change is the DJ's and puts the
    /// sync light out.
    func setTempo(_ value: Double, bySync: Bool = false) {
        let clamped = min(max(value, TempoRange.minTempo), TempoRange.maxTempo)
        if !bySync && synced { synced = false }
        rebase(rate: clamped)
        tempo = clamped
        playback.setTempo(deck: deck, tempo: Float(clamped))
        onSyncInputChange?()
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


// MARK: - Slice 3b: analysis, cues, loops, jump, key shift, scrub

extension DeckModel {
    // MARK: Analysis

    /// Clears the per-track analysis and starts fetching the new track's.
    fileprivate func resetAnalysis(for newTrack: DeckTrack?) {
        analysisTask?.cancel()
        detailTask?.cancel()
        detailKey = nil
        beats = .empty
        beatsVersion += 1
        phrases = []
        rawPhrases = []
        vocals = Data()
        detailBytes = nil
        detailPalette = nil
        loop = nil
        pendingLoopIn = nil
        loopHoldUntil = 0
        tickHoldUntil = 0
        scrubbing = false
        // What the row already carries, until the full list arrives.
        cues = (newTrack?.hotCues.map(DeckCue.init) ?? [])
            + (newTrack?.memoryCues.map { DeckCue(positionMs: Double($0), memory: true) } ?? [])
        guard let newTrack, newTrack.analysed, let backend else { return }
        let id = newTrack.id
        analysisTask = Task { [weak self] in
            if let beats = try? await backend.trackBeats(id: id), !Task.isCancelled, let self, self.track?.id == id {
                self.install(beats: BeatGrid(beats: beats))
            }
            if let cues = try? await backend.trackCues(id: id), !Task.isCancelled, let self, self.track?.id == id {
                self.install(cues: cues.map(DeckCue.init))
            }
            if let raw = try? await backend.trackPhrases(id: id), !Task.isCancelled, let self, self.track?.id == id {
                self.rawPhrases = raw
                self.relayoutPhrases()
            }
            if let vocals = try? await backend.trackVocals(id: id), !Task.isCancelled, let self, self.track?.id == id {
                self.vocals = vocals
            }
        }
    }

    /// The track was analysed (or analysed again): draw the new waveforms, grid and cues.
    func reloadAnalysis(bpmX100: UInt32? = nil, durationSec: UInt32? = nil) {
        guard var current = track else { return }
        current.analysed = true
        if let bpmX100, bpmX100 > 0 { current.bpmX100 = bpmX100 }
        if let durationSec, durationSec > 0 { current.durationSec = durationSec }
        track = current
        overview = nil
        overviewKey = nil
        analysisVersion += 1
        resetAnalysis(for: current)
        playback.refreshMetronomeGrid(deck: deck)
        Task { await grid.refresh() }
    }

    /// Puts a beat grid on the deck (what the analysis fetch does when it arrives).
    func install(beats grid: BeatGrid) {
        beats = grid
        beatsVersion += 1
        relayoutPhrases()
    }

    func install(cues list: [DeckCue]) { cues = list }

    fileprivate func relayoutPhrases() {
        let beatMs = beats.isEmpty ? (track.map { $0.bpmX100 > 0 ? 60_000 / (Double($0.bpmX100) / 100) : 0 } ?? 0) : 0
        phrases = PhraseSpan.spans(rawPhrases, totalMs: durationSeconds * 1000, beatMs: beatMs)
    }

    /// Asks for the scrolling waveform's bytes in this palette; ignored if it already has them.
    func requestDetail(palette: WaveformPalette) {
        guard let track, track.analysed, let backend else { return }
        let key = "\(track.id)#\(palette.rawValue)"
        guard key != detailKey else { return }
        detailKey = key
        detailTask?.cancel()
        let id = track.id
        detailTask = Task { [weak self] in
            let data = try? await backend.waveform(id: id, kind: palette.detailKind)
            guard !Task.isCancelled, let self, self.track?.id == id, self.detailKey == key else { return }
            self.detailBytes = data
            self.detailPalette = palette
        }
    }

    // MARK: Derived

    /// The grid cue and loop points snap to when Q is on.
    var quantizeGrid: BeatGrid? { quantize ? beats : nil }

    /// The key as it sounds with the key shift applied.
    var shiftedKey: String { KeyTranspose.transpose(track?.key ?? "", semitones: keyShift) }

    var hotCues: [DeckCue] { cues.filter { !$0.memory } }
    var memoryCues: [DeckCue] { CueLookup.memory(cues) }

    // MARK: Zoom

    func zoom(direction: Int) { setZoom(bars: DetailZoom.step(zoomBars, direction: direction)) }

    func setZoom(bars: Double) {
        let next = DetailZoom.clamped(bars)
        guard next != zoomBars else { return }
        zoomBars = next
        onZoomChange?(next)
    }

    /// DUAL CONTROL: take the other deck's zoom or jump size without echoing it back.
    func applyLinked(zoomBars bars: Double) { zoomBars = DetailZoom.clamped(bars) }

    func applyLinked(jumpSize size: JumpSize) {
        applyingLink = true
        jumpSize = size
        applyingLink = false
    }

    // MARK: Quantize

    func toggleQuantize() { quantize.toggle() }

    /// `ms` on the beat grid when Q is on.
    func snapped(_ ms: Double) -> Double { quantizeGrid?.nearestBeatMs(ms) ?? ms }

    // MARK: Hot cue pads

    /// A pad went down (or its key): jump to its cue, and from a pause play while it is held.
    func padPressed(_ letter: String) {
        guard isLoaded else { return }
        // An empty pad is set at the playhead; a set one is only ever called.
        guard let target = CueLookup.hot(cues, letter: letter) else {
            setHotCue(letter)
            return
        }
        cue.latch()
        let actions = pad.press(letter: letter, cueMs: target.positionMs, playing: anchor.playing)
        heldPad = pad.heldLetter
        run(actions)
    }

    func padReleased() {
        let actions = pad.release()
        heldPad = nil
        run(actions)
    }

    fileprivate func latchPad() {
        pad.latch()
        if heldPad != nil { heldPad = nil }
    }

    // MARK: Memory cues

    func callPreviousMemory() { call(CueLookup.previousMemory(cues, positionMs: position(at: now()) * 1000)) }
    func callNextMemory() { call(CueLookup.nextMemory(cues, positionMs: position(at: now()) * 1000)) }
    func callMemory(number: Int) { call(CueLookup.memory(cues, number: number)) }

    /// Calling a memory cue moves the head there and makes it the cue point; a memory loop is
    /// called as a loop, from its in point.
    func call(_ target: DeckCue?) {
        guard isLoaded, let target else { return }
        latchPad()
        cue.latch()
        if target.isLoop {
            setLoop(inMs: target.positionMs, outMs: target.outMs)
        } else {
            seek(toSeconds: target.positionMs / 1000)
        }
        cue.moveCuePoint(to: target.positionMs)
    }

    // MARK: Loops

    func setLoop(inMs: Double, outMs: Double) {
        guard isLoaded, outMs > inMs else { return }
        loop = DeckLoop(inMs: inMs, outMs: outMs, active: true)
        loopHoldUntil = now() + 0.4
        // The head goes to the in point if it is outside, as the engine does.
        let head = position(at: now()) * 1000
        if head >= outMs || head < inMs { seek(toSeconds: inMs / 1000) }
        playback.setLoop(deck: deck, inMs: inMs, outMs: outMs)
    }

    private var headMs: Double { position(at: now()) * 1000 }

    /// A loop of `beats` from the head: the in point on the beat when Q is on.
    func loopOfBeats(_ beats: Double) {
        guard isLoaded else { return }
        let at = headMs
        if let range = self.beats.beatLoopRange(snapTo: quantizeGrid, atMs: at, beats: beats) {
            setLoop(inMs: range.inMs, outMs: range.outMs)
        } else if let track, track.bpmX100 > 0 {
            // No grid: the file's own BPM sets the length.
            let start = at
            setLoop(inMs: start, outMs: start + beats * 60_000 / (Double(track.bpmX100) / 100))
        }
    }

    /// The AU button: exit an active loop, else loop the chosen length from the head.
    func autoLoop() {
        guard isLoaded else { return }
        if loop?.active == true {
            setLooping(false)
        } else {
            loopOfBeats(loopLength)
        }
    }

    /// A beat-loop key or pad: set the length and start the loop.
    func beatLoop(_ beats: Double) {
        loopLength = min(max(beats, LoopLength.minimum), LoopLength.maximum)
        loopOfBeats(loopLength)
    }

    func markLoopIn() {
        guard isLoaded else { return }
        pendingLoopIn = snapped(headMs)
    }

    func markLoopOut() {
        guard isLoaded, let start = pendingLoopIn else { return }
        let out = snapped(headMs)
        if out > start { setLoop(inMs: start, outMs: out) }
        pendingLoopIn = nil
    }

    /// RELOOP when the loop is off, EXIT when it is on.
    func reloopOrExit() {
        guard isLoaded, let loop else { return }
        setLooping(!loop.active)
    }

    func setLooping(_ on: Bool) {
        guard let current = loop else { return }
        loop = DeckLoop(inMs: current.inMs, outMs: current.outMs, active: on)
        loopHoldUntil = now() + 0.4
        playback.setLooping(deck: deck, on: on)
    }

    /// Halves the loop length; an active loop is shortened from its in point.
    func halveLoop() { resizeLoop(LoopLength.halved(loopLength)) }

    func doubleLoop() { resizeLoop(LoopLength.doubled(loopLength)) }

    private func resizeLoop(_ beats: Double) {
        loopLength = beats
        guard let current = loop, current.active else { return }
        if let range = self.beats.beatLoopRange(snapTo: nil, atMs: current.inMs, beats: beats) {
            setLoop(inMs: range.inMs, outMs: range.outMs)
        } else if let track, track.bpmX100 > 0 {
            setLoop(inMs: current.inMs, outMs: current.inMs + beats * 60_000 / (Double(track.bpmX100) / 100))
        }
    }

    // MARK: Beat jump

    func jump(direction: Int) {
        guard isLoaded else { return }
        let target = BeatJump.target(
            fromMs: headMs, direction: direction, size: jumpSize, grid: beats,
            bpmX100: Double(track?.bpmX100 ?? 0), durationMs: durationSeconds * 1000)
        seek(toSeconds: target / 1000)
    }

    // MARK: Sync

    func setSynced(_ on: Bool) { synced = on && isLoaded }

    /// What a follower needs to know about this deck (`SyncDeck`).
    func syncState(at time: TimeInterval? = nil) -> SyncDeck {
        SyncDeck(
            bpmX100: Double(track?.bpmX100 ?? 0), tempo: tempo, playing: anchor.playing,
            position: position(at: time ?? now()), grid: beats)
    }

    /// PLAY held until the master's next beat: the engine counts `delayMs` in output frames.
    func playAfter(delayMs: Double) {
        guard isLoaded else { return }
        cue.latch()
        latchPad()
        rebase(playing: true)
        playback.playAfter(deck: deck, delayMs: delayMs)
    }

    // MARK: Key shift, metronome

    func setKeyShift(_ semitones: Int) {
        guard shiftsKey else { return }
        keyShift = min(max(semitones, -12), 12)
        playback.setKeyShift(deck: deck, semitones: Int8(keyShift))
    }

    func nudgeKeyShift(by delta: Int) { setKeyShift(keyShift + delta) }

    func toggleMetronome() {
        metronome.toggle()
        playback.setMetronome(deck: deck, on: metronome)
    }

    // MARK: Scrub

    /// The waveform was grabbed: the engine's audio follows the pointer until `scrubEnd`.
    func scrubBegin() {
        guard isLoaded, !scrubbing else { return }
        latchPad()
        cue.latch()
        scrubResume = anchor.playing
        scrubbing = true
        rebase(playing: false)
        playback.scrubBegin(deck: deck)
    }

    func scrub(toSeconds seconds: Double) {
        guard scrubbing else { return }
        let target = min(max(seconds, 0), durationSeconds)
        var next = anchor
        if next.sampleRate > 0 { next.frames = Int64((target * Double(next.sampleRate)).rounded()) }
        next.at = now()
        next.playing = false
        anchor = next
        playback.scrubTo(deck: deck, ms: target * 1000)
    }

    func scrubEnd() {
        guard scrubbing else { return }
        scrubbing = false
        tickHoldUntil = now() + 0.3
        playback.scrubEnd(deck: deck)
        if scrubResume { rebase(playing: true) }
        scrubResume = false
    }
}
