import Testing

@testable import rbxport

@MainActor
struct RowPagerTests {
    private func opened(_ backend: MockBackend, query: String = "") async throws -> OpenedView {
        let handle = try await backend.openView(
            ViewSpec(source: .collection, sort: .trackNo, descending: false, query: query))
        return OpenedView(handle: handle, generation: 1)
    }

    @Test func aMissReturnsNilThenTheRowArrives() async throws {
        let backend = MockBackend(trackCount: 300)
        let pager = RowPager(backend: backend)
        var loaded: [Range<Int>] = []
        pager.onPageLoaded = { loaded.append($0) }
        pager.show(try await opened(backend))

        #expect(pager.rowCount == 300)
        #expect(pager.row(at: 5) == nil)
        await pager.settle()
        #expect(pager.row(at: 5)?.title == "Track 005")
        #expect(loaded == [0..<128])
    }

    @Test func rowsInOnePageShareOneFetch() async throws {
        let backend = MockBackend(trackCount: 300)
        let pager = RowPager(backend: backend)
        pager.show(try await opened(backend))
        for i in 0..<50 { _ = pager.row(at: i) }
        await pager.settle()
        for i in 0..<50 { #expect(pager.row(at: i) != nil) }
        #expect(await backend.fetchCalls.count == 1)
    }

    @Test func eachPageFetchesItsOwnWindow() async throws {
        let backend = MockBackend(trackCount: 300)
        let pager = RowPager(backend: backend)
        pager.show(try await opened(backend))
        _ = pager.row(at: 130)
        _ = pager.row(at: 299)
        await pager.settle()
        let calls = await backend.fetchCalls.map(\.offset).sorted()
        #expect(calls == [128, 256])
        #expect(pager.row(at: 299)?.title == "Track 299")
        #expect(pager.row(at: 300) == nil)
    }

    @Test func theOldestPageIsEvicted() async throws {
        let backend = MockBackend(trackCount: 600)
        let pager = RowPager(backend: backend, maxPages: 2)
        pager.show(try await opened(backend))
        for index in [0, 128, 256] {
            _ = pager.row(at: index)
            await pager.settle()
        }
        #expect(pager.cachedPageCount == 2)
        #expect(pager.row(at: 256) != nil)
        #expect(pager.row(at: 0) == nil)  // evicted: refetches
    }

    @Test func showingAnotherViewDropsTheCache() async throws {
        let backend = MockBackend(trackCount: 300)
        let pager = RowPager(backend: backend)
        pager.show(try await opened(backend))
        _ = pager.row(at: 0)
        await pager.settle()
        #expect(pager.cachedPageCount == 1)

        pager.show(try await opened(backend, query: "Track 29"))
        #expect(pager.cachedPageCount == 0)
        #expect(pager.rowCount == 10)
        #expect(pager.row(at: 0) == nil)
        await pager.settle()
        #expect(pager.row(at: 0)?.title == "Track 290")
    }
}
