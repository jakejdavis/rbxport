import Foundation

/// What a live menu entry does. Entries with no command are drawn greyed: rekordbox has
/// them and the edit ones arrive in Phase 4. Order and labels follow `src/lib/contextMenus.ts`.
enum MenuCommand: Equatable, Sendable {
    case showInFinder
    case showInformation
    /// Load the selected track onto a deck (Player 1 is deck A).
    case loadToDeck(Deck)
    case exportPlaylist(PlaylistFileFormat)
}

struct MenuItemSpec: Equatable {
    var title: String
    var command: MenuCommand?
    var submenu: [MenuRow]?

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
    }

    /// Right-clicking a track, top to bottom as `TRACK_MENU` has it. Show in Finder, Show
    /// information and Load track to player 1 are live; player 2 arrives with the dual decks,
    /// the rest are edits (Phase 4).
    static func trackMenu(_ context: TrackContext) -> [MenuRow] {
        let hasSelection = context.selectionCount > 0
        var rows: [MenuRow] = [
            .item(
                MenuItemSpec(
                    title: "Load", command: nil,
                    submenu: [
                        context.selectionCount == 1 ? live("Load track to player 1", .loadToDeck(.a)) : grey("Load track to player 1"),
                        grey("Load track to player 2"),
                    ])),
            .separator,
            grey("Import To Collection"),
            grey("Analyze Track"),
            grey("Analysis Lock", [grey("On"), grey("Off")]),
            .separator,
            grey("Add To Playlist", []),
            grey("Add To Tag List"),
            grey("Reload Tag"),
            grey("Get Info from iTunes"),
            grey("Track Type", []),
            .separator,
            grey("Export Track", []),
            .separator,
            grey("Auto Load Hot Cue", [grey("Enable Auto Load Hot Cue"), grey("Disable Auto Load Hot Cue")]),
            grey("Reset DJ Play Count"),
            grey("Add New Analysis Data"),
        ]
        if !context.inExplorer { rows.append(grey("Convert Memory Cues to Hot Cues")) }
        rows += [
            .separator,
            grey(context.inTagList ? "Remove from Tag List" : "Remove from Playlist"),
            grey("Remove from Collection"),
            grey("Remove from History"),
            .separator,
            hasSelection ? live("Show information", .showInformation) : grey("Show information"),
            hasSelection ? live("Show in Finder", .showInFinder) : grey("Show in Finder"),
            .separator,
            grey("Track information", [grey("Publish"), grey("Do not publish")]),
        ]
        return rows
    }

    // MARK: Tree nodes

    /// The menu for a source-list node, or nil where rekordbox has none.
    static func treeMenu(for kind: SidebarNode.Kind) -> [MenuRow]? {
        switch kind {
        case .section(.playlists):
            return [grey("Create New Playlist"), grey("Create New Folder")]
        case .folder:
            return [
                grey("Export Folder", []),
                .separator,
                grey("Create New Playlist"),
                grey("Create New Folder"),
                .separator,
                grey("Playlist display setting"),
                .separator,
                grey("Rename Folder"),
                grey("Delete Folder"),
                .separator,
                grey("Sort Items"),
                .separator,
                grey("Add To Shortcut"),
            ]
        case .playlist, .smartPlaylist:
            var rows: [MenuRow] = [
                grey("Export Playlist", []),
                .separator,
                grey("Create New Playlist"),
            ]
            if kind == .smartPlaylist { rows.append(grey("Edit Intelligent Playlist")) }
            rows += [
                grey("Create New Folder"),
                .separator,
                grey("Playlist display setting"),
                .separator,
                grey("Add Artwork"),
                .separator,
                grey("Rename Playlist"),
                grey("Delete Playlist"),
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
        default:
            return nil
        }
    }
}
