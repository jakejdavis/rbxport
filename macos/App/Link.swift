import AppKit
import Foundation
import Observation

// MARK: - Preferences

/// How the player list is sorted when a CDJ browses the key menu.
enum LinkKeySort: String, CaseIterable, Sendable {
    /// Abm, B, Ebm, F#, Bbm ... (the default)
    case musical
    /// A, Ab, B ...
    case alphabetical
}

/// The LINK preferences, kept in the store under the names the React app used (`djSystem.*`).
@MainActor struct LinkPrefs {
    let store: PreferencesStore

    /// The chosen interface name; nil is Automatic.
    var interface: String? {
        get { store.linkInterface }
        nonmutating set { store.linkInterface = newValue }
    }

    /// Off unless the person turned it on.
    var autoJoin: Bool {
        get { store.autoJoinLink }
        nonmutating set { store.autoJoinLink = newValue }
    }

    var keySort: LinkKeySort {
        get { store.linkKeySort }
        nonmutating set { store.linkKeySort = newValue }
    }
}

// MARK: - Auto-join

/// Starts LINK once when a player or mixer first becomes available (`useAutoJoinLink.ts`).
///
/// A person can still disconnect by hand: the same visible devices do not trigger another attempt
/// until they leave and return. A failed start is not repeated while the network stays the same.
struct AutoJoinTracker: Equatable {
    private(set) var attempted: String?

    /// Players and mixers, as one comparable signature; empty when there are none.
    static func signature(of peers: [LinkPeer]) -> String {
        peers.filter { $0.kind == .player || $0.kind == .mixer }
            .map { "\($0.kind):\($0.number):\($0.address)" }
            .sorted().joined(separator: "|")
    }

    /// Whether to start LINK now. Remembers the attempt when it says yes.
    mutating func shouldStart(enabled: Bool, peers: [LinkPeer], status: LinkStatus?, busy: Bool) -> Bool {
        let available = Self.signature(of: peers)
        if !enabled || available.isEmpty {
            attempted = nil
            return false
        }
        if status?.on == true {
            attempted = available
            return false
        }
        guard !busy, let status, status.problem == nil, attempted != available else { return false }
        attempted = available
        return true
    }
}

// MARK: - Watcher policy

/// Whether the passive listener on UDP 50000 starts at launch.
enum LinkWatcherPolicy {
    /// Off when `RBXPORT_NO_LINK_WATCHER=1`, and under XCTest (which must never bind a port).
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if environment["RBXPORT_NO_LINK_WATCHER"] == "1" { return false }
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil { return false }
        if NSClassFromString("XCTestCase") != nil { return false }
        return true
    }
}

// MARK: - Model

/// LINK as the window shows it: the session status, the devices heard, the preferences, and the
/// actions the strip and the Settings pane share.
@MainActor @Observable
final class LinkModel {
    /// Nil until the first status has been read.
    private(set) var status: LinkStatus?
    private(set) var peers: [LinkPeer] = []
    /// True while a start or stop is in flight.
    private(set) var busy = false
    /// What went wrong with the last action, for the pane.
    private(set) var error: String?
    /// A dev hook fed this model fake data: nothing talks to the backend and events are ignored.
    private(set) var isDemo = false

    var interface: String? { didSet { if interface != oldValue { prefs.interface = interface } } }
    var autoJoin: Bool {
        didSet {
            if autoJoin != oldValue {
                prefs.autoJoin = autoJoin
                evaluateAutoJoin()
            }
        }
    }
    var keySort: LinkKeySort { didSet { if keySort != oldValue { prefs.keySort = keySort } } }

    @ObservationIgnored private let backend: any BackendProtocol
    @ObservationIgnored private let prefs: LinkPrefs
    @ObservationIgnored private var tracker = AutoJoinTracker()
    @ObservationIgnored private var activation: Task<Void, Never>?
    /// Whether keys read in alphanumeric (Camelot) notation: the Device display preference.
    @ObservationIgnored var alphanumericKeys: () -> Bool = { false }
    /// Where a refusal is shown (the app's status notice).
    @ObservationIgnored var notify: (String) -> Void = { _ in }

    init(backend: any BackendProtocol, defaults: UserDefaults, store: PreferencesStore? = nil) {
        self.backend = backend
        prefs = LinkPrefs(store: store ?? PreferencesStore(defaults: defaults))
        interface = prefs.interface
        autoJoin = prefs.autoJoin
        keySort = prefs.keySort
    }

    // MARK: Derived

    var isOn: Bool { status?.on ?? false }

    /// Off with a reason it cannot come on (rekordbox holds the ports; the link went down).
    var isBlocked: Bool { status.map { !$0.on && $0.problem != nil } ?? false }

    /// Players and mixers heard before LINK is on. A source of our own is not something to link to.
    var otherDevices: [LinkPeer] { peers.filter { $0.kind == .player || $0.kind == .mixer } }

    /// The strip shows while LINK is on, or when something is there to link to.
    var stripVisible: Bool { isOn || !otherDevices.isEmpty }

    var players: [LinkPlayer] { status?.players ?? [] }
    var canTakeTempo: Bool { players.contains { $0.master } }

    /// Decks left of the mixer, the mixers, then the decks right of them: rekordbox seats the mixer
    /// between the players.
    var seating: (left: [LinkPlayer], mixers: [LinkPlayer], right: [LinkPlayer]) {
        let decks = players.filter { $0.kind == .player }
        let half = (decks.count + 1) / 2
        return (Array(decks.prefix(half)), players.filter { $0.kind != .player }, Array(decks.dropFirst(half)))
    }

    /// Hover text for the LINK button.
    var buttonHelp: String {
        if isBlocked { return L10n.t("PRO DJ LINK is unavailable. Click to see why.") }
        if isOn { return L10n.t("PRO DJ LINK is on. Players on the network can browse and play this library. Click to turn it off.") }
        let count = otherDevices.count
        return count == 1
            ? L10n.t("1 device on the network. Turn PRO DJ LINK on to serve this library to it.")
            : "\(count) devices on the network. Turn PRO DJ LINK on to serve this library to them."
    }

    /// The pane's headline for the connection.
    var statusLabel: String {
        guard let status else { return error == nil ? L10n.t("Checking connection\u{2026}") : L10n.t("Unavailable") }
        if !status.on { return L10n.t("Disconnected") }
        switch status.state {
        case .up: return L10n.t("Connected")
        case .waiting: return L10n.t("Waiting for devices")
        case .down: return L10n.t("Connection lost")
        default: return L10n.t("Connecting\u{2026}")
        }
    }

    /// The reason to show, if any: an action's error, else why LINK is off.
    var problem: String? { error ?? status?.problem }

    // MARK: Events

    func handle(status new: LinkStatus) {
        guard !isDemo else { return }
        status = new
        error = nil
        evaluateAutoJoin()
    }

    func handle(peers new: [LinkPeer]) {
        guard !isDemo else { return }
        peers = new
        evaluateAutoJoin()
    }

    /// Reads status and peers again, for the start, the pane's poll and the app regaining focus
    /// (quitting rekordbox frees the ports without any LINK event).
    func refresh() async {
        guard !isDemo else { return }
        async let newStatus = backend.linkStatus()
        async let newPeers = backend.linkPeers()
        let (loadedStatus, loadedPeers) = await (newStatus, newPeers)
        // An action that began while the read was in flight has the newer word.
        guard !busy else { return }
        status = loadedStatus
        peers = loadedPeers
        evaluateAutoJoin()
    }

    /// Reads LINK's status again whenever the app comes to the front: quitting rekordbox frees the
    /// ports without any LINK event, and "unavailable" should clear without a restart.
    func refreshOnActivation() {
        guard activation == nil else { return }
        activation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await self?.refresh()
            }
        }
    }

    // MARK: Actions

    /// Turns LINK on or off, as the strip's button and the pane's Connect do.
    func toggle() async {
        if isOn { await stop() } else { await start() }
    }

    func start() async {
        guard !busy, !isDemo else { return }
        busy = true
        error = nil
        defer { busy = false }
        let result = await backend.startLinkExport(
            interface: interface, alphanumericKeys: alphanumericKeys(), alphabeticalKeys: keySort == .alphabetical)
        status = result
        evaluateAutoJoin()
    }

    func stop() async {
        guard !busy, !isDemo else { return }
        busy = true
        error = nil
        defer { busy = false }
        status = await backend.stopLinkExport()
        evaluateAutoJoin()
    }

    func setMaster(_ on: Bool) async {
        guard isOn, !isDemo else { return }
        status = await backend.linkSetMaster(on: on)
    }

    /// The master tempo moves a whole BPM at a time, as rekordbox's minus and plus do.
    func nudge(_ deltaBpm: Double) async {
        guard isOn, !isDemo else { return }
        status = await backend.linkNudgeMaster(deltaBpm: deltaBpm)
    }

    func takeMasterTempo() async {
        guard isOn, canTakeTempo, !isDemo else { return }
        status = await backend.linkTakeMasterTempo()
    }

    /// A dragged library track dropped on a player: tell that CDJ to load it. Only the first
    /// track is sent; a refusal (the player has not mounted the library yet) is shown.
    @discardableResult
    func drop(trackIDs: [String], onPlayer number: UInt8) async -> Bool {
        guard let id = trackIDs.first(where: { !$0.isEmpty && !$0.hasPrefix("file:") }), !isDemo else { return false }
        do {
            try await backend.linkLoadTrack(playerNumber: number, trackID: id)
            return true
        } catch {
            notify(describe(error))
            return false
        }
    }

    // MARK: Auto-join

    private func evaluateAutoJoin() {
        guard !isDemo else { return }
        if tracker.shouldStart(enabled: autoJoin, peers: peers, status: status, busy: busy) {
            Task { await start() }
        }
    }

    // MARK: Demo

    /// Dev hook (`RBXPORT_DEMO_LINK=1`): shows `status` and `peers` with no backend traffic at all.
    func showDemo(status: LinkStatus, peers: [LinkPeer]) {
        isDemo = true
        self.status = status
        self.peers = peers
    }

    static let demoStatus = LinkStatus(
        on: true, problem: nil,
        interface: LinkInterface(name: "en5", address: "192.168.1.20", adapter: "USB 10/100/1000 LAN", connection: .wired),
        players: [
            LinkPlayer(
                number: 1, name: "CDJ-3000", kind: .player, address: "192.168.1.31",
                loaded: LinkLoaded(id: "1", title: "Midnight Drive", artist: "Aya"), playing: true, master: true, sync: true,
                cued: false, mounted: true),
            LinkPlayer(
                number: 2, name: "CDJ-3000", kind: .player, address: "192.168.1.32",
                loaded: LinkLoaded(id: "2", title: "Low Light", artist: "Kest"), playing: false, master: false, sync: true,
                cued: true, mounted: true),
            LinkPlayer(
                number: 3, name: "CDJ-3000", kind: .player, address: "192.168.1.33", loaded: nil, playing: false,
                master: false, sync: false, cued: false, mounted: true),
            LinkPlayer(
                number: 33, name: "DJM-V10", kind: .mixer, address: "192.168.1.40", loaded: nil, playing: false,
                master: false, sync: false, cued: false, mounted: false),
        ],
        interfaces: [
            LinkInterface(name: "en5", address: "192.168.1.20", adapter: "USB 10/100/1000 LAN", connection: .wired),
            LinkInterface(name: "en0", address: "192.168.1.14", adapter: L10n.t("Wi-Fi"), connection: .wireless),
        ],
        master: false, masterBpm: 124.0, state: .up, number: 17)
}
