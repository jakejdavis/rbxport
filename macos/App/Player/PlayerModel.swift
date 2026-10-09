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
    /// A transient message for the deck panel (the output could not open, a preview failed).
    private(set) var notice: String?
    /// The master meters as of the last update; the VU meters of the next slice read it.
    @ObservationIgnored private(set) var meters: Meters?

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
        playback = backend.playback
        decks = [Deck.a, Deck.b].map {
            DeckModel(deck: $0, playback: backend.playback, waveforms: waveforms, artworks: artwork, defaults: defaults, now: now)
        }
        preview = PreviewModel(playback: backend.playback, now: now)
        panelOpen = defaults.object(forKey: "player.open") as? Bool ?? true
    }

    /// Starts carrying the engine's events to the decks.
    func start() {
        guard pump == nil else { return }
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
            decks[0].apply(tick: tick.a, sampleRate: tick.sampleRate, at: at)
            decks[1].apply(tick: tick.b, sampleRate: tick.sampleRate, at: at)
        case .meters(let m):
            meters = m
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

    enum KeyCommand: Equatable { case togglePlay, cueDown, cueUp, swallow }

    /// What a key event means to the player, or nil to pass it on. Space toggles play/pause on
    /// deck A and C is the held CUE, unless a text field has focus. Modifier chords belong to
    /// the menus (Shift is deck B, a later slice).
    nonisolated static func command(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isUp: Bool, isRepeat: Bool, typing: Bool
    ) -> KeyCommand? {
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch (keyCode, isUp) {
        case (49, false): return typing ? nil : (isRepeat ? .swallow : .togglePlay)
        case (49, true): return typing ? nil : .swallow
        case (8, false): return typing ? nil : (isRepeat ? .swallow : .cueDown)
        // Releasing CUE is honoured even when focus has moved to a text field.
        case (8, true): return .cueUp
        default: return nil
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
        // Losing the keyboard mid-press must not leave CUE held.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deckA.cueReleased() }
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
        guard
            let command = Self.command(
                keyCode: event.keyCode, modifiers: event.modifierFlags, isUp: event.type == .keyUp,
                isRepeat: event.type == .keyDown && event.isARepeat, typing: typing)
        else { return false }
        switch command {
        case .togglePlay: deckA.togglePlay()
        case .cueDown: deckA.cuePressed()
        case .cueUp: deckA.cueReleased()
        case .swallow: break
        }
        return true
    }
}
