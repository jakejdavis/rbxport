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
