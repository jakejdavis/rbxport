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
    /// One track in full, for the info panel. Throws `NotFound` for a track that has gone.
    func trackDetails(id: String) async throws -> TrackDetails
    /// The lists the Info tab's pickers offer (keys, genres, My Tags).
    func trackLookups() async throws -> TrackLookups
    /// A track's overview waveform in a palette's layout; empty when it has no analysis.
    func waveform(id: String, kind: WaveformKind) async throws -> Data
    /// The artwork image file, or nil (none, missing, or refused by the core).
    func artwork(id: String) async -> Data?
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
    private let core: Core

    /// The installed rekordbox library, opened read-only. `cacheDir` holds the snapshot cache.
    init(cacheDir: URL?) {
        let bridge = EventBridge()
        events = bridge.stream
        if let cacheDir {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        core = Core(listener: bridge, cacheDir: cacheDir?.path)
    }

    /// A fixture library in `fixtureDir` (built if empty), for tests and previews.
    init(fixtureDir: URL) {
        let bridge = EventBridge()
        events = bridge.stream
        core = Core.withFixture(listener: bridge, dir: fixtureDir.path)
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
    func trackDetails(id: String) async throws -> TrackDetails { try core.trackDetails(trackId: id) }
    func trackLookups() async throws -> TrackLookups { try core.trackLookups() }
    func waveform(id: String, kind: WaveformKind) async throws -> Data {
        try core.waveform(trackId: id, kind: kind)
    }
    func artwork(id: String) async -> Data? { core.artwork(trackId: id) }
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
