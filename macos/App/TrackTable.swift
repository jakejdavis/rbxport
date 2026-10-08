import AppKit
import SwiftUI

/// An AppKit table over a view of the library. Rows load lazily, one page of
/// 128 at a time, as `NSTableView` asks for the cells that are on screen.
struct TrackTable: NSViewRepresentable {
    let backend: any BackendProtocol
    let opened: OpenedView
    let onSort: (SortKey, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(backend: backend) }

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
            if spec.sort != nil {
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
            var sort: SortKey?
            var rightAligned = false
        }

        static let columns: [Spec] = [
            Spec(id: "trackNo", title: "#", width: 50, sort: .trackNo, rightAligned: true),
            Spec(id: "title", title: "Title", width: 280, sort: .title),
            Spec(id: "artist", title: "Artist", width: 180, sort: .artist),
            Spec(id: "album", title: "Album", width: 180, sort: .album),
            Spec(id: "genre", title: "Genre", width: 110, sort: .genre),
            Spec(id: "bpm", title: "BPM", width: 64, sort: .bpm, rightAligned: true),
            Spec(id: "key", title: "Key", width: 54, sort: .key),
            Spec(id: "duration", title: "Time", width: 56, sort: .duration, rightAligned: true),
            Spec(id: "rating", title: "Rating", width: 70, sort: .rating),
            Spec(id: "dateAdded", title: "Date Added", width: 100, sort: .dateAdded),
        ]

        weak var table: NSTableView?
        var onSort: (SortKey, Bool) -> Void = { _, _ in }
        private let pager: RowPager

        var opened: OpenedView? { pager.opened }

        init(backend: any BackendProtocol) {
            pager = RowPager(backend: backend)
            super.init()
            pager.onPageLoaded = { [weak self] range in
                guard let table = self?.table else { return }
                table.reloadData(
                    forRowIndexes: IndexSet(integersIn: range),
                    columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
        }

        func show(_ opened: OpenedView) {
            pager.show(opened)
            table?.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { pager.rowCount }

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
            if let data = pager.row(at: index) {
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
            guard let descriptor = tableView.sortDescriptors.first, let id = descriptor.key,
                let key = Self.columns.first(where: { $0.id == id })?.sort
            else { return }
            onSort(key, !descriptor.ascending)
        }
    }
}
