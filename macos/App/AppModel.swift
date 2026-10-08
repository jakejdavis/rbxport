import Foundation
import Observation

/// One sidebar row, rebuilt from the flat depth-ordered list.
struct TreeItem: Identifiable, Hashable, Sendable {
    let id: Int  // position in the flat list: ids from different tables may collide
    let node: TreeNode
    var children: [TreeItem]?

    static func == (a: TreeItem, b: TreeItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var symbol: String {
        switch node.kind {
        case .allTracks: "music.note.list"
        case .collection: "square.stack"
        case .histories: "clock"
        case .folder: "folder"
        case .playlist: "music.note"
        case .smartPlaylist: "gearshape"
        case .historyFolder: "calendar"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// The track source this node opens, or nil for a heading.
    var source: TrackSource? {
        switch node.kind {
        case .allTracks, .collection: .collection
        case .histories: nil
        case .folder: .playlistFolder(id: node.id)
        case .playlist, .smartPlaylist: .playlist(id: node.id)
        case .historyFolder, .history: .history(id: node.id)
        }
    }

    static func hierarchy(from flat: [TreeNode]) -> [TreeItem] {
        // Build bottom-up with a stack of (depth, index) so children nest.
        struct Pending { var item: TreeItem; var depth: UInt32 }
        var roots: [TreeItem] = []
        var stack: [Pending] = []
        func close(downTo depth: UInt32) {
            while let top = stack.last, top.depth >= depth {
                stack.removeLast()
                if let parent = stack.last {
                    stack[stack.count - 1].item.children = (parent.item.children ?? []) + [top.item]
                } else {
                    roots.append(top.item)
                }
            }
        }
        for (index, node) in flat.enumerated() {
            close(downTo: node.depth)
            stack.append(Pending(item: TreeItem(id: index, node: node, children: nil), depth: node.depth))
        }
        close(downTo: 0)
        return roots
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

    private(set) var phase: Phase = .loading
    private(set) var summary: LibrarySummary?
    private(set) var tree: [TreeItem] = []
    private(set) var opened: OpenedView?
    private(set) var viewError: String?

    var selection: Int? {
        didSet { if selection != oldValue { reopen() } }
    }
    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    private(set) var sortKey: SortKey = .trackNo
    private(set) var descending = false

    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var started = false

    init(backend: any BackendProtocol) {
        self.backend = backend
    }

    /// Starts listening for library events, then loads the library.
    func start() {
        guard !started else { return }
        started = true
        phase = .loading
        let backend = backend
        eventTask = Task { [weak self] in
            for await event in backend.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        // Loading decrypts and indexes the whole library: the backend runs it off the main actor.
        loadTask = Task { _ = await backend.loadLibrary() }
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
            await refresh(selectFirst: false)
        case .libraryProblem(let problem):
            switch problem {
            case .failed(let message): phase = .failed(message)
            case .missing(let masterDb): phase = .failed("No rekordbox library found at \(masterDb).")
            }
        case .tagListChanged, .editHistoryChanged:
            break
        }
    }

    private func refresh(selectFirst: Bool) async {
        do {
            async let loadedSummary = backend.summary()
            async let loadedTree = backend.playlistTree()
            let (newSummary, flat) = try await (loadedSummary, loadedTree)
            let keptNodeID = item(withID: selection)?.node.id
            summary = newSummary
            tree = TreeItem.hierarchy(from: flat)
            phase = .ready
            let kept = keptNodeID.flatMap { id in flat.firstIndex { $0.id == id } }
            let newSelection = kept ?? (selectFirst || selection != nil ? 0 : nil)
            if newSelection == selection {
                reopen()
            } else {
                selection = newSelection  // reopens
            }
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

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            reopen()
        }
    }

    private func item(withID id: Int?) -> TreeItem? {
        func find(_ items: [TreeItem]) -> TreeItem? {
            for item in items {
                if item.id == id { return item }
                if let hit = find(item.children ?? []) { return hit }
            }
            return nil
        }
        return find(tree)
    }

    /// Reopens the selected node as a view with the current sort and query.
    func reopen() {
        guard let source = item(withID: selection)?.source else { return }
        generation += 1
        let mine = generation
        let spec = ViewSpec(source: source, sort: sortKey, descending: descending, query: query)
        let backend = backend
        Task {
            do {
                let handle = try await backend.openView(spec)
                guard mine == generation else { return }  // a newer request superseded this one
                viewError = nil
                opened = OpenedView(handle: handle, generation: mine)
            } catch {
                guard mine == generation else { return }
                viewError = describe(error)
            }
        }
    }
}
