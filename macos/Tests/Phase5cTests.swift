import AppKit
import Foundation
import Testing

@testable import rbxport

// Pro DJ Link. Nothing here can open a socket: the mock backend answers every call.

private func peer(_ number: UInt8, _ kind: LinkDeviceKind = .player, address: String = "10.0.0.5") -> LinkPeer {
    LinkPeer(number: number, name: "CDJ", kind: kind, address: address)
}

private func player(
    _ number: UInt8, kind: LinkDeviceKind = .player, loaded: LinkLoaded? = nil, playing: Bool = false,
    master: Bool = false, cued: Bool = false
) -> LinkPlayer {
    LinkPlayer(
        number: number, name: "CDJ", kind: kind, address: "10.0.0.\(number)", loaded: loaded, playing: playing,
        master: master, sync: false, cued: cued, mounted: true)
}

private func status(
    on: Bool, problem: String? = nil, players: [LinkPlayer] = [], state: LinkState? = nil, master: Bool = false, bpm: Double = 120
) -> LinkStatus {
    LinkStatus(
        on: on, problem: problem,
        interface: on ? LinkInterface(name: "en5", address: "10.0.0.2", adapter: nil, connection: .wired) : nil,
        players: players,
        interfaces: [
            LinkInterface(name: "en5", address: "10.0.0.2", adapter: "USB LAN", connection: .wired),
            LinkInterface(name: "en0", address: "10.0.1.2", adapter: "Wi-Fi", connection: .wireless),
        ], master: master, masterBpm: bpm, state: state ?? (on ? .up : .off), number: on ? 17 : nil)
}

@MainActor
private func makeModel(_ backend: MockBackend, defaults: UserDefaults? = nil) -> LinkModel {
    LinkModel(backend: backend, defaults: defaults ?? scratchDefaults())
}

// MARK: - Strip visibility and state

@MainActor
@Suite(.scratchDefaults)
struct LinkStripTests {
    @Test func hiddenUntilAPlayerOrMixerIsHeard() async {
        let model = makeModel(MockBackend())
        #expect(!model.stripVisible, "before any status")
        model.handle(status: status(on: false))
        #expect(!model.stripVisible)
        model.handle(peers: [peer(17, .rekordbox), peer(9, .device)])
        #expect(!model.stripVisible, "a source of our own, or an unknown device, is nothing to link to")
        model.handle(peers: [peer(2, .mixer)])
        #expect(model.stripVisible, "a mixer counts")
        model.handle(peers: [peer(1)])
        #expect(model.stripVisible)
    }

    @Test func visibleWhileOnEvenWithNoDevicesHeard() {
        let model = makeModel(MockBackend())
        model.handle(status: status(on: true, state: .waiting))
        #expect(model.stripVisible)
        model.handle(status: status(on: false))
        #expect(!model.stripVisible)
    }

    @Test func blockedIsOffWithAReason() {
        let model = makeModel(MockBackend())
        let reason = "rekordbox is running and holds the link ports. Quit it to turn LINK on."
        model.handle(status: status(on: false, problem: reason))
        #expect(model.isBlocked)
        #expect(model.buttonHelp == "PRO DJ LINK is unavailable. Click to see why.")
        #expect(model.problem == reason)
        #expect(!model.stripVisible, "nothing heard, nothing to show")
        model.handle(peers: [peer(1)])
        #expect(model.stripVisible, "a device is there: the strip says LINK is unavailable, and why")
        model.handle(status: status(on: true))
        #expect(!model.isBlocked)
    }

    @Test func buttonHelpCountsDevices() {
        let model = makeModel(MockBackend())
        model.handle(status: status(on: false))
        model.handle(peers: [peer(1)])
        #expect(model.buttonHelp.hasPrefix("1 device on the network."))
        model.handle(peers: [peer(1), peer(2, address: "10.0.0.6")])
        #expect(model.buttonHelp.hasPrefix("2 devices on the network."))
        model.handle(status: status(on: true))
        #expect(model.buttonHelp.hasPrefix("PRO DJ LINK is on."))
    }

    @Test func playersSitEitherSideOfTheMixer() {
        let model = makeModel(MockBackend())
        model.handle(status: status(on: true, players: [player(1), player(2), player(3), player(33, kind: .mixer)]))
        let seats = model.seating
        #expect(seats.left.map(\.number) == [1, 2])
        #expect(seats.mixers.map(\.number) == [33])
        #expect(seats.right.map(\.number) == [3])
    }

    @Test func takeTempoNeedsAMasterPlayer() {
        let model = makeModel(MockBackend())
        model.handle(status: status(on: true, players: [player(1), player(2)]))
        #expect(!model.canTakeTempo)
        model.handle(status: status(on: true, players: [player(1, master: true), player(2)]))
        #expect(model.canTakeTempo)
    }

    @Test func statusLabelsFollowTheState() {
        let model = makeModel(MockBackend())
        #expect(model.statusLabel == "Checking connection\u{2026}")
        model.handle(status: status(on: false))
        #expect(model.statusLabel == "Disconnected")
        model.handle(status: status(on: true, state: .waiting))
        #expect(model.statusLabel == "Waiting for devices")
        model.handle(status: status(on: true, state: .joining))
        #expect(model.statusLabel == "Connecting\u{2026}")
        model.handle(status: status(on: true, state: .up))
        #expect(model.statusLabel == "Connected")
        model.handle(status: status(on: true, state: .down))
        #expect(model.statusLabel == "Connection lost")
    }

    @Test func deviceRowsNameWhatEachPlayerIsDoing() {
        let loaded = LinkLoaded(id: "4", title: "T", artist: "A")
        #expect(LinkPane.deviceStatus(player(1)) == "Online")
        #expect(LinkPane.deviceStatus(player(1, loaded: loaded)) == "Loaded")
        #expect(LinkPane.deviceStatus(player(1, loaded: loaded, playing: true)) == "Playing")
        #expect(LinkPane.role(player(2)) == "player 2")
        #expect(LinkPane.role(player(33, kind: .mixer)) == "mixer 33")
        #expect(LinkPane.connection(.wired) == "Wired" && LinkPane.connection(.wireless) == "Wi-Fi" && LinkPane.connection(nil) == "Unknown")
    }
}

// MARK: - Actions

@MainActor
@Suite(.scratchDefaults)
struct LinkActionTests {
    @Test func theButtonStartsThenStops() async {
        let backend = MockBackend()
        let model = makeModel(backend)
        model.handle(status: status(on: false))
        await model.toggle()
        #expect(model.isOn)
        #expect(await backend.linkCalls() == ["start(auto,alphanumeric:false,alphabetical:false)"])
        await model.toggle()
        #expect(!model.isOn)
        #expect(await backend.linkCalls().last == "stop")
    }

    @Test func startUsesTheChosenInterfaceAndKeyPreferences() async {
        let backend = MockBackend()
        let model = makeModel(backend)
        model.interface = "en7"
        model.keySort = .alphabetical
        model.alphanumericKeys = { true }
        model.handle(status: status(on: false))
        await model.start()
        #expect(await backend.linkCalls() == ["start(en7,alphanumeric:true,alphabetical:true)"])
    }

    @Test func aRefusalLeavesLinkOffWithTheReason() async {
        let backend = MockBackend()
        let reason = "rekordbox is running and holds the link ports. Quit it to turn LINK on."
        await backend.scriptLink { $0.status = status(on: false, problem: reason) }
        let model = makeModel(backend)
        await model.refresh()
        #expect(model.isBlocked)
        await model.start()
        #expect(!model.isOn)
        #expect(model.status?.problem == reason)
        #expect(!model.busy)
    }

    @Test func busyBlocksASecondStart() async {
        let backend = MockBackend()
        let model = makeModel(backend)
        model.handle(status: status(on: false))
        async let first: Void = model.start()
        async let second: Void = model.start()
        _ = await (first, second)
        #expect(await backend.linkCalls().count == 1)
    }

    @Test func masterNudgeAndTakeTempoReachTheBackend() async {
        let backend = MockBackend()
        let model = makeModel(backend)
        await backend.scriptLink { $0.status = status(on: true, players: [player(1, master: true)], bpm: 124) }
        await model.refresh()
        await model.setMaster(true)
        #expect(model.status?.master == true)
        await model.nudge(1)
        #expect(model.status?.masterBpm == 125)
        await model.nudge(-1)
        #expect(model.status?.masterBpm == 124)
        await model.takeMasterTempo()
        #expect(await backend.linkCalls() == ["master(true)", "nudge(1.0)", "nudge(-1.0)", "takeTempo"])
    }

    @Test func controlsDoNothingWhileOff() async {
        let backend = MockBackend()
        let model = makeModel(backend)
        await model.refresh()
        await model.setMaster(true)
        await model.nudge(1)
        await model.takeMasterTempo()
        #expect(await backend.linkCalls().isEmpty)
    }

    @Test func takeTempoIsSkippedWhenNoPlayerIsMaster() async {
        let backend = MockBackend()
        let model = makeModel(backend)
        await backend.scriptLink { $0.status = status(on: true, players: [player(1)]) }
        await model.refresh()
        await model.takeMasterTempo()
        #expect(await backend.linkCalls().isEmpty)
    }

    @Test func droppedTracksLoadOnThePlayer() async {
        let backend = MockBackend()
        let model = makeModel(backend)
        await backend.scriptLink { $0.status = status(on: true, players: [player(2)]) }
        await model.refresh()
        let sent = await model.drop(trackIDs: ["", "file:/x.wav", "12", "13"], onPlayer: 2)
        #expect(sent)
        #expect(await backend.linkCalls() == ["load(2,12)"], "the first library track only")
    }

    @Test func aDropOfOnlyLooseFilesSendsNothing() async {
        let backend = MockBackend()
        let model = makeModel(backend)
        #expect(await model.drop(trackIDs: ["file:/x.wav"], onPlayer: 1) == false)
        #expect(await backend.linkCalls().isEmpty)
    }

    @Test func aRefusedLoadIsShown() async {
        let backend = MockBackend()
        let model = makeModel(backend)
        var shown: [String] = []
        model.notify = { shown.append($0) }
        await backend.scriptLink { $0.loadFailure = FfiError.Internal(message: "player 2 has not mounted the library yet", detail: nil) }
        #expect(await model.drop(trackIDs: ["5"], onPlayer: 2) == false)
        #expect(shown == ["player 2 has not mounted the library yet"])
    }

    @Test func eventsReplaceTheStatusAndPeers() {
        let model = makeModel(MockBackend())
        model.handle(status: status(on: true, players: [player(1, playing: true)]))
        #expect(model.players.first?.playing == true)
        model.handle(status: status(on: false))
        #expect(model.players.isEmpty)
        model.handle(peers: [peer(3)])
        #expect(model.peers.count == 1)
    }

    @Test func theDemoShowsFakeDataAndNeverTalksToTheBackend() async {
        let backend = MockBackend()
        let model = makeModel(backend)
        model.showDemo(status: LinkModel.demoStatus, peers: [])
        #expect(model.isOn && model.stripVisible)
        #expect(model.seating.mixers.count == 1)
        model.handle(status: status(on: false))
        #expect(model.isOn, "events are ignored in the demo")
        await model.toggle()
        await model.setMaster(true)
        await model.nudge(1)
        await model.refresh()
        #expect(await model.drop(trackIDs: ["1"], onPlayer: 1) == false)
        #expect(await backend.linkCalls().isEmpty)
    }
}

// MARK: - Settings model

@MainActor
@Suite(.scratchDefaults)
struct LinkSettingsTests {
    @Test func defaultsAreAutomaticOffAndMusical() {
        let model = makeModel(MockBackend())
        #expect(model.interface == nil)
        #expect(!model.autoJoin)
        #expect(model.keySort == .musical)
    }

    @Test func preferencesPersistUnderTheReactNames() {
        let defaults = scratchDefaults()
        let model = makeModel(MockBackend(), defaults: defaults)
        model.interface = "en5"
        model.autoJoin = true
        model.keySort = .alphabetical
        #expect(defaults.string(forKey: "djSystem.linkInterface") == "en5")
        #expect(defaults.bool(forKey: "djSystem.autoJoinLink"))
        #expect(defaults.string(forKey: "djSystem.linkKeySort") == "alphabetical")
        let reopened = makeModel(MockBackend(), defaults: defaults)
        #expect(reopened.interface == "en5" && reopened.autoJoin && reopened.keySort == .alphabetical)
        reopened.interface = nil
        #expect(defaults.object(forKey: "djSystem.linkInterface") == nil, "Automatic removes the key")
    }

    @Test func aMissingSavedInterfaceIsKept() async {
        let backend = MockBackend()
        await backend.scriptLink { $0.status = status(on: false) }
        let model = makeModel(backend)
        model.interface = "en9"
        await model.refresh()
        #expect(model.interface == "en9")
        #expect(model.status?.interfaces.contains { $0.name == "en9" } == false)
    }

    @Test func theSettingsPaneRefreshesOnlyReadsStatus() async {
        let backend = MockBackend()
        let model = makeModel(backend)
        await model.refresh()
        #expect(model.status != nil)
        #expect(await backend.linkCalls().isEmpty, "reading status never starts anything")
    }
}

// MARK: - Auto-join

/// `#expect` cannot call a mutating method, so the tracker sits in a class.
private final class JoinProbe {
    var tracker = AutoJoinTracker()
    func ask(enabled: Bool, peers: [LinkPeer], status: LinkStatus?, busy: Bool) -> Bool {
        tracker.shouldStart(enabled: enabled, peers: peers, status: status, busy: busy)
    }
}

@MainActor
@Suite(.scratchDefaults)
struct LinkAutoJoinTests {
    @Test func startsOnceWhenADeviceFirstAppears() {
        let probe = JoinProbe()
        let off = status(on: false)
        #expect(!probe.ask(enabled: true, peers: [], status: off, busy: false))
        #expect(probe.ask(enabled: true, peers: [peer(1)], status: off, busy: false))
        #expect(!probe.ask(enabled: true, peers: [peer(1)], status: off, busy: false), "the same devices: not again")
    }

    @Test func aManualStopDoesNotRestartUntilTheDevicesChange() {
        let probe = JoinProbe()
        let off = status(on: false)
        #expect(probe.ask(enabled: true, peers: [peer(1)], status: off, busy: false))
        #expect(!probe.ask(enabled: true, peers: [peer(1)], status: status(on: true), busy: false))
        #expect(!probe.ask(enabled: true, peers: [peer(1)], status: off, busy: false), "stopped by hand")
        #expect(probe.ask(enabled: true, peers: [peer(1), peer(2, address: "10.0.0.6")], status: off, busy: false), "a new device")
    }

    @Test func devicesLeavingResetsIt() {
        let probe = JoinProbe()
        let off = status(on: false)
        #expect(probe.ask(enabled: true, peers: [peer(1)], status: off, busy: false))
        #expect(!probe.ask(enabled: true, peers: [], status: off, busy: false))
        #expect(probe.ask(enabled: true, peers: [peer(1)], status: off, busy: false), "they came back")
    }

    @Test func respectsTheSwitchTheStatusAndAnInFlightStart() {
        let probe = JoinProbe()
        let off = status(on: false)
        #expect(!probe.ask(enabled: false, peers: [peer(1)], status: off, busy: false))
        #expect(!probe.ask(enabled: true, peers: [peer(1)], status: nil, busy: false), "status unknown")
        #expect(!probe.ask(enabled: true, peers: [peer(1)], status: status(on: false, problem: "rekordbox is running"), busy: false))
        #expect(!probe.ask(enabled: true, peers: [peer(1)], status: off, busy: true))
        #expect(probe.ask(enabled: true, peers: [peer(1)], status: off, busy: false), "none of those used up the attempt")
    }

    @Test func onlyPlayersAndMixersCount() {
        let probe = JoinProbe()
        let off = status(on: false)
        #expect(!probe.ask(enabled: true, peers: [peer(17, .rekordbox), peer(9, .device)], status: off, busy: false))
        #expect(probe.ask(enabled: true, peers: [peer(33, .mixer)], status: off, busy: false))
    }

    @Test func theModelStartsLinkWhenADeviceAppearsAndItIsOn() async {
        let backend = MockBackend()
        let model = makeModel(backend)
        model.handle(status: status(on: false))
        model.handle(peers: [peer(1)])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await backend.linkCalls().isEmpty, "auto-join is off by default")
        model.autoJoin = true
        #expect(await eventually { await backend.linkCalls().count == 1 })
        #expect(await eventually { model.isOn })
        // A stop by hand does not bring it back for the same device.
        await model.stop()
        model.handle(peers: [peer(1)])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await backend.linkCalls().filter { $0.hasPrefix("start") }.count == 1)
    }
}

// MARK: - Watcher and wiring

@MainActor
@Suite(.scratchDefaults)
struct LinkWiringTests {
    @Test func theWatcherPolicyHonoursTheSwitchAndXCTest() {
        #expect(LinkWatcherPolicy.isEnabled(environment: [:]) == false, "this process is a test run")
        #expect(!LinkWatcherPolicy.isEnabled(environment: ["RBXPORT_NO_LINK_WATCHER": "1"]))
        #expect(!LinkWatcherPolicy.isEnabled(environment: ["XCTestConfigurationFilePath": "/x"]))
        #expect(!LinkWatcherPolicy.isEnabled(environment: ["XCTestBundlePath": "/x"]))
    }

    @Test func appModelStartsTheWatcherOnlyWhenAllowed() async {
        let skipped = MockBackend(trackCount: 3)
        let quiet = AppModel(backend: skipped, layoutStore: isolatedStore())
        quiet.startsLinkWatcher = false
        quiet.start()
        await quiet.waitUntilSettled()
        #expect(await skipped.watcherStarts() == 0)

        let allowed = MockBackend(trackCount: 3)
        let loud = AppModel(backend: allowed, layoutStore: isolatedStore())
        loud.startsLinkWatcher = true
        loud.start()
        await loud.waitUntilSettled()
        #expect(await allowed.watcherStarts() == 1)
        #expect(await allowed.linkCalls().isEmpty, "launch never starts LINK")
    }

    @Test func linkEventsReachTheModel() async {
        let backend = MockBackend(trackCount: 3)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.startsLinkWatcher = false
        model.start()
        await model.waitUntilSettled()
        await model.handle(.linkPeers(peers: [peer(1)]))
        #expect(model.link.stripVisible)
        await model.handle(.linkStatus(status: status(on: true, players: [player(1, playing: true)])))
        #expect(model.link.isOn && model.link.players.count == 1)
    }

    @Test func aRefusedDropShowsInTheStatusNotice() async {
        let backend = MockBackend(trackCount: 3)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        await backend.scriptLink { $0.loadFailure = FfiError.Internal(message: "LINK is not running.", detail: nil) }
        _ = await model.link.drop(trackIDs: ["1"], onPlayer: 1)
        #expect(model.notice == "LINK is not running.")
    }
}
