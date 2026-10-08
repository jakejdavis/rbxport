import Foundation

/// An in-memory library for previews and unit tests.
actor MockBackend: BackendProtocol {
    nonisolated let events: AsyncStream<LibraryEvent>
    private let continuation: AsyncStream<LibraryEvent>.Continuation

    private var trackCount: Int
    private var nodes: [TreeNode]
    private var views: [UInt32: (spec: ViewSpec, titles: [Int])] = [:]
    private var nextViewID: UInt32 = 1
    private let failLoad: String?
    private var generation: UInt32 = 1

    private(set) var fetchCalls: [(viewID: UInt32, offset: UInt32, len: UInt32)] = []
    private(set) var openedSpecs: [ViewSpec] = []
    private(set) var treeCalls = 0

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
            trackCount: UInt32(trackCount), playlistCount: 2, readOnly: true, dbVersion: nil, loadMs: 1)
    }

    func playlistTree() async throws -> [TreeNode] {
        treeCalls += 1
        return nodes
    }

    func openView(_ spec: ViewSpec) async throws -> ViewHandle {
        openedSpecs.append(spec)
        var order = Array(0..<trackCount)
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

    func fetchRows(viewID: UInt32, offset: UInt32, len: UInt32) async throws -> [Row] {
        fetchCalls.append((viewID, offset, len))
        guard let view = views[viewID] else {
            throw FfiError.NotFound(message: "view \(viewID) is gone", detail: nil)
        }
        let start = min(Int(offset), view.titles.count)
        let end = min(start + Int(len), view.titles.count)
        return (start..<end).map { Self.row(track: view.titles[$0], position: $0 + 1) }
    }

    static func title(_ n: Int) -> String { String(format: "Track %03d", n) }

    static func row(track n: Int, position: Int) -> Row {
        Row(
            id: String(n + 1), trackNo: UInt32(position), title: title(n), artist: "Artist \(n % 7)",
            album: "Album", genre: "House", label: "", comment: "", bpmX100: 12_000 + UInt32(n),
            key: "8A", durationSec: 200, rating: UInt8(n % 6), analysed: 1, dateAdded: "2026-01-01",
            releaseDate: "", hotCues: [], memoryCues: [], artworkHue: 0, hasArtwork: false, fileName: "")
    }
}
