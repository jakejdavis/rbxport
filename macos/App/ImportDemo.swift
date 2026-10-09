import Foundation

extension ItunesTrack: Identifiable {}

/// Fixture-only hooks for the Phase 5b screenshots, since synthetic clicks do not reach SwiftUI.
///
/// `RBXPORT_DEMO_IMPORT` is a comma-separated list of steps:
/// - `export`: writes the first playlist to the first fake stick, so there is an export to import
/// - `usb`: selects the stick and opens the Import from USB sheet; `usb-run` presses Import
/// - `itunes`: opens the iTunes node on the XML named by `RBXPORT_ITUNES_XML`; `itunes-open` opens its
///   first folder and selects its first playlist; `itunes-tick` ticks everything; `itunes-import` imports
///
/// Like the device demo, every step refuses unless the library is a generated fixture
/// (`RBXPORT_FIXTURE_DIR` set and confirmed by the core). The stick must be a fake volume under a
/// temporary directory, and the XML must be a file under one: the real Music library is never read.
enum ImportDemoGuard {
    /// The XML named by the environment, when it is under a temporary directory.
    static func itunesXML(_ environment: [String: String]) -> String? {
        guard let path = environment["RBXPORT_ITUNES_XML"], DeviceDemoGuard.isTemporary(path) else { return nil }
        return path
    }
}

extension AppModel {
    func runImportDemo(_ steps: String, environment: [String: String]) async {
        guard environment["RBXPORT_FIXTURE_DIR"] != nil, await backend.isFixtureLibrary() else {
            notice = "Import demo refused: it runs only against a fixture library."
            return
        }
        let list = steps.split(separator: ",").map(String.init)
        let wantsStick = list.contains { ["export", "usb", "usb-run"].contains($0) }
        var stick: String?
        if wantsStick {
            guard let volumes = DeviceDemoGuard.fakeVolumes(environment) else {
                notice = "Import demo refused: RB_LITE_FAKE_VOLUMES must name directories under a temporary folder."
                return
            }
            await refreshDevices()
            guard let device = devices.devices.first(where: { volumes.contains($0.path) }), DeviceDemoGuard.isTemporary(device.path) else {
                notice = "Import demo refused: no fake volume is mounted."
                return
            }
            stick = device.path
        }
        if list.contains(where: { $0.hasPrefix("itunes") }), ImportDemoGuard.itunesXML(environment) == nil {
            notice = "Import demo refused: RBXPORT_ITUNES_XML must be a file under a temporary folder."
            return
        }
        for step in list {
            switch step {
            case "export":
                exportPrefs.ejectAfterSync = false
                if let playlist = sidebar.playlistTargets().first, let stick { await exportPlaylist(id: playlist.id, to: stick) }
            case "usb":
                if let stick {
                    selectedNodeID = "\(Self.deviceNodePrefix)\(stick)"
                    try? await Task.sleep(for: .milliseconds(500))
                    openUsbImport(path: stick)
                }
            case "usb-run":
                // The demo has no one to press the confirmation's button, and it is fixture-only.
                let original = dialogs
                dialogs.confirm = { _, _, _ in true }
                await usbImport?.run()
                dialogs = original
            case "itunes":
                selectedNodeID = SidebarModel.itunesID
                if let xml = ImportDemoGuard.itunesXML(environment) { await itunes.load(path: xml) }
            case "itunes-open":
                if let folder = itunes.rows.first(where: \.isFolder) { itunes.toggleCollapsed(folder) }
                if let playlist = itunes.rows.first(where: { !$0.isFolder }) { await itunes.select(playlist) }
            case "itunes-tick":
                itunes.tickAll()
            case "itunes-import":
                await itunes.importSelected()
            default: break
            }
        }
    }
}
