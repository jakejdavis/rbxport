import Foundation

/// Everything the UI needs from the library, behind a protocol so previews and
/// unit tests can swap in `MockBackend`.
protocol BackendProtocol: Sendable {
    /// Library events (ready, problem, changed...). One consumer should iterate it.
    var events: AsyncStream<LibraryEvent> { get }

    /// Loads the library. The outcome also arrives on `events`; the model reacts to that.
    func loadLibrary() async -> LoadOutcome
    func summary() async throws -> LibrarySummary
    func playlistTree() async throws -> [TreeNode]
    func openView(_ spec: ViewSpec) async throws -> ViewHandle
    func fetchRows(viewID: UInt32, offset: UInt32, len: UInt32, extraColumns: [ExtraColumn]) async throws -> [Row]
    /// Track ids at positions `from...to` (inclusive) of a view, in view order.
    func viewIDsInRange(viewID: UInt32, from: UInt32, to: UInt32) async throws -> [String]
    /// The BPMs and keys the filter bar offers for the spec's source and query (its own filter is ignored).
    func filterValues(_ spec: ViewSpec) async throws -> FilterValues
    func explorerRoots() async throws -> [ExplorerRoot]
    /// The folders directly under `path`, by name, capped by the core.
    func explorerChildren(path: String) async throws -> ExplorerChildren
    func listDevices() async throws -> [Device]
    /// Writes a playlist to `path`; returns the number of tracks written.
    func exportPlaylistFile(playlistID: String, path: String, format: PlaylistFileFormat) async throws -> UInt32
    /// The audio file of a track (or a loose `file:` id).
    func trackPath(id: String) async throws -> String
    /// The same, answered at once, for a drag that needs the file as it begins. Nil when unknown.
    nonisolated func trackPathSync(id: String) -> String?
    /// One track in full, for the info panel. Throws `NotFound` for a track that has gone.
    func trackDetails(id: String) async throws -> TrackDetails
    /// The lists the Info tab's pickers offer (keys, genres, My Tags).
    func trackLookups() async throws -> TrackLookups
    /// A track's overview waveform in a palette's layout; empty when it has no analysis.
    func waveform(id: String, kind: WaveformKind) async throws -> Data
    /// The artwork image file, or nil (none, missing, or refused by the core).
    func artwork(id: String) async -> Data?
    /// A track's beat grid (PQTZ offset applied); empty without an analysis.
    func trackBeats(id: String) async throws -> [Beat]
    /// A track's hot cues, memory cues and loops.
    func trackCues(id: String) async throws -> [Cue]
    func trackPhrases(id: String) async throws -> [Phrase]
    /// One intensity byte per 46.44 ms where a voice was heard.
    func trackVocals(id: String) async throws -> Data
    /// The decks and the preview player.
    var playback: any PlaybackEngine { get }

    // MARK: Editing. Every call passes the core's write gate and throws `FfiError.ReadOnly` when it is closed.

    /// True when the loaded library is a generated fixture. Developer hooks that write need this.
    func isFixtureLibrary() async -> Bool
    /// Library Protection, as the app's setting stands.
    func setProtectLibrary(_ protect: Bool) async
    /// The undo/redo state and labels.
    func editHistory() async -> EditHistory
    func undo() async throws -> EditHistory
    func redo() async throws -> EditHistory
    /// New items return their id. `parent` is a playlist folder's id, or `"root"`.
    func createPlaylist(name: String, parent: String) async throws -> String
    func createFolder(name: String, parent: String) async throws -> String
    func createSmartPlaylist(name: String, parent: String, rule: SmartRule) async throws -> String
    func smartRule(playlistID: String) async throws -> SmartRule
    func saveSmartPlaylist(playlistID: String, name: String, rule: SmartRule) async throws -> EditHistory
    func renamePlaylist(id: String, name: String) async throws -> EditHistory
    /// `index` counts the parent's children with the moved item lifted out; nil appends.
    func movePlaylist(id: String, parent: String, index: UInt32?) async throws -> EditHistory
    func deletePlaylist(id: String) async throws -> EditHistory
    /// Sort Items: one undo step.
    func sortChildren(parent: String) async throws -> EditHistory
    /// Returns how many tracks were new to the playlist.
    func addTracksToPlaylist(playlistID: String, trackIDs: [String]) async throws -> UInt32
    func removeTracksFromPlaylist(playlistID: String, trackIDs: [String]) async throws -> EditHistory
    /// Sets the playlist's full track order.
    func reorderPlaylist(playlistID: String, trackIDs: [String]) async throws

    // MARK: Phase 4b: metadata, Tag List, history, collection, import, missing files.

    /// Stars 0 to 5 on every track, one undo step. More than 5 throws `Malformed`.
    func setTrackRating(ids: [String], stars: UInt8) async throws -> EditHistory
    func setTrackComment(ids: [String], comment: String) async throws -> EditHistory
    /// Colour 1 to 8, or 0 for none. Anything else throws `Malformed`.
    func setTrackColor(ids: [String], color: UInt8) async throws -> EditHistory
    /// An Info-tab field. `.bpm` takes one track and is not undoable.
    func setTrackField(ids: [String], field: TrackField, value: String) async throws -> EditHistory
    func addToTagList(ids: [String]) async throws -> UInt32
    func removeFromTagList(ids: [String]) async throws -> UInt32
    func reloadTags(ids: [String]) async throws -> UInt32
    func resetPlayCount(ids: [String]) async throws -> EditHistory
    func removeFromHistory(historyID: String, ids: [String]) async throws -> UInt32
    /// Permanent; the undo history is cleared. The files stay on disk.
    func removeFromCollection(ids: [String]) async throws -> UInt32
    /// Imports files and folders. Raises `.importProgress` events while it runs.
    func importFiles(paths: [String]) async throws -> ImportReport
    func importXML(path: String) async throws -> XmlImportReport
    func missingTracks(limit: UInt32) async throws -> MissingTracks
    func findDuplicates(limit: UInt32) async throws -> Duplicates
    func relocateTrack(id: String, path: String) async throws -> UInt32
    func autoRelocate(folders: [String]) async throws -> RelocateReport

    // MARK: Phase 4c: cues, beat grid, analysis, plays. All behind the write gate.

    /// Adds a cue at a position; returns its id. A refusal throws `FfiError.ReadOnly`.
    func addCue(trackID: String, slot: CueSlot, positionMs: UInt32) async throws -> String
    func addLoop(trackID: String, slot: CueSlot, inMs: UInt32, outMs: UInt32, beats: UInt16) async throws -> String
    /// A hot cue takes a colour-table index; a memory cue its named index 0 to 7; nil resets.
    func setCueColour(cueID: String, colour: UInt8?) async throws
    func deleteCue(cueID: String) async throws
    func convertMemoryCuesToHot(trackID: String) async throws -> UInt32
    func gridState(trackID: String) async throws -> GridState
    /// `fromMs` limits the edit to the beats from there on; `transaction` groups taps into one undo step.
    func gridEdit(trackID: String, edit: GridEdit, fromMs: UInt32?, transaction: String?) async throws -> GridState
    func gridUndo(trackID: String) async throws -> GridState
    func gridRedo(trackID: String) async throws -> GridState
    /// The analysis lock, on or off.
    func gridLock(trackID: String, on: Bool) async throws -> GridState
    /// Analyses one track (seconds of work; runs off the actor).
    func analyseTrack(trackID: String, settings: AnalysisSettings, rekordboxMode: Bool) async throws -> AnalysisResult
    /// Re-reads the library once, after a run of analyses.
    func reloadLibrary() async throws -> UInt32
    func recordPlay(trackID: String) async throws -> UInt32
}

/// Forwards the Rust core's callbacks into an `AsyncStream`.
final class EventBridge: EventListener, Sendable {
    let stream: AsyncStream<LibraryEvent>
    private let continuation: AsyncStream<LibraryEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: LibraryEvent.self)
    }

    // Called on whatever thread raised the event; yielding is thread-safe and non-blocking.
    func onEvent(event: LibraryEvent) {
        continuation.yield(event)
    }

    deinit { continuation.finish() }
}

/// Owns the UniFFI `Core`. Every call blocks, so none run on the main actor.
actor Backend: BackendProtocol {
    nonisolated let events: AsyncStream<LibraryEvent>
    nonisolated let playback: any PlaybackEngine
    private let core: Core

    /// The installed rekordbox library, opened read-only. `cacheDir` holds the snapshot cache.
    init(cacheDir: URL?) {
        let bridge = EventBridge()
        events = bridge.stream
        if let cacheDir {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        let core = Core(listener: bridge, cacheDir: cacheDir?.path)
        self.core = core
        playback = Backend.makePlayback(core)
    }

    /// A fixture library in `fixtureDir` (built if empty), for tests and previews.
    init(fixtureDir: URL) {
        let bridge = EventBridge()
        events = bridge.stream
        let core = Core.withFixture(listener: bridge, dir: fixtureDir.path)
        self.core = core
        playback = Backend.makePlayback(core)
    }

    /// The playback object. Honours `RBXPORT_NULL_AUDIO=1` (a silent, real-time sink).
    private static func makePlayback(_ core: Core) -> any PlaybackEngine {
        let bridge = PlaybackBridge()
        return RustPlayback(playback: core.playback(listener: bridge), bridge: bridge)
    }

    static var defaultCacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.rbxport.native", isDirectory: true)
    }

    func loadLibrary() async -> LoadOutcome { core.loadLibrary() }
    func summary() async throws -> LibrarySummary { try core.summary() }
    func playlistTree() async throws -> [TreeNode] { try core.playlistTree() }
    func openView(_ spec: ViewSpec) async throws -> ViewHandle { try core.openView(spec: spec) }
    func fetchRows(viewID: UInt32, offset: UInt32, len: UInt32, extraColumns: [ExtraColumn]) async throws -> [Row] {
        try core.fetchRows(viewId: viewID, offset: offset, len: len, extraColumns: extraColumns)
    }
    func viewIDsInRange(viewID: UInt32, from: UInt32, to: UInt32) async throws -> [String] {
        try core.viewIdsInRange(viewId: viewID, from: from, to: to)
    }
    func filterValues(_ spec: ViewSpec) async throws -> FilterValues { try core.filterValues(spec: spec) }
    func explorerRoots() async throws -> [ExplorerRoot] { try core.explorerRoots() }
    func explorerChildren(path: String) async throws -> ExplorerChildren { try core.explorerChildren(path: path) }
    func listDevices() async throws -> [Device] { try core.listDevices() }
    func exportPlaylistFile(playlistID: String, path: String, format: PlaylistFileFormat) async throws -> UInt32 {
        try core.exportPlaylistFile(playlistId: playlistID, path: path, format: format)
    }
    func trackPath(id: String) async throws -> String { try core.trackPath(trackId: id) }
    nonisolated func trackPathSync(id: String) -> String? { try? core.trackPath(trackId: id) }
    func trackDetails(id: String) async throws -> TrackDetails { try core.trackDetails(trackId: id) }
    func trackLookups() async throws -> TrackLookups { try core.trackLookups() }
    func waveform(id: String, kind: WaveformKind) async throws -> Data {
        try core.waveform(trackId: id, kind: kind)
    }
    func artwork(id: String) async -> Data? { core.artwork(trackId: id) }
    func trackBeats(id: String) async throws -> [Beat] { try core.trackBeats(trackId: id) }
    func trackCues(id: String) async throws -> [Cue] { try core.trackCues(trackId: id) }
    func trackPhrases(id: String) async throws -> [Phrase] { try core.trackPhrases(trackId: id) }
    func trackVocals(id: String) async throws -> Data { Data(try core.trackVocals(trackId: id)) }

    func isFixtureLibrary() async -> Bool { core.isFixtureLibrary() }
    func setProtectLibrary(_ protect: Bool) async { core.setProtectLibrary(protect: protect) }
    func editHistory() async -> EditHistory { core.editHistory() }
    func undo() async throws -> EditHistory { try core.undo() }
    func redo() async throws -> EditHistory { try core.redo() }
    func createPlaylist(name: String, parent: String) async throws -> String {
        try core.createPlaylist(name: name, parent: parent)
    }
    func createFolder(name: String, parent: String) async throws -> String {
        try core.createFolder(name: name, parent: parent)
    }
    func createSmartPlaylist(name: String, parent: String, rule: SmartRule) async throws -> String {
        try core.createSmartPlaylist(name: name, parent: parent, rule: rule)
    }
    func smartRule(playlistID: String) async throws -> SmartRule { try core.smartRule(playlistId: playlistID) }
    func saveSmartPlaylist(playlistID: String, name: String, rule: SmartRule) async throws -> EditHistory {
        try core.saveSmartPlaylist(playlistId: playlistID, name: name, rule: rule)
    }
    func renamePlaylist(id: String, name: String) async throws -> EditHistory {
        try core.renamePlaylist(id: id, name: name)
    }
    func movePlaylist(id: String, parent: String, index: UInt32?) async throws -> EditHistory {
        try core.movePlaylist(id: id, parent: parent, index: index)
    }
    func deletePlaylist(id: String) async throws -> EditHistory { try core.deletePlaylist(id: id) }
    func sortChildren(parent: String) async throws -> EditHistory { try core.sortChildren(parent: parent) }
    func addTracksToPlaylist(playlistID: String, trackIDs: [String]) async throws -> UInt32 {
        try core.addTracksToPlaylist(playlistId: playlistID, trackIds: trackIDs)
    }
    func removeTracksFromPlaylist(playlistID: String, trackIDs: [String]) async throws -> EditHistory {
        try core.removeTracksFromPlaylist(playlistId: playlistID, trackIds: trackIDs)
    }
    func reorderPlaylist(playlistID: String, trackIDs: [String]) async throws {
        try core.reorderPlaylist(playlistId: playlistID, trackIds: trackIDs)
    }

    func setTrackRating(ids: [String], stars: UInt8) async throws -> EditHistory {
        try core.setTrackRating(trackIds: ids, stars: stars)
    }
    func setTrackComment(ids: [String], comment: String) async throws -> EditHistory {
        try core.setTrackComment(trackIds: ids, comment: comment)
    }
    func setTrackColor(ids: [String], color: UInt8) async throws -> EditHistory {
        try core.setTrackColor(trackIds: ids, color: color)
    }
    func setTrackField(ids: [String], field: TrackField, value: String) async throws -> EditHistory {
        try core.setTrackField(trackIds: ids, field: field, value: value)
    }
    func addToTagList(ids: [String]) async throws -> UInt32 { try core.addToTagList(trackIds: ids) }
    func removeFromTagList(ids: [String]) async throws -> UInt32 { try core.removeFromTagList(trackIds: ids) }
    func reloadTags(ids: [String]) async throws -> UInt32 { try core.reloadTags(trackIds: ids) }
    func resetPlayCount(ids: [String]) async throws -> EditHistory { try core.resetPlayCount(trackIds: ids) }
    func removeFromHistory(historyID: String, ids: [String]) async throws -> UInt32 {
        try core.removeFromHistory(historyId: historyID, trackIds: ids)
    }
    func removeFromCollection(ids: [String]) async throws -> UInt32 { try core.removeFromCollection(trackIds: ids) }

    // Imports and the relocate walk can run for a while. They leave the actor so row fetches,
    // waveforms and the other reads are not queued behind them.
    func importFiles(paths: [String]) async throws -> ImportReport {
        let core = core
        return try await Task.detached { try core.importFiles(paths: paths) }.value
    }
    func importXML(path: String) async throws -> XmlImportReport {
        let core = core
        return try await Task.detached { try core.importXml(path: path) }.value
    }
    func missingTracks(limit: UInt32) async throws -> MissingTracks {
        let core = core
        return try await Task.detached { try core.missingTracks(limit: limit) }.value
    }
    func findDuplicates(limit: UInt32) async throws -> Duplicates {
        let core = core
        return try await Task.detached { try core.findDuplicates(limit: limit) }.value
    }
    func relocateTrack(id: String, path: String) async throws -> UInt32 {
        try core.relocateTrack(trackId: id, path: path)
    }
    func autoRelocate(folders: [String]) async throws -> RelocateReport {
        let core = core
        return try await Task.detached { try core.autoRelocate(folders: folders) }.value
    }

    func addCue(trackID: String, slot: CueSlot, positionMs: UInt32) async throws -> String {
        try core.addCue(trackId: trackID, slot: slot, positionMs: positionMs)
    }
    func addLoop(trackID: String, slot: CueSlot, inMs: UInt32, outMs: UInt32, beats: UInt16) async throws -> String {
        try core.addLoop(trackId: trackID, slot: slot, inMs: inMs, outMs: outMs, beats: beats)
    }
    func setCueColour(cueID: String, colour: UInt8?) async throws { try core.setCueColour(cueId: cueID, colour: colour) }
    func deleteCue(cueID: String) async throws { try core.deleteCue(cueId: cueID) }
    func convertMemoryCuesToHot(trackID: String) async throws -> UInt32 {
        try core.convertMemoryCuesToHot(trackId: trackID)
    }
    func gridState(trackID: String) async throws -> GridState { try core.gridState(trackId: trackID) }
    func gridEdit(trackID: String, edit: GridEdit, fromMs: UInt32?, transaction: String?) async throws -> GridState {
        try core.gridEdit(trackId: trackID, edit: edit, fromMs: fromMs, transaction: transaction)
    }
    func gridUndo(trackID: String) async throws -> GridState { try core.gridUndo(trackId: trackID) }
    func gridRedo(trackID: String) async throws -> GridState { try core.gridRedo(trackId: trackID) }
    func gridLock(trackID: String, on: Bool) async throws -> GridState { try core.gridLock(trackId: trackID, on: on) }
    func analyseTrack(trackID: String, settings: AnalysisSettings, rekordboxMode: Bool) async throws -> AnalysisResult {
        let core = core
        return try await Task.detached {
            try core.analyseTrack(trackId: trackID, settings: settings, rekordboxMode: rekordboxMode)
        }.value
    }
    func reloadLibrary() async throws -> UInt32 {
        let core = core
        return try await Task.detached { try core.reloadLibrary() }.value
    }
    func recordPlay(trackID: String) async throws -> UInt32 { try core.recordPlay(trackId: trackID) }
}

func describe(_ error: Error) -> String {
    if let e = error as? FfiError {
        switch e {
        case .ReadOnly(let m, _), .NotFound(let m, _), .Malformed(let m, _), .Cancelled(let m, _), .Internal(let m, _):
            return m
        }
    }
    return String(describing: error)
}
