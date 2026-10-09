import Foundation

/// An in-memory library for previews and unit tests.
actor MockBackend: BackendProtocol {
    nonisolated let events: AsyncStream<LibraryEvent>
    /// The scripted engine behind `playback`; tests drive and inspect it.
    nonisolated let mockPlayback = MockPlayback()
    nonisolated var playback: any PlaybackEngine { mockPlayback }
    private let continuation: AsyncStream<LibraryEvent>.Continuation

    private var trackCount: Int
    private var nodes: [TreeNode]
    private var views: [UInt32: (spec: ViewSpec, titles: [Int])] = [:]
    private var nextViewID: UInt32 = 1
    private let failLoad: String?
    private var generation: UInt32 = 1

    // Editing state. The mock keeps the playlist tree and memberships and undoes by snapshot.
    /// What a metadata edit changed on a track (the mock's stand-in for the database row).
    struct Meta: Equatable {
        var rating: UInt8?
        var comment: String?
        var color: UInt8?
        var fields: [String: String] = [:]
    }
    fileprivate struct Snapshot {
        var label: String
        var nodes: [TreeNode]
        var memberships: [String: [String]]
        var smartRules: [String: SmartRule]
        var meta: [String: Meta] = [:]
        var tagList: [String] = []
    }
    fileprivate(set) var meta: [String: Meta] = [:]
    fileprivate(set) var tagList: [String] = []
    fileprivate(set) var removedTracks: Set<String> = []
    /// What the import calls answer, set by tests. The mock emits one progress event per `progressTitles`.
    var importAnswer = ImportReport(imported: 0, skipped: [], tracks: [], existing: [])
    var xmlAnswer = XmlImportReport(imported: 0, existing: 0, skipped: [], playlists: 0, cues: 0, tracks: [])
    var progressTitles: [String] = []
    private(set) var importedPaths: [[String]] = []
    /// The missing tracks the mock lists; `relocateTrack` removes one.
    var missingList: [MissingTrack] = []
    var duplicateGroups: [DuplicateGroup] = []
    var autoRelocateAnswer = RelocateReport(relocated: 0, unresolved: 0)
    private(set) var autoRelocateFolders: [[String]] = []
    private(set) var relocations: [(id: String, path: String)] = []
    private var gateProtected = true
    private var gateRunning = false
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var memberships: [String: [String]] = [:]
    private var smartRules: [String: SmartRule] = [:]
    private var nextPlaylistID = 100
    /// Every edit call, in order, as `name(args)` text for tests to assert on.
    private(set) var editLog: [String] = []
    private(set) var protectCalls: [Bool] = []
    /// Makes the next edit fail with this error (once), so a test can see how the UI reports it.
    var failNextEdit: FfiError?
    fileprivate var isFixture = true

    private(set) var fetchCalls: [(viewID: UInt32, offset: UInt32, len: UInt32)] = []
    private(set) var fetchExtras: [[ExtraColumn]] = []
    private(set) var idRangeCalls: [(viewID: UInt32, from: UInt32, to: UInt32)] = []
    private(set) var openedSpecs: [ViewSpec] = []
    private(set) var treeCalls = 0
    private(set) var filterValueSpecs: [ViewSpec] = []
    private(set) var explorerChildrenCalls: [String] = []
    private(set) var deviceCalls = 0
    private(set) var exports: [(playlistID: String, path: String, format: PlaylistFileFormat)] = []

    private(set) var detailCalls: [String] = []
    private(set) var lookupCalls = 0
    private(set) var waveformCalls: [(id: String, kind: WaveformKind)] = []
    private(set) var artworkCalls: [String] = []
    /// Per-track overrides for the info panel and media calls, set by tests.
    var detailOverrides: [String: TrackDetails] = [:]
    /// How long `trackDetails` takes for a track, so a test can make a reply arrive late.
    var detailDelays: [String: Duration] = [:]
    var waveformAnswers: [String: Data] = [:]
    var artworkAnswers: [String: Data] = [:]
    var artworkDelay: Duration = .zero
    var waveformDelay: Duration = .zero
    /// What the analysis reads answer per track, set by tests.
    var beatAnswers: [String: [Beat]] = [:]
    var cueAnswers: [String: [Cue]] = [:]
    var phraseAnswers: [String: [Phrase]] = [:]
    var vocalAnswers: [String: Data] = [:]
    private(set) var analysisCalls: [String] = []
    // Phase 4c state.
    private var nextCueID = 9_000
    private(set) var gridStates: [String: GridState] = [:]
    private(set) var gridEdits: [(track: String, edit: GridEdit, fromMs: UInt32?, transaction: String?)] = []
    private(set) var analysisRuns: [(track: String, rekordbox: Bool)] = []
    private(set) var peakAnalyses = 0
    private var activeAnalyses = 0
    private(set) var reloadCalls = 0
    private(set) var recordedPlays: [String] = []
    /// How long an analysis takes, and which tracks fail it, set by tests.
    var analysisDelay: Duration = .zero
    var analysisFailures: [String: FfiError] = [:]
    private(set) var peakWaveformCalls = 0
    private(set) var peakArtworkCalls = 0
    private var activeArtworkCalls = 0
    private var activeWaveformCalls = 0

    /// What the explorer, device and filter calls answer, set by tests.
    var explorerRootList: [ExplorerRoot] = [ExplorerRoot(name: "Music", path: "/mock/Music")]
    var explorerFolders: [String: ExplorerChildren] = [
        "/mock/Music": ExplorerChildren(names: ["House", "Techno"], total: 2)
    ]
    var deviceList: [Device] = []
    /// What the Phase 5a device, export and sync calls answer, and what they were asked.
    var devices5a = MockDeviceScript()
    var imports5b = MockImportScript()
    /// What the Phase 5c LINK calls answer, and what they were asked. Nothing here opens a socket.
    var link5c = MockLinkScript()
    var filterValuesAnswer = FilterValues(
        bpms: [CountedBpm(value: 120, count: 50), CountedBpm(value: 128, count: 5)],
        keys: [CountedKey(value: "Am", count: 3), CountedKey(value: "C", count: 2)], tags: [])

    init(trackCount: Int = 300, nodes: [TreeNode]? = nil, failLoad: String? = nil) {
        (events, continuation) = AsyncStream.makeStream(of: LibraryEvent.self)
        self.trackCount = trackCount
        self.nodes = nodes ?? MockBackend.sampleTree
        self.failLoad = failLoad
    }

    static let sampleTree: [TreeNode] = [
        TreeNode(id: "all", name: "All Tracks", kind: .allTracks, depth: 0, expanded: nil, childCount: 300),
        TreeNode(id: "playlists", name: "Playlists", kind: .collection, depth: 0, expanded: true, childCount: 2),
        TreeNode(id: "10", name: "Warm-up", kind: .playlist, depth: 1, expanded: nil, childCount: 20),
        TreeNode(id: "11", name: "Peak", kind: .playlist, depth: 1, expanded: nil, childCount: 5),
    ]

    // MARK: Test controls

    func emit(_ event: LibraryEvent) { continuation.yield(event) }

    /// Replaces the library contents and raises `LibraryChanged`, as a reload would.
    func changeLibrary(trackCount: Int, nodes: [TreeNode]? = nil) {
        self.trackCount = trackCount
        if let nodes { self.nodes = nodes }
        generation += 1
        views.removeAll()
        continuation.yield(.libraryChanged(generation: generation))
    }

    // MARK: BackendProtocol

    func loadLibrary() async -> LoadOutcome {
        if let failLoad {
            continuation.yield(.libraryProblem(problem: .failed(message: failLoad)))
            return .problem
        }
        continuation.yield(.libraryReady)
        return .ready
    }

    func summary() async throws -> LibrarySummary {
        LibrarySummary(
            trackCount: UInt32(trackCount), playlistCount: UInt32(nodes.filter { Self.isList($0.kind) }.count),
            readOnly: gateClosed, dbVersion: nil, loadMs: 1)
    }

    func playlistTree() async throws -> [TreeNode] {
        treeCalls += 1
        return nodes
    }

    func openView(_ spec: ViewSpec) async throws -> ViewHandle {
        openedSpecs.append(spec)
        var order = Array(0..<trackCount)
        if case .playlist(let id) = spec.source, let members = memberships[id] {
            order = members.compactMap { Int($0).map { $0 - 1 } }.filter { $0 >= 0 && $0 < trackCount }
        }
        if case .tagList = spec.source {
            order = tagList.compactMap { Int($0).map { $0 - 1 } }.filter { $0 >= 0 && $0 < trackCount }
        }
        order.removeAll { removedTracks.contains(String($0 + 1)) }
        if !spec.query.isEmpty {
            order = order.filter { Self.title($0).localizedCaseInsensitiveContains(spec.query) }
        }
        if spec.sort == .title { order.sort { Self.title($0) < Self.title($1) } }
        if spec.descending { order.reverse() }
        let id = nextViewID
        nextViewID += 1
        views[id] = (spec, order)
        return ViewHandle(viewId: id, len: UInt32(order.count), generation: generation)
    }

    func fetchRows(viewID: UInt32, offset: UInt32, len: UInt32, extraColumns: [ExtraColumn]) async throws -> [Row] {
        fetchCalls.append((viewID, offset, len))
        fetchExtras.append(extraColumns)
        guard let view = views[viewID] else {
            throw FfiError.NotFound(message: "view \(viewID) is gone", detail: nil)
        }
        let start = min(Int(offset), view.titles.count)
        let end = min(start + Int(len), view.titles.count)
        return (start..<end).map { applyMeta(Self.row(track: view.titles[$0], position: $0 + 1, extra: extraColumns)) }
    }

    func viewIDsInRange(viewID: UInt32, from: UInt32, to: UInt32) async throws -> [String] {
        idRangeCalls.append((viewID, from, to))
        guard let view = views[viewID] else {
            throw FfiError.NotFound(message: "view \(viewID) is gone", detail: nil)
        }
        guard !view.titles.isEmpty else { return [] }
        let lo = min(Int(from), Int(to))
        let hi = min(max(Int(from), Int(to)), view.titles.count - 1)
        guard lo <= hi else { return [] }
        return (lo...hi).map { String(view.titles[$0] + 1) }
    }

    func filterValues(_ spec: ViewSpec) async throws -> FilterValues {
        filterValueSpecs.append(spec)
        return filterValuesAnswer
    }

    func explorerRoots() async throws -> [ExplorerRoot] { explorerRootList }

    func explorerChildren(path: String) async throws -> ExplorerChildren {
        explorerChildrenCalls.append(path)
        return explorerFolders[path] ?? ExplorerChildren(names: [], total: 0)
    }

    func listDevices() async throws -> [Device] {
        deviceCalls += 1
        return deviceList
    }

    func exportPlaylistFile(playlistID: String, path: String, format: PlaylistFileFormat) async throws -> UInt32 {
        exports.append((playlistID, path, format))
        return 5
    }

    func trackPath(id: String) async throws -> String { "/mock/audio/track-\(id).mp3" }
    nonisolated func trackPathSync(id: String) -> String? { "/mock/audio/track-\(id).mp3" }

    func setArtwork(_ data: Data, for id: String) { artworkAnswers[id] = data }
    func setArtworkDelay(_ delay: Duration) { artworkDelay = delay }
    func setWaveform(_ data: Data, for id: String) { waveformAnswers[id] = data }
    func setAnalysis(for id: String, beats: [Beat] = [], cues: [Cue] = [], phrases: [Phrase] = [], vocals: Data = Data()) {
        beatAnswers[id] = beats
        cueAnswers[id] = cues
        phraseAnswers[id] = phrases
        vocalAnswers[id] = vocals
    }
    func setWaveformDelay(_ delay: Duration) { waveformDelay = delay }
    func setDetail(_ details: TrackDetails, delay: Duration? = nil) {
        detailOverrides[details.id] = details
        detailDelays[details.id] = delay
    }

    func trackDetails(id: String) async throws -> TrackDetails {
        detailCalls.append(id)
        if let delay = detailDelays[id] { try? await Task.sleep(for: delay) }
        if let override = detailOverrides[id] { return override }
        guard let n = Int(id), n >= 1, n <= trackCount, !removedTracks.contains(id) else {
            throw FfiError.NotFound(message: "That track is no longer in the library.", detail: nil)
        }
        return applyMeta(Self.details(track: n - 1))
    }

    func trackLookups() async throws -> TrackLookups {
        lookupCalls += 1
        return TrackLookups(
            keys: ["Am", "C"], genres: ["House", "Techno"],
            myTagCategories: [MyTagCategory(name: "Mood", tags: [MyTag(id: "t1", name: "Peak")])])
    }

    func waveform(id: String, kind: WaveformKind) async throws -> Data {
        waveformCalls.append((id, kind))
        activeWaveformCalls += 1
        peakWaveformCalls = max(peakWaveformCalls, activeWaveformCalls)
        defer { activeWaveformCalls -= 1 }
        if waveformDelay > .zero { try? await Task.sleep(for: waveformDelay) }
        return waveformAnswers[id] ?? Data()
    }

    func trackBeats(id: String) async throws -> [Beat] {
        analysisCalls.append("beats:\(id)")
        return beatAnswers[id] ?? []
    }
    func trackCues(id: String) async throws -> [Cue] {
        analysisCalls.append("cues:\(id)")
        return cueAnswers[id] ?? []
    }
    func trackPhrases(id: String) async throws -> [Phrase] {
        analysisCalls.append("phrases:\(id)")
        return phraseAnswers[id] ?? []
    }
    func trackVocals(id: String) async throws -> Data {
        analysisCalls.append("vocals:\(id)")
        return vocalAnswers[id] ?? Data()
    }

    func artwork(id: String) async -> Data? {
        artworkCalls.append(id)
        activeArtworkCalls += 1
        peakArtworkCalls = max(peakArtworkCalls, activeArtworkCalls)
        defer { activeArtworkCalls -= 1 }
        if artworkDelay > .zero { try? await Task.sleep(for: artworkDelay) }
        return artworkAnswers[id]
    }

    func setExplorer(roots: [ExplorerRoot], folders: [String: ExplorerChildren]) {
        explorerRootList = roots
        explorerFolders = folders
    }

    func setDevices(_ devices: [Device]) { deviceList = devices }

    static func details(track n: Int) -> TrackDetails {
        TrackDetails(
            id: String(n + 1), title: title(n), artist: "Artist \(n % 7)", album: "Album", albumArtist: "", originalArtist: "",
            composer: "", remixer: "", lyricist: "", genre: "House", label: "", key: "8A", comment: "", mixName: "",
            message: "", color: "0", rating: UInt8(n % 6), bpmX100: 12_000 + UInt32(n), durationSec: 200, year: 2020,
            trackNumber: 1, discNumber: 0, playCount: 3, fileType: 1, fileSize: 8_000_000, bitrate: 320,
            sampleRate: 44_100, bitDepth: 16, dateCreated: "2026-01-02", releaseDate: "", path: "/mock/audio/track-\(n + 1).mp3",
            hotCueAutoLoad: false, publish: false, hasArtwork: false, myTags: [])
    }

    static func title(_ n: Int) -> String { String(format: "Track %03d", n) }

    /// Each track is 3 minutes 20 seconds and 1 MB (+ its number in KB) when `.size` is asked for.
    static func row(track n: Int, position: Int, extra columns: [ExtraColumn] = []) -> Row {
        var extra = ExtraFields(
            size: nil, discNo: nil, albumArtist: nil, composer: nil, lyricist: nil, fileType: nil, year: nil,
            mixName: nil, remixer: nil, originalArtist: nil, sampleRate: nil, bitrate: nil, bitDepth: nil,
            location: nil, dateCreated: nil, publishTrackInfo: nil, message: nil, color: nil, djPlayCount: nil,
            myTag: nil, trackNumber: nil, cloud: nil)
        if columns.contains(.size) { extra.size = 1_000_000 + UInt64(n) * 1_000 }
        if columns.contains(.composer) { extra.composer = "Composer \(n % 3)" }
        return Row(
            id: String(n + 1), trackNo: UInt32(position), title: title(n), artist: "Artist \(n % 7)",
            album: "Album", genre: "House", label: "", comment: "", bpmX100: 12_000 + UInt32(n),
            key: "8A", durationSec: 200, rating: UInt8(n % 6), analysed: 1, dateAdded: "2026-01-01",
            releaseDate: "", hotCues: [], memoryCues: [], artworkHue: 0, hasArtwork: false, fileName: "",
            extra: extra)
    }
}

// MARK: - Editing

extension MockBackend {
    static let protectedMessage = "Editing is locked by Library Protection. Turn it off in Preferences to edit."
    static let runningMessage = "Editing is locked while rekordbox is running. Quit rekordbox to enable editing."

    fileprivate static func isList(_ kind: NodeKind) -> Bool { kind == .playlist || kind == .smartPlaylist || kind == .folder }

    fileprivate var gateClosed: Bool { gateProtected || gateRunning }

    // Test controls.
    func setRekordboxRunning(_ running: Bool) { gateRunning = running }
    func setMembers(_ ids: [String], of playlist: String) { memberships[playlist] = ids }
    func members(of playlist: String) -> [String] { memberships[playlist] ?? [] }
    var currentNodes: [TreeNode] { nodes }

    func isFixtureLibrary() async -> Bool { isFixture }
    func setSmartRule(_ rule: SmartRule, for id: String) { smartRules[id] = rule }
    func setIsFixture(_ value: Bool) { isFixture = value }
    func setFailure(_ error: FfiError) { failNextEdit = error }

    func setProtectLibrary(_ protect: Bool) async {
        protectCalls.append(protect)
        gateProtected = protect
    }

    func editHistory() async -> EditHistory { historyValue() }

    fileprivate func historyValue() -> EditHistory {
        EditHistory(
            generation: generation, canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty,
            undoLabel: undoStack.last?.label, redoLabel: redoStack.last?.label)
    }

    fileprivate func snapshot(_ label: String) -> Snapshot {
        Snapshot(label: label, nodes: nodes, memberships: memberships, smartRules: smartRules, meta: meta, tagList: tagList)
    }

    fileprivate func restore(_ s: Snapshot) {
        nodes = s.nodes
        memberships = s.memberships
        smartRules = s.smartRules
        meta = s.meta
        tagList = s.tagList
    }

    /// Runs one edit through the gate. `label` makes it undoable; nil edits only clear the redo branch.
    fileprivate func edit<T>(
        _ log: String, label: String?, tagListOnly: Bool = false, permanent: Bool = false, _ body: () throws -> T
    ) throws -> T {
        editLog.append(log)
        if gateProtected { throw FfiError.ReadOnly(message: Self.protectedMessage, detail: nil) }
        if gateRunning { throw FfiError.ReadOnly(message: Self.runningMessage, detail: nil) }
        if let failure = failNextEdit {
            failNextEdit = nil
            throw failure
        }
        let before = snapshot(label ?? "")
        let result = try body()
        if label != nil { undoStack.append(before) }
        redoStack.removeAll()
        if permanent { undoStack.removeAll() }
        publish(tagListOnly: tagListOnly)
        return result
    }

    fileprivate func publish(tagListOnly: Bool = false) {
        generation += 1
        views.removeAll()
        continuation.yield(tagListOnly ? .tagListChanged(generation: generation) : .libraryChanged(generation: generation))
        continuation.yield(.editHistoryChanged(history: historyValue()))
    }

    func undo() async throws -> EditHistory { try step(undo: true) }
    func redo() async throws -> EditHistory { try step(undo: false) }

    private func step(undo: Bool) throws -> EditHistory {
        editLog.append(undo ? "undo" : "redo")
        if gateProtected { throw FfiError.ReadOnly(message: Self.protectedMessage, detail: nil) }
        if gateRunning { throw FfiError.ReadOnly(message: Self.runningMessage, detail: nil) }
        guard let target = undo ? undoStack.popLast() : redoStack.popLast() else {
            throw FfiError.NotFound(
                message: undo ? "There is no library edit to undo." : "There is no library edit to redo.", detail: nil)
        }
        let now = snapshot(target.label)
        restore(target)
        if undo { redoStack.append(now) } else { undoStack.append(now) }
        publish()
        return historyValue()
    }

    // MARK: Tree helpers

    fileprivate func index(of id: String) -> Int? { nodes.firstIndex { $0.id == id } }

    /// `index` and everything nested under it.
    fileprivate func subtree(at index: Int) -> Range<Int> {
        let depth = nodes[index].depth
        var end = index + 1
        while end < nodes.count, nodes[end].depth > depth { end += 1 }
        return index..<end
    }

    /// Indexes of a parent's direct children; `"root"` is the Playlists heading.
    fileprivate func childIndexes(of parent: String) -> [Int]? {
        let heading = parent == "root" ? "playlists" : parent
        guard let at = index(of: heading) else { return nil }
        let depth = nodes[at].depth
        return subtree(at: at).dropFirst().filter { nodes[$0].depth == depth + 1 }
    }

    fileprivate func parentDepth(_ parent: String) -> UInt32? {
        let heading = parent == "root" ? "playlists" : parent
        return index(of: heading).map { nodes[$0].depth }
    }

    /// Where a new child at `position` (nil: last) goes among `parent`'s children.
    fileprivate func insertionPoint(parent: String, position: Int?) -> Int? {
        let heading = parent == "root" ? "playlists" : parent
        guard let at = index(of: heading), let kids = childIndexes(of: parent) else { return nil }
        if let position, position < kids.count { return kids[position] }
        return subtree(at: at).upperBound
    }

    fileprivate func create(_ kind: NodeKind, name: String, parent: String) throws -> String {
        guard let depth = parentDepth(parent), let at = insertionPoint(parent: parent, position: nil) else {
            throw FfiError.Malformed(message: "no playlist or folder \(parent)", detail: nil)
        }
        let heading = parent == "root" ? "playlists" : parent
        if let h = index(of: heading), nodes[h].kind == .playlist || nodes[h].kind == .smartPlaylist {
            throw FfiError.Malformed(message: "\(parent) is not a folder", detail: nil)
        }
        let id = String(nextPlaylistID)
        nextPlaylistID += 1
        nodes.insert(
            TreeNode(
                id: id, name: name, kind: kind, depth: depth + 1, expanded: kind == .folder ? true : nil,
                childCount: kind == .smartPlaylist ? nil : 0),
            at: at)
        if kind == .playlist { memberships[id] = [] }
        return id
    }

    func createPlaylist(name: String, parent: String) async throws -> String {
        try edit("createPlaylist(\(name),\(parent))", label: nil) { try create(.playlist, name: name, parent: parent) }
    }

    func createFolder(name: String, parent: String) async throws -> String {
        try edit("createFolder(\(name),\(parent))", label: nil) { try create(.folder, name: name, parent: parent) }
    }

    func createSmartPlaylist(name: String, parent: String, rule: SmartRule) async throws -> String {
        try edit("createSmartPlaylist(\(name),\(parent))", label: nil) {
            let id = try create(.smartPlaylist, name: name, parent: parent)
            smartRules[id] = rule
            return id
        }
    }

    func smartRule(playlistID: String) async throws -> SmartRule {
        guard let at = index(of: playlistID), nodes[at].kind == .smartPlaylist else {
            throw FfiError.NotFound(message: "That playlist is not in the library.", detail: nil)
        }
        return smartRules[playlistID] ?? SmartRule(logic: .all, conditions: [])
    }

    func saveSmartPlaylist(playlistID: String, name: String, rule: SmartRule) async throws -> EditHistory {
        try edit("saveSmartPlaylist(\(playlistID),\(name))", label: "Rename Playlist") {
            guard let at = index(of: playlistID), nodes[at].kind == .smartPlaylist else {
                throw FfiError.Malformed(message: "\(playlistID) is not an intelligent playlist", detail: nil)
            }
            if rule.conditions.contains(where: { $0.property.isEmpty }) {
                throw FfiError.Malformed(message: "\"\" is not a property a rule can use here.", detail: nil)
            }
            smartRules[playlistID] = rule
            nodes[at].name = name
            return historyValue()
        }
    }

    func renamePlaylist(id: String, name: String) async throws -> EditHistory {
        try edit("renamePlaylist(\(id),\(name))", label: "Rename Playlist") {
            guard let at = index(of: id) else { throw FfiError.Malformed(message: "no playlist or folder \(id)", detail: nil) }
            nodes[at].name = name
            return historyValue()
        }
    }

    func movePlaylist(id: String, parent: String, index position: UInt32?) async throws -> EditHistory {
        try edit("movePlaylist(\(id),\(parent),\(position.map(String.init) ?? "nil"))", label: "Move Playlist") {
            guard let at = index(of: id) else { throw FfiError.Malformed(message: "no playlist or folder \(id)", detail: nil) }
            let range = subtree(at: at)
            let heading = parent == "root" ? "playlists" : parent
            guard let target = index(of: heading), let newDepth = parentDepth(parent) else {
                throw FfiError.Malformed(message: "no playlist or folder \(parent)", detail: nil)
            }
            if range.contains(target) {
                throw FfiError.Malformed(message: "that would put a folder inside itself", detail: nil)
            }
            var moving = Array(nodes[range])
            nodes.removeSubrange(range)
            let delta = Int(newDepth) + 1 - Int(moving[0].depth)
            for i in moving.indices { moving[i].depth = UInt32(Int(moving[i].depth) + delta) }
            let at2 = insertionPoint(parent: parent, position: position.map(Int.init)) ?? nodes.count
            nodes.insert(contentsOf: moving, at: at2)
            return historyValue()
        }
    }

    func deletePlaylist(id: String) async throws -> EditHistory {
        try edit("deletePlaylist(\(id))", label: "Delete Playlist") {
            guard let at = index(of: id) else { throw FfiError.Malformed(message: "no playlist or folder \(id)", detail: nil) }
            nodes.removeSubrange(subtree(at: at))
            return historyValue()
        }
    }

    func sortChildren(parent: String) async throws -> EditHistory {
        try edit("sortChildren(\(parent))", label: "Sort Items") {
            guard let kids = childIndexes(of: parent), let first = kids.first else { return historyValue() }
            let groups = kids.map { Array(nodes[subtree(at: $0)]) }
            let sorted = groups.sorted { $0[0].name.lowercased() < $1[0].name.lowercased() }
            let end = subtree(at: kids.last!).upperBound
            nodes.replaceSubrange(first..<end, with: sorted.flatMap { $0 })
            return historyValue()
        }
    }

    func addTracksToPlaylist(playlistID: String, trackIDs: [String]) async throws -> UInt32 {
        try edit("addTracks(\(playlistID),\(trackIDs.joined(separator: ",")))", label: nil) {
            guard let at = index(of: playlistID), nodes[at].kind == .playlist else {
                throw FfiError.Malformed(message: "no playlist \(playlistID)", detail: nil)
            }
            var members = memberships[playlistID] ?? []
            var added: UInt32 = 0
            for id in trackIDs where !members.contains(id) {
                members.append(id)
                added += 1
            }
            memberships[playlistID] = members
            nodes[at].childCount = UInt32(members.count)
            return added
        }
    }

    func removeTracksFromPlaylist(playlistID: String, trackIDs: [String]) async throws -> EditHistory {
        try edit("removeTracks(\(playlistID),\(trackIDs.joined(separator: ",")))", label: "Remove Tracks from Playlist") {
            guard let at = index(of: playlistID), nodes[at].kind == .playlist else {
                throw FfiError.Malformed(message: "no playlist \(playlistID)", detail: nil)
            }
            let drop = Set(trackIDs)
            let members = (memberships[playlistID] ?? []).filter { !drop.contains($0) }
            memberships[playlistID] = members
            nodes[at].childCount = UInt32(members.count)
            return historyValue()
        }
    }

    func reorderPlaylist(playlistID: String, trackIDs: [String]) async throws {
        try edit("reorder(\(playlistID),\(trackIDs.joined(separator: ",")))", label: nil) {
            let old = memberships[playlistID] ?? []
            let kept = trackIDs.filter { old.contains($0) }
            memberships[playlistID] = kept + old.filter { !kept.contains($0) }
        }
    }
}


// MARK: - Phase 4b

extension MockBackend {
    static let ratingRange = "is not a rating between 0 and 5"

    fileprivate func applyMeta(_ row: Row) -> Row {
        guard let m = meta[row.id] else { return row }
        var row = row
        if let rating = m.rating { row.rating = rating }
        if let comment = m.comment { row.comment = comment }
        if let value = m.fields["title"] { row.title = value }
        if let value = m.fields["artist"] { row.artist = value }
        if let value = m.fields["album"] { row.album = value }
        if let value = m.fields["genre"] { row.genre = value }
        if let value = m.fields["label"] { row.label = value }
        if let value = m.fields["bpm"], let bpm = Double(value) { row.bpmX100 = UInt32(bpm * 100) }
        if let color = m.color { row.extra.color = color }
        return row
    }

    fileprivate func applyMeta(_ details: TrackDetails) -> TrackDetails {
        guard let m = meta[details.id] else { return details }
        var d = details
        if let rating = m.rating { d.rating = rating }
        if let comment = m.comment { d.comment = comment }
        if let color = m.color { d.color = color == 0 ? "" : String(color) }
        if let value = m.fields["title"] { d.title = value }
        if let value = m.fields["artist"] { d.artist = value }
        if let value = m.fields["album"] { d.album = value }
        if let value = m.fields["genre"] { d.genre = value }
        if let value = m.fields["label"] { d.label = value }
        if let value = m.fields["year"] { d.year = UInt32(value) ?? d.year }
        if let value = m.fields["bpm"], let bpm = Double(value) { d.bpmX100 = UInt32(bpm * 100) }
        return d
    }

    private func requireCollection(_ ids: [String]) throws {
        if ids.contains(where: { $0.hasPrefix("file:") }) {
            throw FfiError.Malformed(message: "That file is not in the collection. Import it first.", detail: nil)
        }
    }

    func setTrackRating(ids: [String], stars: UInt8) async throws -> EditHistory {
        try edit("setTrackRating(\(ids.joined(separator: ",")),\(stars))", label: "Track Edit") {
            try requireCollection(ids)
            if stars > 5 { throw FfiError.Malformed(message: "\(stars) \(Self.ratingRange)", detail: nil) }
            for id in ids { meta[id, default: Meta()].rating = stars }
            return historyValue()
        }
    }

    func setTrackComment(ids: [String], comment: String) async throws -> EditHistory {
        try edit("setTrackComment(\(ids.joined(separator: ",")),\(comment))", label: "Track Edit") {
            try requireCollection(ids)
            for id in ids { meta[id, default: Meta()].comment = comment }
            return historyValue()
        }
    }

    func setTrackColor(ids: [String], color: UInt8) async throws -> EditHistory {
        try edit("setTrackColor(\(ids.joined(separator: ",")),\(color))", label: "Track Edit") {
            try requireCollection(ids)
            if color > 8 { throw FfiError.Malformed(message: "\(color) is not a colour from 0 to 8.", detail: nil) }
            for id in ids { meta[id, default: Meta()].color = color }
            return historyValue()
        }
    }

    func setTrackField(ids: [String], field: TrackField, value: String) async throws -> EditHistory {
        let name = "\(field)"
        let isBpm = field == .bpm
        return try edit("setTrackField(\(ids.joined(separator: ",")),\(name),\(value))", label: isBpm ? nil : "Track Edit") {
            try requireCollection(ids)
            if isBpm {
                guard ids.count == 1 else {
                    throw FfiError.Malformed(message: "Select a single track to change its BPM.", detail: nil)
                }
                guard let bpm = Double(value.trimmingCharacters(in: .whitespaces)), (40.0...499.0).contains(bpm) else {
                    throw FfiError.Malformed(message: "Enter a BPM from 40 to 499.", detail: nil)
                }
            }
            for id in ids { meta[id, default: Meta()].fields[name] = value }
            return historyValue()
        }
    }

    func addToTagList(ids: [String]) async throws -> UInt32 {
        try edit("addToTagList(\(ids.joined(separator: ",")))", label: nil, tagListOnly: true) {
            try requireCollection(ids)
            var added: UInt32 = 0
            for id in ids where !tagList.contains(id) {
                tagList.append(id)
                added += 1
            }
            return generation
        }
    }

    func removeFromTagList(ids: [String]) async throws -> UInt32 {
        try edit("removeFromTagList(\(ids.joined(separator: ",")))", label: nil, tagListOnly: true) {
            tagList.removeAll { ids.contains($0) }
            return generation
        }
    }

    func reloadTags(ids: [String]) async throws -> UInt32 {
        try edit("reloadTags(\(ids.joined(separator: ",")))", label: nil) {
            try requireCollection(ids)
            return generation
        }
    }

    func resetPlayCount(ids: [String]) async throws -> EditHistory {
        try edit("resetPlayCount(\(ids.joined(separator: ",")))", label: "Track Edit") {
            try requireCollection(ids)
            for id in ids { meta[id, default: Meta()].fields["playCount"] = "0" }
            return historyValue()
        }
    }

    func removeFromHistory(historyID: String, ids: [String]) async throws -> UInt32 {
        try edit("removeFromHistory(\(historyID),\(ids.joined(separator: ",")))", label: nil) { generation }
    }

    func removeFromCollection(ids: [String]) async throws -> UInt32 {
        try edit("removeFromCollection(\(ids.joined(separator: ",")))", label: nil, permanent: true) {
            try requireCollection(ids)
            removedTracks.formUnion(ids)
            tagList.removeAll { ids.contains($0) }
            for key in memberships.keys { memberships[key]?.removeAll { ids.contains($0) } }
            for group in duplicateGroups.indices {
                duplicateGroups[group].tracks.removeAll { ids.contains($0.id) }
            }
            duplicateGroups.removeAll { $0.tracks.count < 2 }
            return generation
        }
    }

    func importFiles(paths: [String]) async throws -> ImportReport {
        importedPaths.append(paths)
        let report = try edit("importFiles(\(paths.joined(separator: ",")))", label: nil) { () -> ImportReport in
            for (index, title) in progressTitles.enumerated() {
                continuation.yield(
                    .importProgress(
                        progress: ImportProgress(
                            path: paths.first ?? "", state: "writing", done: UInt32(index + 1),
                            total: UInt32(progressTitles.count), title: title)))
            }
            trackCount += Int(importAnswer.imported)
            return importAnswer
        }
        return report
    }

    func importXML(path: String) async throws -> XmlImportReport {
        importedPaths.append([path])
        return try edit("importXML(\(path))", label: nil) {
            trackCount += Int(xmlAnswer.imported)
            return xmlAnswer
        }
    }

    var latestViewID: UInt32 { nextViewID - 1 }

    // Test controls for the import and relocate answers.
    func setImport(_ report: ImportReport, titles: [String] = []) {
        importAnswer = report
        progressTitles = titles
    }
    func setXML(_ report: XmlImportReport) { xmlAnswer = report }
    func setMissing(_ list: [MissingTrack]) { missingList = list }
    func setDuplicates(_ groups: [DuplicateGroup]) { duplicateGroups = groups }
    func setAutoRelocate(_ report: RelocateReport) { autoRelocateAnswer = report }

    func missingTracks(limit: UInt32) async throws -> MissingTracks {
        MissingTracks(total: UInt32(missingList.count), tracks: Array(missingList.prefix(Int(limit))))
    }

    func findDuplicates(limit: UInt32) async throws -> Duplicates {
        let extra = duplicateGroups.reduce(0) { $0 + $1.tracks.count - 1 }
        return Duplicates(
            groups: UInt32(duplicateGroups.count), extra: UInt32(extra), shown: Array(duplicateGroups.prefix(Int(limit))))
    }

    func relocateTrack(id: String, path: String) async throws -> UInt32 {
        try edit("relocateTrack(\(id),\(path))", label: nil) {
            relocations.append((id, path))
            missingList.removeAll { $0.id == id }
            return generation
        }
    }

    func autoRelocate(folders: [String]) async throws -> RelocateReport {
        autoRelocateFolders.append(folders)
        return try edit("autoRelocate(\(folders.joined(separator: ",")))", label: nil) {
            let answer = autoRelocateAnswer
            missingList.removeFirst(min(Int(answer.relocated), missingList.count))
            return answer
        }
    }

    // MARK: Phase 4c

    func setAnalysisDelay(_ delay: Duration) { analysisDelay = delay }
    func setAnalysisFailure(_ error: FfiError, for id: String) { analysisFailures[id] = error }

    /// A write that is not undoable: logged, gated, and failable once.
    private func gated<T>(_ log: String, _ body: () throws -> T) throws -> T {
        editLog.append(log)
        if gateProtected { throw FfiError.ReadOnly(message: Self.protectedMessage, detail: nil) }
        if gateRunning { throw FfiError.ReadOnly(message: Self.runningMessage, detail: nil) }
        if let failure = failNextEdit {
            failNextEdit = nil
            throw failure
        }
        return try body()
    }

    private func makeCue(slot: CueSlot, position: UInt32, out: UInt32) throws -> Cue {
        nextCueID += 1
        switch slot {
        case .memory:
            return Cue(id: "\(nextCueID)", positionMs: position, outMs: out, letter: "", memory: true, colour: nil, comment: "")
        case .hot(let letter):
            guard letter.count == 1, ("A"..."P").contains(letter) else {
                throw FfiError.Malformed(message: "\(letter) is not a hot cue slot rekordbox has", detail: nil)
            }
            return Cue(id: "\(nextCueID)", positionMs: position, outMs: out, letter: letter, memory: false, colour: nil, comment: "")
        }
    }

    func addCue(trackID: String, slot: CueSlot, positionMs: UInt32) async throws -> String {
        try gated("addCue(\(trackID),\(slot),\(positionMs))") {
            let cue = try makeCue(slot: slot, position: positionMs, out: 0)
            cueAnswers[trackID, default: []].append(cue)
            continuation.yield(.cuesChanged(trackId: trackID))
            return cue.id
        }
    }

    func addLoop(trackID: String, slot: CueSlot, inMs: UInt32, outMs: UInt32, beats: UInt16) async throws -> String {
        try gated("addLoop(\(trackID),\(slot),\(inMs),\(outMs))") {
            guard outMs > inMs else { throw FfiError.Malformed(message: "A loop must end after it starts.", detail: nil) }
            let cue = try makeCue(slot: slot, position: inMs, out: outMs)
            cueAnswers[trackID, default: []].append(cue)
            continuation.yield(.cuesChanged(trackId: trackID))
            return cue.id
        }
    }

    private func owner(of cueID: String) throws -> String {
        guard let track = cueAnswers.first(where: { $0.value.contains { $0.id == cueID } })?.key else {
            throw FfiError.NotFound(message: "no cue \(cueID)", detail: nil)
        }
        return track
    }

    func setCueColour(cueID: String, colour: UInt8?) async throws {
        try gated("setCueColour(\(cueID),\(colour.map(String.init) ?? "nil"))") {
            let track = try owner(of: cueID)
            if let i = cueAnswers[track]?.firstIndex(where: { $0.id == cueID }) {
                cueAnswers[track]?[i].colour = colour.map { "#0000\(String($0 + 16, radix: 16))" }
            }
            continuation.yield(.cuesChanged(trackId: track))
        }
    }

    func deleteCue(cueID: String) async throws {
        try gated("deleteCue(\(cueID))") {
            let track = try owner(of: cueID)
            cueAnswers[track]?.removeAll { $0.id == cueID }
            continuation.yield(.cuesChanged(trackId: track))
        }
    }

    func convertMemoryCuesToHot(trackID: String) async throws -> UInt32 {
        try gated("convertMemoryCuesToHot(\(trackID))") {
            let cues = cueAnswers[trackID] ?? []
            let taken = Set(cues.filter { !$0.memory }.map(\.letter))
            var free = "ABCDEFGHIJKLMNOP".map(String.init).filter { !taken.contains($0) }.makeIterator()
            var made: UInt32 = 0
            for memory in cues.filter(\.memory).sorted(by: { $0.positionMs < $1.positionMs }) {
                guard let letter = free.next() else { break }
                cueAnswers[trackID, default: []].append(
                    try makeCue(slot: .hot(letter: letter), position: memory.positionMs, out: memory.outMs))
                made += 1
            }
            continuation.yield(.cuesChanged(trackId: trackID))
            return made
        }
    }

    private func gridState(for id: String) -> GridState {
        gridStates[id] ?? GridState(
            bpmX100: beatAnswers[id]?.first.map { UInt32($0.tempoX100) } ?? 0, beats: UInt32(beatAnswers[id]?.count ?? 0),
            canUndo: false, canRedo: false, undoLabel: nil, redoLabel: nil, locked: false)
    }

    func gridState(trackID: String) async throws -> GridState { gridState(for: trackID) }

    func gridEdit(trackID: String, edit: GridEdit, fromMs: UInt32?, transaction: String?) async throws -> GridState {
        try gated("gridEdit(\(trackID),\(edit))") {
            var state = gridState(for: trackID)
            if state.locked { throw FfiError.ReadOnly(message: "The beat grid is locked. Unlock it to edit.", detail: nil) }
            gridEdits.append((trackID, edit, fromMs, transaction))
            if case .nudge(let ms) = edit {
                beatAnswers[trackID] = beatAnswers[trackID]?.map {
                    Beat(timeMs: UInt32(max(0, Int64($0.timeMs) + Int64(ms))), number: $0.number, tempoX100: $0.tempoX100)
                }
            }
            state.canUndo = true
            state.undoLabel = "Edit"
            gridStates[trackID] = state
            continuation.yield(.gridChanged(trackId: trackID))
            return state
        }
    }

    func gridUndo(trackID: String) async throws -> GridState {
        try gated("gridUndo(\(trackID))") {
            var state = gridState(for: trackID)
            guard state.canUndo else { throw FfiError.NotFound(message: "Nothing to undo.", detail: nil) }
            state.canUndo = false
            state.canRedo = true
            gridStates[trackID] = state
            continuation.yield(.gridChanged(trackId: trackID))
            return state
        }
    }

    func gridRedo(trackID: String) async throws -> GridState {
        try gated("gridRedo(\(trackID))") {
            var state = gridState(for: trackID)
            guard state.canRedo else { throw FfiError.NotFound(message: "Nothing to redo.", detail: nil) }
            state.canUndo = true
            state.canRedo = false
            gridStates[trackID] = state
            continuation.yield(.gridChanged(trackId: trackID))
            return state
        }
    }

    func gridLock(trackID: String, on: Bool) async throws -> GridState {
        try gated("gridLock(\(trackID),\(on))") {
            var state = gridState(for: trackID)
            state.locked = on
            gridStates[trackID] = state
            continuation.yield(.gridChanged(trackId: trackID))
            return state
        }
    }

    func analyseTrack(trackID: String, settings: AnalysisSettings, rekordboxMode: Bool) async throws -> AnalysisResult {
        activeAnalyses += 1
        peakAnalyses = max(peakAnalyses, activeAnalyses)
        defer { activeAnalyses -= 1 }
        if analysisDelay > .zero { try? await Task.sleep(for: analysisDelay) }
        return try gated("analyseTrack(\(trackID))") {
            if let failure = analysisFailures[trackID] { throw failure }
            analysisRuns.append((trackID, rekordboxMode))
            continuation.yield(.analysisChanged(trackId: trackID))
            return AnalysisResult(trackId: trackID, analysed: 105, bpmX100: 12_800, key: "Am", beats: 64, durationSec: 20, elapsedMs: 5)
        }
    }

    func reloadLibrary() async throws -> UInt32 {
        reloadCalls += 1
        generation += 1
        continuation.yield(.libraryChanged(generation: generation))
        return generation
    }

    func recordPlay(trackID: String) async throws -> UInt32 {
        try gated("recordPlay(\(trackID))") {
            recordedPlays.append(trackID)
            return generation
        }
    }
}


// MARK: - Phase 5a: devices, export, sync

/// Scripted answers and the call log of the device calls. Tests set the first group and read the second.
struct MockDeviceScript: Sendable {
    var exportReport = ExportReport(
        tracks: 5, playlists: 1, bytesCopied: 5_000_000, analysisFiles: 5, reused: 0, removed: 0, playlistsAdded: 1,
        playlistsRemoved: 0, skipped: [], verified: true)
    /// The progress states an export walks through, with `total` tracks.
    var steps: [ExportState] = [.preparing, .checking, .copying, .database, .verifying, .publishing, .done]
    var total: UInt32 = 5
    /// How long each step takes, so a test can look at the model mid-export.
    var stepDelay: Duration = .zero
    var exportFailure: FfiError?
    var ejectFailure: FfiError?
    var settings: [String: DeviceSettings] = [:]
    var saveFailure: FfiError?
    var syncOverrides: [String: SyncDeviceReport] = [:]
    var missing: [MissingExportFile] = []
    var syncStates: [String: DeviceSyncState] = [:]
    var verifyAnswer = VerifyReport(tracks: 5, playlists: 1, missingAudio: [], errors: [], ok: true)
    var progressSnapshot: [ExportProgress] = []

    var calls: [String] = []
    var ejected: [String] = []
    var saved: [(path: String, settings: DeviceSettings)] = []
    var cancelled: [String] = []
    var watcherStarts = 0
}

extension MockBackend {
    func scriptDevices(_ change: @Sendable (inout MockDeviceScript) -> Void) { change(&devices5a) }
    func deviceCalls5a() -> [String] { devices5a.calls }
    func ejectedPaths() -> [String] { devices5a.ejected }
    func savedSettings() -> [(path: String, settings: DeviceSettings)] { devices5a.saved }
    func cancelledPaths() -> [String] { devices5a.cancelled }
    func watcherStartCount() -> Int { devices5a.watcherStarts }

    static func blankSettings() -> DeviceSettings {
        let slots: (Int64, Int64, Bool) -> MenuSlot = { id, item, visible in
            MenuSlot(id: id, menuItem: item, name: "ITEM \(item)", seq: visible ? id : 0, visible: visible)
        }
        return DeviceSettings(
            hasDeviceLibrary: true, hasOneLibrary: true, hasDevSetting: true, waveformColor: .threeBand,
            waveformPosition: .center, overviewWaveform: .half, keyDisplay: .classic, hasLibrarySettings: true,
            deviceName: "STICK", backgroundColorType: 0,
            categories: [slots(1, 1, true), slots(2, 2, true), slots(3, 3, false), slots(4, 4, true)],
            sorts: [slots(1, 25, true), slots(2, 26, true), slots(3, 5, true), slots(4, 11, false)],
            subColumn: nil, colors: (1...8).map { ColorName(id: Int64($0), name: "Colour \($0)") })
    }

    func startDeviceWatcher() async { devices5a.watcherStarts += 1 }

    func ejectDevice(path: String) async throws {
        devices5a.calls.append("eject(\(path))")
        if let failure = devices5a.ejectFailure { throw failure }
        devices5a.ejected.append(path)
        deviceList.removeAll { $0.path == path }
        continuation.yield(.devicesChanged)
    }

    func deviceSettings(path: String) async throws -> DeviceSettings {
        devices5a.calls.append("deviceSettings(\(path))")
        return devices5a.settings[path] ?? Self.blankSettings()
    }

    func saveDeviceSettings(path: String, settings: DeviceSettings) async throws -> DeviceSettings {
        devices5a.calls.append("saveDeviceSettings(\(path))")
        if let failure = devices5a.saveFailure { throw failure }
        var stored = settings
        stored.deviceName = settings.deviceName.trimmingCharacters(in: .whitespaces)
        stored.hasDevSetting = true
        devices5a.settings[path] = stored
        devices5a.saved.append((path, stored))
        return stored
    }

    /// Walks the scripted progress for one destination, honouring a cancel asked meanwhile.
    private func runExport(to path: String, title: String) async throws {
        devices5a.cancelled.removeAll { $0 == path }
        let steps = devices5a.steps
        for (index, step) in steps.enumerated() {
            if devices5a.stepDelay > .zero { try? await Task.sleep(for: devices5a.stepDelay) }
            if devices5a.cancelled.contains(path), step != .done {
                continuation.yield(
                    .exportProgress(progress: ExportProgress(path: path, state: .cancelled, done: UInt32(index), total: devices5a.total, title: "")))
                throw FfiError.Cancelled(message: "Export stopped.", detail: nil)
            }
            let done = step == .done ? devices5a.total : min(UInt32(index), devices5a.total)
            continuation.yield(
                .exportProgress(progress: ExportProgress(path: path, state: step, done: done, total: devices5a.total, title: step == .copying ? title : "")))
        }
    }

    func exportPlaylistToDevice(playlistID: String, destination: String, options: ExportOptions) async throws -> ExportReport {
        devices5a.calls.append("exportPlaylist(\(playlistID),\(destination),delete:\(options.deleteUnlistedMusic))")
        if let failure = devices5a.exportFailure {
            continuation.yield(
                .exportProgress(progress: ExportProgress(path: destination, state: .failed, done: 0, total: 0, title: describe(failure))))
            throw failure
        }
        try await runExport(to: destination, title: "Track 001")
        continuation.yield(.exportDone(report: devices5a.exportReport))
        return devices5a.exportReport
    }

    func exportTracksToDevice(trackIDs: [String], destination: String, options: ExportOptions) async throws -> ExportReport {
        devices5a.calls.append("exportTracks(\(trackIDs.joined(separator: ",")),\(destination))")
        if let failure = devices5a.exportFailure { throw failure }
        try await runExport(to: destination, title: "Track 001")
        continuation.yield(.exportDone(report: devices5a.exportReport))
        return devices5a.exportReport
    }

    func syncDevices(playlistIDs: [String], destinations: [String], options: ExportOptions) async throws -> [SyncDeviceReport] {
        devices5a.calls.append("sync(\(playlistIDs.joined(separator: ",")) -> \(destinations.joined(separator: ",")),eject:\(options.ejectAfterSync))")
        var reports: [SyncDeviceReport] = []
        // The core writes every stick at once: all of them announce themselves before any finishes.
        for path in destinations {
            continuation.yield(.syncProgress(progress: SyncProgress(path: path, state: .writing)))
            continuation.yield(.exportProgress(progress: ExportProgress(path: path, state: .preparing, done: 0, total: devices5a.total, title: "")))
        }
        for path in destinations {
            if let override = devices5a.syncOverrides[path] {
                continuation.yield(.syncProgress(progress: SyncProgress(path: path, state: override.error == nil ? .done : .failed)))
                reports.append(override)
                continue
            }
            do {
                try await runExport(to: path, title: "Track 001")
            } catch {
                continuation.yield(.syncProgress(progress: SyncProgress(path: path, state: .failed)))
                reports.append(SyncDeviceReport(path: path, report: nil, error: describe(error), ejected: false, ejectError: nil))
                continue
            }
            var ejected = false
            if options.ejectAfterSync {
                continuation.yield(.syncProgress(progress: SyncProgress(path: path, state: .ejecting)))
                ejected = true
                devices5a.ejected.append(path)
                deviceList.removeAll { $0.path == path }
                continuation.yield(.devicesChanged)
            }
            continuation.yield(.syncProgress(progress: SyncProgress(path: path, state: .done)))
            reports.append(SyncDeviceReport(path: path, report: devices5a.exportReport, error: nil, ejected: ejected, ejectError: nil))
        }
        return reports
    }

    func validateExportFiles(playlistIDs: [String]) async throws -> [MissingExportFile] {
        devices5a.calls.append("validate(\(playlistIDs.joined(separator: ",")))")
        return devices5a.missing
    }

    func deviceSyncState(path: String) async throws -> DeviceSyncState {
        devices5a.calls.append("syncState(\(path))")
        return devices5a.syncStates[path] ?? DeviceSyncState(selected: [], onDevice: [], libraries: [], automatic: false)
    }

    func verifyDevice(path: String) async throws -> VerifyReport {
        devices5a.calls.append("verify(\(path))")
        return devices5a.verifyAnswer
    }

    func cancelExport(path: String) async { devices5a.cancelled.append(path) }

    func exportProgress() async -> [ExportProgress] { devices5a.progressSnapshot }
}

// MARK: - Phase 5b

/// What the USB-import and iTunes calls answer, and what they were asked.
struct MockImportScript: Sendable {
    var usbReport = UsbImportReport(tracks: 3, histories: 2, settings: 1, skipped: 1, warnings: [])
    /// Per-kind answers override `usbReport` ("cues", "history", "settings").
    var usbByKind: [String: UsbImportReport] = [:]
    var usbFailure: [String: FfiError] = [:]
    var usbDelay: Duration = .zero
    var library: ItunesLibrary?
    var libraries: [String: ItunesLibrary] = [:]
    var tracks: [String: [ItunesTrack]] = [:]
    var itunesReport = XmlImportReport(imported: 2, existing: 1, skipped: [], playlists: 2, cues: 0, tracks: [])
    var itunesFailure: FfiError?
    var usbCalls: [String] = []
    var itunesCalls: [String] = []
}

extension MockBackend {
    func scriptImports(_ change: @Sendable (inout MockImportScript) -> Void) { change(&imports5b) }
    func usbCalls() -> [String] { imports5b.usbCalls }
    func itunesCalls() -> [String] { imports5b.itunesCalls }

    func importUSB(path: String, cues: Bool, history: Bool, settings: Bool) async throws -> UsbImportReport {
        let kind = cues ? "cues" : history ? "history" : "settings"
        imports5b.usbCalls.append("importUSB(\(path),cues:\(cues),history:\(history),settings:\(settings))")
        if imports5b.usbDelay > .zero { try? await Task.sleep(for: imports5b.usbDelay) }
        // The gate guards cues and history; copying settings touches no library row.
        if cues || history {
            if gateProtected { throw FfiError.ReadOnly(message: Self.protectedMessage, detail: nil) }
            if gateRunning { throw FfiError.ReadOnly(message: Self.runningMessage, detail: nil) }
        }
        if let failure = imports5b.usbFailure[kind] { throw failure }
        continuation.yield(.importProgress(progress: ImportProgress(path: path, state: "writing", done: 1, total: 1, title: kind)))
        let report = imports5b.usbByKind[kind] ?? imports5b.usbReport
        if report.tracks > 0 || report.histories > 0 { publish() }
        return report
    }

    func itunesDefaultLibrary() async throws -> ItunesLibrary? {
        imports5b.itunesCalls.append("default")
        return isFixture ? nil : imports5b.library
    }

    func itunesLibrary(at path: String) async throws -> ItunesLibrary {
        imports5b.itunesCalls.append("library(\(path))")
        if let library = imports5b.libraries[path] ?? (imports5b.library?.path == path ? imports5b.library : nil) {
            return library
        }
        throw FfiError.NotFound(message: "That file could not be read.", detail: nil)
    }

    func itunesPlaylistTracks(path: String, nodeID: String) async throws -> [ItunesTrack] {
        imports5b.itunesCalls.append("tracks(\(nodeID))")
        return imports5b.tracks[nodeID] ?? []
    }

    func importItunesSelected(path: String, ids: [String]) async throws -> XmlImportReport {
        imports5b.itunesCalls.append("import(\(ids.joined(separator: ",")))")
        return try edit("importItunes(\(ids.joined(separator: ",")))", label: nil) {
            if let failure = imports5b.itunesFailure { throw failure }
            continuation.yield(.importProgress(progress: ImportProgress(path: path, state: "writing", done: 1, total: 1, title: "")))
            trackCount += Int(imports5b.itunesReport.imported)
            return imports5b.itunesReport
        }
    }
}

// MARK: - Phase 5c

/// What the LINK calls answer, and what they were asked. The mock never opens a socket.
struct MockLinkScript: Sendable {
    static let off = LinkStatus(
        on: false, problem: nil, interface: nil, players: [], interfaces: [], master: false, masterBpm: 120,
        state: .off, number: nil)
    var status = MockLinkScript.off
    var peers: [LinkPeer] = []
    /// What a start answers; defaults to "up on en5".
    var startAnswer: LinkStatus?
    var loadFailure: FfiError?
    var calls: [String] = []
    var watcherStarts = 0
}

extension MockBackend {
    func scriptLink(_ change: @Sendable (inout MockLinkScript) -> Void) { change(&link5c) }
    func linkCalls() -> [String] { link5c.calls }
    func watcherStarts() -> Int { link5c.watcherStarts }

    func linkStatus() async -> LinkStatus { link5c.status }
    func linkPeers() async -> [LinkPeer] { link5c.peers }
    func startPeerWatcher() async { link5c.watcherStarts += 1 }

    func startLinkExport(interface: String?, alphanumericKeys: Bool, alphabeticalKeys: Bool) async -> LinkStatus {
        link5c.calls.append("start(\(interface ?? "auto"),alphanumeric:\(alphanumericKeys),alphabetical:\(alphabeticalKeys))")
        if link5c.status.problem != nil && !link5c.status.on { return link5c.status }
        let answer = link5c.startAnswer ?? LinkStatus(
            on: true, problem: nil,
            interface: LinkInterface(name: interface ?? "en5", address: "10.0.0.2", adapter: "USB Ethernet", connection: .wired),
            players: link5c.status.players, interfaces: link5c.status.interfaces, master: false, masterBpm: 120,
            state: .up, number: 17)
        link5c.status = answer
        return answer
    }

    func stopLinkExport() async -> LinkStatus {
        link5c.calls.append("stop")
        link5c.status = LinkStatus(
            on: false, problem: nil, interface: nil, players: [], interfaces: link5c.status.interfaces, master: false,
            masterBpm: link5c.status.masterBpm, state: .off, number: nil)
        return link5c.status
    }

    func linkLoadTrack(playerNumber: UInt8, trackID: String) async throws {
        link5c.calls.append("load(\(playerNumber),\(trackID))")
        if let failure = link5c.loadFailure { throw failure }
    }

    func linkSetMaster(on: Bool) async -> LinkStatus {
        link5c.calls.append("master(\(on))")
        link5c.status.master = on
        return link5c.status
    }

    func linkNudgeMaster(deltaBpm: Double) async -> LinkStatus {
        link5c.calls.append("nudge(\(deltaBpm))")
        link5c.status.masterBpm += deltaBpm
        return link5c.status
    }

    func linkTakeMasterTempo() async -> LinkStatus {
        link5c.calls.append("takeTempo")
        return link5c.status
    }
}
