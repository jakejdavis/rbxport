import AppKit
import SwiftUI

/// An AppKit table over a view of the library. Rows load lazily, one page of
/// 128 at a time, as `NSTableView` asks for the cells that are on screen.
struct TrackTable: NSViewRepresentable {
    let library: LibraryHandle
    let opened: OpenedView
    let onSort: (String, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 22
        table.columnAutoresizingStyle = .noColumnAutoresizing

        for spec in Coordinator.columns {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 30
            column.resizingMask = .userResizingMask
            if spec.sortable {
                column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            }
            if spec.rightAligned { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSort = onSort
        coordinator.library = library
        if coordinator.opened != opened {
            coordinator.show(opened)
            if let first = scroll.documentView as? NSTableView, first.numberOfRows > 0 {
                first.scrollRowToVisible(0)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct Spec {
            let id: String
            let title: String
            let width: CGFloat
            var sortable = true
            var rightAligned = false
        }

        // Column ids double as `sort_from_wire` names ("trackNo" falls back to track order).
        static let columns: [Spec] = [
            Spec(id: "trackNo", title: "#", width: 50, rightAligned: true),
            Spec(id: "title", title: "Title", width: 280),
            Spec(id: "artist", title: "Artist", width: 180),
            Spec(id: "album", title: "Album", width: 180),
            Spec(id: "genre", title: "Genre", width: 110),
            Spec(id: "bpm", title: "BPM", width: 64, rightAligned: true),
            Spec(id: "key", title: "Key", width: 54),
            Spec(id: "duration", title: "Time", width: 56, rightAligned: true),
            Spec(id: "rating", title: "Rating", width: 70),
            Spec(id: "dateAdded", title: "Date Added", width: 100),
        ]

        nonisolated static let pageSize = 128
        /// Pages kept in memory; a view this size is far more than a screen needs.
        static let maxPages = 256

        weak var table: NSTableView?
        var library: LibraryHandle?
        var onSort: (String, Bool) -> Void = { _, _ in }
        private(set) var opened: OpenedView?

        /// Cache keyed by view id + page.
        private struct PageKey: Hashable { let viewID: UInt32; let page: Int }
        private var pages: [PageKey: [Row]] = [:]
        private var pageOrder: [PageKey] = []
        private var inFlight: Set<PageKey> = []
        private var applyingSortFromModel = false

        func show(_ opened: OpenedView) {
            self.opened = opened
            pages.removeAll(keepingCapacity: true)
            pageOrder.removeAll(keepingCapacity: true)
            inFlight.removeAll()
            table?.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            Int(opened?.handle.len ?? 0)
        }

        private func row(at index: Int) -> Row? {
            guard let opened else { return nil }
            let key = PageKey(viewID: opened.handle.viewId, page: index / Self.pageSize)
            if let page = pages[key] { return page[safe: index % Self.pageSize] }
            load(key)
            return nil
        }

        private func load(_ key: PageKey) {
            guard let library, !inFlight.contains(key) else { return }
            inFlight.insert(key)
            let offset = UInt32(key.page * Self.pageSize)
            Task {
                let rows = try? await Task.detached(priority: .userInitiated) {
                    try library.fetchRows(viewId: key.viewID, offset: offset, len: UInt32(Self.pageSize))
                }.value
                inFlight.remove(key)
                // Drop the page if the table has moved on to another view.
                guard let rows, key.viewID == opened?.handle.viewId else { return }
                pages[key] = rows
                pageOrder.append(key)
                if pageOrder.count > Self.maxPages {
                    pages.removeValue(forKey: pageOrder.removeFirst())
                }
                let first = key.page * Self.pageSize
                table?.reloadData(
                    forRowIndexes: IndexSet(integersIn: first..<(first + rows.count)),
                    columnIndexes: IndexSet(integersIn: 0..<(table?.numberOfColumns ?? 0)))
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            guard let id = tableColumn?.identifier else { return nil }
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            let spec = Self.columns.first { $0.id == id.rawValue }
            cell.textField?.alignment = spec?.rightAligned == true ? .right : .left
            if let data = row(at: index) {
                cell.textField?.stringValue = Self.text(for: id.rawValue, in: data)
                cell.textField?.textColor = .labelColor
            } else {
                // Placeholder until the page arrives.
                cell.textField?.stringValue = id.rawValue == "title" ? "Loading..." : ""
                cell.textField?.textColor = .tertiaryLabelColor
            }
            return cell
        }

        static func text(for column: String, in row: Row) -> String {
            switch column {
            case "trackNo": String(row.trackNo)
            case "title": row.title
            case "artist": row.artist
            case "album": row.album
            case "genre": row.genre
            case "bpm": row.bpmX100 == 0 ? "" : String(format: "%.2f", Double(row.bpmX100) / 100)
            case "key": row.key
            case "duration": String(format: "%d:%02d", row.durationSec / 60, row.durationSec % 60)
            case "rating": String(repeating: "\u{2605}", count: Int(min(row.rating, 5)))
            case "dateAdded": row.dateAdded
            default: ""
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            onSort(key, !descriptor.ascending)
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
