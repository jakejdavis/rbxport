import Foundation
import Testing

@testable import rbxport

/// The real Rust core over a generated fixture library (never the installed one).
struct BridgeIntegrationTests {
    private func fixtureDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rbxport-fixture-\(UUID().uuidString)")
    }

    @Test func loadsAFixtureAndPagesRows() async throws {
        let dir = fixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(fixtureDir: dir)

        #expect(await backend.loadLibrary() == .ready)
        var iterator = backend.events.makeAsyncIterator()
        #expect(await iterator.next() == .libraryReady)

        #expect(try await backend.summary().trackCount == 40)
        let tree = try await backend.playlistTree()
        #expect(tree.first?.kind == .allTracks)

        let view = try await backend.openView(
            ViewSpec(source: .collection, sort: .title, descending: true, query: "", searchField: .all))
        #expect(view.len == 40)
        let rows = try await backend.fetchRows(viewID: view.viewId, offset: 0, len: 5, extraColumns: [])
        #expect(rows.first?.title == "Track 039")
        #expect(rows.count == 5)
    }

    @Test func errorsKeepTheirKind() async throws {
        let dir = fixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(fixtureDir: dir)
        _ = await backend.loadLibrary()
        await #expect(throws: FfiError.self) {
            _ = try await backend.fetchRows(viewID: 9999, offset: 0, len: 1, extraColumns: [])
        }
    }
}
