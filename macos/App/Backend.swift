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
