import AppKit
import SwiftUI

// MARK: - Enable state

/// What the menu bar may do right now, read from the model: the selection, the editing gate, the
/// layout, the loaded decks. Kept apart from the views so it can be tested.
struct MenuState: Equatable {
    /// The library may be edited (not protected, not locked by rekordbox).
    var canEdit = false
    var hasSelection = false
    var singleSelection = false
    var canUndo = false
    var canRedo = false
    var canRemoveFromPlaylist = false
    /// An editable playlist, smart playlist or folder is selected in the source list.
    var treeItemEditable = false
    var smartPlaylistSelected = false
    var hasDevices = false
    var deckALoaded = false
    var deckBLoaded = false
    var twoDecks = false

    var importEnabled: Bool { canEdit }
    var newItemEnabled: Bool { canEdit }
    var renameEnabled: Bool { canEdit && treeItemEditable }
    var deleteEnabled: Bool { canEdit && treeItemEditable }
    var editSmartEnabled: Bool { canEdit && smartPlaylistSelected }
    var analyseEnabled: Bool { canEdit && hasSelection }
    var addToTagListEnabled: Bool { canEdit && hasSelection }
    var removeFromCollectionEnabled: Bool { canEdit && hasSelection }
    var loadToDeckEnabled: Bool { singleSelection }
    var showInFinderEnabled: Bool { hasSelection }
    var usbImportEnabled: Bool { hasDevices }
    /// Deck B answers the keys only in the two-deck layout.
    var deckBEnabled: Bool { twoDecks }
}

extension AppModel {
    var menuState: MenuState {
        let node = selectedSidebarNode
        return MenuState(
            canEdit: canEdit, hasSelection: !selectedIDs.isEmpty, singleSelection: selectedIDs.count == 1,
            canUndo: canUndo, canRedo: canRedo, canRemoveFromPlaylist: canRemoveFromPlaylist,
            treeItemEditable: node?.isEditableItem ?? false, smartPlaylistSelected: node?.kind == .smartPlaylist,
            hasDevices: !devices.devices.isEmpty, deckALoaded: player.deckA.isLoaded, deckBLoaded: player.deckB.isLoaded,
            twoDecks: player.layout.deckCount == 2)
    }
}

// MARK: - Commands

/// The whole menu bar, in one place: File, Edit, View, Track, Playlist, Player and Help, with the
/// system's own App and Window menus around them. Shortcuts come from the binding table
/// (`Keymap`), so a key changed in Settings changes here and nowhere else owns it.
struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var keymap: Keymap { model.prefs.keymap }
    private var state: MenuState { model.menuState }

    /// A menu button whose key equivalent is the binding's.
    private func item(_ title: String, _ key: MenuKey, action: @escaping () -> Void) -> some View {
        Button(title, action: action).keyboardShortcut(keymap.shortcut(for: key))
    }

    /// A Cmd-less key would take the key from text fields, so only a menu key with a modifier gets here.
    private var typingInText: Bool { NSApp.keyWindow?.firstResponder is NSTextView }

    var body: some Commands {
        // File
        CommandGroup(replacing: .newItem) {
            Menu(L10n.t("Import")) {
                item(L10n.t("Track\u{2026}"), .importTracks) { Task { await model.importFromPanel(folders: false) } }
                    .disabled(!state.importEnabled)
                item(L10n.t("Import Folder\u{2026}"), .importFolder) { Task { await model.importFromPanel(folders: true) } }
                    .disabled(!state.importEnabled)
                Button(L10n.t("Import rekordbox xml\u{2026}")) { Task { await model.importXMLFromPanel() } }
                    .disabled(!state.importEnabled)
                // Browsing the Music library writes nothing; only its Import button needs editing.
                Button(L10n.t("Import iTunes Library xml\u{2026}")) { Task { await model.openItunesFromPanel() } }
                Button("USB Device\u{2026}") { model.openUsbImportFromMenu() }
                    .disabled(!state.usbImportEnabled)
            }
            Divider()
            item(L10n.t("Sync Manager\u{2026}"), .syncManager) { model.openSyncManager() }
            Divider()
            Button(L10n.t("Missing File Manager\u{2026}")) { model.openMissingFiles() }
            Button(L10n.t("Find duplicates\u{2026}")) { model.openDuplicates() }
        }

        // Edit
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoMenuTitle) { model.performHistoryCommand(redo: false) }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!state.canUndo && !typingInText)
            Button(model.redoMenuTitle) { model.performHistoryCommand(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!state.canRedo && !typingInText)
        }
        CommandGroup(after: .textEditing) {
            item("Find", .find) { model.focusSearch() }
        }

        // View
        CommandGroup(after: .sidebar) {
            Menu(L10n.t("Layout")) {
                ForEach(PlayerLayout.allCases) { layout in
                    Toggle(
                        layout.menuLabel,
                        isOn: Binding(
                            get: { model.player.layout == layout }, set: { if $0 { model.player.layout = layout } })
                    )
                    .keyboardShortcut(keymap.shortcut(for: layout.menuKey))
                }
            }
            Picker(L10n.t("Key display format"), selection: Binding(get: { model.keyStyle }, set: { model.keyStyle = $0 })) {
                ForEach(KeyStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker(L10n.t("Waveform color"), selection: Binding(get: { model.waveformPalette }, set: { model.waveformPalette = $0 })) {
                ForEach(WaveformPalette.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Row Size", selection: Binding(get: { model.rowSize }, set: { model.rowSize = $0 })) {
                ForEach(RowSize.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Button(L10n.t("Reset columns")) { model.resetColumns() }
            Divider()
            Toggle("Show Track Filter", isOn: Binding(get: { model.filterBarOpen }, set: { model.filterBarOpen = $0 }))
                .keyboardShortcut(keymap.shortcut(for: .showFilter))
            Toggle("Show Player", isOn: Binding(get: { model.player.panelOpen }, set: { model.player.panelOpen = $0 }))
                .keyboardShortcut(keymap.shortcut(for: .showPlayer))
            Toggle(L10n.t("Show Information"), isOn: Binding(get: { model.infoPanelOpen }, set: { model.infoPanelOpen = $0 }))
                .keyboardShortcut(keymap.shortcut(for: .showInformation))
            Toggle("Show Playlist Counts", isOn: Binding(get: { model.prefs.playlistCounts }, set: { model.prefs.playlistCounts = $0 }))
        }

        // Track
        CommandMenu(L10n.t("Track")) {
            Button(L10n.t("Load track to player 1")) { model.runTrackMenu(.loadToDeck(.a)) }
                .disabled(!state.loadToDeckEnabled)
            Button(L10n.t("Load track to player 2")) { model.runTrackMenu(.loadToDeck(.b)) }
                .disabled(!state.loadToDeckEnabled)
            Divider()
            item(L10n.t("Analyze Track"), .analyse) { model.analyseSelection() }
                .disabled(!state.analyseEnabled)
            Button(L10n.t("Show in Finder")) { model.runTrackMenu(.showInFinder) }
                .disabled(!state.showInFinderEnabled)
            Divider()
            Button(L10n.t("Add To Tag List")) { model.runTrackMenu(.addToTagList) }
                .disabled(!state.addToTagListEnabled)
            Button(L10n.t("Remove from Playlist")) { model.runTrackMenu(.removeFromPlaylist) }
                .disabled(!state.canRemoveFromPlaylist)
            Button(L10n.t("Remove from Collection")) { model.runTrackMenu(.removeFromCollection) }
                .disabled(!state.removeFromCollectionEnabled)
        }

        // Playlist
        CommandMenu(L10n.t("Playlist")) {
            item(L10n.t("Create New Playlist"), .newPlaylist) { Task { await model.createPlaylist(near: model.selectedSidebarNode) } }
                .disabled(!state.newItemEnabled)
            item(L10n.t("Create New Folder"), .newFolder) { Task { await model.createFolder(near: model.selectedSidebarNode) } }
                .disabled(!state.newItemEnabled)
            Button(L10n.t("Create New Intelligent Playlist")) { model.newSmartPlaylist(near: model.selectedSidebarNode) }
                .disabled(!state.newItemEnabled)
            Divider()
            Button(L10n.t("Rename")) { if let node = model.selectedSidebarNode { model.runTreeMenu(.rename, on: node) } }
                .disabled(!state.renameEnabled)
            Button(L10n.t("Edit Intelligent Playlist\u{2026}")) {
                if let node = model.selectedSidebarNode { model.runTreeMenu(.editSmartPlaylist, on: node) }
            }
            .disabled(!state.editSmartEnabled)
            Button(L10n.t("Delete")) { if let node = model.selectedSidebarNode { model.runTreeMenu(.delete, on: node) } }
                .disabled(!state.deleteEnabled)
        }

        // Player: the decks' keys live in the binding table (Settings > Keyboard); these are the same
        // actions for the pointer.
        CommandMenu("Player") {
            Button("Play/Pause Player 1") { model.player.perform(.togglePlay, on: .a) }
                .disabled(!state.deckALoaded)
            Button("Play/Pause Player 2") { model.player.perform(.togglePlay, on: .b) }
                .disabled(!state.deckBLoaded || !state.deckBEnabled)
            Divider()
            Button("Quantize Player 1") { model.player.perform(.quantize, on: .a) }
                .disabled(!state.deckALoaded)
            Button("Quantize Player 2") { model.player.perform(.quantize, on: .b) }
                .disabled(!state.deckBLoaded || !state.deckBEnabled)
            Button("Master Tempo Player 1") { model.player.perform(.masterTempo, on: .a) }
                .disabled(!state.deckALoaded)
            Button("Master Tempo Player 2") { model.player.perform(.masterTempo, on: .b) }
                .disabled(!state.deckBLoaded || !state.deckBEnabled)
            Button("Beat Sync Player 2") { model.player.perform(.beatSync, on: .b) }
                .disabled(!state.deckBLoaded || !state.deckBEnabled)
            Divider()
            Button("Change Metronome sound") { model.player.perform(.metronomeSound) }
        }

        // Help
        CommandGroup(replacing: .help) {
            Button(L10n.t("Report bug\u{2026}")) { openWindow(id: BugReportScene.id) }
        }
    }
}

extension PlayerLayout {
    /// The binding-table item that carries this layout's shortcut.
    var menuKey: MenuKey {
        switch self {
        case .one: .layoutOne
        case .two: .layoutTwo
        case .simple: .layoutSimple
        case .browser: .layoutBrowser
        }
    }
}
