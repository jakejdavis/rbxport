import Foundation

/// What a live menu entry does. Entries with no command are drawn greyed: rekordbox has
/// them and the edit ones arrive in Phase 4. Order and labels follow `src/lib/contextMenus.ts`.
enum MenuCommand: Equatable, Sendable {
    case showInFinder
    case showInformation
    /// Load the selected track onto a deck (Player 1 is deck A).
    case loadToDeck(Deck)
    case exportPlaylist(PlaylistFileFormat)
    // Edits. Live only while the library may be edited.
    case createPlaylist
    case createFolder
    case createSmartPlaylist
    case editSmartPlaylist
    case rename
    case delete
    case sortItems
    /// Add the selected tracks to the playlist with this id.
    case addToPlaylist(String)
    case removeFromPlaylist
    // Phase 4b.
    case importToCollection
    case addToTagList
    case removeFromTagList
    case reloadTag
    case resetPlayCount
    case removeFromCollection
    case removeFromHistory
    /// Colour 1 to 8, or 0 for none, on the selection.
    case setColor(UInt8)
    // Phase 4c.
    case analyse
    case analysisLock(Bool)
    case convertMemoryToHot
    // Phase 5a: devices. The path is the device's mount point.
    /// Export the playlist a tree node stands for to the device.
    case exportToDevice(String)
    /// Export the selected tracks to the device, in no playlist.
    case exportTrackToDevice(String)
    case ejectDevice
    case openSyncManager
}

struct MenuItemSpec: Equatable {
    var title: String
    var command: MenuCommand?
    var submenu: [MenuRow]?
    /// A colour dot drawn beside the title (0 draws the ring for none).
    var colorDot: UInt8?

    /// A leaf is live when it has a command; a submenu when any of its entries is.
    var isEnabled: Bool {
        if let submenu { return submenu.contains { $0.isEnabled } }
        return command != nil
    }
}

enum MenuRow: Equatable {
    case separator
    case item(MenuItemSpec)

    var isEnabled: Bool {
        if case .item(let item) = self { item.isEnabled } else { false }
    }
}

enum ContextMenus {
    private static func grey(_ title: String, _ submenu: [MenuRow]? = nil) -> MenuRow {
        .item(MenuItemSpec(title: title, command: nil, submenu: submenu))
    }

    private static func live(_ title: String, _ command: MenuCommand) -> MenuRow {
        .item(MenuItemSpec(title: title, command: command, submenu: nil))
    }

    // MARK: Track rows

    struct TrackContext: Equatable {
        /// Tracks the menu acts on (the selection, after a right-click selected the row).
        var selectionCount: Int
        /// The view is the Tag List: "Remove from Playlist" reads "Remove from Tag List".
        var inTagList = false
        /// The view is the Explorer: no "Convert Memory Cues to Hot Cues".
        var inExplorer = false
        /// The library may be edited (the write gate is open).
        var editable = false
        /// Playlists "Add To Playlist" offers.
        var playlists: [PlaylistTarget] = []
        /// The view is an ordinary playlist, so tracks can be taken out of it.
        var inPlaylist = false
        /// The view is a history session, so plays can be taken off it.
        var inHistory = false
        /// Some selected rows are files the Explorer lists, not tracks of the collection.
        var hasLoose = false
        /// Every selected row is such a file.
        var allLoose = false
        /// The devices "Export Track" offers.
        var devices: [DeviceTarget] = []
    }

    /// Right-clicking a track, top to bottom as `TRACK_MENU` has it. Show in Finder, Show
    /// information and Load track to player 1 and 2 are live (player 2 is refused outside the
    /// 2 PLAYER layout); the rest are edits (Phase 4).
    static func trackMenu(_ context: TrackContext) -> [MenuRow] {
        let hasSelection = context.selectionCount > 0
        // Edits of the collection: a selection of collection tracks and an open write gate.
        let edits = context.editable && hasSelection && !context.hasLoose
        func edit(_ title: String, _ command: MenuCommand) -> MenuRow { edits ? live(title, command) : grey(title) }
        var rows: [MenuRow] = [
            .item(
                MenuItemSpec(
                    title: "Load", command: nil,
                    submenu: [
                        context.selectionCount == 1 ? live("Load track to player 1", .loadToDeck(.a)) : grey("Load track to player 1"),
                        context.selectionCount == 1 ? live("Load track to player 2", .loadToDeck(.b)) : grey("Load track to player 2"),
                    ])),
            .separator,
            context.editable && context.hasLoose ? live("Import To Collection", .importToCollection) : grey("Import To Collection"),
            edit("Analyze Track", .analyse),
            .item(
                MenuItemSpec(
                    title: "Analysis Lock", command: nil,
                    submenu: [edit("On", .analysisLock(true)), edit("Off", .analysisLock(false))])),
            .separator,
            addToPlaylist(context),
            edit("Add To Tag List", .addToTagList),
            edit("Reload Tag", .reloadTag),
            colorMenu(enabled: edits),
            grey("Get Info from iTunes"),
            grey("Track Type", []),
            .separator,
            exportTrackMenu(context),
            .separator,
            grey("Auto Load Hot Cue", [grey("Enable Auto Load Hot Cue"), grey("Disable Auto Load Hot Cue")]),
            edit("Reset DJ Play Count", .resetPlayCount),
            grey("Add New Analysis Data"),
        ]
        if !context.inExplorer { rows.append(edit("Convert Memory Cues to Hot Cues", .convertMemoryToHot)) }
        rows += [
            .separator,
            context.inTagList
                ? (context.editable && hasSelection ? live("Remove from Tag List", .removeFromTagList) : grey("Remove from Tag List"))
                : (context.editable && context.inPlaylist && hasSelection
                    ? live("Remove from Playlist", .removeFromPlaylist) : grey("Remove from Playlist")),
            edit("Remove from Collection", .removeFromCollection),
            context.editable && context.inHistory && hasSelection
                ? live("Remove from History", .removeFromHistory) : grey("Remove from History"),
            .separator,
            hasSelection ? live("Show information", .showInformation) : grey("Show information"),
            hasSelection ? live("Show in Finder", .showInFinder) : grey("Show in Finder"),
            .separator,
            grey("Track information", [grey("Publish"), grey("Do not publish")]),
        ]
        return rows
    }

    /// "Export Track ▸ device": live for tracks of the collection while a device is mounted.
    private static func exportTrackMenu(_ context: TrackContext) -> MenuRow {
        guard context.selectionCount > 0, !context.allLoose, !context.devices.isEmpty else { return grey("Export Track", []) }
        return .item(
            MenuItemSpec(
                title: "Export Track", command: nil,
                submenu: context.devices.map { live($0.name, .exportTrackToDevice($0.path)) }))
    }

    /// "Export Playlist ▸ device": one entry per mounted device.
    private static func exportPlaylistMenu(_ devices: [DeviceTarget]) -> MenuRow {
        guard !devices.isEmpty else { return grey("Export Playlist", []) }
        return .item(
            MenuItemSpec(
                title: "Export Playlist", command: nil,
                submenu: devices.map { live($0.name, .exportToDevice($0.path)) }))
    }

    /// "Color ▸": none, then the eight colours, each with its dot.
    static func colorMenu(enabled: Bool) -> MenuRow {
        let items: [MenuRow] = (0...8).map { id in
            let color = UInt8(id)
            return .item(
                MenuItemSpec(
                    title: TrackColors.name(color), command: enabled ? .setColor(color) : nil, submenu: nil,
                    colorDot: color))
        }
        return .item(MenuItemSpec(title: "Color", command: nil, submenu: enabled ? items : []))
    }

    /// "Add To Playlist ▸": every ordinary playlist as `Folder › Playlist`, live for a selection.
    private static func addToPlaylist(_ context: TrackContext) -> MenuRow {
        guard context.editable, context.selectionCount > 0 else { return grey("Add To Playlist", []) }
        return .item(
            MenuItemSpec(
                title: "Add To Playlist", command: nil,
                submenu: context.playlists.map { live($0.title, .addToPlaylist($0.id)) }))
    }

    // MARK: Tree nodes

    /// The menu for a source-list node, or nil where rekordbox has none. The edit entries are
    /// live when `editable`, greyed otherwise.
    static func treeMenu(
        for kind: SidebarNode.Kind, editable: Bool = false, devices: [DeviceTarget] = [], deviceBusy: Bool = false
    ) -> [MenuRow]? {
        func edit(_ title: String, _ command: MenuCommand) -> MenuRow { editable ? live(title, command) : grey(title) }
        switch kind {
        case .section(.playlists):
            return [
                edit("Create New Playlist", .createPlaylist),
                edit("Create New Folder", .createFolder),
                edit("Create New Intelligent Playlist", .createSmartPlaylist),
            ]
        case .folder:
            return [
                grey("Export Folder", []),
                .separator,
                edit("Create New Playlist", .createPlaylist),
                edit("Create New Folder", .createFolder),
                edit("Create New Intelligent Playlist", .createSmartPlaylist),
                .separator,
                grey("Playlist display setting"),
                .separator,
                edit("Rename Folder", .rename),
                edit("Delete Folder", .delete),
                .separator,
                edit("Sort Items", .sortItems),
                .separator,
                grey("Add To Shortcut"),
            ]
        case .playlist, .smartPlaylist:
            var rows: [MenuRow] = [
                exportPlaylistMenu(devices),
                .separator,
                edit("Create New Playlist", .createPlaylist),
            ]
            if kind == .smartPlaylist { rows.append(edit("Edit Intelligent Playlist", .editSmartPlaylist)) }
            rows += [
                edit("Create New Folder", .createFolder),
                edit("Create New Intelligent Playlist", .createSmartPlaylist),
                .separator,
                grey("Playlist display setting"),
                .separator,
                grey("Add Artwork"),
                .separator,
                edit("Rename Playlist", .rename),
                edit("Delete Playlist", .delete),
                .separator,
                .item(
                    MenuItemSpec(
                        title: "Export a playlist to a file", command: nil,
                        submenu: [
                            live("m3u8", .exportPlaylist(.m3u8)),
                            live("txt", .exportPlaylist(.txt)),
                        ])),
                .separator,
                grey("Add To Shortcut"),
            ]
            return rows
        case .device:
            return [
                deviceBusy ? grey("Eject") : live("Eject", .ejectDevice),
                .separator,
                live("Sync Manager\u{2026}", .openSyncManager),
            ]
        case .section(.devices):
            return [live("Sync Manager\u{2026}", .openSyncManager)]
        default:
            return nil
        }
    }
}
