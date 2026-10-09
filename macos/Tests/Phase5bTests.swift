import Foundation
import Testing

@testable import rbxport

private func stick(_ name: String) -> Device {
    Device(
        name: name, path: "/Volumes/\(name)", totalBytes: 100, freeBytes: 40, fileSystem: "FAT32", removable: true,
        volumeId: "dev:1", export: nil)
}

private func usbReport(
    tracks: UInt32 = 0, histories: UInt32 = 0, settings: UInt32 = 0, skipped: UInt32 = 0, warnings: [String] = []
) -> UsbImportReport {
    UsbImportReport(tracks: tracks, histories: histories, settings: settings, skipped: skipped, warnings: warnings)
}

/// A small Music library: a folder of two playlists and a loose one.
private let musicPath = "/tmp/rbxport-test/Library.xml"
private func musicLibrary(path: String = musicPath) -> ItunesLibrary {
    ItunesLibrary(
        path: path,
        tree: [
            ItunesNode(id: "itunes:0", name: "Sets", isFolder: true, depth: 0, trackCount: nil),
            ItunesNode(id: "itunes:1", name: "Warm", isFolder: false, depth: 1, trackCount: 2),
            ItunesNode(id: "itunes:2", name: "Peak", isFolder: false, depth: 1, trackCount: 1),
            ItunesNode(id: "itunes:3", name: "Loose", isFolder: false, depth: 0, trackCount: 1),
        ])
}

private func musicTrack(_ id: String, _ title: String) -> ItunesTrack {
    ItunesTrack(id: id, title: title, artist: "Ann", path: "/tmp/\(title).wav", rating: 4, comment: "")
}

// MARK: - USB import sheet model

@MainActor
@Suite(.scratchDefaults)
struct UsbImportTests {
    private func makeModel(
        backend: MockBackend, defaults: UserDefaults? = nil, stub: StubDialogs = StubDialogs(),
        blocked: Set<UsbImportKind> = [], busy: Box<[Bool]> = Box([]), imported: Box<Int> = Box(0)
    ) -> UsbImportModel {
        UsbImportModel(
            path: "/Volumes/A", deviceName: "A", backend: backend,
            prefs: DeviceExportPrefs(defaults: defaults ?? scratchDefaults()), dialogs: { stub.dialogs },
            blockReason: { blocked.contains($0) ? "blocked \($0.rawValue)" : nil },
            busy: { busy.value.append($0) }, didImport: { imported.value += 1 })
    }

    @Test func theWordsForEachKindMatchTheReactWindow() {
        #expect(UsbImportModel.text(for: .cues, usbReport(tracks: 3, skipped: 1)) == "Updated 3 tracks; skipped 1.")
        #expect(UsbImportModel.text(for: .cues, usbReport(tracks: 1)) == "Updated 1 track.")
        #expect(UsbImportModel.text(for: .history, usbReport(histories: 2)) == "Imported 2 play-history entries.")
        #expect(UsbImportModel.text(for: .history, usbReport(histories: 1)) == "Imported 1 play-history entry.")
        #expect(UsbImportModel.text(for: .history, usbReport()) == "No new play-history entries.")
        #expect(UsbImportModel.text(for: .settings, usbReport(settings: 3)) == "Imported 3 CDJ/mixer settings files.")
        #expect(UsbImportModel.text(for: .settings, usbReport()) == "No CDJ/mixer settings files found.")
        #expect(UsbImportKind.allCases.map(\.writesLibrary) == [true, true, false])
    }

    @Test func ticksOpenAsReactDoesAndAreRemembered() async {
        let defaults = scratchDefaults()
        let model = makeModel(backend: MockBackend(), defaults: defaults)
        #expect(model.plan == [.cues, .history], "cues and history on, settings off")
        model.set(.settings, true)
        model.set(.cues, false)
        #expect(model.plan == [.history, .settings])
        let again = makeModel(backend: MockBackend(), defaults: defaults)
        #expect(again.plan == [.history, .settings], "the ticks come back with the same preferences")
        #expect(defaults.object(forKey: "usbExport.importButtonSettings") as? Bool == true)
    }

    @Test func protectionBlocksOnlyTheKindsThatWriteTheLibrary() {
        let model = makeModel(backend: MockBackend(), blocked: [.cues, .history])
        model.set(.settings, true)
        #expect(model.plan == [.settings])
        #expect(!model.isTicked(.cues))
        model.set(.cues, true)
        #expect(model.blocked(.cues) == "blocked cues")
        #expect(!model.isTicked(.cues), "a blocked kind cannot be ticked")
        let none = makeModel(backend: MockBackend(), blocked: [.cues, .history, .settings])
        #expect(!none.canRun)
    }

    @Test func cuesAskFirstAndDecliningDoesNothing() async {
        let backend = MockBackend()
        let stub = StubDialogs()
        stub.confirms = false
        let model = makeModel(backend: backend, stub: stub)
        await model.run()
        #expect(stub.confirmed.map(\.message) == [UsbImportModel.confirmMessage])
        #expect(stub.confirmed.first?.detail == "This replaces cues and grids for matching tracks in your library.")
        #expect(model.phase == .choosing)
        #expect(await backend.usbCalls().isEmpty)
    }

    @Test func aRunDoesEachKindAloneAndSumsWhatTheyBroughtIn() async {
        let backend = MockBackend()
        await backend.scriptImports {
            $0.usbByKind = [
                "cues": usbReport(tracks: 3, skipped: 1), "history": usbReport(histories: 2, warnings: ["History 'Set' was left on the USB."]),
                "settings": usbReport(settings: 1),
            ]
        }
        await backend.setProtectLibrary(false)
        let busy = Box<[Bool]>([])
        let imported = Box(0)
        let model = makeModel(backend: backend, busy: busy, imported: imported)
        model.set(.settings, true)
        await model.run()
        #expect(
            await backend.usbCalls() == [
                "importUSB(/Volumes/A,cues:true,history:false,settings:false)",
                "importUSB(/Volumes/A,cues:false,history:true,settings:false)",
                "importUSB(/Volumes/A,cues:false,history:false,settings:true)",
            ])
        #expect(model.phase == .finished && !model.failed)
        #expect(model.lines.map(\.text) == [
            "Updated 3 tracks; skipped 1.", "Imported 2 play-history entries.", "History 'Set' was left on the USB.",
            "Imported 1 CDJ/mixer settings file.",
        ])
        #expect(model.lines.map(\.level) == [.ok, .ok, .warning, .ok])
        #expect((model.totals.tracks, model.totals.histories, model.totals.settings, model.totals.skipped) == (3, 2, 1, 1))
        #expect(model.totals.warnings.count == 1)
        #expect(busy.value == [true, false])
        #expect(imported.value == 1)
        #expect(model.summaryTitle == "Import complete")
    }

    @Test func oneKindFailingDoesNotStopTheOthersAndCanBeRetried() async {
        let backend = MockBackend()
        await backend.scriptImports {
            $0.usbFailure["history"] = FfiError.Internal(message: "USB import: Could not read play history", detail: nil)
            $0.usbByKind["cues"] = usbReport(tracks: 1)
        }
        await backend.setProtectLibrary(false)
        let model = makeModel(backend: backend)
        await model.run()
        #expect(model.failed && model.phase == .finished)
        #expect(model.lines.map(\.level) == [.ok, .failed])
        #expect(model.lines[1].text == "Couldn\u{2019}t import play history. USB import: Could not read play history")
        #expect(model.summaryTitle == "Import finished with problems")
        model.reset()
        #expect(model.phase == .choosing && model.lines.isEmpty && !model.failed)
        #expect(model.plan == [.cues, .history], "Try Again keeps the ticks")
        #expect(model.totals.tracks == 0)
    }

    @Test func theCoresGateRefusalIsReportedAndSettingsStillRun() async {
        // The mock is protected by default; the sheet's own check is bypassed to see the core refuse.
        let backend = MockBackend()
        let model = makeModel(backend: backend)
        model.set(.settings, true)
        await model.run()
        #expect(model.lines.map(\.level) == [.failed, .failed, .ok])
        #expect(model.lines[0].text.hasSuffix("Editing is locked by Library Protection. Turn it off in Preferences to edit."))
        #expect(model.lines[2].text == "Imported 1 CDJ/mixer settings file.", "settings write no library row, so protection lets them through")
        #expect(model.failed)
    }

    // MARK: Through the app model

    private func ready(unlocked: Bool = true) async -> (AppModel, MockBackend, StubDialogs) {
        let backend = MockBackend(trackCount: 50)
        await backend.setDevices([stick("A"), stick("B")])
        await backend.scriptImports { $0.usbReport = usbReport(tracks: 2, histories: 1) }
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.protectLibrary = !unlocked
        let stub = StubDialogs()
        model.dialogs = stub.dialogs
        model.start()
        #expect(await eventually { model.opened != nil && model.devices.devices.count == 2 && (!unlocked || !model.isReadOnly) })
        return (model, backend, stub)
    }

    @Test func theSheetOpensForADeviceAndFollowsTheGate() async {
        let (model, _, _) = await ready(unlocked: false)
        model.openUsbImport(path: "/Volumes/A")
        let sheet = try! #require(model.usbImport)
        #expect(sheet.deviceName == "A")
        #expect(sheet.blocked(.cues) == "Turn off Library Protection to import cues and beat grids.")
        #expect(sheet.blocked(.history) == "Turn off Library Protection to import play history.")
        #expect(sheet.blocked(.settings) == nil)
        model.closeUsbImport()
        #expect(model.usbImport == nil)
        model.protectLibrary = false
        #expect(await eventually { !model.isReadOnly })
        model.openUsbImport(path: "/Volumes/A")
        #expect(model.usbImport?.blocked(.cues) == nil)
    }

    @Test func aGoneOrBusyDeviceIsRefusedWithAnExplanation() async {
        let (model, _, _) = await ready()
        model.openUsbImport(path: "/Volumes/Gone")
        #expect(model.usbImport == nil && model.notice == "That device is no longer connected.")
        model.exportJobs.handle(progress: ExportProgress(path: "/Volumes/B", state: .copying, done: 1, total: 5, title: "x"))
        model.openUsbImport(path: "/Volumes/B")
        #expect(model.usbImport == nil && model.notice == "An export to B is running. Wait for it to finish.")
    }

    @Test func aRunTurnsTheStatusBarOnAndOffAndRefreshesTheLibrary() async {
        let (model, backend, _) = await ready()
        model.openUsbImport(path: "/Volumes/A")
        let sheet = try! #require(model.usbImport)
        let before = model.summary?.trackCount
        await sheet.run()
        #expect(sheet.phase == .finished)
        #expect(!model.importInFlight && model.importProgress == nil)
        #expect(await backend.usbCalls().count == 2)
        #expect(await eventually { model.editHistory.canUndo == false && model.summary != nil })
        #expect(model.summary?.trackCount == before)
    }

    @Test func theMenuPicksTheSelectedOrOnlyDevice() async {
        let (model, _, _) = await ready()
        model.openUsbImportFromMenu()
        #expect(model.usbImport == nil && model.notice == "Select a device in the Devices list first.")
        model.selectedNodeID = "dev:/Volumes/B"
        model.openUsbImportFromMenu()
        #expect(model.usbImport?.path == "/Volumes/B")
        let (empty, backend, _) = await ready()
        await backend.setDevices([])
        await empty.refreshDevices()
        empty.openUsbImportFromMenu()
        #expect(empty.usbImport == nil && empty.notice == "No USB device is connected.")
    }

    @Test func theDeviceMenuAndPanelOfferTheImport() async {
        let idle = ContextMenus.treeMenu(for: .device)!
        guard case .item(let first) = idle[0] else {
            Issue.record("no first row")
            return
        }
        #expect(first.title == "Import from Device\u{2026}" && first.command == .importFromDevice && first.isEnabled)
        guard case .item(let busy) = ContextMenus.treeMenu(for: .device, deviceBusy: true)![0] else {
            Issue.record("no first row")
            return
        }
        #expect(!busy.isEnabled, "no import while an export is writing to the stick")
        let (model, _, _) = await ready()
        model.runDeviceMenu(.importFromDevice, on: model.sidebar.node(withID: "dev:/Volumes/A")!)
        #expect(model.usbImport?.path == "/Volumes/A")
    }
}

/// A reference cell the model's closures write into.
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - iTunes browser

@MainActor
@Suite(.scratchDefaults)
struct ItunesTests {
    private func makeModel(
        _ backend: MockBackend, defaults: UserDefaults? = nil, stub: StubDialogs = StubDialogs(),
        notices: Box<[String]> = Box([]), busy: Box<[Bool]> = Box([])
    ) -> ItunesModel {
        ItunesModel(
            backend: backend, defaults: defaults ?? scratchDefaults(), dialogs: { stub.dialogs },
            notify: { notices.value.append($0) }, busy: { busy.value.append($0) })
    }

    private func scripted(fixture: Bool = false) async -> MockBackend {
        let backend = MockBackend()
        await backend.setIsFixture(fixture)
        await backend.scriptImports {
            $0.library = musicLibrary()
            $0.tracks = [
                "itunes:1": [musicTrack("1", "One"), musicTrack("2", "Two")], "itunes:2": [musicTrack("3", "Three")],
            ]
        }
        return backend
    }

    @Test func aFixtureLibraryNeverLooksAtTheMusicFolderOrTheRememberedPath() async {
        let defaults = scratchDefaults()
        defaults.set(musicPath, forKey: ItunesModel.pathKey)
        let backend = await scripted(fixture: true)
        let model = makeModel(backend, defaults: defaults)
        await model.openIfNeeded()
        #expect(model.library == nil)
        #expect(await backend.itunesCalls().isEmpty)
    }

    @Test func theUsualPlaceIsReadOnFirstShowAndRemembered() async {
        let defaults = scratchDefaults()
        let backend = await scripted()
        let model = makeModel(backend, defaults: defaults)
        await model.openIfNeeded()
        #expect(model.library?.path == musicPath)
        #expect(defaults.string(forKey: ItunesModel.pathKey) == musicPath)
        await model.openIfNeeded()
        #expect(await backend.itunesCalls() == ["default"], "only the first show reads it")
    }

    @Test func aRememberedFileWinsOverTheUsualPlaceWhenItIsStillThere() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rbxport-itunes-\(UUID().uuidString).xml")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let defaults = scratchDefaults()
        defaults.set(file.path, forKey: ItunesModel.pathKey)
        let backend = await scripted()
        await backend.scriptImports { $0.libraries[file.path] = musicLibrary(path: file.path) }
        let model = makeModel(backend, defaults: defaults)
        await model.openIfNeeded()
        #expect(model.library?.path == file.path)
        #expect(await backend.itunesCalls() == ["library(\(file.path))"])

        defaults.set("/nonexistent/Library.xml", forKey: ItunesModel.pathKey)
        let fallback = makeModel(await scripted(), defaults: defaults)
        await fallback.openIfNeeded()
        #expect(fallback.library?.path == musicPath, "a remembered file that is gone falls back to the usual place")
    }

    @Test func chooseReadsTheFileAndABadOneKeepsTheOldLibrary() async {
        let stub = StubDialogs()
        let backend = await scripted(fixture: true)
        let model = makeModel(backend, stub: stub)
        await model.choose()
        #expect(model.library == nil, "cancelled")
        stub.file = URL(fileURLWithPath: musicPath)
        await model.choose()
        #expect(model.library?.tree.count == 4)
        #expect(model.collapsed == ["itunes:0"], "folders start closed")
        stub.file = URL(fileURLWithPath: "/tmp/not-there.xml")
        await model.choose()
        #expect(model.error == "That file could not be read.")
        #expect(model.library?.path == musicPath)
    }

    @Test func theTreeTicksLikeTheSyncManagers() async {
        let model = makeModel(await scripted())
        await model.openIfNeeded()
        #expect(model.rows.map(\.name) == ["Sets", "Loose"], "the closed folder hides its playlists")
        let folder = model.rows[0]
        model.toggleCollapsed(folder)
        #expect(model.rows.map(\.name) == ["Sets", "Warm", "Peak", "Loose"])
        #expect(model.rows.map(\.depth) == [0, 1, 1, 0])
        #expect(model.playlistCount == 3)
        model.toggle(model.rows[1])
        #expect(model.tickState(folder) == .mixed)
        model.toggle(folder)
        #expect(model.tickState(folder) == .on, "a half-ticked folder ticks everything below it")
        model.toggle(folder)
        #expect(model.tickState(folder) == .off && model.ticked.isEmpty)
        model.tickAll()
        #expect(model.selectedPlaylists == ["itunes:1", "itunes:2", "itunes:3"], "in tree order")
        #expect(model.selectionText == "3 of 3 playlists selected")
        model.clearTicks()
        #expect(model.selectionText == "0 of 3 playlists selected")
    }

    @Test func selectingAPlaylistListsItsTracksAndAFolderNone() async {
        let backend = await scripted()
        let model = makeModel(backend)
        await model.openIfNeeded()
        model.toggleCollapsed(model.rows[0])
        await model.select(model.rows[1])
        #expect(model.tracks.map(\.title) == ["One", "Two"])
        #expect(model.selectedID == "itunes:1")
        await model.select(model.rows[0])
        #expect(model.tracks.isEmpty)
        #expect(await backend.itunesCalls().last == "tracks(itunes:1)", "a folder asks nothing")
        #expect(await backend.editLog.isEmpty, "browsing never writes")
    }

    @Test func importingSendsTheTickedPlaylistsInTreeOrderThroughTheGate() async {
        let backend = await scripted()
        await backend.scriptImports {
            $0.itunesReport = XmlImportReport(imported: 2, existing: 1, skipped: [], playlists: 2, cues: 0, tracks: [])
        }
        await backend.setProtectLibrary(false)
        let notices = Box<[String]>([])
        let busy = Box<[Bool]>([])
        let model = makeModel(backend, notices: notices, busy: busy)
        await model.openIfNeeded()
        model.toggleCollapsed(model.rows[0])
        model.toggle(model.rows[3])
        model.toggle(model.rows[1])
        #expect(model.canImport(canEdit: true) && !model.canImport(canEdit: false))
        let report = await model.importSelected()
        #expect(report?.imported == 2)
        #expect(await backend.itunesCalls().last == "import(itunes:1,itunes:3)")
        #expect(model.resultLine == "Imported 2 playlists from iTunes (3 tracks, 2 new).")
        #expect(notices.value == [model.resultLine!])
        #expect(model.ticked.isEmpty, "ticks clear after an import")
        #expect(busy.value == [true, false])
        #expect(await backend.editLog.contains("importItunes(itunes:1,itunes:3)"))
    }

    @Test func aClosedGateRefusesWithItsWordsAndKeepsTheTicks() async {
        let backend = await scripted()
        let notices = Box<[String]>([])
        let model = makeModel(backend, notices: notices)
        await model.openIfNeeded()
        model.tickAll()
        let report = await model.importSelected()
        #expect(report == nil)
        #expect(model.resultLine == "Editing is locked by Library Protection. Turn it off in Preferences to edit.")
        #expect(notices.value == [model.resultLine!])
        #expect(model.ticked.count == 3, "nothing was imported, so the ticks stay")
        #expect(!model.isImporting)
    }

    @Test func nothingTickedAsksForAPlaylistAndSkippedTracksAreListed() async {
        let backend = await scripted()
        await backend.setProtectLibrary(false)
        let notices = Box<[String]>([])
        let stub = StubDialogs()
        let model = makeModel(backend, stub: stub, notices: notices)
        await model.openIfNeeded()
        #expect(await model.importSelected() == nil)
        #expect(notices.value == [ItunesModel.selectOne])
        #expect(!(await backend.itunesCalls().contains { $0.hasPrefix("import") }))
        await backend.scriptImports {
            $0.itunesReport = XmlImportReport(imported: 1, existing: 0, skipped: ["Gone: file not found"], playlists: 1, cues: 0, tracks: [])
        }
        model.tickAll()
        _ = await model.importSelected()
        #expect(stub.informed.map(\.message) == ["1 track was not imported"])
        #expect(stub.informed.first?.detail == "Gone: file not found")
        #expect(model.resultLine?.hasSuffix("1 skipped.") == true)
    }

    @Test func theSummaryPluralises() {
        func report(_ i: UInt32, _ e: UInt32, _ p: UInt32) -> XmlImportReport {
            XmlImportReport(imported: i, existing: e, skipped: [], playlists: p, cues: 0, tracks: [])
        }
        #expect(ItunesModel.summary(report(1, 0, 1)) == "Imported 1 playlist from iTunes (1 track, 1 new).")
        #expect(ItunesModel.summary(report(0, 4, 2)) == "Imported 2 playlists from iTunes (4 tracks, 0 new).")
    }

    // MARK: Sidebar and the app model

    @Test func theSidebarHasAnITunesNodeThatOpensTheBrowser() async {
        let backend = MockBackend(trackCount: 50)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        let section = model.sidebar.section(.itunes)
        #expect(section.name == "iTunes")
        #expect(section.children.map(\.id) == ["itunes"])
        #expect(model.sidebar.canSelect("itunes") && SidebarNode.source(forID: "itunes") == nil)
        #expect(!model.isItunesSelected)
        model.selectNode("itunes")
        #expect(model.isItunesSelected)
    }

    @Test func importIsLockedByProtectionAndByARunningRekordbox() async {
        let backend = MockBackend(trackCount: 50)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.start()
        #expect(await eventually { model.opened != nil })
        #expect(model.itunesLockedReason == "Editing is locked by Library Protection. Turn it off in Settings to import.")
        model.protectLibrary = false
        #expect(await eventually { !model.isReadOnly })
        #expect(model.itunesLockedReason == nil)
    }

    @Test func theFileMenuChoosesAFileAndShowsTheBrowser() async {
        let backend = await scripted(fixture: true)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        let stub = StubDialogs()
        stub.file = URL(fileURLWithPath: musicPath)
        model.dialogs = stub.dialogs
        model.start()
        #expect(await eventually { model.opened != nil })
        await model.openItunesFromPanel()
        #expect(model.isItunesSelected)
        #expect(model.itunes.library?.path == musicPath)
    }

    @Test func importProgressReachesTheStatusBarWhileTheBrowserImports() async {
        let backend = await scripted(fixture: true)
        await backend.setProtectLibrary(false)
        let model = AppModel(backend: backend, layoutStore: isolatedStore())
        model.protectLibrary = false
        let stub = StubDialogs()
        stub.file = URL(fileURLWithPath: musicPath)
        model.dialogs = stub.dialogs
        model.start()
        #expect(await eventually { model.opened != nil && !model.isReadOnly })
        await model.openItunesFromPanel()
        model.itunes.tickAll()
        _ = await model.itunes.importSelected()
        #expect(!model.importInFlight && model.importProgress == nil, "the bar is cleared when the import ends")
        #expect(model.notice == "Imported 2 playlists from iTunes (3 tracks, 2 new).")
    }
}
