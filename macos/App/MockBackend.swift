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
    fileprivate struct Snapshot {
        var label: String
        var nodes: [TreeNode]
        var memberships: [String: [String]]
        var smartRules: [String: SmartRule]
    }
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
        return (start..<end).map { Self.row(track: view.titles[$0], position: $0 + 1, extra: extraColumns) }
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
        guard let n = Int(id), n >= 1, n <= trackCount else {
            throw FfiError.NotFound(message: "That track is no longer in the library.", detail: nil)
        }
        return Self.details(track: n - 1)
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
        Snapshot(label: label, nodes: nodes, memberships: memberships, smartRules: smartRules)
    }

    fileprivate func restore(_ s: Snapshot) {
        nodes = s.nodes
        memberships = s.memberships
        smartRules = s.smartRules
    }

    /// Runs one edit through the gate. `label` makes it undoable; nil edits only clear the redo branch.
    fileprivate func edit<T>(_ log: String, label: String?, _ body: () throws -> T) throws -> T {
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
        publish()
        return result
    }

    fileprivate func publish() {
        generation += 1
        views.removeAll()
        continuation.yield(.libraryChanged(generation: generation))
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
