import Foundation
import AppKit
import Observation

/// What the status bar says about a multi-row selection.
struct SelectionSummary: Equatable, Sendable {
    let count: Int
    let seconds: UInt64
    let bytes: UInt64
    /// How many of the selected tracks are in loaded pages (only those can be totalled).
    let totalled: Int

    var isPartial: Bool { totalled < count }

    var text: String {
        var text = "\(count) tracks \u{00B7} \(CellFormat.totalTime(seconds)) \u{00B7} \(CellFormat.bytes(bytes))"
        if isPartial { text += " (loaded rows only)" }
        return text
    }
}

extension ColumnContext {
    /// The column layout a track source uses.
    init(_ source: TrackSource) {
        switch source {
        case .collection, .tagList: self = .collection
        case .playlist, .playlistFolder: self = .playlist
        case .history: self = .history
        case .folder: self = .folder
        }
    }
}

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let backend: any BackendProtocol
    /// The rows of the open view, shared with the table.
    let pager: RowPager
    let layoutStore: ColumnLayoutStore

    private(set) var phase: Phase = .loading
    var summary: LibrarySummary? {
        didSet { info.editable = canEdit }
    }
    let sidebar: SidebarModel
    private(set) var opened: OpenedView?
    private(set) var viewError: String?
    /// A transient message for the status line (an export finished, a reveal failed).
    var notice: String?

    /// The undo/redo state, as the core last announced it.
    var editHistory = EditHistory(generation: 0, canUndo: false, canRedo: false, undoLabel: nil, redoLabel: nil)
    /// The open smart-playlist editor sheet, if any.
    var smartEditor: SmartEditorModel?
    /// The open Missing Files and Find Duplicates sheets, if any.
    var missingFiles: MissingFilesModel?
    var duplicates: DuplicatesModel?
    /// Phase 5b: the open Import from USB sheet, and the iTunes / Music library browser.
    var usbImport: UsbImportModel?
    private(set) var itunes: ItunesModel!
    /// Panels and alerts; tests replace them.
    var dialogs = Dialogs.live
    /// An import is running (the status bar shows `importProgress`).
    @ObservationIgnored var importInFlight = false
    var importProgress: ImportProgressState?
    /// Library Protection (Settings > General). On by default, as in the React app. Persisted;
    /// pushed to the core, whose write gate is the single authority.
    var protectLibrary: Bool {
        didSet {
            guard protectLibrary != oldValue else { return }
            layoutStore.defaults.set(protectLibrary, forKey: Self.protectLibraryKey)
            Task { await applyProtection() }
        }
    }
    static let protectLibraryKey = "protectLibrary"
    /// How often the summary is re-read to notice rekordbox starting or quitting. Off in tests.
    var readOnlyPollInterval: Duration?
    @ObservationIgnored var pollTask: Task<Void, Never>?

    /// The selected source-list node, by id (`all`, `pl:10`, `hi:3`, `ex:/path`, `tag`).
    /// Persisted across launches.
    var selectedNodeID: String? {
        didSet {
            guard selectedNodeID != oldValue else { return }
            if let id = selectedNodeID { layoutStore.defaults.set(id, forKey: SidebarModel.Keys.selected) }
            // A different source starts with nothing selected; the same one (after a reload) keeps its tracks.
            if selectedNodeID != currentNodeID { clearTrackSelection() }
            updateDevicePanel()
            reopen()
        }
    }

    // MARK: Filter bar

    /// The bar is shown. Only this is persisted; the picks apply while the bar is open.
    var filterBarOpen: Bool {
        didSet {
            guard filterBarOpen != oldValue else { return }
            layoutStore.defaults.set(filterBarOpen, forKey: "filterBar.open")
            if filterState.isNarrowing { reopen() } else { refreshFilterValues() }
        }
    }
    var filterState = FilterState() {
        didSet { if filterState != oldValue && filterBarOpen && (filterState.wire() != oldValue.wire()) { reopen() } }
    }
    /// What the bar's lists offer for the current source and query.
    private(set) var filterValues: FilterValues?
    private var filterValuesKey: FilterValuesKey?
    private var filterToken = 0
    private var libraryEpoch = 0

    private struct FilterValuesKey: Equatable {
        let source: TrackSource
        let query: String
        let field: SearchField
        let epoch: Int
    }

    /// Whether the info panel is shown (Show information, View > Show Information). Persisted.
    var infoPanelOpen: Bool {
        didSet {
            guard infoPanelOpen != oldValue else { return }
            layoutStore.defaults.set(infoPanelOpen, forKey: "infoPanel.open")
            info.setActive(infoPanelOpen)
        }
    }
    let info: InfoPanelModel
    let artwork: ArtworkService
    let waveforms: WaveformService
    /// The decks and the preview player.
    let player: PlayerModel
    /// Tracks waiting to be analysed, and how far the run has got.
    let analysis: AnalysisQueue
    /// Phase 5a: where every export and sync has got to, the mounted volumes, and the export prefs.
    let exportJobs: ExportJobsModel
    let devices: DevicesModel
    let exportPrefs: DeviceExportPrefs
    /// The Sync Manager window's model.
    private(set) var syncManager: SyncManagerModel!
    /// The selected device's settings, while a device is selected.
    private(set) var devicePanel: DeviceSettingsModel?
    /// Bumped to ask the main window to open the Sync Manager window.
    var syncWindowRequests = 0
    /// Tracks analysed in the current run, for the decks to redraw once the library is re-read.
    @ObservationIgnored var analysedResults: [AnalysisResult] = []

    /// How tall rows are when the Artwork or Preview column is shown. Persisted.
    var rowSize: RowSize {
        didSet { if rowSize != oldValue { layoutStore.defaults.set(rowSize.rawValue, forKey: "rowSize") } }
    }
    /// The palette the Preview column draws in. Persisted.
    var waveformPalette: WaveformPalette {
        didSet { if waveformPalette != oldValue { layoutStore.defaults.set(waveformPalette.rawValue, forKey: "waveformPalette") } }
    }

    /// The height of table rows for the shown columns: compact unless a column draws images.
    var rowHeight: CGFloat { RowSize.height(for: layout, preference: rowSize) }
    /// Reveals files in the Finder; replaced in tests.
    var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    var searchField: SearchField = .all {
        didSet { if searchField != oldValue && !query.isEmpty { reopen() } }
    }
    /// Bumped by the Find command; the search field focuses itself when it changes.
    private(set) var searchFocusRequests = 0

    private(set) var context: ColumnContext = .collection
    private(set) var layout: ColumnLayout
    var keyStyle: KeyStyle {
        didSet {
            guard keyStyle != oldValue else { return }
            layoutStore.defaults.set(keyStyle.rawValue, forKey: "keyStyle")
            if sortKey == .key || sortKey == .keyCamelot {
                sortKey = keyStyle == .camelot ? .keyCamelot : .key
                reopen()
            }
        }
    }

    /// The selected tracks, by id: they survive re-sorting, reloads and page eviction.
    private(set) var selectedIDs: Set<String> = []
    private(set) var selectionAnchor: String?
    private(set) var selectionSummary: SelectionSummary?
    /// Called for Return, Shift-Return or a double-click on a track: loads it onto a deck (A by
    /// default, B for Shift-Return).
    var onLoadToDeck: (String, Deck) -> Void = { _, _ in }
    private(set) var sortKey: SortKey = .trackNo
    private(set) var descending = false

    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var started = false
    private var currentNodeID: String?
    private var selectionTask: Task<Void, Never>?
    private var selectionToken = 0

    init(backend: any BackendProtocol, layoutStore: ColumnLayoutStore = ColumnLayoutStore()) {
        self.backend = backend
        self.layoutStore = layoutStore
        sidebar = SidebarModel(backend: backend, defaults: layoutStore.defaults)
        selectedNodeID = layoutStore.defaults.string(forKey: SidebarModel.Keys.selected)
        protectLibrary = (layoutStore.defaults.object(forKey: Self.protectLibraryKey) as? Bool) ?? true
        filterBarOpen = layoutStore.defaults.bool(forKey: "filterBar.open")
        pager = RowPager(backend: backend)
        layout = layoutStore.load(.collection)
        keyStyle = layoutStore.defaults.string(forKey: "keyStyle").flatMap(KeyStyle.init) ?? .classic
        let defaults = layoutStore.defaults
        artwork = ArtworkService(backend: backend)
        waveforms = WaveformService(backend: backend)
        info = InfoPanelModel(backend: backend, artwork: artwork, defaults: defaults)
        infoPanelOpen = defaults.bool(forKey: "infoPanel.open")
        rowSize = defaults.string(forKey: "rowSize").flatMap(RowSize.init) ?? .standard
        waveformPalette = defaults.string(forKey: "waveformPalette").flatMap(WaveformPalette.init) ?? .bands
        player = PlayerModel(backend: backend, waveforms: waveforms, artwork: artwork, defaults: defaults)
        analysis = AnalysisQueue(backend: backend, defaults: defaults)
        exportJobs = ExportJobsModel()
        devices = DevicesModel(jobs: exportJobs)
        exportPrefs = DeviceExportPrefs(defaults: defaults)
        info.setActive(infoPanelOpen)
        itunes = ItunesModel(
            backend: backend, defaults: defaults, dialogs: { [weak self] in self?.dialogs ?? .live },
            notify: { [weak self] in self?.notice = $0 },
            busy: { [weak self] on in
                self?.importInFlight = on
                self?.importProgress = on ? ImportProgressState(done: 0, total: 0, title: "") : nil
            })
        info.onEdit = { [weak self] edit, id in await self?.applyInfoEdit(edit, to: id) ?? false }
        onLoadToDeck = { [weak self] id, deck in
            guard let self else { return }
            self.player.load(trackID: id, row: self.loadedRow(id: id), into: deck)
        }
        syncManager = SyncManagerModel(
            backend: backend, sidebar: sidebar, devices: devices, jobs: exportJobs, prefs: exportPrefs,
            dialogs: { [weak self] in self?.dialogs ?? .live }, notify: { [weak self] in self?.notice = $0 },
            refreshDevices: { [weak self] in await self?.refreshDevices() })
        exportJobs.nameFor = { [weak self] path in self?.devices.device(path: path)?.name ?? (path as NSString).lastPathComponent }
        exportJobs.onActivityChange = { [weak self] in self?.sidebar.reloadRows() }
        sidebar.onDevices = { [weak self] list in
            self?.devices.set(list)
            self?.updateDevicePanel()
        }
        player.exportTrackToDevice = { [weak self] id, path in
            guard let self else { return }
            Task { await self.exportTracks([id], to: path) }
        }
        player.deviceTargets = { [weak self] in self?.deviceTargets ?? [] }
        player.configureWrites { [weak self] in self?.canEdit ?? false }
        player.setWaveformPalette = { [weak self] palette in self?.waveformPalette = palette }
        player.analyseTracks = { [weak self] ids in self?.analyse(ids) }
        analysis.onAnalysed = { [weak self] result in self?.analysedResults.append(result) }
        analysis.onDrained = { [weak self] in
            guard let self else { return }
            // One reload for the whole run, not one per track. The index learns where the new
            // analysis files are only now, so the decks read them after it, not at each event.
            let results = self.analysedResults
            self.analysedResults = []
            Task {
                _ = try? await self.backend.reloadLibrary()
                self.waveforms.removeAll()
                for result in results { self.player.handle(analysed: result) }
            }
        }
        player.loadSelected = { [weak self] in
            guard let self, self.selectedIDs.count == 1, let id = self.selectedIDs.first else { return }
            self.player.load(trackID: id, row: self.loadedRow(id: id))
        }
    }

    /// Starts listening for library events, then loads the library.
    func start() {
        guard !started else { return }
        started = true
        phase = .loading
        player.start()
        let backend = backend
        eventTask = Task { [weak self] in
            for await event in backend.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        // Loading decrypts and indexes the whole library: the backend runs it off the main actor.
        let protect = protectLibrary
        loadTask = Task {
            await backend.setProtectLibrary(protect)
            _ = await backend.loadLibrary()
            // Volumes arriving and leaving raise `.devicesChanged`; jobs already running are adopted.
            await backend.startDeviceWatcher()
            exportJobs.seed(await backend.exportProgress())
        }
        startReadOnlyPolling()
    }

    /// Waits for the initial load and the events it raised to be handled. For tests.
    func waitUntilSettled() async {
        await loadTask?.value
        // Events are handled in order on `eventTask`; give it a turn to drain.
        for _ in 0..<20 { await Task.yield() }
    }

    func handle(_ event: LibraryEvent) async {
        switch event {
        case .libraryReady:
            await refresh(selectFirst: true)
        case .libraryChanged:
            // View ids died with the old generation: reload the tree and reopen the selection.
            // Analysis and artwork may have changed too; the info panel re-reads its record.
            artwork.removeAll()
            waveforms.removeAll()
            info.libraryChanged()
            await refresh(selectFirst: false)
        case .libraryProblem(let problem):
            switch problem {
            case .failed(let message): phase = .failed(message)
            case .missing(let masterDb): phase = .failed("No rekordbox library found at \(masterDb).")
            }
        case .editHistoryChanged(let history):
            editHistory = history
        case .tagListChanged:
            await tagListChanged()
        case .importProgress(let progress):
            importProgressed(progress)
        case .cuesChanged, .gridChanged, .analysisChanged:
            await handleEditEvent(event)
        case .devicesChanged:
            await devicesChanged()
        case .exportProgress(let progress):
            exportJobs.handle(progress: progress)
        case .syncProgress(let progress):
            exportJobs.handle(sync: progress)
        case .exportDone:
            // The report comes back to whoever asked; the stick now holds an export.
            await refreshDevices()
        }
    }

    func refresh(selectFirst: Bool) async {
        do {
            async let loadedSummary = backend.summary()
            async let loadedTree = backend.playlistTree()
            let (newSummary, flat) = try await (loadedSummary, loadedTree)
            summary = newSummary
            libraryEpoch += 1
            sidebar.setLibraryTree(flat)
            let firstLoad = phase != .ready
            phase = .ready
            // Back to the node that was selected (restored from the last launch on the first
            // load); one that no longer exists falls back to All Tracks.
            let wanted = selectedNodeID.flatMap { sidebar.canSelect($0) ? $0 : nil } ?? "all"
            if wanted == selectedNodeID { reopen() } else { selectedNodeID = wanted }
            if firstLoad {
                if let roots = try? await backend.explorerRoots() { sidebar.setExplorerRoots(roots) }
                Task { await sidebar.restoreExplorer() }
            }
            Task { await sidebar.refreshDevices() }
        } catch {
            phase = .failed(describe(error))
        }
    }

    func sort(by key: SortKey, descending: Bool) {
        guard key != sortKey || descending != self.descending else { return }
        sortKey = key
        self.descending = descending
        reopen()
    }

    /// A header click: ascending, then descending, then off (the view's own order).
    func cycleSort(on column: ColumnID) {
        guard let key = ColumnCatalogue.spec(for: column).sortKey(for: keyStyle) else { return }
        let next = SortCycle.next(current: (sortKey, descending), clicked: key)
        sort(by: next.key, descending: next.descending)
    }

    func focusSearch() { searchFocusRequests += 1 }

    func clearSearch() { query = "" }

    // MARK: Columns

    /// The extra fields rows are fetched with: what the shown columns need, and the size
    /// (for the selection's total) whatever is shown.
    var extraColumns: [ExtraColumn] {
        var wanted = [ExtraColumn.size]
        for column in layout.extraColumns where !wanted.contains(column) { wanted.append(column) }
        return wanted
    }

    func setLayout(_ new: ColumnLayout) {
        guard new != layout else { return }
        let before = Set(extraColumns)
        layout = new
        layoutStore.save(new, for: context)
        // New fields need new rows.
        if Set(extraColumns) != before { reopen() }
    }

    func toggleColumn(_ id: ColumnID) { setLayout(layout.toggling(id)) }

    func resizeColumn(_ id: ColumnID, to width: Double) { setLayout(layout.resized(id, to: width)) }

    /// The visible columns after a drag-reorder (without `#`).
    func reorderColumns(_ order: [ColumnID]) {
        guard Set(order) == Set(layout.order), order.count == layout.order.count else { return }
        var next = layout
        next.order = order
        setLayout(next)
    }

    func resetColumns() {
        layoutStore.reset(context)
        setLayout(.defaults(for: context))
    }

    // MARK: Selection

    func loadToDeck(trackID: String, deck: Deck = .a) { onLoadToDeck(trackID, deck) }

    private func clearTrackSelection() {
        selectionToken += 1
        selectionTask?.cancel()
        selectedIDs = []
        selectionAnchor = nil
        selectionSummary = nil
        info.selectionChanged([], row: nil)
    }

    /// The table's selection changed to these row indexes. Loaded rows map to ids at once;
    /// rows in pages that are not loaded (a big shift-click range, Select All) are resolved
    /// through the backend. With `keepingUnloaded`, selected tracks that are not in any
    /// loaded page stay selected (an additive click after a reload has only restored the
    /// visible part of the table's selection).
    func tableSelectionChanged(_ indexes: IndexSet, keepingUnloaded: Bool) {
        guard let opened else { return }
        selectionToken += 1
        let token = selectionToken
        selectionTask?.cancel()

        let pageSize = RowPager.pageSize
        let count = pager.rowCount
        var ids = Set<String>()
        var missing: [ClosedRange<Int>] = []
        for range in indexes.rangeView {
            var i = range.lowerBound
            let end = min(range.upperBound, count)
            while i < end {
                let page = i / pageSize
                let pageEnd = min((page + 1) * pageSize, end)
                if let rows = pager.loadedPage(page) {
                    for j in i..<pageEnd where j % pageSize < rows.count { ids.insert(rows[j % pageSize].id) }
                } else if let last = missing.last, last.upperBound + 1 == i {
                    missing[missing.count - 1] = last.lowerBound...(pageEnd - 1)
                } else {
                    missing.append(i...(pageEnd - 1))
                }
                i = pageEnd
            }
        }
        if keepingUnloaded {
            var loaded = Set<String>()
            pager.forEachLoadedRow { _, row in loaded.insert(row.id) }
            ids.formUnion(selectedIDs.filter { !loaded.contains($0) })
        }
        applySelection(ids, anchoredBy: indexes.count == 1 ? ids.first : nil)

        guard !missing.isEmpty else { return }
        let backend = backend
        let viewID = opened.handle.viewId
        let resolved = ids
        selectionTask = Task { [weak self] in
            var all = resolved
            for range in missing {
                guard let fetched = try? await backend.viewIDsInRange(
                    viewID: viewID, from: UInt32(range.lowerBound), to: UInt32(range.upperBound))
                else { return }
                all.formUnion(fetched)
            }
            guard let self, !Task.isCancelled, token == self.selectionToken else { return }
            self.applySelection(all, anchoredBy: nil)
        }
    }

    /// Waits for the ids of unloaded rows to arrive. For tests.
    func settleSelection() async { await selectionTask?.value }

    private func applySelection(_ ids: Set<String>, anchoredBy anchor: String?) {
        selectedIDs = ids
        if let anchor { selectionAnchor = anchor } else if let current = selectionAnchor, !ids.contains(current) {
            selectionAnchor = ids.first
        } else if selectionAnchor == nil {
            selectionAnchor = ids.first
        }
        recomputeSelectionSummary()
        info.selectionChanged(ids, row: ids.count == 1 ? loadedRow(id: ids.first ?? "") : nil)
    }

    /// The row for `id` if its page is loaded.
    func loadedRow(id: String) -> Row? {
        var found: Row?
        pager.forEachLoadedRow { _, row in if found == nil && row.id == id { found = row } }
        return found
    }

    /// Totals the selected tracks that are in loaded pages. Call again when pages load.
    func recomputeSelectionSummary() {
        guard selectedIDs.count > 1 else {
            selectionSummary = nil
            return
        }
        var seconds: UInt64 = 0
        var bytes: UInt64 = 0
        var found = 0
        let selected = selectedIDs
        pager.forEachLoadedRow { _, row in
            guard selected.contains(row.id) else { return }
            found += 1
            seconds += UInt64(row.durationSec)
            bytes += row.extra.size ?? 0
        }
        let summary = SelectionSummary(count: selected.count, seconds: seconds, bytes: bytes, totalled: found)
        if summary != selectionSummary { selectionSummary = summary }
    }

    /// The row indexes in `range` whose tracks are selected, for restoring the table's
    /// selection as pages load.
    func selectedIndexes(in range: Range<Int>) -> IndexSet {
        var found = IndexSet()
        guard !selectedIDs.isEmpty, !range.isEmpty else { return found }
        let pageSize = RowPager.pageSize
        for page in (range.lowerBound / pageSize)...((range.upperBound - 1) / pageSize) {
            guard let rows = pager.loadedPage(page) else { continue }
            for (offset, row) in rows.enumerated() where selectedIDs.contains(row.id) {
                let index = page * pageSize + offset
                if range.contains(index) { found.insert(index) }
            }
        }
        return found
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            reopen()
        }
    }

    /// Reopens the selected node as a view with the current sort and query.
    func reopen() {
        guard let nodeID = selectedNodeID, let source = SidebarNode.source(forID: nodeID) else { return }
        currentNodeID = nodeID
        let newContext = ColumnContext(source)
        if newContext != context {
            context = newContext
            layout = layoutStore.load(newContext)
        }
        generation += 1
        let mine = generation
        let extra = extraColumns
        let spec = ViewSpec(
            source: source, sort: sortKey, descending: descending, query: query, searchField: searchField,
            filter: filterBarOpen ? filterState.wire() : TrackFilter(bpm: nil, keys: nil, ratings: nil, colors: nil))
        refreshFilterValues()
        let backend = backend
        Task {
            do {
                let handle = try await backend.openView(spec)
                guard mine == generation else { return }  // a newer request superseded this one
                viewError = nil
                let view = OpenedView(handle: handle, generation: mine, extraColumns: extra)
                opened = view
                pager.show(view)
                recomputeSelectionSummary()
            } catch {
                guard mine == generation else { return }
                viewError = describe(error)
            }
        }
    }

    /// Opens, keeps or closes the device panel to follow the selected sidebar node.
    func updateDevicePanel() {
        guard let device = selectedDevice else {
            devicePanel = nil
            return
        }
        if devicePanel?.path == device.path { return }
        let panel = DeviceSettingsModel(path: device.path, backend: backend)
        devicePanel = panel
        Task { await panel.load() }
    }

    // MARK: Filter values

    /// Re-fetches the bar's lists when the source, query, scope or library changed since the last fetch.
    /// The spec carries no filter, so a picked value never hides the others.
    func refreshFilterValues() {
        guard filterBarOpen, let nodeID = selectedNodeID, let source = SidebarNode.source(forID: nodeID) else { return }
        let key = FilterValuesKey(source: source, query: query, field: searchField, epoch: libraryEpoch)
        guard key != filterValuesKey else { return }
        filterValuesKey = key
        filterToken += 1
        let token = filterToken
        // The filter does not apply to a folder on disk.
        if case .folder = source {
            filterValues = nil
            return
        }
        let spec = ViewSpec(
            source: source, sort: .trackNo, descending: false, query: query, searchField: searchField,
            filter: TrackFilter(bpm: nil, keys: nil, ratings: nil, colors: nil))
        let backend = backend
        Task {
            let values = try? await backend.filterValues(spec)
            guard token == filterToken else { return }
            filterValues = values
        }
    }

    func resetFilter() { filterState.reset() }

    // MARK: Sidebar selection

    /// A click in the source list.
    func selectNode(_ id: String) {
        selectedNodeID = id
    }

    // MARK: Context-menu commands

    /// What the track menu needs to know about the current selection and source.
    func trackMenuContext() -> ContextMenus.TrackContext {
        ContextMenus.TrackContext(
            selectionCount: selectedIDs.count, inTagList: selectedNodeID == "tag",
            inExplorer: selectedNodeID?.hasPrefix("ex:") ?? false, editable: canEdit,
            playlists: sidebar.playlistTargets(), inPlaylist: openPlaylistID != nil,
            inHistory: openHistoryID != nil, hasLoose: selectedIDs.contains(where: Self.isLoose),
            allLoose: !selectedIDs.isEmpty && selectedIDs.allSatisfy(Self.isLoose), devices: deviceTargets)
    }

    /// Runs a live entry of the track menu on the selection.
    func runTrackMenu(_ command: MenuCommand) {
        switch command {
        case .showInFinder:
            let ids = Array(selectedIDs)
            Task { await revealInFinder(trackIDs: ids) }
        case .showInformation: showInformation()
        case .loadToDeck(let deck):
            if let id = selectedIDs.first, selectedIDs.count == 1 { player.load(trackID: id, row: loadedRow(id: id), into: deck) }
        case .addToPlaylist(let id): Task { await addSelectionToPlaylist(id) }
        case .removeFromPlaylist: Task { await removeSelectionFromPlaylist() }
        case .addToTagList: Task { await addSelectionToTagList() }
        case .removeFromTagList: Task { await removeSelectionFromTagList() }
        case .reloadTag: Task { await reloadSelectionTags() }
        case .resetPlayCount: Task { await resetSelectionPlayCount() }
        case .removeFromCollection: Task { await removeSelectionFromCollection() }
        case .removeFromHistory: Task { await removeSelectionFromHistory() }
        case .importToCollection: Task { await importSelectionToCollection() }
        case .analyse: analyseSelection()
        case .analysisLock(let on):
            let ids = orderedSelection
            Task { await setAnalysisLock(on, ids: ids) }
        case .convertMemoryToHot:
            let ids = orderedSelection
            Task { await convertMemoryCuesToHot(ids: ids) }
        case .setColor(let color):
            let ids = orderedSelection
            Task { await setColor(color, ids: ids) }
        case .exportTrackToDevice(let path):
            let ids = orderedSelection
            Task { await exportTracks(ids, to: path) }
        case .exportToDevice, .ejectDevice, .openSyncManager, .importFromDevice, .exportPlaylist, .createPlaylist, .createFolder, .createSmartPlaylist, .editSmartPlaylist, .rename, .delete,
            .sortItems:
            break
        }
    }

    /// Show in Finder: reveals the audio files of these tracks.
    func revealInFinder(trackIDs: [String]) async {
        var urls: [URL] = []
        for id in trackIDs.prefix(200) {
            if let path = try? await backend.trackPath(id: id) { urls.append(URL(fileURLWithPath: path)) }
        }
        guard !urls.isEmpty else {
            notice = "No file to show."
            return
        }
        reveal(urls)
    }

    /// Show information: opens the info panel on the selection.
    func showInformation() { infoPanelOpen = true }

    func toggleInformation() { infoPanelOpen.toggle() }

    /// Exports the playlist behind a source-list node to `url`.
    @discardableResult
    func exportPlaylist(nodeID: String, to url: URL, format: PlaylistFileFormat) async -> UInt32? {
        guard nodeID.hasPrefix("pl:") else { return nil }
        do {
            let count = try await backend.exportPlaylistFile(
                playlistID: String(nodeID.dropFirst(3)), path: url.path, format: format)
            notice = "Exported \(count) track\(count == 1 ? "" : "s") to \(url.lastPathComponent)."
            return count
        } catch {
            notice = "Export failed: \(describe(error))"
            return nil
        }
    }

    func dismissNotice() { notice = nil }
}
