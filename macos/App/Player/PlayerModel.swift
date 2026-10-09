import AppKit
import Observation
import QuartzCore

/// The player: both decks, the mixer, the preview player, and the pump that carries the engine's
/// events to them. The layout says how many decks are drawn; deck B exists (and plays) whatever
/// it is.
@MainActor @Observable
final class PlayerModel {
    let playback: any PlaybackEngine
    let decks: [DeckModel]
    let preview: PreviewModel
    /// The mixer strip, the master level, the limiter and the output: owned here so they are
    /// pushed to the engine at launch whether or not any layout draws them.
    let mixer: MixerModel
    let master: MasterModel
    let limiter: LimiterModel
    let audio: AudioSettingsModel

    /// What the decks take of the window. Persisted (default one deck).
    var layout: PlayerLayout {
        didSet {
            guard layout != oldValue else { return }
            if layout != .browser { lastDeckLayout = layout }
            if persistsLayout {
                defaults.set(layout.rawValue, forKey: PlayerLayout.key)
                defaults.set(lastDeckLayout.rawValue, forKey: "player.lastDeckLayout")
            }
            // Loading a key-shifted or synced deck in a layout without the second deck is fine;
            // but a sync light on a deck that is no longer drawn would be invisible.
            if layout.deckCount < 2 { for deck in decks { deck.setSynced(false) } }
        }
    }
    /// The layout to come back to from the full browser.
    private(set) var lastDeckLayout: PlayerLayout
    /// Dev launches (`RBXPORT_LAYOUT`) must not rewrite the real preference.
    @ObservationIgnored var persistsLayout = true

    /// The deck panel above the browser is drawn: every layout but the full browser.
    var panelOpen: Bool {
        get { layout != .browser }
        set { layout = newValue ? lastDeckLayout : .browser }
    }

    /// The one-deck panel's height in points, within `panelHeightRange`. Persisted.
    var panelHeight: Double {
        didSet { if panelHeight != oldValue { defaults.set(panelHeight, forKey: "player.height") } }
    }
    static let panelHeightRange = 300.0...520.0
    /// The two-deck panel's height. Persisted.
    var dualPanelHeight: Double {
        didSet { if dualPanelHeight != oldValue { defaults.set(dualPanelHeight, forKey: "player.dualHeight") } }
    }
    static let dualPanelHeightRange = 400.0...680.0
    /// The simple player is one fixed strip.
    static let simplePanelHeight = 104.0

    /// The height of the panel the layout draws.
    var currentPanelHeight: Double {
        get {
            switch layout {
            case .two: dualPanelHeight
            case .simple: Self.simplePanelHeight
            case .one, .browser: panelHeight
            }
        }
        set {
            switch layout {
            case .two: dualPanelHeight = min(max(newValue, Self.dualPanelHeightRange.lowerBound), Self.dualPanelHeightRange.upperBound)
            case .one: panelHeight = min(max(newValue, Self.panelHeightRange.lowerBound), Self.panelHeightRange.upperBound)
            case .simple, .browser: break
            }
        }
    }

    /// DUAL CONTROL: one zoom and one jump size for both decks. Persisted.
    var dualControl: Bool {
        didSet {
            guard dualControl != oldValue else { return }
            defaults.set(dualControl, forKey: "player.dualControl")
            // Switching it on takes deck A's values for both.
            if dualControl { link(from: .a) }
        }
    }

    /// The deck the other follows when BEAT SYNC is lit. Only one: that is what MASTER means.
    private(set) var syncMaster = Deck.a

    /// A transient message for the deck panel (the output could not open, a preview failed).
    private(set) var notice: String?
    /// The master meters as of the last update; the VU meters of the next slice read it.
    @ObservationIgnored private(set) var meters: Meters?
    /// When `meters` arrived, on the player's clock, for the meters' fall.
    @ObservationIgnored private(set) var metersAt: TimeInterval = 0
    @ObservationIgnored private let now: () -> TimeInterval

    @ObservationIgnored private let backend: any BackendProtocol
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    /// Called for the sleeve of an empty simple player: load what the browser has selected.
    @ObservationIgnored var loadSelected: (() -> Void)?
    /// Which deck a held CUE key or hot cue key went down on, so letting go reaches it even if
    /// Shift was released first.
    @ObservationIgnored private var cueDeck = Deck.a
    @ObservationIgnored private var padDeck = Deck.a

    var deckA: DeckModel { decks[0] }
    var deckB: DeckModel { decks[1] }

    init(
        backend: any BackendProtocol, waveforms: WaveformService, artwork: ArtworkService, defaults: UserDefaults,
        now: @escaping () -> TimeInterval = CACurrentMediaTime
    ) {
        self.backend = backend
        self.defaults = defaults
        self.now = now
        playback = backend.playback
        decks = [Deck.a, Deck.b].map {
            DeckModel(
                deck: $0, playback: backend.playback, waveforms: waveforms, artworks: artwork, backend: backend,
                defaults: defaults, now: now)
        }
        preview = PreviewModel(playback: backend.playback, now: now)
        // The stored layout; before layouts, "Show Player" off was the full browser.
        let stored = defaults.string(forKey: PlayerLayout.key).flatMap(PlayerLayout.init)
        let legacyHidden = defaults.object(forKey: "player.open") as? Bool == false
        let initial = stored ?? (legacyHidden ? .browser : .default)
        layout = initial
        var last = initial == .browser ? PlayerLayout.one : initial
        if initial == .browser, let remembered = defaults.string(forKey: "player.lastDeckLayout").flatMap(PlayerLayout.init),
            remembered != .browser
        {
            last = remembered
        }
        lastDeckLayout = last
        panelHeight = min(max(defaults.object(forKey: "player.height") as? Double ?? 360, Self.panelHeightRange.lowerBound), Self.panelHeightRange.upperBound)
        dualPanelHeight = min(max(defaults.object(forKey: "player.dualHeight") as? Double ?? 480, Self.dualPanelHeightRange.lowerBound), Self.dualPanelHeightRange.upperBound)
        dualControl = defaults.object(forKey: "player.dualControl") as? Bool ?? false
        metronomeSound = min(max(defaults.object(forKey: "player.metronomeSound") as? Int ?? 2, 1), 3)
        // Read the engine's mixer back; push the remembered master level, limiter and output
        // settings. None of this opens the audio output.
        mixer = MixerModel(playback: backend.playback)
        master = MasterModel(playback: backend.playback, defaults: defaults)
        limiter = LimiterModel(playback: backend.playback, defaults: defaults)
        audio = AudioSettingsModel(playback: backend.playback, defaults: defaults)
        wireDecks()
    }

    private func wireDecks() {
        for deck in decks {
            deck.onZoomChange = { [weak self, weak deck] bars in
                guard let self, let deck, self.dualControl else { return }
                self.other(than: deck.deck).applyLinked(zoomBars: bars)
            }
            deck.onJumpSizeChange = { [weak self, weak deck] size in
                guard let self, let deck, self.dualControl else { return }
                self.other(than: deck.deck).applyLinked(jumpSize: size)
            }
            deck.onSyncInputChange = { [weak self] in self?.refollow() }
        }
    }

    private func other(than which: Deck) -> DeckModel { which == .a ? decks[1] : decks[0] }

    /// DUAL CONTROL on: both decks take `source`'s zoom and jump size.
    private func link(from source: Deck) {
        let from = deck(source)
        let to = other(than: source)
        to.applyLinked(zoomBars: from.zoomBars)
        to.applyLinked(jumpSize: from.jumpSize)
    }

    /// Starts carrying the engine's events to the decks.
    func start() {
        guard pump == nil else { return }
        playback.setMetronomeSound(UInt8(metronomeSound))
        let events = playback.events
        pump = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
    }

    func deck(_ which: Deck) -> DeckModel { which == .a ? decks[0] : decks[1] }

    func handle(_ event: PlaybackEvent) {
        switch event {
        case .tick(let tick, let at):
            decks[0].apply(tick: tick.a, sampleRate: tick.sampleRate, at: at, shiftsKey: tick.shiftsKey)
            decks[1].apply(tick: tick.b, sampleRate: tick.sampleRate, at: at, shiftsKey: tick.shiftsKey)
        case .meters(let m):
            meters = m
            metersAt = now()
        case .deck(let e):
            deck(e.deck).handle(deckEvent: e)
            if let message = e.message, e.loadId == deck(e.deck).loadID { notice = "Could not load: \(message)" }
        case .reset:
            // The output was dropped for a device or rate change: put every loaded track back
            // where it was, and show the mixer the engine was rebuilt with.
            for deck in decks { deck.reloadAfterReset() }
            mixer.refresh()
        case .failure(let message):
            notice = message
        case .previewResult(let token, let error):
            preview.resolve(token: token, error: error)
            if let error { notice = "Preview failed: \(error)" }
        }
    }

    func dismissNotice() { notice = nil }

    // MARK: Loading

    /// Loads a track onto a deck. `row` is the table row it came from (it carries everything the
    /// deck shows); without one the track's details are fetched.
    /// Returns false when the layout has no such deck: loading B in a one-deck layout is refused.
    @discardableResult
    func load(trackID: String, row: Row?, into which: Deck = .a) -> Bool {
        if which == .b && layout.deckCount < 2 {
            notice = "Switch to the 2 PLAYER layout to load player 2."
            return false
        }
        // A track on a deck ends a preview, as a deck starting would.
        preview.stop()
        notice = nil
        if let row, row.id == trackID {
            deck(which).load(DeckTrack(row: row))
            return true
        }
        let backend = backend
        Task { [weak self] in
            do {
                let details = try await backend.trackDetails(id: trackID)
                self?.deck(which).load(DeckTrack(details: details))
            } catch {
                self?.notice = "Could not load: \(describe(error))"
            }
        }
        return true
    }

    // MARK: Keys

    /// The metronome click, 1 to 3; F9 cycles 2, 3, 1. Remembered across launches.
    private(set) var metronomeSound: Int {
        didSet { defaults.set(metronomeSound, forKey: "player.metronomeSound") }
    }

    func cycleMetronomeSound() {
        metronomeSound = metronomeSound == 3 ? 1 : metronomeSound == 2 ? 3 : 2
        playback.setMetronomeSound(UInt8(metronomeSound))
    }

    /// Carries out a key's meaning on a deck (A unless Shift made it B).
    func perform(_ action: PlayerKeyAction, on which: Deck = .a) {
        let d = deck(which)
        switch action {
        case .togglePlay: togglePlay(which)
        case .cueDown:
            cueDeck = which
            d.cuePressed()
        case .cueUp: deck(cueDeck).cueReleased()
        case .quantize: d.toggleQuantize()
        case .memoryPrevious: d.callPreviousMemory()
        case .memoryNext: d.callNextMemory()
        case .memoryNumber(let n): d.callMemory(number: n)
        case .hotCueDown(let letter):
            padDeck = which
            d.padPressed(letter)
        case .hotCueUp: deck(padDeck).padReleased()
        case .loopIn: d.markLoopIn()
        case .loopOut: d.markLoopOut()
        case .reloop: d.reloopOrExit()
        case .beatLoop(let beats): d.beatLoop(beats)
        case .loopHalve: d.halveLoop()
        case .loopDouble: d.doubleLoop()
        case .jump(let direction): d.jump(direction: direction)
        case .zoom(let direction): d.zoom(direction: direction)
        case .masterTempo: d.toggleMasterTempo()
        case .tempoReset: d.resetTempo()
        case .bpmUp: d.nudgeTempo(steps: 1)
        case .bpmDown: d.nudgeTempo(steps: -1)
        case .beatSync: beatSync(which)
        case .metronomeSound: cycleMetronomeSound()
        case .swallow: break
        }
    }

    // MARK: Sync

    /// Makes `which` the deck the other follows. A master never follows, so its own light goes out.
    func setSyncMaster(_ which: Deck) {
        syncMaster = which
        deck(which).setSynced(false)
    }

    /// BEAT SYNC on a deck: lit, it matches the master's tempo and bar now and keeps following
    /// the tempo; pressed again, it lets go. Only in the two-deck layout, and never on the master.
    func beatSync(_ which: Deck) {
        guard layout.deckCount == 2, which != syncMaster else { return }
        let follower = deck(which)
        if follower.synced {
            follower.setSynced(false)
            return
        }
        let leader = deck(syncMaster)
        guard follower.isLoaded, leader.track != nil else { return }
        let state = follower.syncState()
        let (tempo, nudge) = SyncLogic.syncTo(leader: leader.syncState(), follower: state)
        follower.setTempo(tempo, bySync: true)
        // The nudge is measured against where the follower is now; the tempo does not move it.
        if abs(nudge) > 0.001 { follower.seek(toSeconds: state.position + nudge) }
        follower.setSynced(true)
    }

    /// While lit, a follower keeps the master's playing BPM: re-matched whenever it changes.
    func refollow() {
        guard layout.deckCount == 2 else { return }
        let leader = deck(syncMaster)
        let leaderBpm = Double(leader.track?.bpmX100 ?? 0) * leader.tempo
        guard leaderBpm > 0 else { return }
        for follower in decks where follower.deck != syncMaster && follower.synced {
            let fileBpm = Double(follower.track?.bpmX100 ?? 0)
            guard fileBpm > 0 else { continue }
            let tempo = SyncLogic.tempoFor(
                leader: SyncDeck(bpmX100: leaderBpm), follower: SyncDeck(bpmX100: fileBpm))
            if abs(tempo - follower.tempo) > 1e-4 { follower.setTempo(tempo, bySync: true) }
        }
    }

    /// PLAY. With BEAT SYNC lit and Q on, a stopped deck starts on the beat, as a CDJ with SYNC
    /// and QUANTIZE does: it is put on its own nearest beat and held until the master's next
    /// one lands. A master that is not running has no next beat to wait for, so the deck is
    /// lined up with it and started at once. Anything else simply toggles.
    func togglePlay(_ which: Deck) {
        let d = deck(which)
        if layout.deckCount == 2, d.isLoaded, !d.isPlaying, d.synced, d.quantize, which != syncMaster {
            let leader = deck(syncMaster).syncState()
            let follower = d.syncState()
            if leader.playing, let wait = SyncLogic.beatWait(leader: leader), !d.beats.isEmpty {
                let onBeat = d.beats.nearestBeatMs(follower.position * 1000) / 1000
                if abs(onBeat - follower.position) > 0.001 { d.seek(toSeconds: onBeat) }
                d.playAfter(delayMs: wait * 1000)
                return
            }
            let nudge = SyncLogic.beatNudgeFor(leader: leader, follower: follower)
            if abs(nudge) > 0.001 { d.seek(toSeconds: follower.position + nudge) }
        }
        d.togglePlay()
    }

    // MARK: Meters

    /// A deck's own channel peak from the last meter update, 0 when it is stale.
    func channelPeak(_ which: Deck) -> Double {
        guard let meters, now() - metersAt < 0.1 else { return 0 }
        return Double(which == .a ? meters.deckAPeak : meters.deckBPeak)
    }

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            // AppKit delivers local monitors on the main thread.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self.handleKey(event) }
            return consumed ? nil : event
        }
        // Losing the keyboard mid-press must not leave CUE or a pad held.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.decks.forEach {
                    $0.cueReleased()
                    $0.padReleased()
                }
            }
        }
    }

    func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let responder = event.window?.firstResponder
        let typing = responder is NSTextView || responder is NSTextField
        // The sidebar's outline uses left and right to fold its folders.
        if responder is NSOutlineView, event.keyCode == PlayerKeymap.left || event.keyCode == PlayerKeymap.right {
            return false
        }
        let raw = KeyChord(
            character: event.charactersIgnoringModifiers?.lowercased() ?? "", keyCode: event.keyCode,
            modifiers: event.modifierFlags)
        // Shift is deck B, in the two-deck layout only.
        guard let (which, chord) = PlayerKeymap.route(raw, twoDecks: layout.deckCount == 2) else { return false }
        guard
            let action = PlayerKeymap.action(
                for: chord, isUp: event.type == .keyUp, isRepeat: event.type == .keyDown && event.isARepeat,
                typing: typing, loaded: deck(which).isLoaded),
            // Deck B has no metronome-sound key (F9) of its own.
            !(which == .b && action == .metronomeSound)
        else { return false }
        perform(action, on: which)
        return true
    }
}
