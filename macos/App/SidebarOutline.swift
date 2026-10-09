import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The source list: an `NSOutlineView` in source-list style with collapsible group sections.
/// It reads the `SidebarModel` and reports clicks, expansion and menu commands back to it.
/// Explorer folders load their children when first expanded.
struct SidebarOutline: NSViewRepresentable {
    let model: AppModel
    /// Passed in so SwiftUI re-runs `updateNSView` when the structure or selection moves.
    let version: Int
    let selectedID: String?
    let showCounts: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarNSOutlineView()
        outline.style = .sourceList
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 12
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.menuProvider = { [weak coordinator = context.coordinator] node in coordinator?.menu(for: node) }
        outline.onRename = { [weak coordinator = context.coordinator] in coordinator?.renameSelected() }
        outline.registerForDraggedTypes([.rbxportSidebarNode, .rbxportTracks, .rbxportExportTracks, .rbxportExportPlaylist, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        context.coordinator.outline = outline
        model.sidebar.onNodeReloaded = { [weak coordinator = context.coordinator] node in
            coordinator?.nodeReloaded(node)
        }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.reload()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(version: version, selectedID: selectedID)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        weak var outline: SidebarNSOutlineView?
        let model: AppModel
        private var sidebar: SidebarModel { model.sidebar }
        private var shownVersion = -1
        // Programmatic expansion and selection must not feed back into the model.
        private var applying = false
        /// The row whose name is being edited, and whether Escape was pressed.
        private var renamingNode: SidebarNode?
        private var renameCancelled = false

        init(model: AppModel) { self.model = model }

        private var shownLanguage = L10n.current

        func update(version: Int, selectedID: String?) {
            _ = L10n.revision.value
            if version != shownVersion || L10n.current != shownLanguage {
                shownLanguage = L10n.current
                reload()
            } else { syncSelection() }
            if let id = sidebar.renameRequest {
                // After this update: starting an edit changes first responder and layout.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sidebar.renameRequest == id else { return }
                    self.sidebar.renameRequest = nil
                    if let node = self.sidebar.node(withID: id) { self.beginRename(node) }
                }
            }
        }

        // MARK: Inline rename

        func renameSelected() {
            guard model.canEdit, let outline, outline.selectedRow >= 0,
                let node = outline.item(atRow: outline.selectedRow) as? SidebarNode, node.isEditableItem
            else { return }
            beginRename(node)
        }

        /// Puts the row's name into a text field. Enter or clicking away commits, Escape restores.
        func beginRename(_ node: SidebarNode) {
            guard let outline, node.isEditableItem else { return }
            var ancestor = node.parent
            applying = true
            while let current = ancestor, !current.isSection {
                outline.expandItem(current)
                ancestor = current.parent
            }
            applying = false
            let row = outline.row(forItem: node)
            guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView
            else { return }
            outline.scrollRowToVisible(row)
            renamingNode = node
            renameCancelled = false
            cell.beginEditing(delegate: self)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            renameCancelled = true
            outline?.window?.makeFirstResponder(outline)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let node = renamingNode else { return }
            renamingNode = nil
            let text = field.stringValue
            (field.superview as? SidebarCellView)?.endEditing(restoring: node.name)
            outline?.window?.makeFirstResponder(outline)
            guard !renameCancelled else { return }
            let model = model
            Task { await model.rename(node, to: text) }
        }

        func reload() {
            guard let outline else { return }
            shownVersion = sidebar.version
            applying = true
            outline.reloadData()
            applyExpansion(under: nil)
            applying = false
            syncSelection()
        }

        /// One Explorer folder's children arrived.
        func nodeReloaded(_ node: SidebarNode) {
            guard let outline else { return }
            applying = true
            outline.reloadItem(node, reloadChildren: true)
            if sidebar.isExpanded(node) { outline.expandItem(node) }
            applyExpansion(under: node)
            applying = false
            syncSelection()
        }

        private func applyExpansion(under parent: SidebarNode?) {
            guard let outline else { return }
            let nodes = parent?.children ?? sidebar.visibleSections
            for node in nodes where node.isExpandable {
                if sidebar.isExpanded(node) {
                    outline.expandItem(node)
                    applyExpansion(under: node)
                } else {
                    outline.collapseItem(node)
                }
            }
        }

        private func syncSelection() {
            guard let outline else { return }
            let wanted = model.selectedNodeID.flatMap { sidebar.node(withID: $0) }
            let row = wanted.map { outline.row(forItem: $0) } ?? -1
            guard row != outline.selectedRow else { return }
            applying = true
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            else { outline.deselectAll(nil) }
            applying = false
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? SidebarNode else { return sidebar.visibleSections.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? SidebarNode else { return sidebar.visibleSections[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? SidebarNode)?.isExpandable ?? false
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? SidebarNode)?.isSection ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? SidebarNode)?.isSelectable ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier(node.isSection ? "section" : "node")
            let cell =
                outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCellView
                ?? SidebarCellView(identifier: identifier, isSection: node.isSection)
            cell.show(node, count: sidebar.showChildCounts && node.showsCount ? node.childCount : nil)
            if node.kind == .device {
                let model = model
                let path = node.path
                cell.configureEject(enabled: path.flatMap { model.devices.device(path: $0) }.map { model.devices.canEject($0) } ?? false) {
                    if let path { Task { await model.eject(path: path) } }
                }
            }
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let outline, outline.selectedRow >= 0,
                let node = outline.item(atRow: outline.selectedRow) as? SidebarNode
            else { return }
            model.selectNode(node.id)
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
            if node.isExplorerDirectory, !node.childrenLoaded {
                let sidebar = sidebar
                Task { await sidebar.loadChildren(of: node) }
            }
            if node.kind == .section(.devices) {
                let sidebar = sidebar
                Task { await sidebar.refreshDevices() }
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !applying, let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
            sidebar.setExpanded(node, true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !applying, let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
            sidebar.setExpanded(node, false)
        }

        // MARK: Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? SidebarNode, node.isEditableItem else { return nil }
            let pasteboardItem = NSPasteboardItem()
            // Moving a playlist inside the tree is an edit; dragging one to a device is not.
            if model.canEdit { pasteboardItem.setString(node.id, forType: .rbxportSidebarNode) }
            if node.kind == .playlist || node.kind == .smartPlaylist, let id = node.libraryID {
                pasteboardItem.setString(id, forType: .rbxportExportPlaylist)
            }
            return pasteboardItem.types.isEmpty ? nil : pasteboardItem
        }

        func outlineView(
            _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            let pasteboard = info.draggingPasteboard
            // A device takes playlists and tracks to export; nothing else is dropped on it.
            if let node = item as? SidebarNode, node.kind == .device {
                guard index == NSOutlineViewDropOnItemIndex, deviceDropAccepts(pasteboard, node) else { return [] }
                return .copy
            }
            guard model.canEdit else { return [] }
            if let id = pasteboard.string(forType: .rbxportSidebarNode), let dragged = sidebar.node(withID: id) {
                guard let plan = sidebar.movePlan(dragging: dragged, onto: item as? SidebarNode, childIndex: index) else {
                    return []
                }
                outlineView.setDropItem(plan.outlineParent, dropChildIndex: plan.outlineIndex)
                return .move
            }
            if pasteboard.availableType(from: [.rbxportTracks]) == nil,
                pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            {
                // Files from the Finder are imported, and added when dropped on a playlist.
                guard let node = item as? SidebarNode, index == NSOutlineViewDropOnItemIndex,
                    node.kind == .playlist || node.kind == .allTracks
                else { return [] }
                return .copy
            }
            if pasteboard.availableType(from: [.rbxportTracks]) != nil {
                // Tracks land on an ordinary playlist (a smart one is its rule; a folder holds none).
                guard let node = item as? SidebarNode, node.kind == .playlist, index == NSOutlineViewDropOnItemIndex
                else { return [] }
                return .copy
            }
            return []
        }

        func outlineView(
            _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
        ) -> Bool {
            let pasteboard = info.draggingPasteboard
            let model = model
            if let node = item as? SidebarNode, node.kind == .device, let path = node.path {
                if let playlist = pasteboard.string(forType: .rbxportExportPlaylist), !playlist.isEmpty {
                    Task { await model.exportPlaylist(id: playlist, to: path) }
                    return true
                }
                let tracks = NSPasteboard.PasteboardType.exportTrackIDs(from: pasteboard)
                if !tracks.isEmpty {
                    Task { await model.exportTracks(tracks, to: path) }
                    return true
                }
                return false
            }
            if let id = pasteboard.string(forType: .rbxportSidebarNode), let dragged = sidebar.node(withID: id),
                let plan = sidebar.movePlan(dragging: dragged, onto: item as? SidebarNode, childIndex: index)
            {
                Task { await model.move(dragged, to: plan) }
                return true
            }
            if pasteboard.availableType(from: [.rbxportTracks]) == nil,
                let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                !urls.isEmpty, let node = item as? SidebarNode
            {
                Task { await model.dropFiles(urls, on: node) }
                return true
            }
            let tracks = NSPasteboard.PasteboardType.trackIDs(from: pasteboard)
            if !tracks.isEmpty, let node = item as? SidebarNode, node.kind == .playlist, let playlist = node.libraryID {
                Task { await model.addToPlaylist(playlist, trackIDs: tracks) }
                return true
            }
            return false
        }

        /// Whether a drag carries something a device can be given, and the device is free.
        private func deviceDropAccepts(_ pasteboard: NSPasteboard, _ node: SidebarNode) -> Bool {
            guard let path = node.path, !model.exportJobs.isActive(path: path) else { return false }
            if let playlist = pasteboard.string(forType: .rbxportExportPlaylist), !playlist.isEmpty { return true }
            return !NSPasteboard.PasteboardType.exportTrackIDs(from: pasteboard).isEmpty
        }

        // MARK: Context menu

        func menu(for node: SidebarNode) -> NSMenu? {
            let device = node.path.flatMap { model.devices.device(path: $0) }
            let rows = ContextMenus.treeMenu(
                for: node.kind, editable: model.canEdit, devices: model.deviceTargets,
                deviceBusy: device.map { !model.devices.canEject($0) } ?? false)
            guard let rows else { return nil }
            return MenuBuilder.menu(rows) { [weak self] command in self?.run(command, on: node) }
        }

        private func run(_ command: MenuCommand, on node: SidebarNode) {
            switch command {
            case .exportToDevice, .ejectDevice, .openSyncManager, .importFromDevice:
                model.runDeviceMenu(command, on: node)
                return
            case .exportPlaylist:
                break
            default:
                model.runTreeMenu(command, on: node)
                return
            }
            guard case .exportPlaylist(let format) = command else { return }
            let panel = NSSavePanel()
            let ext = format == .txt ? "txt" : "m3u8"
            panel.nameFieldStringValue = "\(node.name).\(ext)"
            if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
            panel.canCreateDirectories = true
            let model = model
            let id = node.id
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in await model.exportPlaylist(nodeID: id, to: url, format: format) }
            }
        }
    }
}

/// Builds `NSMenu`s from the pure menu description.
@MainActor
enum MenuBuilder {
    static func menu(_ rows: [MenuRow], handler: @escaping (MenuCommand) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for row in rows {
            switch row {
            case .separator:
                menu.addItem(.separator())
            case .item(let spec):
                let item = ClosureMenuItem(title: spec.title)
                item.isEnabled = spec.isEnabled
                if let dot = spec.colorDot { item.image = TrackColors.dot(dot) }
                if let submenu = spec.submenu {
                    item.submenu = Self.menu(submenu, handler: handler)
                } else if let command = spec.command {
                    item.handler = { handler(command) }
                }
                menu.addItem(item)
            }
        }
        return menu
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)? {
        didSet {
            target = self
            action = handler == nil ? nil : #selector(run)
        }
    }

    init(title: String) { super.init(title: title, action: nil, keyEquivalent: "") }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler?() }
}

/// `NSOutlineView` that asks for a menu per row, and does not select what it right-clicks.
final class SidebarNSOutlineView: NSOutlineView {
    var menuProvider: ((SidebarNode) -> NSMenu?)?
    /// Return or F2 on the selected row.
    var onRename: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 120: onRename?()  // Return, Enter, F2
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? SidebarNode else { return nil }
        return menuProvider?(node)
    }
}

/// One source-list row: symbol, name, and an optional count.
final class SidebarCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let eject = NSButton()
    private var onEject: (() -> Void)?
    private lazy var ejectWidth = eject.widthAnchor.constraint(equalToConstant: 0)

    init(identifier: NSUserInterfaceItemIdentifier, isSection: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        if isSection {
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            return
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = Self.iconTint(emphasized: false)
        icon.symbolConfiguration = .init(scale: .medium)
        imageView = icon
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .tertiaryLabelColor
        count.translatesAutoresizingMaskIntoConstraints = false
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        eject.isBordered = false
        eject.imagePosition = .imageOnly
        eject.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
        eject.contentTintColor = .secondaryLabelColor
        eject.target = self
        eject.action = #selector(ejectClicked)
        eject.isHidden = true
        eject.setAccessibilityLabel("Eject")
        eject.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        addSubview(count)
        addSubview(eject)
        NSLayoutConstraint.activate([
            eject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            eject.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectWidth,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -4),
            count.trailingAnchor.constraint(equalTo: eject.leadingAnchor, constant: -2),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Source-list icons are accent-coloured, as in Music.app, and turn white on a selected
    /// (emphasised) row so they do not vanish into the selection.
    static func iconTint(emphasized: Bool) -> NSColor {
        emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { icon.contentTintColor = Self.iconTint(emphasized: backgroundStyle == .emphasized) }
    }

    @objc private func ejectClicked() { onEject?() }

    /// A device row's Eject button: dimmed while an export is writing to it.
    @MainActor
    func configureEject(enabled: Bool, action: @escaping () -> Void) {
        eject.isHidden = false
        ejectWidth.constant = 16
        eject.isEnabled = enabled
        eject.toolTip = enabled ? "Eject" : DevicesModel.busyMessage
        onEject = action
    }

    /// Turns the name into an editable field with its text selected.
    @MainActor
    func beginEditing(delegate: NSTextFieldDelegate) {
        label.isEditable = true
        label.isSelectable = true
        label.delegate = delegate
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectAll(nil)
    }

    @MainActor
    func endEditing(restoring name: String) {
        label.isEditable = false
        label.isSelectable = false
        label.delegate = nil
        label.stringValue = name
    }

    @MainActor
    func show(_ node: SidebarNode, count shown: UInt32?) {
        label.stringValue = node.displayName
        if node.isSection { return }
        icon.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
        label.textColor = node.kind == .note ? .tertiaryLabelColor : .labelColor
        icon.isHidden = node.kind == .note
        count.stringValue = node.detail ?? shown.map { String($0) } ?? ""
        eject.isHidden = true
        ejectWidth.constant = 0
        onEject = nil
        toolTip = nil
    }
}
