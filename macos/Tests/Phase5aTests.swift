import AppKit
import Foundation
import Testing

@testable import rbxport

private func stick(
    _ name: String, free: UInt64 = 40, total: UInt64 = 100, fs: String = "FAT32", export: DeviceExport? = nil
) -> Device {
    Device(
        name: name, path: "/Volumes/\(name)", totalBytes: total, freeBytes: free, fileSystem: fs, removable: true,
        volumeId: "dev:1", export: export)
}

private func progress(_ path: String, _ state: ExportState, _ done: UInt32 = 0, _ total: UInt32 = 10, _ title: String = "") -> ExportProgress {
    ExportProgress(path: path, state: state, done: done, total: total, title: title)
}

private let tree: [TreeNode] = [
    TreeNode(id: "all", name: "All Tracks", kind: .allTracks, depth: 0, expanded: nil, childCount: 50),
    TreeNode(id: "playlists", name: "Playlists", kind: .collection, depth: 0, expanded: true, childCount: 4),
    TreeNode(id: "1", name: "Sets", kind: .folder, depth: 1, expanded: true, childCount: 2),
    TreeNode(id: "2", name: "Warm-up", kind: .playlist, depth: 2, expanded: nil, childCount: 3),
    TreeNode(id: "3", name: "Peak", kind: .smartPlaylist, depth: 2, expanded: nil, childCount: nil),
    TreeNode(id: "4", name: "Loose", kind: .playlist, depth: 1, expanded: nil, childCount: 1),
]

private func specs(_ rows: [MenuRow]) -> [MenuItemSpec] {
    rows.compactMap { row in
        if case .item(let item) = row { return item }
        return nil
    }
}

private func spec(_ rows: [MenuRow], _ title: String) -> MenuItemSpec? { specs(rows).first { $0.title == title } }

// MARK: - Pure rules

@MainActor
@Suite(.scratchDefaults)
struct DeviceRulesTests {
    private func slots() -> [MenuSlot] {
        [
            MenuSlot(id: 1, menuItem: 4, name: "TRACK", seq: 1, visible: true),
            MenuSlot(id: 2, menuItem: 1, name: "GENRE", seq: 2, visible: true),
            MenuSlot(id: 3, menuItem: 2, name: "ARTIST", seq: 3, visible: true),
            MenuSlot(id: 4, menuItem: 11, name: "KEY", seq: 0, visible: false),
            MenuSlot(id: 5, menuItem: 5, name: "BPM", seq: 0, visible: false),
        ]
    }

    @Test func activeIsInOrderAndInactiveIsAlphabetical() {
        #expect(DeviceSlots.active(slots()).map(\.name) == ["TRACK", "GENRE", "ARTIST"])
        #expect(DeviceSlots.inactive(slots()).map(\.name) == ["BPM", "KEY"])
    }

    @Test func activatingAppendsAndRenumbers() {
        let next = DeviceSlots.activate(slots(), id: 4)
        #expect(DeviceSlots.active(next).map(\.name) == ["TRACK", "GENRE", "ARTIST", "KEY"])
        #expect(DeviceSlots.active(next).map(\.seq) == [1, 2, 3, 4])
        #expect(DeviceSlots.activate(next, id: 4) == next, "already active: nothing moves")
    }

    @Test func deactivatingClosesUpButNeverRemovesAFixedRow() {
        let next = DeviceSlots.deactivate(.category, slots(), id: 2)
        #expect(DeviceSlots.active(next).map(\.name) == ["TRACK", "ARTIST"])
        #expect(DeviceSlots.active(next).map(\.seq) == [1, 2])
        #expect(next.first { $0.id == 2 }?.seq == 0)
        #expect(DeviceSlots.deactivate(.category, slots(), id: 1) == slots(), "TRACK is fixed in Category")
        #expect(DeviceSlots.isFixed(.sort, 25) && DeviceSlots.isFixed(.sort, 26) && !DeviceSlots.isFixed(.sort, 4))
    }

    @Test func shiftingSwapsNeighboursAndStopsAtTheEnds() {
        let down = DeviceSlots.shift(slots(), id: 2, by: 1)
        #expect(DeviceSlots.active(down).map(\.name) == ["TRACK", "ARTIST", "GENRE"])
        #expect(DeviceSlots.shift(slots(), id: 1, by: -1) == slots())
        #expect(DeviceSlots.shift(slots(), id: 3, by: 1) == slots())
        #expect(DeviceSlots.shift(slots(), id: 4, by: 1) == slots(), "a hidden row does not move")
    }

    @Test func alphabetShowsItsLongName() {
        let alphabet = MenuSlot(id: 9, menuItem: 26, name: "ALPHABET", seq: 2, visible: true)
        #expect(DeviceSlots.displayName(alphabet) == "ALPHABET/TRACK NAME")
        #expect(DeviceSlots.displayName(slots()[0]) == "TRACK")
    }

    @Test func exportPrefsPersistAndBuildTheOptions() {
        let defaults = scratchDefaults()
        let prefs = DeviceExportPrefs(defaults: defaults)
        #expect(!prefs.deleteUnlistedMusic && !prefs.ejectAfterSync && !prefs.maximumCompatibility)
        #expect(prefs.options().compatibility == nil && !prefs.options().ejectAfterSync)
        #expect(prefs.stickDefaults.waveformColor == .threeBand && prefs.stickDefaults.keyDisplay == .classic)
        prefs.deleteUnlistedMusic = true
        prefs.maximumCompatibility = true
        prefs.conversionFormat = .mp3
        let options = DeviceExportPrefs(defaults: defaults).options(ejectAfterSync: true)
        #expect(options.deleteUnlistedMusic && options.compatibility == .mp3 && options.ejectAfterSync)
        defaults.set("rgb", forKey: "djSystem.waveformColor")
        #expect(prefs.stickDefaults.waveformColor == .rgb)
    }

    @Test func theDemoGuardAcceptsOnlyTemporaryDirectories() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        #expect(DeviceDemoGuard.isTemporary(temp.path))
        #expect(!DeviceDemoGuard.isTemporary("/Volumes/DJ STICK"))
        #expect(!DeviceDemoGuard.isTemporary(NSHomeDirectory()))
        #expect(!DeviceDemoGuard.isTemporary("/"))
        #expect(!DeviceDemoGuard.isTemporary("/tmp"), "the temporary root itself is not a stick")
        #expect(DeviceDemoGuard.fakeVolumes(["RB_LITE_FAKE_VOLUMES": temp.path]) == [temp.path])
        #expect(DeviceDemoGuard.fakeVolumes(["RB_LITE_FAKE_VOLUMES": "\(temp.path):/Volumes/REAL"]) == nil)
        #expect(DeviceDemoGuard.fakeVolumes([:]) == nil)
    }

    @Test func aDraggedTrackIsOfferedToDevicesEvenWhenTheLibraryIsLocked() throws {
        let item = try #require(TrackDrag.pasteboardItem(id: "42", path: nil, canEdit: false))
        #expect(item.string(forType: .rbxportExportTracks) == "42")
        #expect(item.string(forType: .rbxportTracks) == nil)
        let locked = try #require(TrackDrag.pasteboardItem(id: "42", path: "/Music/a.mp3", canEdit: false))
        #expect(locked.string(forType: .rbxportExportTracks) == "42")
        // A loose Explorer file is not in the collection: there is nothing to export by id.
        let loose = try #require(TrackDrag.pasteboardItem(id: "file:/Music/x.mp3", path: "/Music/x.mp3", canEdit: false))
        #expect(loose.string(forType: .rbxportExportTracks) == nil)
    }
}

// MARK: - Progress, list and eject

@MainActor
@Suite(.scratchDefaults)
struct ExportProgressTests {
    @Test func jobsReportTheirStatusAndStopOnlyBeforeThePublish() {
        let jobs = ExportJobsModel()
        #expect(jobs.statusText == nil && !jobs.isActive && jobs.fraction == nil)
        jobs.handle(progress: progress("/Volumes/A", .preparing))
        #expect(jobs.statusText == "Preparing A\u{2026}")
        jobs.handle(progress: progress("/Volumes/A", .copying, 3, 10, "Track 003"))
        #expect(jobs.statusText == "Copying A: 3 of 10 \u{00B7} Track 003\u{2026}")
        #expect(jobs.canStop && jobs.fraction == 0.3 && jobs.fraction(for: "/Volumes/A") == 0.3)
        jobs.handle(progress: progress("/Volumes/A", .publishing, 10))
        #expect(!jobs.canStop, "after the databases are written the export finishes")
        #expect(jobs.fraction == 0.99, "held under 100% until done")
        jobs.handle(progress: progress("/Volumes/A", .done, 10))
        #expect(jobs.statusText == nil && !jobs.isActive && jobs.fraction == 1)
    }

    @Test func severalDevicesShareOneAggregate() {
        let jobs = ExportJobsModel()
        jobs.handle(progress: progress("/Volumes/A", .preparing))
        jobs.handle(progress: progress("/Volumes/B", .preparing))
        jobs.handle(progress: progress("/Volumes/A", .done, 10))
        jobs.handle(progress: progress("/Volumes/B", .copying, 5))
        #expect(jobs.activeJobs.map(\.path) == ["/Volumes/B"])
        #expect(jobs.fraction == 0.75)
        jobs.handle(progress: progress("/Volumes/A", .copying, 2))
        #expect(jobs.statusText == "Exporting to 2 devices: 35%")
    }

    @Test func aNewBatchReplacesTheFinishedOne() {
        let jobs = ExportJobsModel()
        jobs.handle(progress: progress("/Volumes/A", .done, 10))
        jobs.handle(sync: SyncProgress(path: "/Volumes/A", state: .done))
        jobs.handle(progress: progress("/Volumes/B", .preparing))
        #expect(jobs.jobs.keys.sorted() == ["/Volumes/B"])
        jobs.handle(sync: SyncProgress(path: "/Volumes/B", state: .writing))
        #expect(jobs.syncStates == ["/Volumes/B": .writing], "the first stick of a run drops the last run's outcomes")
        jobs.handle(sync: SyncProgress(path: "/Volumes/C", state: .writing))
        #expect(jobs.syncStates.count == 2, "its neighbours in the same run keep theirs")
        // Another stick joining the running batch keeps its neighbour.
        jobs.handle(progress: progress("/Volumes/C", .preparing))
        #expect(jobs.jobs.keys.sorted() == ["/Volumes/B", "/Volumes/C"])
    }

    @Test func failuresAndStoppedJobsAreNotActive() {
        let jobs = ExportJobsModel()
        jobs.handle(progress: progress("/Volumes/A", .preparing))
        jobs.handle(progress: progress("/Volumes/A", .failed, 0, 0, "Disk full"))
        #expect(!jobs.isActive(path: "/Volumes/A") && jobs.failure(for: "/Volumes/A") == "Disk full")
        jobs.handle(progress: progress("/Volumes/B", .preparing))
        jobs.handle(progress: progress("/Volumes/B", .cancelled, 2))
        #expect(!jobs.isActive(path: "/Volumes/B") && jobs.job(for: "/Volumes/B")?.state.label == "Stopped")
        jobs.handle(progress: progress("/Volumes/C", .preparing))
        jobs.handle(progress: progress("/Volumes/C", .failed, 0, 0, ""))
        #expect(jobs.failure(for: "/Volumes/C")?.hasPrefix("The export failed before the device could be verified") == true)
        jobs.clearFinished()
        #expect(jobs.jobs.keys.sorted() == [] || jobs.jobs.values.allSatisfy { $0.state.isActive })
    }

    @Test func activityChangesTellTheSidebar() {
        let jobs = ExportJobsModel()
        var calls = 0
        jobs.onActivityChange = { calls += 1 }
        jobs.handle(progress: progress("/Volumes/A", .preparing))
        jobs.handle(progress: progress("/Volumes/A", .copying, 1))
        #expect(calls == 1, "busy once")
        jobs.handle(progress: progress("/Volumes/A", .done, 10))
        #expect(calls == 2, "free again")
    }

    @Test func theSyncStateTracksWritingAndEjecting() {
        let jobs = ExportJobsModel()
        jobs.handle(sync: SyncProgress(path: "/Volumes/A", state: .writing))
        #expect(jobs.isSyncing(path: "/Volumes/A"))
        jobs.handle(sync: SyncProgress(path: "/Volumes/A", state: .done))
        #expect(!jobs.isSyncing(path: "/Volumes/A"))
    }

    @Test func theSummaryNamesWhatLanded() {
        let report = ExportReport(
            tracks: 5, playlists: 1, bytesCopied: 1, analysisFiles: 5, reused: 0, removed: 0, playlistsAdded: 1,
            playlistsRemoved: 0, skipped: ["x"], verified: true)
        #expect(ExportSummary.text(report, device: "A") == "Exported: 5 tracks on A, 1 playlist, 1 skipped (audio missing).")
    }

    @Test func deviceFormattingReadsLikeTheReactPanel() {
        let device = stick("A", free: 25, total: 100, fs: "exFAT", export: DeviceExport(tracks: 1, playlists: 2, ours: true, written: ""))
        #expect(device.hasUnusualFileSystem && !stick("B").hasUnusualFileSystem)
        #expect(device.usedFraction == 0.75)
        #expect(device.contentsText == "1 track, 2 playlists" && stick("B").contentsText == "No export")
        #expect(Device(name: "x", path: "/x", totalBytes: 0, freeBytes: 0, fileSystem: "", removable: true, volumeId: "", export: nil).spaceText == "")
    }
}

// MARK: - The model over a mock

@MainActor
@Suite(.scratchDefaults)
struct DeviceModelTests {
    private func ready(devices: [Device] = [stick("A"), stick("B")], unlocked: Bool = true) async -> (AppModel, MockBackend, StubDialogs) {
        let backend = MockBackend(trackCount: 50, nodes: tree)
        await backend.setDevices(devices)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.protectLibrary = !unlocked
        let stub = StubDialogs()
        model.dialogs = stub.dialogs
        model.start()
        #expect(await eventually { model.opened != nil && model.devices.devices.count == devices.count })
        return (model, backend, stub)
    }

    private func calls(_ backend: MockBackend) async -> [String] { await backend.deviceCalls5a() }

    @Test func theDeviceListFollowsTheCoreAndTheWatcherStartsOnce() async {
        let (model, backend, _) = await ready()
        #expect(model.devices.devices.map(\.name) == ["A", "B"])
        #expect(model.sidebar.section(.devices).children.map(\.id) == ["dev:/Volumes/A", "dev:/Volumes/B"])
        #expect(model.sidebar.section(.devices).children.allSatisfy { $0.isSelectable })
        #expect(model.sidebar.section(.devices).children[0].detail == "0.0 MB free")
        #expect(await eventually { await backend.watcherStartCount() == 1 })
        // A stick is pulled: the core says volumes changed, the list follows.
        await backend.setDevices([stick("B")])
        await backend.emit(.devicesChanged)
        #expect(await eventually { model.devices.devices.map(\.name) == ["B"] })
        #expect(model.sidebar.section(.devices).children.map(\.name) == ["B"])
        await backend.setDevices([])
        await backend.emit(.devicesChanged)
        #expect(await eventually { model.sidebar.section(.devices).children.map(\.name) == ["No devices"] })
        #expect(model.deviceTargets.isEmpty)
    }

    @Test func selectingADeviceOpensItsPanelAndPullingItClosesIt() async {
        let (model, backend, _) = await ready()
        await backend.scriptDevices { $0.settings["/Volumes/A"] = MockBackend.blankSettings() }
        model.selectNode("dev:/Volumes/A")
        #expect(model.selectedDevice?.name == "A")
        #expect(await eventually { model.devicePanel?.settings != nil })
        #expect(model.devicePanel?.path == "/Volumes/A")
        // It stays the same panel across a refresh, with its tab.
        model.devicePanel?.tab = .sort
        await model.refreshDevices()
        #expect(model.devicePanel?.tab == .sort)
        // Pulled: the selection falls back to All Tracks and the panel goes.
        await backend.setDevices([stick("B")])
        await backend.emit(.devicesChanged)
        #expect(await eventually { model.selectedNodeID == "all" })
        #expect(model.devicePanel == nil && model.selectedDevice == nil)
    }

    @Test func exportingAPlaylistCallsTheCoreAndShowsProgress() async {
        let (model, backend, _) = await ready()
        await backend.scriptDevices { $0.stepDelay = .milliseconds(30) }
        let task = Task { await model.exportPlaylist(id: "2", to: "/Volumes/A") }
        #expect(await eventually { model.exportJobs.isActive(path: "/Volumes/A") })
        #expect(model.exportJobs.statusText?.contains("A") == true)
        #expect(!model.devices.canEject(model.devices.device(path: "/Volumes/A")!), "busy while it writes")
        #expect(model.devices.canEject(model.devices.device(path: "/Volumes/B")!))
        let report = await task.value
        #expect(report?.tracks == 5)
        #expect(model.notice == "Exported: 5 tracks on A, 1 playlist.")
        #expect(await calls(backend).contains("exportPlaylist(2,/Volumes/A,delete:false)"))
        #expect(await eventually { !model.exportJobs.isActive })
        #expect(model.exportJobs.job(for: "/Volumes/A")?.state == .done)
        // The library was not touched: nothing was written through the gate.
        #expect(await backend.editLog.isEmpty)
    }

    @Test func exportingNeedsNoWriteAccessToTheLibrary() async {
        let (model, backend, _) = await ready(unlocked: false)
        #expect(model.isReadOnly)
        let report = await model.exportPlaylist(id: "2", to: "/Volumes/A")
        #expect(report != nil)
        #expect(await calls(backend).contains { $0.hasPrefix("exportPlaylist(2") })
    }

    @Test func aSecondExportToABusyDeviceIsRefusedWithoutAskingTheCore() async {
        let (model, backend, _) = await ready()
        await backend.emit(.exportProgress(progress: progress("/Volumes/A", .copying, 1)))
        #expect(await eventually { model.exportJobs.isActive(path: "/Volumes/A") })
        let refused = await model.exportPlaylist(id: "2", to: "/Volumes/A")
        #expect(refused == nil)
        #expect(model.notice == "An export to A is already running.")
        #expect(await calls(backend).isEmpty)
        // The other stick is free.
        #expect(await model.exportPlaylist(id: "2", to: "/Volumes/B") != nil)
    }

    @Test func anUnpluggedDeviceIsRefusedAndAFailureIsReported() async {
        let (model, backend, _) = await ready()
        #expect(await model.exportPlaylist(id: "2", to: "/Volumes/GONE") == nil)
        #expect(model.notice == "That device is no longer connected.")
        await backend.scriptDevices { $0.exportFailure = FfiError.Internal(message: "Disk full", detail: nil) }
        #expect(await model.exportPlaylist(id: "2", to: "/Volumes/A") == nil)
        #expect(model.notice == "Export failed: Disk full")
        await backend.scriptDevices {
            $0.exportFailure = FfiError.Cancelled(message: "Export stopped.", detail: nil)
        }
        _ = await model.exportPlaylist(id: "2", to: "/Volumes/A")
        #expect(model.notice == "Export stopped.")
    }

    @Test func exportTrackSendsCollectionTracksAndSkipsLooseFiles() async {
        let (model, backend, _) = await ready()
        _ = await model.exportTracks(["7", "file:/x/y.mp3", "9"], to: "/Volumes/B")
        #expect(await calls(backend).contains("exportTracks(7,9,/Volumes/B)"))
        #expect(await model.exportTracks(["file:/x/y.mp3"], to: "/Volumes/B") == nil)
        #expect(model.notice == "Import the file to the collection before exporting it to a device.")
    }

    @Test func stoppingAnExportAsksTheCoreAndTheMockEndsItCancelled() async {
        let (model, backend, _) = await ready()
        await backend.scriptDevices { $0.stepDelay = .milliseconds(60) }
        let task = Task { await model.exportPlaylist(id: "2", to: "/Volumes/A") }
        #expect(await eventually { model.exportJobs.canStop })
        model.cancelAllExports()
        #expect(await task.value == nil)
        #expect(await backend.cancelledPaths() == ["/Volumes/A"])
        #expect(model.notice == "Export stopped.")
        #expect(model.exportJobs.job(for: "/Volumes/A")?.state == .cancelled)
        #expect(!model.exportJobs.isActive)
    }

    @Test func ejectingIsRefusedWhileAnExportRunsAndWorksAfter() async {
        let (model, backend, _) = await ready()
        await backend.emit(.exportProgress(progress: progress("/Volumes/A", .verifying, 10)))
        #expect(await eventually { model.exportJobs.isActive(path: "/Volumes/A") })
        let refused = await model.eject(path: "/Volumes/A")
        #expect(refused == .refused(DevicesModel.busyMessage))
        #expect(model.notice == DevicesModel.busyMessage)
        #expect(await backend.ejectedPaths().isEmpty, "the core was never asked")
        await backend.emit(.exportProgress(progress: progress("/Volumes/A", .done, 10)))
        #expect(await eventually { !model.exportJobs.isActive })
        #expect(await model.eject(path: "/Volumes/A") == .ejected)
        #expect(model.notice == "A: Safely ejected.")
        #expect(await backend.ejectedPaths() == ["/Volumes/A"])
        #expect(await eventually { model.devices.devices.map(\.name) == ["B"] })
    }

    @Test func anEjectTheOSRefusesIsReported() async {
        let (model, backend, _) = await ready()
        await backend.scriptDevices { $0.ejectFailure = FfiError.Internal(message: "Resource busy", detail: nil) }
        #expect(await model.eject(path: "/Volumes/B") == .failed("Resource busy"))
        #expect(model.notice == "B: Could not eject. Resource busy")
        #expect(model.devices.devices.count == 2)
        #expect(await model.eject(path: "/Volumes/NOPE") == nil)
    }

    @Test func ejectingTheSelectedDeviceLeavesItsPanel() async {
        let (model, _, _) = await ready()
        model.selectNode("dev:/Volumes/A")
        #expect(model.devicePanel != nil)
        _ = await model.eject(path: "/Volumes/A")
        #expect(await eventually { model.selectedNodeID == "all" })
        #expect(model.devicePanel == nil)
    }

    @Test func theMenusOfferEveryDeviceAndGoGreyWithNone() async {
        let (model, _, _) = await ready()
        let targets = model.deviceTargets
        #expect(targets.map(\.name) == ["A", "B"])
        let playlist = ContextMenus.treeMenu(for: .playlist, devices: targets)!
        let export = spec(playlist, "Export Playlist")!
        #expect(export.isEnabled)
        #expect(specs(export.submenu!).first?.command == .exportToDevice("/Volumes/A"))
        #expect(!ContextMenus.treeMenu(for: .playlist)![0].isEnabled, "no device, no export")
        // Export Track: needs a selection of collection tracks.
        let trackRows = ContextMenus.trackMenu(.init(selectionCount: 2, devices: targets))
        let track = spec(trackRows, "Export Track")!
        #expect(track.isEnabled && track.submenu!.count == 2)
        let loose = ContextMenus.trackMenu(.init(selectionCount: 1, hasLoose: true, allLoose: true, devices: targets))
        #expect(spec(loose, "Export Track")?.isEnabled == false)
        // The device row: Eject goes grey while it is busy; Sync Manager is always there.
        let idle = ContextMenus.treeMenu(for: .device)!
        #expect(specs(idle).map(\.title) == ["Import from Device\u{2026}", "Eject", "Sync Manager\u{2026}"])
        let busy = ContextMenus.treeMenu(for: .device, deviceBusy: true)!
        #expect(spec(busy, "Eject")?.isEnabled == false)
    }

    @Test func menuCommandsReachTheExports() async {
        let (model, backend, _) = await ready()
        let node = model.sidebar.node(withID: "pl:2")!
        model.runTreeMenu(.exportToDevice("/Volumes/B"), on: node)  // routed by the outline to runDeviceMenu
        model.runDeviceMenu(.exportToDevice("/Volumes/B"), on: node)
        #expect(await eventually { await calls(backend).contains("exportPlaylist(2,/Volumes/B,delete:false)") })
        let device = model.sidebar.node(withID: "dev:/Volumes/A")!
        model.runDeviceMenu(.openSyncManager, on: device)
        #expect(model.syncWindowRequests == 1)
        model.runDeviceMenu(.ejectDevice, on: device)
        #expect(await eventually { await backend.ejectedPaths() == ["/Volumes/A"] })
    }

    @Test func theDeckMenuHandsItsTrackToTheExport() async {
        let (model, backend, _) = await ready()
        model.player.exportTrackToDevice?("12", "/Volumes/A")
        #expect(await eventually { await calls(backend).contains("exportTracks(12,/Volumes/A)") })
        #expect(model.player.deviceTargets?().map(\.name) == ["A", "B"])
    }

    @Test func aLateStartAdoptsTheCoresProgress() async {
        let backend = MockBackend(trackCount: 5, nodes: tree)
        await backend.setDevices([stick("A")])
        await backend.scriptDevices { $0.progressSnapshot = [progress("/Volumes/A", .copying, 4)] }
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.exportJobs.isActive(path: "/Volumes/A") })
    }
}

// MARK: - Device panel

@MainActor
@Suite(.scratchDefaults)
struct DevicePanelTests {
    private func panel(_ configure: @Sendable (inout MockDeviceScript) -> Void = { _ in }) async -> (DeviceSettingsModel, MockBackend) {
        let backend = MockBackend(trackCount: 5)
        await backend.scriptDevices(configure)
        let model = DeviceSettingsModel(path: "/Volumes/A", backend: backend)
        await model.load()
        return (model, backend)
    }

    @Test func loadingShowsWhatTheStickHolds() async {
        let (model, backend) = await panel()
        #expect(model.settings?.deviceName == "STICK" && model.settings?.hasLibrarySettings == true)
        #expect(await backend.deviceCalls5a() == ["deviceSettings(/Volumes/A)"])
    }

    @Test func everyChangeIsWrittenAndTheStickAnswersAreWhatIsShown() async {
        let (model, backend) = await panel()
        await model.setWaveformColor(.rgb)
        await model.setKeyDisplay(.alphanumeric)
        await model.setWaveformPosition(.left)
        let saved = await backend.savedSettings()
        #expect(saved.count == 3)
        #expect(saved.map(\.settings.waveformColor) == [.rgb, .rgb, .rgb])
        #expect(saved.last?.settings.keyDisplay == .alphanumeric && saved.last?.settings.waveformPosition == .left)
        #expect(model.settings?.waveformColor == .rgb)
        // Setting the same value again writes nothing.
        await model.setWaveformColor(.rgb)
        #expect(await backend.savedSettings().count == 3)
    }

    @Test func theNameIsTrimmedAndAnEmptyOneIsIgnored() async {
        let (model, backend) = await panel()
        await model.commitName("   FRIDAY   ")
        #expect(model.settings?.deviceName == "FRIDAY")
        await model.commitName("   ")
        await model.commitName("FRIDAY")
        #expect(await backend.savedSettings().count == 1)
        await model.commitName(String(repeating: "x", count: 100))
        #expect(model.settings?.deviceName.count == 64)
    }

    @Test func colorNamesAndTheSubColumnAreEdited() async {
        let (model, _) = await panel()
        await model.renameColor(id: 3, to: " Vocal ")
        #expect(model.settings?.colors.first { $0.id == 3 }?.name == "Vocal")
        await model.setSubColumn(5)
        #expect(model.settings?.subColumn == 5)
        await model.setSubColumn(nil)
        #expect(model.settings?.subColumn == nil)
    }

    @Test func theListTabsMoveRowsThroughTheRules() async {
        let (model, backend) = await panel()
        model.pickedSlot = 3  // hidden (menuItem 3)
        #expect(model.canActivate(.category) && !model.canDeactivate(.category))
        await model.activate(.category)
        #expect(DeviceSlots.active(model.settings!.categories).map(\.id) == [1, 2, 4, 3])
        model.pickedSlot = 4
        #expect(model.canShift(.category, by: -1) && model.canShift(.category, by: 1))
        await model.shift(.category, by: 1)
        #expect(DeviceSlots.active(model.settings!.categories).map(\.id) == [1, 2, 3, 4])
        model.pickedSlot = 3
        await model.deactivate(.category)
        #expect(DeviceSlots.active(model.settings!.categories).map(\.id) == [1, 2, 4])
        // TRACK is fixed in Category and stays.
        model.pickedSlot = 4
        #expect(!model.canDeactivate(.category))
        // A fixed sort cannot be taken out.
        model.pickedSlot = 1
        #expect(!model.canDeactivate(.sort))
        await model.deactivate(.sort)
        #expect(await backend.savedSettings().count == 3)
    }

    @Test func aStickWithoutALibraryOffersNoListEdits() async {
        let blank = {
            var settings = MockBackend.blankSettings()
            settings.hasLibrarySettings = false
            settings.hasDeviceLibrary = false
            return settings
        }()
        let (model, _) = await panel { $0.settings["/Volumes/A"] = blank }
        model.pickedSlot = 3
        #expect(!model.canActivate(.category) && !model.canShift(.category, by: 1))
    }

    @Test func aRefusedWriteReloadsWhatTheStickHolds() async {
        let (model, backend) = await panel()
        await backend.scriptDevices { $0.saveFailure = FfiError.Internal(message: "Read-only volume", detail: nil) }
        await model.setWaveformColor(.blue)
        #expect(model.error == "Read-only volume")
        #expect(model.settings?.waveformColor == .threeBand, "the panel shows the stick, not the wish")
    }

    @Test func quickChangesAreWrittenInOrder() async {
        let (model, backend) = await panel()
        async let one: Void = model.setWaveformColor(.blue)
        async let two: Void = model.setKeyDisplay(.alphanumeric)
        _ = await (one, two)
        await model.settle()
        let saved = await backend.savedSettings()
        #expect(saved.count == 2)
        #expect(saved.last?.settings.waveformColor == .blue && saved.last?.settings.keyDisplay == .alphanumeric)
    }
}

// MARK: - Sync Manager

@MainActor
@Suite(.scratchDefaults)
struct SyncManagerTests {
    private func ready(devices: [Device] = [stick("A"), stick("B")]) async -> (AppModel, MockBackend, StubDialogs) {
        let backend = MockBackend(trackCount: 50, nodes: tree)
        await backend.setDevices(devices)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        let stub = StubDialogs()
        model.dialogs = stub.dialogs
        model.start()
        #expect(await eventually { model.opened != nil && model.devices.devices.count == devices.count })
        return (model, backend, stub)
    }

    @Test func theTreeTicksLeavesAndFoldersFollowTheirChildren() async {
        let (model, _, _) = await ready()
        let sync = model.syncManager!
        #expect(sync.rows.map(\.name) == ["Sets", "Warm-up", "Peak", "Loose"])
        #expect(sync.rows.map(\.depth) == [0, 1, 1, 0])
        let sets = sync.rows[0]
        #expect(sync.tickState(sets) == .off)
        sync.toggle(sync.rows[1])
        #expect(sync.tickState(sets) == .mixed)
        sync.toggle(sets)
        #expect(sync.tickState(sets) == .on && sync.selectedPlaylists == ["2", "3"])
        sync.toggle(sets)
        #expect(sync.tickState(sets) == .off && sync.selectedPlaylists.isEmpty)
        sync.tickAll()
        #expect(sync.selectedPlaylists == ["2", "3", "4"])
        sync.toggleCollapsed(sets)
        #expect(sync.rows.map(\.name) == ["Sets", "Loose"])
        sync.clearTicks()
        #expect(sync.summaryText == "0 playlists \u{2192} 0 USB devices")
    }

    @Test func tickingADeviceRestoresItsLastSelection() async {
        let (model, backend, _) = await ready()
        await backend.scriptDevices {
            $0.syncStates["/Volumes/A"] = DeviceSyncState(
                selected: [SyncPlaylist(libraryId: "4", name: "Loose"), SyncPlaylist(libraryId: "99", name: "Gone")],
                onDevice: ["Loose"], libraries: [], automatic: false)
        }
        let sync = model.syncManager!
        sync.toggle(sync.rows[1])
        await sync.toggleDevice("/Volumes/A")
        #expect(sync.selectedPlaylists == ["2", "4"], "added to what was ticked; ids the library no longer has are dropped")
        #expect(sync.selectedDevices == ["/Volumes/A"])
        await sync.toggleDevice("/Volumes/A")
        #expect(sync.selectedDevices.isEmpty)
        #expect(sync.summaryText == "2 playlists \u{2192} 0 USB devices")
    }

    @Test func syncChecksFilesThenWritesEveryTickedDeviceAtOnce() async {
        let (model, backend, _) = await ready()
        let sync = model.syncManager!
        #expect(!sync.canSync)
        sync.tickAll()
        await sync.toggleDevice("/Volumes/A")
        await sync.toggleDevice("/Volumes/B")
        #expect(sync.canSync && sync.summaryText == "3 playlists \u{2192} 2 USB devices")
        await sync.sync()
        let log = await backend.deviceCalls5a()
        let validate = log.firstIndex(of: "validate(2,3,4)")
        let run = log.firstIndex(of: "sync(2,3,4 -> /Volumes/A,/Volumes/B,eject:false)")
        #expect(validate != nil && run != nil && validate! < run!)
        #expect(sync.results["/Volumes/A"] == "Sync complete." && sync.results["/Volumes/B"] == "Sync complete.")
        #expect(sync.statusLines == ["A: Sync complete.", "B: Sync complete."])
        #expect(!sync.isSyncing)
        #expect(await eventually { model.exportJobs.jobs.count == 2 && !model.exportJobs.isActive })
        #expect(model.exportJobs.syncStates["/Volumes/A"] == .done)
    }

    @Test func ejectAfterSyncIsPassedAndReported() async {
        let (model, backend, _) = await ready()
        let sync = model.syncManager!
        sync.ejectAfterSync = true
        #expect(model.exportPrefs.ejectAfterSync, "kept in the prefs")
        sync.tickAll()
        await sync.toggleDevice("/Volumes/A")
        await sync.sync()
        #expect(await backend.deviceCalls5a().contains("sync(2,3,4 -> /Volumes/A,eject:true)"))
        #expect(sync.statusLines == ["A: Safely ejected."], "the stick is gone from the list, so its row is too; the footer says what happened")
        #expect(await eventually { model.devices.devices.map(\.name) == ["B"] })
    }

    @Test func missingFilesAskFirstAndDecliningStopsTheSync() async {
        let (model, backend, stub) = await ready()
        await backend.scriptDevices {
            $0.missing = (1...12).map { MissingExportFile(title: "Song \($0)", path: "/gone/\($0).mp3") }
        }
        let sync = model.syncManager!
        sync.tickAll()
        await sync.toggleDevice("/Volumes/A")
        stub.confirms = false
        await sync.sync()
        #expect(stub.confirmed.count == 1)
        #expect(stub.confirmed[0].message == "12 files are missing")
        #expect(stub.confirmed[0].detail.contains("Song 10") && !stub.confirmed[0].detail.contains("Song 11"))
        #expect(stub.confirmed[0].detail.hasSuffix("\u{2026}and 2 more."))
        #expect(sync.statusLines == [SyncManagerModel.missingMessage])
        #expect(!(await backend.deviceCalls5a()).contains { $0.hasPrefix("sync(") })
        stub.confirms = true
        await sync.sync()
        #expect((await backend.deviceCalls5a()).contains { $0.hasPrefix("sync(") })
    }

    @Test func aDeviceThatVanishedBeforeTheRunIsSaidSo() async {
        let (model, backend, _) = await ready()
        let sync = model.syncManager!
        sync.tickAll()
        await sync.toggleDevice("/Volumes/A")
        await backend.setDevices([stick("B")])
        await sync.sync()
        #expect(sync.statusLines == [SyncManagerModel.goneMessage])
        #expect(sync.selectedDevices.isEmpty)
        #expect(!(await backend.deviceCalls5a()).contains { $0.hasPrefix("sync(") })
    }

    @Test func eachDevicesOutcomeIsReportedOnItsOwn() async {
        let (model, backend, _) = await ready()
        await backend.scriptDevices {
            $0.syncOverrides["/Volumes/A"] = SyncDeviceReport(
                path: "/Volumes/A", report: nil, error: "That device is no longer connected.", ejected: false, ejectError: nil)
            $0.syncOverrides["/Volumes/B"] = SyncDeviceReport(
                path: "/Volumes/B", report: $0.exportReport, error: nil, ejected: false,
                ejectError: "The sync was incomplete or could not be verified. Review it before ejecting.")
        }
        let sync = model.syncManager!
        sync.tickAll()
        await sync.toggleDevice("/Volumes/A")
        await sync.toggleDevice("/Volumes/B")
        await sync.sync()
        #expect(sync.results["/Volumes/A"] == "That device is no longer connected.")
        #expect(sync.results["/Volumes/B"]?.hasPrefix("Not ejected: The sync was incomplete") == true)
        let skipped = SyncDeviceReport(
            path: "x", report: ExportReport(tracks: 1, playlists: 1, bytesCopied: 0, analysisFiles: 0, reused: 0, removed: 0, playlistsAdded: 0, playlistsRemoved: 0, skipped: ["a", "b"], verified: true),
            error: nil, ejected: false, ejectError: nil)
        #expect(SyncManagerModel.text(for: skipped) == "Sync complete; 2 skipped (audio missing).")
    }

    @Test func progressAndCancelComeFromTheSharedJobs() async {
        let (model, backend, _) = await ready()
        await backend.scriptDevices { $0.stepDelay = .milliseconds(60) }
        let sync = model.syncManager!
        sync.tickAll()
        await sync.toggleDevice("/Volumes/A")
        let run = Task { await sync.sync() }
        #expect(await eventually { model.exportJobs.canStop && sync.progressLine != nil })
        #expect(sync.progressLine == "Writing to A\u{2026}")
        #expect(sync.isBusy("/Volumes/A") && !sync.isBusy("/Volumes/B"))
        #expect(!model.devices.canEject(model.devices.device(path: "/Volumes/A")!))
        await sync.cancelAll()
        await run.value
        #expect(await backend.cancelledPaths().contains("/Volumes/A"))
        #expect(sync.results["/Volumes/A"] == "Export stopped.")
        #expect(sync.progressLine == nil)
    }

    @Test func verifyReadsTheStickBack() async {
        let (model, backend, _) = await ready()
        let sync = model.syncManager!
        await sync.verify("/Volumes/A")
        #expect(sync.results["/Volumes/A"] == "Verified: 5 tracks, 1 playlists read back.")
        await backend.scriptDevices {
            $0.verifyAnswer = VerifyReport(tracks: 5, playlists: 1, missingAudio: ["a.wav"], errors: ["bad page"], ok: false)
        }
        await sync.verify("/Volumes/A")
        #expect(sync.results["/Volumes/A"] == "Verification found problems: bad page; Missing audio: a.wav")
        await backend.emit(.exportProgress(progress: progress("/Volumes/B", .copying, 1)))
        #expect(await eventually { model.exportJobs.isActive(path: "/Volumes/B") })
        let before = await backend.deviceCalls5a().count
        await sync.verify("/Volumes/B")
        #expect(await backend.deviceCalls5a().count == before, "not while it is being written")
    }

    @Test func ejectingFromTheWindowRefusesWhileBusyAndForgetsTheStickAfter() async {
        let (model, backend, _) = await ready()
        let sync = model.syncManager!
        await sync.toggleDevice("/Volumes/A")
        await backend.emit(.exportProgress(progress: progress("/Volumes/A", .copying, 1)))
        #expect(await eventually { model.exportJobs.isActive(path: "/Volumes/A") })
        await sync.eject("/Volumes/A")
        #expect(sync.results["/Volumes/A"] == DevicesModel.busyMessage)
        #expect(await backend.ejectedPaths().isEmpty)
        await backend.emit(.exportProgress(progress: progress("/Volumes/A", .done, 10)))
        #expect(await eventually { !model.exportJobs.isActive })
        await sync.eject("/Volumes/A")
        #expect(await backend.ejectedPaths() == ["/Volumes/A"])
        #expect(sync.selectedDevices.isEmpty && sync.results["/Volumes/A"] == nil)
        #expect(model.notice == "A: Safely ejected.")
    }

    @Test func theWindowIsOpenedByARequest() async {
        let (model, _, _) = await ready()
        #expect(model.syncWindowRequests == 0)
        model.openSyncManager()
        model.openSyncManager()
        #expect(model.syncWindowRequests == 2)
        #expect(SyncManagerScene.id == "sync-manager")
    }
}
