import Foundation

/// What the table needs to show one opened view.
struct OpenedView: Equatable, Sendable {
    let handle: ViewHandle
    let generation: Int
    /// The optional fields the rows are fetched with (the shown extra columns, plus `.size`).
    var extraColumns: [ExtraColumn] = []
}

/// Lazily loads and caches pages of rows for the open view. The table asks for
/// rows by index; a miss returns nil and starts a page load, and `onPageLoaded`
/// fires when it lands.
@MainActor
final class RowPager {
    static let pageSize = 128
    /// Pages kept in memory; a view this size is far more than a screen needs.
    static let defaultMaxPages = 256

    private struct PageKey: Hashable { let viewID: UInt32; let page: Int }

    private let backend: any BackendProtocol
    private let maxPages: Int
    private var pages: [PageKey: [Row]] = [:]
    private var pageOrder: [PageKey] = []
    private var loading: [PageKey: Task<Void, Never>] = [:]
    private(set) var opened: OpenedView?

    /// Called with the row indexes a loaded page covers.
    var onPageLoaded: (Range<Int>) -> Void = { _ in }

    init(backend: any BackendProtocol, maxPages: Int = RowPager.defaultMaxPages) {
        self.backend = backend
        self.maxPages = maxPages
    }

    var cachedPageCount: Int { pages.count }
    var rowCount: Int { Int(opened?.handle.len ?? 0) }

    /// Switches to another view and forgets everything cached for the last one.
    func show(_ opened: OpenedView?) {
        self.opened = opened
        pages.removeAll(keepingCapacity: true)
        pageOrder.removeAll(keepingCapacity: true)
        for task in loading.values { task.cancel() }
        loading.removeAll()
    }

    /// The row at `index`, or nil while its page loads.
    func row(at index: Int) -> Row? {
        guard let opened, index >= 0, index < rowCount else { return nil }
        let key = PageKey(viewID: opened.handle.viewId, page: index / Self.pageSize)
        if let page = pages[key] {
            let i = index % Self.pageSize
            return i < page.count ? page[i] : nil
        }
        startLoading(key)
        return nil
    }

    /// The row at `index` if its page is already loaded. Never starts a load.
    func peek(at index: Int) -> Row? {
        guard let opened, index >= 0, index < rowCount else { return nil }
        let key = PageKey(viewID: opened.handle.viewId, page: index / Self.pageSize)
        guard let page = pages[key] else { return nil }
        let i = index % Self.pageSize
        return i < page.count ? page[i] : nil
    }

    /// The loaded rows of page `page` (`index / pageSize`), or nil while it is not loaded.
    func loadedPage(_ page: Int) -> [Row]? {
        guard let opened else { return nil }
        return pages[PageKey(viewID: opened.handle.viewId, page: page)]
    }

    /// Visits every loaded row with its index in the view.
    func forEachLoadedRow(_ body: (Int, Row) -> Void) {
        for (key, rows) in pages {
            let first = key.page * Self.pageSize
            for (offset, row) in rows.enumerated() { body(first + offset, row) }
        }
    }

    /// Whether a loaded page holds this track (so a change to it should refetch the rows).
    func containsLoadedRow(id: String) -> Bool {
        pages.values.contains { $0.contains { $0.id == id } }
    }

    /// Waits for every page load in flight.
    func settle() async {
        while let task = loading.values.first {
            await task.value
        }
    }

    private func startLoading(_ key: PageKey) {
        guard loading[key] == nil else { return }
        let backend = backend
        let offset = UInt32(key.page * Self.pageSize)
        let extra = opened?.extraColumns ?? []
        loading[key] = Task { [weak self] in
            let rows = try? await backend.fetchRows(
                viewID: key.viewID, offset: offset, len: UInt32(Self.pageSize), extraColumns: extra)
            guard let self else { return }
            self.finish(key, rows: rows)
        }
    }

    private func finish(_ key: PageKey, rows: [Row]?) {
        loading[key] = nil
        // Drop the page if the table has moved on to another view.
        guard let rows, key.viewID == opened?.handle.viewId else { return }
        pages[key] = rows
        pageOrder.append(key)
        if pageOrder.count > maxPages {
            pages.removeValue(forKey: pageOrder.removeFirst())
        }
        let first = key.page * Self.pageSize
        onPageLoaded(first..<(first + rows.count))
    }
}
