import SwiftUI

@main
struct RbxportApp: App {
    @State private var model: AppModel
    /// Unit tests load this app as their host; they must never touch the real library.
    private let isUnderTest: Bool

    init() {
        let env = ProcessInfo.processInfo.environment
        isUnderTest = env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        let backend: any BackendProtocol
        if !isUnderTest {
            // A daily log file, so the Report a Problem window has something to show.
            _ = try? installLogging()
        }
        if isUnderTest {
            backend = MockBackend(trackCount: 0)
        } else if let dir = env["RBXPORT_FIXTURE_DIR"] {
            // RBXPORT_FIXTURE_DIR opens a generated fixture library instead of the installed one.
            backend = Backend(fixtureDir: URL(fileURLWithPath: dir))
        } else {
            backend = Backend(cacheDir: Backend.defaultCacheDir)
        }
        // RBXPORT_DEFAULTS_SUITE (a path under a temporary folder) keeps a dev launch's settings and
        // window frame out of the real preferences.
        var store = ColumnLayoutStore()
        if let suite = env["RBXPORT_DEFAULTS_SUITE"], DeviceDemoGuard.isTemporary(suite), let defaults = UserDefaults(suiteName: suite) {
            store = ColumnLayoutStore(defaults: defaults)
        }
        let appModel = AppModel(backend: backend, layoutStore: store)
        _model = State(initialValue: appModel)
        // AppleScript reaches the app through this; tests make their own host.
        if !isUnderTest { ScriptHost.install(model: appModel) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    guard !isUnderTest else { return }
                    applyDevHooks()
                    model.readOnlyPollInterval = .seconds(3)
                    model.start()
                    runEditHooks()
                    model.player.installKeyMonitor()
                }
        }
        .defaultSize(width: 1280, height: 900)
        .commands { AppCommands(model: model) }
        Window("Sync Manager", id: SyncManagerScene.id) {
            SyncManagerView(model: model.syncManager, devices: model.devices, jobs: model.exportJobs)
                .environment(model)
        }
        .defaultSize(width: 900, height: 560)
        Window("Report a Problem", id: BugReportScene.id) {
            BugReportView(model: model.bugReport)
        }
        .defaultSize(width: 620, height: 600)
        Settings {
            SettingsView(model: model)
        }
    }

    /// Edit hooks for screenshots, since synthetic clicks do not reach SwiftUI. They write, so
    /// `RBXPORT_DEMO_EDIT` runs only when `RBXPORT_FIXTURE_DIR` is set and the core confirms the
    /// library is a fixture. `RBXPORT_OPEN_SMART_EDITOR=1` only opens the sheet.
    @MainActor private func runEditHooks() {
        let env = ProcessInfo.processInfo.environment
        if let demo = env["RBXPORT_DEMO_EDIT"], env["RBXPORT_FIXTURE_DIR"] != nil {
            Task { @MainActor in
                await model.waitUntilSettled()
                try? await Task.sleep(for: .milliseconds(500))
                await model.runDemoEdit(demo)
            }
        }
        if let steps = env["RBXPORT_DEMO_DEVICES"] {
            Task { @MainActor in
                await model.waitUntilSettled()
                try? await Task.sleep(for: .milliseconds(1200))
                await model.runDeviceDemo(steps, environment: env)
            }
        }
        if let steps = env["RBXPORT_DEMO_IMPORT"] {
            Task { @MainActor in
                await model.waitUntilSettled()
                try? await Task.sleep(for: .milliseconds(1200))
                await model.runImportDemo(steps, environment: env)
            }
        }
        if let steps = env["RBXPORT_DEMO_CHROME"] {
            Task { @MainActor in
                await model.waitUntilSettled()
                try? await Task.sleep(for: .milliseconds(1200))
                await model.runChromeDemo(steps, environment: env)
            }
        }
        // RBXPORT_DEMO_LINK=1 shows a made-up LINK session in the strip and the LINK pane. It is only
        // data in the model: no socket is opened and no backend call is made.
        if env["RBXPORT_DEMO_LINK"] == "1" {
            Task { @MainActor in
                await model.waitUntilSettled()
                model.link.showDemo(status: LinkModel.demoStatus, peers: [])
            }
        }
        if env["RBXPORT_OPEN_SMART_EDITOR"] == "1" {
            Task { @MainActor in
                await model.waitUntilSettled()
                try? await Task.sleep(for: .milliseconds(900))
                model.openDemoSmartEditor()
            }
        }
    }

    /// Dev aids for screenshots: `RBXPORT_LAYOUT=one|two|simple|browser` (not remembered) and
    /// `RBXPORT_OPEN_SETTINGS=1`. Launch with `RBXPORT_NULL_AUDIO=1` so nothing is audible.
    @MainActor private func applyDevHooks() {
        let env = ProcessInfo.processInfo.environment
        if let name = env["RBXPORT_LAYOUT"], let layout = PlayerLayout(rawValue: name) {
            model.player.persistsLayout = false
            model.player.layout = layout
        }
        // RBXPORT_WINDOW_SIZE=1280x900 sizes the main window (the saved frame otherwise wins).
        if let text = env["RBXPORT_WINDOW_SIZE"] {
            let parts = text.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    NSApp.windows.first { $0.isVisible && $0.title != "Audio" }?
                        .setContentSize(NSSize(width: parts[0], height: parts[1]))
                }
            }
        }
        if env["RBXPORT_OPEN_SETTINGS"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                NSApp.activate()
                // The app menu's Settings item (Command-comma), as a click would run it.
                if let menu = NSApp.mainMenu?.items.first?.submenu,
                    let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," })
                {
                    menu.performActionForItem(at: index)
                }
            }
        }
    }
}
