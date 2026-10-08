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

/// What the table needs to show one opened view.
struct OpenedView: Equatable, Sendable {
    let handle: ViewHandle
    let generation: Int
}

@MainActor @Observable
final class AppModel {
    enum Phase {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var library: LibraryHandle?
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
    private(set) var sortKey = "trackNo"
    private(set) var descending = false

    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        phase = .loading
        Task {
            do {
                // Opening decrypts and indexes the whole library: off the main actor.
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let handle = try LibraryHandle.openInstalled()
                    return (handle, handle.summary(), handle.playlistTree())
                }.value
                library = loaded.0
                summary = loaded.1
                tree = TreeItem.hierarchy(from: loaded.2)
                phase = .ready
                selection = 0
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    func sort(by key: String, descending: Bool) {
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

    private func reopen() {
        guard let library else { return }
        guard let source = item(withID: selection)?.source else { return }
        generation += 1
        let mine = generation
        let spec = ViewSpec(source: source, sort: sortKey, descending: descending, query: query)
        Task {
            do {
                let handle = try await Task.detached(priority: .userInitiated) {
                    try library.openView(spec: spec)
                }.value
                guard mine == generation else { return }  // a newer request superseded this one
                viewError = nil
                opened = OpenedView(handle: handle, generation: mine)
            } catch {
                guard mine == generation else { return }
                viewError = Self.describe(error)
            }
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? FfiError {
            switch e {
            case .ReadOnly(let m), .NotFound(let m), .Malformed(let m), .Internal(let m): return m
            }
        }
        return String(describing: error)
    }
}
