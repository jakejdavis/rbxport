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
        if isUnderTest {
            backend = MockBackend(trackCount: 0)
        } else if let dir = env["RBXPORT_FIXTURE_DIR"] {
            // RBXPORT_FIXTURE_DIR opens a generated fixture library instead of the installed one.
            backend = Backend(fixtureDir: URL(fileURLWithPath: dir))
        } else {
            backend = Backend(cacheDir: Backend.defaultCacheDir)
        }
        _model = State(initialValue: AppModel(backend: backend))
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
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoMenuTitle) { model.performHistoryCommand(redo: false) }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo && !(NSApp.keyWindow?.firstResponder is NSTextView))
                Button(model.redoMenuTitle) { model.performHistoryCommand(redo: true) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo && !(NSApp.keyWindow?.firstResponder is NSTextView))
            }
            CommandGroup(after: .newItem) {
                Button("New Playlist") { Task { await model.createPlaylist(near: model.selectedSidebarNode) } }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(!model.canEdit)
                Button("New Folder") { Task { await model.createFolder(near: model.selectedSidebarNode) } }
                    .keyboardShortcut("n", modifiers: [.command, .option, .shift])
                    .disabled(!model.canEdit)
                Button("New Intelligent Playlist") { model.newSmartPlaylist(near: model.selectedSidebarNode) }
                    .disabled(!model.canEdit)
            }
            CommandGroup(after: .importExport) {
                Button("Sync Manager\u{2026}") { model.openSyncManager() }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
                Menu("Import") {
                    Button("Track\u{2026}") { Task { await model.importFromPanel(folders: false) } }
                        .disabled(!model.canEdit)
                    Button("Folder\u{2026}") { Task { await model.importFromPanel(folders: true) } }
                        .disabled(!model.canEdit)
                    Button("rekordbox XML\u{2026}") { Task { await model.importXMLFromPanel() } }
                        .disabled(!model.canEdit)
                    // Browsing the Music library writes nothing; only its Import button needs editing.
                    Button("iTunes Library XML\u{2026}") { Task { await model.openItunesFromPanel() } }
                    Button("USB Device\u{2026}") { model.openUsbImportFromMenu() }
                        .disabled(model.devices.devices.isEmpty)
                }
                Button("Analyze Track(s)") { model.analyseSelection() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!model.canEdit || model.selectedIDs.isEmpty)
                Button("Missing File Manager\u{2026}") { model.openMissingFiles() }
                Button("Find Duplicates\u{2026}") { model.openDuplicates() }
            }
            CommandGroup(after: .textEditing) {
                Button("Find") { model.focusSearch() }.keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Menu("Layout") {
                    ForEach(PlayerLayout.allCases) { layout in
                        Toggle(
                            layout.label,
                            isOn: Binding(
                                get: { model.player.layout == layout }, set: { if $0 { model.player.layout = layout } })
                        )
                        .keyboardShortcut(KeyEquivalent(layout.keyEquivalent), modifiers: .command)
                    }
                }
                Picker(
                    "Key Display",
                    selection: Binding(get: { model.keyStyle }, set: { model.keyStyle = $0 })
                ) {
                    ForEach(KeyStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker(
                    "Waveform Color",
                    selection: Binding(get: { model.waveformPalette }, set: { model.waveformPalette = $0 })
                ) {
                    ForEach(WaveformPalette.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker(
                    "Row Size",
                    selection: Binding(get: { model.rowSize }, set: { model.rowSize = $0 })
                ) {
                    ForEach(RowSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Button("Reset Columns") { model.resetColumns() }
                Toggle(
                    "Show Track Filter",
                    isOn: Binding(get: { model.filterBarOpen }, set: { model.filterBarOpen = $0 })
                )
                .keyboardShortcut("f", modifiers: [.command, .option])
                Toggle(
                    "Show Player",
                    isOn: Binding(get: { model.player.panelOpen }, set: { model.player.panelOpen = $0 })
                )
                .keyboardShortcut("p", modifiers: [.command, .option])
                Toggle(
                    "Show Information",
                    isOn: Binding(get: { model.infoPanelOpen }, set: { model.infoPanelOpen = $0 })
                )
                .keyboardShortcut("i", modifiers: .command)
                Toggle(
                    "Show Playlist Counts",
                    isOn: Binding(get: { model.sidebar.showChildCounts }, set: { model.sidebar.showChildCounts = $0 }))
            }
        }
        Window("Sync Manager", id: SyncManagerScene.id) {
            SyncManagerView(model: model.syncManager, devices: model.devices, jobs: model.exportJobs)
                .environment(model)
        }
        .defaultSize(width: 900, height: 560)
        Settings {
            SettingsView(player: model.player, model: model)
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
