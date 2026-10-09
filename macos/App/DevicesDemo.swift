import AppKit
import Foundation

/// Fixture-only hooks for the Phase 5a screenshots, since synthetic clicks do not reach SwiftUI.
///
/// `RBXPORT_DEMO_DEVICES` is a comma-separated list of steps: `export` (writes the first playlist to the
/// first fake stick and selects it), `panel` or `panel:category|sort|column|color` (selects the stick
/// and its tab), `sync` (opens the Sync Manager, ticks everything and syncs), `verify`.
///
/// They write to a stick, so every step refuses unless the library is a generated fixture
/// (`RBXPORT_FIXTURE_DIR` set and confirmed by the core) and the stick is a fake volume
/// (`RB_LITE_FAKE_VOLUMES`) that lives under a temporary directory.
enum DeviceDemoGuard {
    /// Where a fake stick may live: the system and user temporary directories.
    static func temporaryRoots() -> [String] {
        let roots = [NSTemporaryDirectory(), "/tmp", "/private/tmp", "/private/var/folders"]
        return roots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    /// True when `path` is inside a temporary directory once symlinks are resolved. Never true for
    /// `/Volumes`, the home folder or the root.
    static func isTemporary(_ path: String, roots: [String] = temporaryRoots()) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        // `/tmp` and `/private/tmp` are one place, but a path that does not exist yet resolves to
        // whichever spelling it was given.
        let spellings = [resolved, resolved.hasPrefix("/private/") ? String(resolved.dropFirst(8)) : "/private" + resolved]
        return roots.contains { root in root.count > 1 && spellings.contains { $0.hasPrefix(root + "/") } }
    }

    /// The fake volumes named by the environment, when every one of them is a temporary directory.
    static func fakeVolumes(_ environment: [String: String], roots: [String] = temporaryRoots()) -> [String]? {
        guard let value = environment["RB_LITE_FAKE_VOLUMES"] else { return nil }
        let paths = value.split(separator: ":").map(String.init)
        guard !paths.isEmpty, paths.allSatisfy({ isTemporary($0, roots: roots) }) else { return nil }
        return paths
    }
}

extension AppModel {
    func runDeviceDemo(_ steps: String, environment: [String: String]) async {
        guard environment["RBXPORT_FIXTURE_DIR"] != nil, await backend.isFixtureLibrary() else {
            notice = "Device demo refused: it runs only against a fixture library."
            return
        }
        guard let volumes = DeviceDemoGuard.fakeVolumes(environment) else {
            notice = "Device demo refused: RB_LITE_FAKE_VOLUMES must name directories under a temporary folder."
            return
        }
        await refreshDevices()
        guard let device = devices.devices.first(where: { volumes.contains($0.path) }),
            DeviceDemoGuard.isTemporary(device.path)
        else {
            notice = "Device demo refused: no fake volume is mounted."
            return
        }
        exportPrefs.ejectAfterSync = false
        for step in steps.split(separator: ",").map(String.init) {
            let parts = step.split(separator: ":").map(String.init)
            switch parts[0] {
            case "export":
                if let playlist = sidebar.playlistTargets().first {
                    await exportPlaylist(id: playlist.id, to: device.path)
                }
            case "panel":
                selectedNodeID = "\(Self.deviceNodePrefix)\(device.path)"
                try? await Task.sleep(for: .milliseconds(600))
                if parts.count > 1, let tab = DeviceSettingsModel.Tab.allCases.first(where: { $0.rawValue.lowercased() == parts[1] }) {
                    devicePanel?.tab = tab
                }
            case "sync":
                openSyncManager()
                try? await Task.sleep(for: .milliseconds(900))
                // Only the first playlist: the fixture's other tracks point at files that do not exist.
                if let first = syncManager.rows.first(where: { !$0.isFolder }) { syncManager.toggle(first) }
                await syncManager.toggleDevice(device.path)
                await syncManager.sync()
            case "verify":
                await syncManager.verify(device.path)
            default: break
            }
        }
    }
}
