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
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outline: SidebarNSOutlineView?
        let model: AppModel
        private var sidebar: SidebarModel { model.sidebar }
        private var shownVersion = -1
        // Programmatic expansion and selection must not feed back into the model.
        private var applying = false

        init(model: AppModel) { self.model = model }

        func update(version: Int, selectedID: String?) {
            if version != shownVersion { reload() } else { syncSelection() }
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

        // MARK: Context menu

        func menu(for node: SidebarNode) -> NSMenu? {
            guard let rows = ContextMenus.treeMenu(for: node.kind) else { return nil }
            return MenuBuilder.menu(rows) { [weak self] command in self?.run(command, on: node) }
        }

        private func run(_ command: MenuCommand, on node: SidebarNode) {
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
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(scale: .medium)
        imageView = icon
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .tertiaryLabelColor
        count.translatesAutoresizingMaskIntoConstraints = false
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        addSubview(count)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -4),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @MainActor
    func show(_ node: SidebarNode, count shown: UInt32?) {
        label.stringValue = node.name
        if node.isSection { return }
        icon.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
        label.textColor = node.kind == .note ? .tertiaryLabelColor : .labelColor
        icon.isHidden = node.kind == .note
        count.stringValue = shown.map { String($0) } ?? ""
    }
}
