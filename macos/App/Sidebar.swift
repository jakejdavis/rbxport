import Foundation
import Observation

/// The source list's top-level sections, in display order.
enum SidebarSection: String, CaseIterable, Sendable {
    case playlists, histories, explorer, itunes, devices, tagList

    var title: String {
        switch self {
        case .playlists: L10n.t("Playlists")
        case .histories: L10n.t("Histories")
        case .explorer: L10n.t("Explorer")
        case .itunes: L10n.t("iTunes")
        case .devices: L10n.t("Devices")
        case .tagList: L10n.t("Tag List")
        }
    }
}

/// One row of the source list. A class: `NSOutlineView` identifies items by reference.
@MainActor
final class SidebarNode {
    enum Kind: Equatable, Sendable {
        case section(SidebarSection)
        case allTracks, folder, playlist, smartPlaylist
        case historyFolder, history
        case explorerRoot, explorerFolder
        /// "N more folders not shown": informational, not selectable.
        case note
        case device
        case tagList
        /// The iTunes / Music library browser (read-only).
        case itunes
    }

    let id: String
    let kind: Kind
    var name: String
    var childCount: UInt32?
    /// The directory, for Explorer rows; the mount point, for devices.
    var path: String?
    /// A short line beside the name (a device's free space).
    var detail: String?
    var children: [SidebarNode] = []
    /// Explorer folders load their children when first expanded.
    var childrenLoaded = false
    var loading = false
    var defaultExpanded = false
    weak var parent: SidebarNode?

    init(id: String, kind: Kind, name: String, childCount: UInt32? = nil, path: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.childCount = childCount
        self.path = path
    }

    var isSection: Bool { if case .section = kind { true } else { false } }

    /// The name as drawn: the fixed rows (sections, All Tracks, Tag List) are translated;
    /// a playlist, folder, device or history keeps the name it was given.
    var displayName: String {
        switch kind {
        case .section(let section): section.title
        case .allTracks: L10n.t("All Tracks")
        case .tagList: L10n.t("Tag List")
        default: name
        }
    }

    var isExplorerDirectory: Bool { kind == .explorerRoot || kind == .explorerFolder }

    /// Whether a disclosure triangle is shown: a folder-like row, or an Explorer directory
    /// that has not been read yet (it may or may not have subfolders).
    var isExpandable: Bool {
        if isSection { return true }
        if isExplorerDirectory { return !childrenLoaded || !children.isEmpty }
        return !children.isEmpty
    }

    var isSelectable: Bool {
        switch kind {
        case .section, .note: false
        default: true
        }
    }

    /// Playlists, folders and histories can show how many tracks or entries they hold.
    var showsCount: Bool {
        switch kind {
        case .allTracks, .folder, .playlist, .historyFolder, .history: childCount != nil
        default: false
        }
    }

    var symbol: String {
        switch kind {
        case .section(let section):
            switch section {
            case .playlists: "music.note.list"
            case .histories: "clock"
            case .explorer: "externaldrive"
            case .itunes: "music.note.tv"
            case .devices: "cable.connector"
            case .tagList: "tag"
            }
        case .allTracks: "music.note.house"
        case .folder: "folder"
        case .playlist: "music.note"
        case .smartPlaylist: "gearshape"
        case .historyFolder: "calendar"
        case .history: "clock.arrow.circlepath"
        case .explorerRoot: "internaldrive"
        case .explorerFolder: "folder"
        case .note: "ellipsis"
        case .device: "externaldrive.fill"
        case .tagList: "tag"
        case .itunes: "music.quarternote.3"
        }
    }

    /// The track source a node id opens, or nil for a row that opens nothing. Ids carry their
    /// kind, so a persisted selection resolves without the node (an Explorer folder is not
    /// in the tree until its parents have been read).
    nonisolated static func source(forID id: String) -> TrackSource? {
        if id == "all" { return .collection }
        if id == "tag" { return .tagList }
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let rest = String(id[id.index(after: colon)...])
        switch id[..<colon] {
        case "pl": return .playlist(id: rest)
        case "pf": return .playlistFolder(id: rest)
        case "hi": return .history(id: rest)
        case "ex": return .folder(path: rest)
        default: return nil
        }
    }
}

/// The source list's content and expansion state. Persisted in `defaults`:
/// - `sidebar.expansion`: node id → expanded, only for rows the user has toggled
/// - `sidebar.childCounts`: show child counts (default off)
@MainActor @Observable
final class SidebarModel {
    /// Display order; Histories and the tag list are present only when there is something to show.
    private(set) var sections: [SidebarNode]
    /// Bumped on every structural change; the outline reloads when it moves.
    private(set) var version = 0
    private(set) var expansion: [String: Bool]
    /// The id of a row that should start an inline rename (a new playlist, F2). The outline
    /// takes it and clears it.
    var renameRequest: String? {
        didSet { if renameRequest != nil { version += 1 } }
    }

    var showChildCounts: Bool {
        didSet {
            guard showChildCounts != oldValue else { return }
            prefs.playlistCounts = showChildCounts
            version += 1
        }
    }

    @ObservationIgnored let defaults: UserDefaults
    let prefs: PreferencesStore
    @ObservationIgnored private let backend: any BackendProtocol
    /// Called with the list whenever the devices are set, so the device list model can follow.
    @ObservationIgnored var onDevices: ([Device]) -> Void = { _ in }
    /// Called after an Explorer folder's children arrive, so the outline can reload just that row.
    @ObservationIgnored var onNodeReloaded: (SidebarNode) -> Void = { _ in }

    enum Keys {
        static let expansion = "sidebar.expansion"
        static let selected = "sidebar.selectedNode"
    }

    /// Explorer folders listed per folder (the core's cap is 2000).
    static let noDevicesID = "note:no-devices"

    init(backend: any BackendProtocol, defaults: UserDefaults, prefs: PreferencesStore? = nil) {
        self.backend = backend
        self.defaults = defaults
        let prefs = prefs ?? PreferencesStore(defaults: defaults)
        self.prefs = prefs
        showChildCounts = prefs.playlistCounts
        expansion = (defaults.dictionary(forKey: Keys.expansion) as? [String: Bool]) ?? [:]
        sections = SidebarSection.allCases.map {
            SidebarNode(id: "section:\($0.rawValue)", kind: .section($0), name: $0.title)
        }
        section(.devices).children = [Self.noDevicesNote(parent: section(.devices))]
        section(.tagList).children = [Self.tagListNode(parent: section(.tagList))]
        section(.itunes).children = [Self.itunesNode(parent: section(.itunes))]
        prefs.onChange { [weak self] key in
            if key == PrefKeys.playlistCounts, let self, self.showChildCounts != prefs.playlistCounts {
                self.showChildCounts = prefs.playlistCounts
            }
        }
    }

    func section(_ which: SidebarSection) -> SidebarNode {
        sections.first { $0.kind == .section(which) }!
    }

    /// The sections to draw: Histories hides when the library has none.
    var visibleSections: [SidebarNode] {
        sections.filter { $0.kind != .section(.histories) || !$0.children.isEmpty }
    }

    func node(withID id: String) -> SidebarNode? {
        func find(_ nodes: [SidebarNode]) -> SidebarNode? {
            for node in nodes {
                if node.id == id { return node }
                if let hit = find(node.children) { return hit }
            }
            return nil
        }
        return find(sections)
    }

    /// Whether the id names a row that exists, or an Explorer folder (which may not be loaded yet).
    func canSelect(_ id: String) -> Bool {
        if id.hasPrefix("ex:") { return true }
        return node(withID: id)?.isSelectable ?? false
    }

    // MARK: Building

    /// Rebuilds Playlists and Histories from the core's flat, depth-ordered tree.
    func setLibraryTree(_ flat: [TreeNode]) {
        let playlists = section(.playlists)
        let histories = section(.histories)
        playlists.children = []
        histories.children = []
        var target: SidebarNode?
        var stack: [(depth: UInt32, node: SidebarNode)] = []
        for item in flat {
            if item.depth == 0 {
                stack = []
                switch item.kind {
                case .allTracks:
                    let all = SidebarNode(id: "all", kind: .allTracks, name: item.name, childCount: item.childCount)
                    all.parent = playlists
                    playlists.children.append(all)
                    target = playlists
                case .collection: target = playlists
                case .histories: target = histories
                default: break
                }
                continue
            }
            guard let target else { continue }
            while let top = stack.last, top.depth >= item.depth { stack.removeLast() }
            let parent = stack.last?.node ?? target
            let node = Self.node(for: item)
            node.parent = parent
            parent.children.append(node)
            if item.expanded != nil { stack.append((item.depth, node)) }
        }
        version += 1
    }

    private static func node(for item: TreeNode) -> SidebarNode {
        let kind: SidebarNode.Kind
        let prefix: String
        switch item.kind {
        case .folder: (kind, prefix) = (.folder, "pf")
        case .smartPlaylist: (kind, prefix) = (.smartPlaylist, "pl")
        case .historyFolder: (kind, prefix) = (.historyFolder, "hi")
        case .history: (kind, prefix) = (.history, "hi")
        default: (kind, prefix) = (.playlist, "pl")
        }
        let node = SidebarNode(id: "\(prefix):\(item.id)", kind: kind, name: item.name, childCount: item.childCount)
        node.defaultExpanded = item.expanded ?? false
        return node
    }

    private static func noDevicesNote(parent: SidebarNode) -> SidebarNode {
        let note = SidebarNode(id: noDevicesID, kind: .note, name: "No devices")
        note.parent = parent
        return note
    }

    static let itunesID = "itunes"

    private static func itunesNode(parent: SidebarNode) -> SidebarNode {
        let node = SidebarNode(id: itunesID, kind: .itunes, name: "Music Library")
        node.parent = parent
        return node
    }

    private static func tagListNode(parent: SidebarNode) -> SidebarNode {
        let node = SidebarNode(id: "tag", kind: .tagList, name: "Tag List")
        node.parent = parent
        return node
    }

    func setExplorerRoots(_ roots: [ExplorerRoot]) {
        let explorer = section(.explorer)
        explorer.children = roots.map {
            let node = SidebarNode(id: "ex:\($0.path)", kind: .explorerRoot, name: $0.name, path: $0.path)
            node.parent = explorer
            return node
        }
        version += 1
    }

    /// Redraws the rows without changing their structure (a device became busy or free).
    func reloadRows() { version += 1 }

    func setDevices(_ devices: [Device]) {
        let section = section(.devices)
        if devices.isEmpty {
            section.children = [Self.noDevicesNote(parent: section)]
        } else {
            section.children = devices.map {
                // The mount point names a device: volume ids repeat across fake and cloned volumes.
                let node = SidebarNode(id: "dev:\($0.path)", kind: .device, name: $0.name, path: $0.path)
                node.detail = $0.totalBytes > 0 ? "\(CellFormat.bytes($0.freeBytes)) free" : nil
                node.parent = section
                return node
            }
        }
        version += 1
        onDevices(devices)
    }

    /// Re-lists the mounted volumes. Cheap enough to run when the library loads or the section opens.
    func refreshDevices() async {
        if let devices = try? await backend.listDevices() { setDevices(devices) }
    }

    // MARK: Expansion

    func isExpanded(_ node: SidebarNode) -> Bool {
        if node.isSection { return expansion[node.id] ?? true }
        guard node.isExpandable else { return false }
        return expansion[node.id] ?? node.defaultExpanded
    }

    func setExpanded(_ node: SidebarNode, _ expanded: Bool) {
        guard expansion[node.id] != expanded else { return }
        expansion[node.id] = expanded
        defaults.set(expansion, forKey: Keys.expansion)
    }

    // MARK: Explorer

    /// Reads the folders under an Explorer directory the first time it is needed.
    func loadChildren(of node: SidebarNode) async {
        guard node.isExplorerDirectory, !node.childrenLoaded, !node.loading, let path = node.path else { return }
        node.loading = true
        defer { node.loading = false }
        // An unreadable folder answers with nothing: an empty branch.
        let listing = (try? await backend.explorerChildren(path: path)) ?? ExplorerChildren(names: [], total: 0)
        node.children = listing.names.map { name in
            let full = (path as NSString).appendingPathComponent(name)
            let child = SidebarNode(id: "ex:\(full)", kind: .explorerFolder, name: name, path: full)
            child.parent = node
            return child
        }
        let hidden = Int(listing.total) - listing.names.count
        if hidden > 0 {
            let note = SidebarNode(
                id: "note:\(node.id)", kind: .note, name: "\(hidden) more folder\(hidden == 1 ? "" : "s") not shown")
            note.parent = node
            node.children.append(note)
        }
        node.childrenLoaded = true
        onNodeReloaded(node)
        await loadExpandedChildren(under: node)
    }

    /// Re-reads expanded Explorer folders after a launch, top-down.
    func restoreExplorer() async {
        for root in section(.explorer).children where isExpanded(root) { await loadChildren(of: root) }
    }

    private func loadExpandedChildren(under node: SidebarNode) async {
        for child in node.children where child.isExplorerDirectory && isExpanded(child) {
            await loadChildren(of: child)
        }
    }

    /// Forgets what was read, so the next expansion lists the folder again.
    func reloadExplorer(_ node: SidebarNode) async {
        node.childrenLoaded = false
        node.children = []
        await loadChildren(of: node)
    }
}
