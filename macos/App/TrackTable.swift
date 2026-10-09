import AppKit
import SwiftUI

/// An AppKit table over a view of the library. Rows load lazily, one page of 128 at a
/// time, as `NSTableView` asks for the cells that are on screen. Columns, order and
/// widths come from the model's layout; selection is mirrored into the model by track id.
struct TrackTable: NSViewRepresentable {
    let model: AppModel
    let opened: OpenedView
    let layout: ColumnLayout
    let keyStyle: KeyStyle
    let sortKey: SortKey
    let descending: Bool
    let palette: WaveformPalette
    let rowHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TrackNSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.rowHeight = rowHeight
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.rowDoubleClicked)
        table.onLoad = { [weak coordinator = context.coordinator] deck in coordinator?.loadSelectedToDeck(deck: deck) }
        table.keymap = { [weak model] in model?.prefs.keymap ?? Keymap() }
        table.onEscape = { [weak model] in model?.clearSearch() }
        table.menuProvider = { [weak coordinator = context.coordinator] row in coordinator?.menu(forRow: row) }
        table.onDelete = { [weak model] in
            // Delete takes the selection out of the open playlist. A locked library refuses with its own message.
            guard let model, model.openPlaylistID != nil, !model.selectedIDs.isEmpty else { return }
            Task { await model.removeSelectionFromPlaylist() }
        }
        table.registerForDraggedTypes([.rbxportTracks, .fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .gap
        context.coordinator.table = table
        context.coordinator.installHeaderMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.update(
            opened: opened, layout: layout, keyStyle: keyStyle, sortKey: sortKey, descending: descending,
            palette: palette, rowHeight: rowHeight)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let viewChanged = coordinator.shownView != opened
        // Reading the language here re-runs this method when it changes, and the headers are retitled.
        coordinator.retitleColumns(language: L10n.current, revision: L10n.revision.value)
        coordinator.update(
            opened: opened, layout: layout, keyStyle: keyStyle, sortKey: sortKey, descending: descending,
            palette: palette, rowHeight: rowHeight)
        if viewChanged, let table = scroll.documentView as? NSTableView, table.numberOfRows > 0 {
            table.scrollRowToVisible(0)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var table: TrackNSTableView?
        let model: AppModel
        private var pager: RowPager { model.pager }

        private(set) var shownView: OpenedView?
        private var layout = ColumnLayout.defaults(for: .collection)
        private var keyStyle = KeyStyle.classic
        private var palette = WaveformPalette.bands
        // Guards against feeding our own changes back to the model.
        private var applying = false
        private var restoring = false
        private var settingSort = false

        init(model: AppModel) {
            self.model = model
            super.init()
            pager.onPageLoaded = { [weak self] range in self?.pagesLoaded(range) }
            model.player.preview.onChange = { [weak self] in self?.refreshPreviewCells() }
        }

        /// The previewing row changed: every visible Preview cell redraws its playhead.
        private func refreshPreviewCells() {
            guard let table else { return }
            for row in 0..<table.numberOfRows where table.rowView(atRow: row, makeIfNecessary: false) != nil {
                for case let cell as PreviewCellView in table.rowView(atRow: row, makeIfNecessary: false)?.subviews ?? [] {
                    cell.refreshPlayhead()
                }
            }
        }

        // MARK: Updating from the model

        func update(
            opened: OpenedView, layout: ColumnLayout, keyStyle: KeyStyle, sortKey: SortKey, descending: Bool,
            palette: WaveformPalette, rowHeight: CGFloat
        ) {
            guard let table else { return }
            let styleChanged = keyStyle != self.keyStyle
            let paletteChanged = palette != self.palette
            self.keyStyle = keyStyle
            self.palette = palette
            if table.rowHeight != rowHeight {
                table.rowHeight = rowHeight
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
            }
            applyColumns(layout)
            if shownView != opened {
                shownView = opened
                applying = true
                table.reloadData()
                table.deselectAll(nil)
                applying = false
            } else if styleChanged || paletteChanged {
                table.reloadData(
                    forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows),
                    columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
            syncSortIndicator(sortKey: sortKey, descending: descending)
            restoreSelection(in: 0..<pager.rowCount)
        }

        private func shownIDs() -> [ColumnID] {
            (table?.tableColumns ?? []).compactMap { ColumnID(rawValue: $0.identifier.rawValue) }
        }

        private func applyColumns(_ new: ColumnLayout) {
            guard let table else { return }
            applying = true
            defer { applying = false }
            layout = new
            if shownIDs() != new.shown {
                for column in table.tableColumns { table.removeTableColumn(column) }
                for id in new.shown { table.addTableColumn(makeColumn(id)) }
                table.reloadData()
                return
            }
            for column in table.tableColumns {
                guard let id = ColumnID(rawValue: column.identifier.rawValue) else { continue }
                let width = new.width(of: id)
                // The layout rounds widths; a fractional drag in progress is not a change.
                if abs(column.width - width) >= 1 { column.width = CGFloat(width) }
            }
        }

        private var titledIn: String?

        /// Column headers in the current language (they are NSTableColumn titles, which SwiftUI does not touch).
        func retitleColumns(language: String, revision: Int) {
            guard let table, titledIn != language else { return }
            titledIn = language
            for column in table.tableColumns {
                guard let id = ColumnID(rawValue: column.identifier.rawValue) else { continue }
                let title = L10n.t(ColumnCatalogue.spec(for: id).label, locale: language)
                if column.title != title { column.title = title }
            }
            table.headerView?.needsDisplay = true
        }

        private func makeColumn(_ id: ColumnID) -> NSTableColumn {
            let spec = ColumnCatalogue.spec(for: id)
            let column = NSTableColumn(identifier: .init(id.rawValue))
            column.title = L10n.t(spec.label)
            column.minWidth = ColumnCatalogue.minWidth
            column.maxWidth = ColumnCatalogue.maxWidth
            column.width = CGFloat(layout.width(of: id))
            column.resizingMask = .userResizingMask
            if spec.sortable {
                column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true)
            }
            if spec.rightAligned { column.headerCell.alignment = .right }
            return column
        }

        private func syncSortIndicator(sortKey: SortKey, descending: Bool) {
            guard let table else { return }
            let column = ColumnCatalogue.all.first { $0.sortKey(for: keyStyle) == sortKey }
            let wanted = column.map { [NSSortDescriptor(key: $0.id.rawValue, ascending: !descending)] } ?? []
            guard table.sortDescriptors != wanted else { return }
            settingSort = true
            table.sortDescriptors = wanted
            settingSort = false
        }

        // MARK: Pages and selection

        private func pagesLoaded(_ range: Range<Int>) {
            guard let table else { return }
            table.reloadData(
                forRowIndexes: IndexSet(integersIn: range),
                columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            restoreSelection(in: range)
            model.recomputeSelectionSummary()
            // Dev aid: RBXPORT_SELECT_ROW=<n> selects that row once, for screenshots.
            if !autoSelected, let text = ProcessInfo.processInfo.environment["RBXPORT_SELECT_ROW"],
                let n = Int(text), range.contains(n)
            {
                autoSelected = true
                table.selectRowIndexes(IndexSet(integer: n), byExtendingSelection: false)
            }
            // Dev aid: RBXPORT_EDIT_CELL=<row>:<column> opens that cell's editor (fixture runs only;
            // it writes nothing until a value is committed).
            if !autoEdited, let text = ProcessInfo.processInfo.environment["RBXPORT_EDIT_CELL"],
                ProcessInfo.processInfo.environment["RBXPORT_FIXTURE_DIR"] != nil, model.canEdit,
                let colon = text.firstIndex(of: ":"), let n = Int(text[..<colon]), range.contains(n),
                let id = ColumnID(rawValue: String(text[text.index(after: colon)...])),
                let at = shownIDs().firstIndex(of: id)
            {
                autoEdited = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.table?.selectRowIndexes(IndexSet(integer: n), byExtendingSelection: false)
                    self?.beginEditing(row: n, column: at)
                }
            }
            // Dev aids: RBXPORT_LOAD_ROW=<n> loads that row onto deck A (RBXPORT_PLAY=1 also plays it);
            // RBXPORT_PREVIEW_ROW=<n> previews that row from 30%.
            let env = ProcessInfo.processInfo.environment
            if !autoLoaded, let text = env["RBXPORT_LOAD_ROW"], let n = Int(text), range.contains(n),
                let row = pager.peek(at: n)
            {
                autoLoaded = true
                model.loadToDeck(trackID: row.id)
                if env["RBXPORT_PLAY"] == "1" { model.player.deckA.playWhenLoaded() }
                // RBXPORT_SEEK=<seconds> and RBXPORT_LOOP_BEATS=<n>: once the deck and its grid are
                // ready, move the head there and start an n-beat loop, for screenshots.
                if env["RBXPORT_SEEK"] != nil || env["RBXPORT_LOOP_BEATS"] != nil {
                    let deck = model.player.deckA
                    Task { @MainActor in
                        for _ in 0..<400 where !(deck.isLoaded && !deck.beats.isEmpty && deck.detailBytes != nil) {
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        if let text = env["RBXPORT_SEEK"], let seconds = Double(text) { deck.seek(toSeconds: seconds) }
                        try? await Task.sleep(for: .milliseconds(800))
                        if let text = env["RBXPORT_LOOP_BEATS"], let beats = Double(text) { deck.beatLoop(beats) }
                    }
                }
            }
            // RBXPORT_LOAD_ROW_B=<n> loads that row onto deck B (the 2 PLAYER layout; RBXPORT_PLAY_B=1
            // plays it, RBXPORT_SEEK_B=<seconds> moves its head once it is ready).
            if !autoLoadedB, let text = env["RBXPORT_LOAD_ROW_B"], let n = Int(text), range.contains(n),
                let row = pager.peek(at: n)
            {
                autoLoadedB = true
                model.loadToDeck(trackID: row.id, deck: .b)
                if env["RBXPORT_PLAY_B"] == "1" { model.player.deckB.playWhenLoaded() }
                if let text = env["RBXPORT_SEEK_B"], let seconds = Double(text) {
                    let deck = model.player.deckB
                    Task { @MainActor in
                        for _ in 0..<400 where !(deck.isLoaded && !deck.beats.isEmpty && deck.detailBytes != nil) {
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        deck.seek(toSeconds: seconds)
                    }
                }
            }
            if !autoPreviewed, let text = env["RBXPORT_PREVIEW_ROW"], let n = Int(text), range.contains(n),
                let row = pager.peek(at: n)
            {
                autoPreviewed = true
                model.player.preview.click(
                    trackID: row.id, positionMs: Double(row.durationSec) * 300, durationMs: Double(row.durationSec) * 1000)
            }
        }
        private var autoSelected = false
        private var autoEdited = false
        private var autoLoaded = false
        private var autoLoadedB = false
        private var autoPreviewed = false

        /// Selects the rows of `range` whose tracks are in the model's selection.
        private func restoreSelection(in range: Range<Int>) {
            guard let table else { return }
            let indexes = model.selectedIndexes(in: range).subtracting(table.selectedRowIndexes)
            guard !indexes.isEmpty else { return }
            restoring = true
            table.selectRowIndexes(indexes, byExtendingSelection: true)
            restoring = false
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, !applying, !restoring else { return }
            let flags = NSEvent.modifierFlags
            model.tableSelectionChanged(
                table.selectedRowIndexes, keepingUnloaded: flags.contains(.command) || flags.contains(.shift))
        }

        @objc func rowDoubleClicked() {
            guard let table, table.clickedRow >= 0, let row = pager.peek(at: table.clickedRow) else { return }
            // A double-click on a text column that edits in place (not the title) edits it;
            // everywhere else it loads the track onto a deck.
            if table.clickedColumn >= 0,
                let column = ColumnID(rawValue: table.tableColumns[table.clickedColumn].identifier.rawValue),
                EditableCells.editsOnDoubleClick(column), model.canEditTrack(row.id)
            {
                beginEditing(row: table.clickedRow, column: table.clickedColumn)
                return
            }
            model.loadToDeck(trackID: row.id)
        }

        // MARK: Editing in place

        /// Puts the cell's text into its field. Enter or leaving commits a changed value, Escape restores.
        func beginEditing(row index: Int, column columnIndex: Int) {
            guard let table, let data = pager.peek(at: index),
                let id = ColumnID(rawValue: table.tableColumns[columnIndex].identifier.rawValue),
                EditableCells.target(for: id) != nil,
                let cell = table.view(atColumn: columnIndex, row: index, makeIfNecessary: true) as? TextCellView
            else { return }
            let model = model
            let trackID = data.id
            cell.beginEditing(text: model.editableText(id, row: data)) { [weak table] text in
                Task { @MainActor in
                    let done = await model.commitCell(trackID: trackID, column: id, text: text)
                    // A refused edit puts the stored text back.
                    if !done, let table {
                        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: columnIndex))
                    }
                }
            } restore: { [weak table] in
                table?.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: columnIndex))
            }
        }

        /// Star clicks write the rating; a locked library answers with its own message.
        private func rate(star: UInt8, current: UInt8, id: String) {
            let model = model
            Task { await model.clickStar(star, current: current, id: id) }
        }

        func loadSelectedToDeck(deck: Deck = .a) {
            guard let table, let first = table.selectedRowIndexes.first, let row = pager.peek(at: first) else { return }
            model.loadToDeck(trackID: row.id, deck: deck)
        }

        // MARK: Context menu

        /// Right-clicking an unselected row selects it first; the menu then acts on the selection.
        func menu(forRow row: Int) -> NSMenu? {
            guard let table, row >= 0, row < table.numberOfRows else { return nil }
            if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let rows = ContextMenus.trackMenu(model.trackMenuContext())
            let model = model
            return MenuBuilder.menu(rows) { command in model.runTrackMenu(command) }
        }

        // MARK: Dragging tracks

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            // The audio file always goes out, for Finder and other apps; the track id goes with
            // it only while the library may be edited, since only playlists take track drops.
            // A row whose page is not loaded still takes part in the drag, as an empty placeholder.
            let id = pager.peek(at: row)?.id ?? ""
            let backend = model.backend
            let path = TrackDrag.path(for: id) { backend.trackPathSync(id: $0) }
            return TrackDrag.pasteboardItem(id: id, path: path, canEdit: model.canEdit)
        }

        func tableView(
            _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            // Files from the Finder are imported: into the open playlist, or into the collection.
            if info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
                info.draggingPasteboard.availableType(from: [.rbxportTracks]) == nil
            {
                guard model.canEdit, model.openPlaylistID != nil || model.selectedNodeID == "all" else { return [] }
                tableView.setDropRow(-1, dropOperation: .on)
                return .copy
            }
            // Reordering is the only other drop a table takes: from itself, in a playlist shown in its own order.
            guard model.canReorderRows, (info.draggingSource as? NSTableView) === tableView,
                info.draggingPasteboard.availableType(from: [.rbxportTracks]) != nil
            else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            let model = model
            if info.draggingPasteboard.availableType(from: [.rbxportTracks]) == nil,
                let urls = info.draggingPasteboard.readObjects(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
            {
                Task { await model.dropFilesOnTable(urls) }
                return true
            }
            let ids = NSPasteboard.PasteboardType.trackIDs(from: info.draggingPasteboard)
            guard !ids.isEmpty else { return false }
            Task { await model.reorderRows(carried: ids, insertionRow: row) }
            return true
        }

        // MARK: Data source and cells

        func numberOfRows(in tableView: NSTableView) -> Int { pager.rowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            guard let column = tableColumn, let id = ColumnID(rawValue: column.identifier.rawValue) else { return nil }
            let data = pager.row(at: index)
            switch id {
            case .attr:
                let cell = reusable(tableView, column.identifier) { AttributeCellView() }
                cell.show(analysed: data.map { $0.analysed != 0 } ?? false, cue: !(data?.hotCues.isEmpty ?? true))
                return cell
            case .preview:
                let cell = reusable(tableView, column.identifier) { PreviewCellView() }
                cell.show(row: data, palette: palette, service: model.waveforms, preview: model.player.preview)
                cell.onPreviewClick = { [weak model] row, ms in
                    model?.player.preview.click(
                        trackID: row.id, positionMs: ms, durationMs: Double(row.durationSec) * 1000)
                }
                return cell
            case .artwork:
                let cell = reusable(tableView, column.identifier) { ArtworkCellView() }
                cell.show(row: data, service: model.artwork)
                return cell
            case .rating:
                let cell = reusable(tableView, column.identifier) { RatingCellView() }
                cell.show(stars: data?.rating, alignment: .left)
                cell.trackID = data?.id
                cell.onRate = { [weak self] star, current, id in self?.rate(star: star, current: current, id: id) }
                return cell
            default:
                let spec = ColumnCatalogue.spec(for: id)
                let cell = reusable(tableView, column.identifier) { TextCellView() }
                if let data {
                    cell.show(
                        text: CellFormat.text(id, row: data, keyStyle: keyStyle), id: id,
                        alignment: spec.rightAligned ? .right : .left)
                } else {
                    // Placeholder until the page arrives.
                    cell.show(placeholder: id == .title ? "Loading..." : "", alignment: spec.rightAligned ? .right : .left)
                }
                return cell
            }
        }

        /// A row scrolled out of view: its pending waveform and artwork loads are withdrawn.
        func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
            for case let cell as PreviewCellView in rowView.subviews { cell.cancelLoad() }
            for case let cell as ArtworkCellView in rowView.subviews { cell.cancelLoad() }
        }

        private func reusable<Cell: NSTableCellView>(
            _ table: NSTableView, _ identifier: NSUserInterfaceItemIdentifier, make: () -> Cell
        ) -> Cell {
            if let reused = table.makeView(withIdentifier: identifier, owner: nil) as? Cell { return reused }
            let cell = make()
            cell.identifier = identifier
            return cell
        }

        // MARK: Sorting

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !settingSort, let key = tableView.sortDescriptors.first?.key, let id = ColumnID(rawValue: key)
            else { return }
            // AppKit toggles ascending/descending itself; the model owns the three-state cycle.
            model.cycleSort(on: id)
        }

        // MARK: Columns: reorder and resize

        func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            // `#` stays first.
            columnIndex != 0 && newColumnIndex != 0
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard !applying else { return }
            model.reorderColumns(shownIDs().filter { !ColumnCatalogue.fixed.contains($0) })
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !applying, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                let id = ColumnID(rawValue: column.identifier.rawValue)
            else { return }
            model.resizeColumn(id, to: Double(column.width))
        }

        // MARK: Header menu

        func installHeaderMenu() {
            let menu = NSMenu()
            menu.delegate = self
            table?.headerView?.menu = menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            var clicked: ColumnID?
            if let header = table?.headerView, let event = NSApp.currentEvent {
                let column = header.column(at: header.convert(event.locationInWindow, from: nil))
                if column >= 0, let table { clicked = ColumnID(rawValue: table.tableColumns[column].identifier.rawValue) }
            }
            let single = NSMenuItem(title: "Auto-size This Column", action: #selector(autoSizeColumn(_:)), keyEquivalent: "")
            single.target = self
            single.representedObject = clicked?.rawValue
            single.isEnabled = clicked != nil
            menu.addItem(single)
            let all = NSMenuItem(title: "Auto-size All Columns", action: #selector(autoSizeAll), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
            let reset = NSMenuItem(title: L10n.t("Reset columns"), action: #selector(resetColumns), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
            menu.addItem(.separator())
            for id in ColumnCatalogue.menuOrder {
                let item = NSMenuItem(
                    title: L10n.t(ColumnCatalogue.spec(for: id).label), action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id.rawValue
                item.state = layout.order.contains(id) ? .on : .off
                item.isEnabled = !ColumnCatalogue.required.contains(id)
                menu.addItem(item)
            }
        }

        @objc private func toggleColumn(_ item: NSMenuItem) {
            guard let raw = item.representedObject as? String, let id = ColumnID(rawValue: raw) else { return }
            model.toggleColumn(id)
        }

        @objc private func resetColumns() { model.resetColumns() }

        @objc private func autoSizeColumn(_ item: NSMenuItem) {
            guard let raw = item.representedObject as? String, let id = ColumnID(rawValue: raw) else { return }
            autoSize([id])
        }

        @objc private func autoSizeAll() { autoSize(layout.shown) }

        private func autoSize(_ ids: [ColumnID]) {
            var rows: [Row] = []
            pager.forEachLoadedRow { _, row in if rows.count < ColumnSizer.sampleLimit { rows.append(row) } }
            var next = model.layout
            for id in ids {
                next.widths[id] = ColumnSizer.width(for: id, rows: rows, keyStyle: keyStyle)
            }
            model.setLayout(next)
        }
    }
}

/// Measures what a column needs from the rows that are loaded.
enum ColumnSizer {
    /// Measuring more rows than this costs more than it tells.
    static let sampleLimit = 4000
    static let padding = 16.0
    static let headerPadding = 28.0  // room for the sort indicator

    static func font(for id: ColumnID) -> NSFont {
        ColumnCatalogue.spec(for: id).rightAligned || [.key, .duration].contains(id)
            ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
    }

    static func width(for id: ColumnID, rows: [Row], keyStyle: KeyStyle) -> Double {
        let spec = ColumnCatalogue.spec(for: id)
        // Columns that draw rather than print keep their catalogue width.
        guard ![.attr, .preview, .artwork, .rating].contains(id) else { return spec.width }
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        var widest = (spec.label as NSString).size(withAttributes: [.font: headerFont]).width + headerPadding
        let font = font(for: id)
        for row in rows {
            let text = CellFormat.text(id, row: row, keyStyle: keyStyle)
            if text.isEmpty { continue }
            widest = max(widest, (text as NSString).size(withAttributes: [.font: font]).width + padding)
        }
        return ColumnCatalogue.clamp(Double(widest.rounded(.up)))
    }
}

// MARK: - AppKit pieces

/// `NSTableView` plus the keys rekordbox users expect: Home/End, Page Up/Down and
/// Command-Up/Down move the selection (Shift extends it), Return loads, Escape clears search.
/// Which key does which comes from the binding table (`Keymap`); Delete is the system's.
final class TrackNSTableView: NSTableView {
    /// Return loads onto deck A; Shift-Return onto deck B.
    var onLoad: ((Deck) -> Void)?
    var onEscape: (() -> Void)?
    /// The binding table, with the person's keys.
    var keymap: () -> Keymap = { Keymap() }
    /// Delete or forward-delete.
    var onDelete: (() -> Void)?
    /// The menu for a right-click on a row (-1 when it hit no row).
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let map = keymap()
        var chord = Chord(event: event)
        var binding = map.binding(for: chord, owner: .table, scope: .table)
        var extend = false
        if binding == nil, flags.contains(.shift) {
            // Shift on a movement key extends the selection instead.
            chord.shift = false
            if let found = map.binding(for: chord, owner: .table, scope: .table), case .table(let key) = found.command,
                [.toTop, .toBottom, .pageUp, .pageDown].contains(key)
            {
                binding = found
                extend = true
            }
        }
        if let binding, case .table(let key) = binding.command {
            switch key {
            case .loadToDeck(let deck): onLoad?(deck)
            case .clearSearch: onEscape?()
            case .toTop: move(to: 0, extending: extend)
            case .toBottom: move(to: numberOfRows - 1, extending: extend)
            case .pageUp: page(up: true, extending: extend)
            case .pageDown: page(up: false, extending: extend)
            }
            return
        }
        switch (event.keyCode, flags) {
        case (51, []), (117, []): onDelete?()
        default: super.keyDown(with: event)
        }
    }

    private func move(to target: Int, extending: Bool) {
        guard numberOfRows > 0 else { return }
        let row = min(max(target, 0), numberOfRows - 1)
        if extending, let first = selectedRowIndexes.first, let last = selectedRowIndexes.last {
            let anchor = row > first ? first : last
            selectRowIndexes(IndexSet(integersIn: min(anchor, row)...max(anchor, row)), byExtendingSelection: false)
        } else {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        scrollRowToVisible(row)
    }

    private func page(up: Bool, extending: Bool) {
        let visible = max(rows(in: visibleRect).length - 1, 1)
        let edge = up ? (selectedRowIndexes.first ?? 0) : (selectedRowIndexes.last ?? -1)
        move(to: up ? edge - visible : edge + visible, extending: extending)
    }
}

class TextCellView: NSTableCellView, NSTextFieldDelegate {
    fileprivate let label = NSTextField(labelWithString: "")
    private var editing: (original: String, commit: (String) -> Void, restore: () -> Void)?
    private var cancelled = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Edits the text in place. `commit` gets a changed value; `restore` runs when nothing was changed.
    func beginEditing(text: String, commit: @escaping (String) -> Void, restore: @escaping () -> Void) {
        editing = (text, commit, restore)
        cancelled = false
        label.stringValue = text
        label.isEditable = true
        label.isSelectable = true
        label.delegate = self
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.focusRingType = .default
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelled = true
        window?.makeFirstResponder(superview)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let editing else { return }
        self.editing = nil
        let text = label.stringValue
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.delegate = nil
        if !cancelled, text != editing.original { editing.commit(text) } else { editing.restore() }
        if let table = enclosingScrollView?.documentView { window?.makeFirstResponder(table) }
    }

    func show(text: String, id: ColumnID, alignment: NSTextAlignment) {
        label.font = ColumnSizer.font(for: id)
        label.alignment = alignment
        label.stringValue = text
        label.textColor = .labelColor
    }

    func show(placeholder: String, alignment: NSTextAlignment) {
        label.alignment = alignment
        label.stringValue = placeholder
        label.textColor = .tertiaryLabelColor
    }

    /// Five stars, `rating` of them lit; nil while the row loads.
    func show(stars rating: UInt8?, alignment: NSTextAlignment) {
        label.alignment = alignment
        guard let rating else {
            label.stringValue = ""
            return
        }
        let (lit, total) = CellFormat.stars(rating)
        let text = NSMutableAttributedString()
        for star in 0..<total {
            text.append(
                NSAttributedString(
                    string: "\u{2605}",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: star < lit ? NSColor.labelColor : NSColor.quaternaryLabelColor,
                    ]))
        }
        label.attributedStringValue = text
    }
}

/// The Rating column: stars that rate when clicked. The lit star clears.
final class RatingCellView: TextCellView {
    var trackID: String?
    /// Called with the star clicked (1 to 5), the rating now, and the track.
    var onRate: ((UInt8, UInt8, String) -> Void)?
    private var rating: UInt8 = 0

    override func show(stars rating: UInt8?, alignment: NSTextAlignment) {
        self.rating = rating ?? 0
        super.show(stars: rating, alignment: alignment)
    }

    static var starWidthForTests: CGFloat { starWidth }
    private static let starWidth: CGFloat = ("\u{2605}" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width

    /// The star under `x`, counted from the cell's left edge (the label sits 4 pt in).
    static func star(atX x: CGFloat) -> UInt8? {
        let index = Int(((x - 4) / starWidth).rounded(.down)) + 1
        return x >= 4 && (1...5).contains(index) ? UInt8(index) : nil
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if let id = trackID, !AppModel.isLoose(id), let star = Self.star(atX: x) {
            onRate?(star, rating, id)
            return
        }
        super.mouseDown(with: event)
    }
}

/// The Attribute column: a star for analysed tracks, and "CUE" when there are hot cues.
final class AttributeCellView: NSTableCellView {
    private let star = NSImageView()
    private let cue = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Analysed")
        star.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        star.contentTintColor = .systemYellow
        cue.font = .systemFont(ofSize: 9, weight: .bold)
        cue.textColor = .systemOrange
        cue.stringValue = "CUE"
        let stack = NSStackView(views: [star, cue])
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(analysed: Bool, cue hasCue: Bool) {
        star.isHidden = !analysed
        cue.isHidden = !hasCue
    }
}
