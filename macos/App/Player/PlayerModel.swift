import AppKit
import Observation
import QuartzCore

/// The player: both decks, the preview player, and the pump that carries the engine's events
/// to them. Slice 3a shows deck A; deck B exists and is fed, for the dual layouts to come.
@MainActor @Observable
final class PlayerModel {
    let playback: any PlaybackEngine
    let decks: [DeckModel]
    let preview: PreviewModel

    /// The deck panel above the browser is shown. Persisted.
    var panelOpen: Bool {
        didSet { if panelOpen != oldValue { defaults.set(panelOpen, forKey: "player.open") } }
    }
    /// The deck panel's height in points, within `panelHeightRange`. Persisted.
    var panelHeight: Double {
        didSet { if panelHeight != oldValue { defaults.set(panelHeight, forKey: "player.height") } }
    }
    static let panelHeightRange = 300.0...520.0

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

    var deckA: DeckModel { decks[0] }

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
        panelOpen = defaults.object(forKey: "player.open") as? Bool ?? true
        panelHeight = min(max(defaults.object(forKey: "player.height") as? Double ?? 360, Self.panelHeightRange.lowerBound), Self.panelHeightRange.upperBound)
        metronomeSound = min(max(defaults.object(forKey: "player.metronomeSound") as? Int ?? 2, 1), 3)
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
            for deck in decks { deck.reloadAfterReset() }
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
    func load(trackID: String, row: Row?, into which: Deck = .a) {
        // A track on a deck ends a preview, as a deck starting would.
        preview.stop()
        notice = nil
        if let row, row.id == trackID {
            deck(which).load(DeckTrack(row: row))
            return
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

    /// Carries out a key's meaning on deck A.
    func perform(_ action: PlayerKeyAction) {
        let a = deckA
        switch action {
        case .togglePlay: a.togglePlay()
        case .cueDown: a.cuePressed()
        case .cueUp: a.cueReleased()
        case .quantize: a.toggleQuantize()
        case .memoryPrevious: a.callPreviousMemory()
        case .memoryNext: a.callNextMemory()
        case .memoryNumber(let n): a.callMemory(number: n)
        case .hotCueDown(let letter): a.padPressed(letter)
        case .hotCueUp: a.padReleased()
        case .loopIn: a.markLoopIn()
        case .loopOut: a.markLoopOut()
        case .reloop: a.reloopOrExit()
        case .beatLoop(let beats): a.beatLoop(beats)
        case .loopHalve: a.halveLoop()
        case .loopDouble: a.doubleLoop()
        case .jump(let direction): a.jump(direction: direction)
        case .zoom(let direction): a.zoom(direction: direction)
        case .masterTempo: a.toggleMasterTempo()
        case .tempoReset: a.resetTempo()
        case .bpmUp: a.nudgeTempo(steps: 1)
        case .bpmDown: a.nudgeTempo(steps: -1)
        case .metronomeSound: cycleMetronomeSound()
        case .swallow: break
        }
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
                self?.deckA.cueReleased()
                self?.deckA.padReleased()
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
        let chord = KeyChord(
            character: event.charactersIgnoringModifiers?.lowercased() ?? "", keyCode: event.keyCode,
            modifiers: event.modifierFlags)
        guard
            let action = PlayerKeymap.action(
                for: chord, isUp: event.type == .keyUp, isRepeat: event.type == .keyDown && event.isARepeat,
                typing: typing, loaded: deckA.isLoaded)
        else { return false }
        perform(action)
        return true
    }
}
