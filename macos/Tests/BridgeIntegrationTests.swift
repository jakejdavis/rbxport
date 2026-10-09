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
            ViewSpec(source: .collection, sort: .title, descending: true, query: "", searchField: .all,
                filter: TrackFilter(bpm: nil, keys: nil, ratings: nil, colors: nil)))
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

    @Test func filtersExplorerAndExportCrossTheBridge() async throws {
        let dir = fixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(fixtureDir: dir)
        _ = await backend.loadLibrary()
        let none = TrackFilter(bpm: nil, keys: nil, ratings: nil, colors: nil)
        let all = ViewSpec(
            source: .collection, sort: .title, descending: false, query: "", searchField: .all, filter: none)

        let values = try await backend.filterValues(all)
        #expect(values.bpms == [CountedBpm(value: 128, count: 40)])

        // A rating filter travels as bytes; the fixture's tracks are all unrated.
        var rated = all
        rated.filter = FilterState(rating: FilterColumn(enabled: true, picked: [0])).wire()
        #expect(try await backend.openView(rated).len == 40)
        rated.filter = FilterState(rating: FilterColumn(enabled: true, picked: [4, 5])).wire()
        #expect(try await backend.openView(rated).len == 0)

        // A folder view lists loose files with file: ids.
        let music = dir.appendingPathComponent("music", isDirectory: true)
        try FileManager.default.createDirectory(at: music.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: music.appendingPathComponent("loose.mp3"))
        let children = try await backend.explorerChildren(path: music.path)
        #expect(children.names == ["sub"])
        let folder = try await backend.openView(
            ViewSpec(
                source: .folder(path: music.path), sort: .fileName, descending: false, query: "", searchField: .all,
                filter: none))
        #expect(folder.len == 1)
        let rows = try await backend.fetchRows(viewID: folder.viewId, offset: 0, len: 5, extraColumns: [])
        #expect(rows.first?.id.hasPrefix("file:") == true)
        #expect(try await backend.trackPath(id: rows[0].id).hasSuffix("loose.mp3"))

        // Export writes the file the user chose.
        let tree = try await backend.playlistTree()
        let playlist = try #require(tree.first { $0.kind == .playlist })
        let out = dir.appendingPathComponent("out.m3u8")
        let count = try await backend.exportPlaylistFile(playlistID: playlist.id, path: out.path, format: .m3u8)
        #expect(count == 5)
        #expect(try String(contentsOf: out, encoding: .utf8).hasPrefix("#EXTM3U"))
    }
}
