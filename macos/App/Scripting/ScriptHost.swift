import AppKit
import Foundation

/// What AppleScript can reach: the library through the `Backend`, the decks, LINK, the devices and
/// the preferences through `AppModel`. The Cocoa Scripting objects (`ScriptingObjects.swift`) are
/// thin; every decision lives here so tests can drive it against a `MockBackend`.
///
/// Cocoa Scripting calls us on the main thread and wants an answer before it returns, so reads and
/// KVC setters block the main thread on the backend (which never waits for the main thread).
/// Commands that take long (add, remove, load, export, LINK) suspend instead, in `ScriptingCommands`.
@MainActor
final class ScriptHost {
    /// The running app's host; nil until the window's model exists.
    static var current: ScriptHost?

    let model: AppModel
    /// Whether rekordbox is running. Replaced in tests.
    var rekordboxRunning: () -> Bool = { ScriptHost.detectRekordbox() }
    /// How long a load waits for the deck to take the track.
    var loadTimeout: Duration = .seconds(15)

    init(model: AppModel) { self.model = model }

    static func install(model: AppModel) {
        current = ScriptHost(model: model)
    }

    var backend: any BackendProtocol { model.backend }

    // MARK: - Blocking bridge

    /// Runs backend work and waits for it. Main-thread only: nothing the work does may need the
    /// main actor.
    func blocking<T: Sendable>(_ work: @escaping @Sendable (any BackendProtocol) async throws -> T) throws -> T {
        let backend = backend
        let box = ResultBox<T>()
        Task.detached {
            do { box.finish(.success(try await work(backend))) } catch { box.finish(.failure(error)) }
        }
        box.wait()
        do { return try box.result.get() } catch { throw ScriptError(error) }
    }

    private final class ResultBox<T: Sendable>: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var value: Result<T, Error>?
        var result: Result<T, Error> { value! }
        func finish(_ result: Result<T, Error>) {
            value = result
            semaphore.signal()
        }
        func wait() { semaphore.wait() }
    }

    // MARK: - Reads (cached for one pass of the run loop)

    private struct Cache {
        var ids: [String]?
        var index: [String: Int] = [:]
        var viewID: UInt32?
        var details: [String: TrackDetails] = [:]
        var rows: [String: Row] = [:]
        var playlists: [PlaylistInfo]?
        var scheduled = false
    }
    private var cache = Cache()

    /// Forgets what was read: the library changed, or a script just changed it.
    func invalidate() { cache = Cache() }

    /// A script reads many properties in one pass, so the lists are kept until the run loop turns.
    private func cached<T>(_ path: WritableKeyPath<Cache, T?>, _ make: () throws -> T) rethrows -> T {
        if let hit = cache[keyPath: path] { return hit }
        let value = try make()
        cache[keyPath: path] = value
        if !cache.scheduled {
            cache.scheduled = true
            DispatchQueue.main.async { MainActor.assumeIsolated { self.invalidate() } }
        }
        return value
    }

    /// Every track id, in the collection's own order.
    func trackIDs() throws -> [String] {
        try cached(\.ids) {
            let spec = ViewSpec(
                source: .collection, sort: .trackNo, descending: false, query: "", searchField: .all,
                filter: TrackFilter(bpm: nil, keys: nil, ratings: nil, colors: nil))
            let (handle, ids) = try blocking { backend -> (ViewHandle, [String]) in
                let handle = try await backend.openView(spec)
                let ids = handle.len == 0 ? [] : try await backend.viewIDsInRange(viewID: handle.viewId, from: 0, to: handle.len - 1)
                return (handle, ids)
            }
            cache.viewID = handle.viewId
            cache.index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            return ids
        }
    }

    func hasTrack(_ id: String) throws -> Bool {
        _ = try trackIDs()
        return cache.index[id] != nil
    }

    private func details(_ id: String) throws -> TrackDetails? {
        if let hit = cache.details[id] { return hit }
        guard try hasTrack(id) else { return nil }
        do {
            let found = try blocking { try await $0.trackDetails(id: id) }
            cache.details[id] = found
            return found
        } catch let error as ScriptError where error.code == ScriptError.noSuchObjectCode {
            return nil
        }
    }

    /// The table row of a track, found by its place in the collection.
    func row(of id: String) throws -> Row? {
        if let hit = cache.rows[id] { return hit }
        _ = try trackIDs()
        guard let at = cache.index[id], let viewID = cache.viewID else { return nil }
        let rows = try blocking { try await $0.fetchRows(viewID: viewID, offset: UInt32(at), len: 1, extraColumns: []) }
        guard let found = rows.first, found.id == id else { return nil }
        cache.rows[id] = found
        return found
    }

    /// One property of one track; nil when the track is not in the library.
    func trackValue(_ id: String, _ key: TrackKey) throws -> ScriptValue? {
        if key == .id { return try hasTrack(id) ? .text(id) : nil }
        guard let details = try details(id) else { return nil }
        return ScriptMapping.trackValue(details: details, row: key.needsRow ? try row(of: id) : nil, key: key)
    }

    // MARK: Playlists

    func playlists() throws -> [PlaylistInfo] {
        try cached(\.playlists) {
            ScriptPlaylists.parse(try blocking { try await $0.playlistTree() })
        }
    }

    func playlist(_ id: String) throws -> PlaylistInfo? { try playlists().first { $0.id == id } }

    /// Every playlist and folder at any depth, in tree order.
    func allPlaylistIDs() throws -> [String] { try playlists().map(\.id) }

    /// A folder's playlists one level down, or the top level's for nil.
    func childIDs(of parent: String?) throws -> [String] {
        ScriptPlaylists.children(of: parent, in: try playlists()).map(\.id)
    }

    /// A playlist's tracks in its order; an intelligent playlist's are what its rule admits now. A
    /// folder has none.
    func playlistTrackIDs(_ id: String) throws -> [String] {
        guard let info = try playlist(id), !info.isFolder else { return [] }
        let spec = ViewSpec(
            source: .playlist(id: id), sort: .trackNo, descending: false, query: "", searchField: .all,
            filter: TrackFilter(bpm: nil, keys: nil, ratings: nil, colors: nil))
        return try blocking { backend in
            let handle = try await backend.openView(spec)
            return handle.len == 0 ? [] : try await backend.viewIDsInRange(viewID: handle.viewId, from: 0, to: handle.len - 1)
        }
    }

    // MARK: - Writes the gate decides

    /// A KVC setter's change, waited for here. The core's write gate refuses under Library
    /// Protection and while rekordbox runs; the refusal comes back as "not modifiable".
    func setTrack(_ id: String, _ key: TrackKey, to value: ScriptValue) throws {
        let edit = try ScriptMapping.trackEdit(key, value)
        guard try hasTrack(id) else { throw ScriptError.noSuchObject("That track is no longer in the library.") }
        defer { invalidate() }
        _ = try blocking { backend -> Bool in
            switch edit {
            case .rating(let stars): _ = try await backend.setTrackRating(ids: [id], stars: stars)
            case .comment(let text): _ = try await backend.setTrackComment(ids: [id], comment: text)
            case .color(let color): _ = try await backend.setTrackColor(ids: [id], color: color)
            case .field(let field, let text): _ = try await backend.setTrackField(ids: [id], field: field, value: text)
            }
            return true
        }
    }

    func renamePlaylist(_ id: String, to name: String) throws {
        defer { invalidate() }
        _ = try blocking { try await $0.renamePlaylist(id: id, name: name) }
    }

    func deletePlaylist(_ id: String) throws {
        defer { invalidate() }
        _ = try blocking { try await $0.deletePlaylist(id: id) }
    }

    func movePlaylist(_ id: String, into parent: String, at index: Int?) throws {
        defer { invalidate() }
        _ = try blocking { try await $0.movePlaylist(id: id, parent: parent, index: index.map { UInt32(max(0, $0)) }) }
    }

    /// Makes a regular playlist or a folder in `parent` (`root` for the top), at `index` if given.
    func createPlaylist(name: String?, kind: UInt32, parent: String, at index: Int?) throws -> String {
        guard kind != ScriptCodes.kindSmart else {
            throw ScriptError.failed("A smart playlist's rule is made in the window. Make a regular playlist or a folder.")
        }
        defer { invalidate() }
        let folder = kind == ScriptCodes.kindFolder
        // rekordbox's own default names, as the window's menu uses them.
        let title = name ?? (folder ? "New folder" : "New playlist")
        let id = try blocking { backend in
            folder
                ? try await backend.createFolder(name: title, parent: parent)
                : try await backend.createPlaylist(name: title, parent: parent)
        }
        if let index { try movePlaylist(id, into: parent, at: index) }
        return id
    }

    /// Where `add` and `remove` put tracks: a regular playlist.
    func requireRegularPlaylist(_ id: String) throws {
        guard try playlist(id)?.kind == ScriptCodes.kindPlaylist else {
            throw ScriptError.failed("Tracks can only be added to or removed from a regular playlist.")
        }
    }

    func addTracks(_ ids: [String], to playlist: String) async throws {
        defer { invalidate() }
        do { _ = try await backend.addTracksToPlaylist(playlistID: playlist, trackIDs: ids) } catch { throw ScriptError(error) }
    }

    func removeTracks(_ ids: [String], from playlist: String) async throws {
        defer { invalidate() }
        do { _ = try await backend.removeTracksFromPlaylist(playlistID: playlist, trackIDs: ids) } catch { throw ScriptError(error) }
    }

    func removeTrackBlocking(_ id: String, from playlist: String) throws {
        defer { invalidate() }
        _ = try blocking { try await $0.removeTracksFromPlaylist(playlistID: playlist, trackIDs: [id]) }
    }

    // MARK: - Decks

    var decks: [DeckModel] { [model.player.deckA, model.player.deckB] }

    func deck(_ index: Int) -> DeckModel { index == 2 ? model.player.deckB : model.player.deckA }

    static func deckName(_ index: Int) -> Deck { index == 2 ? .b : .a }

    struct DeckReading: Equatable {
        var index: Int
        var currentTrack: String?
        var playing: Bool
        var position: Double
        var duration: Double
        var tempo: Double
    }

    func reading(ofDeck index: Int) -> DeckReading {
        let deck = deck(index)
        let loaded = deck.isLoaded
        return DeckReading(
            index: index, currentTrack: deck.phase == .empty ? nil : deck.track?.id, playing: deck.isPlaying,
            position: loaded ? deck.position(at: deck.now()) : 0, duration: loaded ? deck.durationSeconds : 0,
            tempo: loaded ? (deck.tempo - 1) * 100 : 0)
    }

    /// PLAY or pause, when the deck is not already doing it. Refused on a deck with nothing loaded,
    /// which has no PLAY to press.
    func setPlaying(deck index: Int, _ wanted: Bool) throws {
        let deck = deck(index)
        guard deck.isLoaded else { throw ScriptError.failed("Deck \(index) has no track loaded.") }
        if deck.isPlaying != wanted { model.player.togglePlay(Self.deckName(index)) }
    }

    /// Loads a track onto a deck and waits until it can play, or says why it cannot.
    func load(track id: String, onDeck index: Int) async throws {
        guard let row = try row(of: id) else { throw ScriptError.noSuchObject("That track is not in the collection.") }
        let player = model.player
        if index == 2, player.layout.deckCount < 2 {
            throw ScriptError.failed(
                "Deck 2 is not in this layout. Choose a layout with 2 players from the View menu.")
        }
        let which = Self.deckName(index)
        player.load(trackID: id, row: row, into: which)
        let deck = deck(index)
        let deadline = ContinuousClock.now + loadTimeout
        while true {
            if deck.track?.id == id {
                if case .failed(let message) = deck.phase { throw ScriptError.failed(message) }
                if deck.isLoaded { return }
            }
            if ContinuousClock.now >= deadline {
                throw ScriptError.failed("Deck \(index) did not finish loading the track.")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - LINK

    var linkExport: Bool { model.link.isOn }

    func setLinkExport(_ on: Bool) async throws {
        if on {
            await model.link.start()
            if !model.link.isOn { throw ScriptError.failed(model.link.problem ?? "LINK could not be turned on.") }
        } else {
            await model.link.stop()
        }
    }

    /// The players heard on the network; mixers and other rekordboxes cannot be loaded onto.
    var linkPlayers: [LinkPeer] { model.link.peers.filter { $0.kind == .player } }

    func loadOnLinkPlayer(track id: String, player number: UInt8) async throws {
        guard try hasTrack(id) else { throw ScriptError.noSuchObject("That track is not in the collection.") }
        do { try await backend.linkLoadTrack(playerNumber: number, trackID: id) } catch { throw ScriptError.failed(describe(error)) }
    }

    // MARK: - Devices and export

    var devices: [Device] { model.devices.devices }

    /// Writes a playlist to a device as the Sync Manager does, with the DJ System and USB export
    /// preferences, and says what was written.
    func export(playlist id: String, devicePath path: String) async throws -> String {
        guard let device = model.devices.device(path: path) else {
            throw ScriptError.noSuchObject("That device is no longer connected.")
        }
        guard !model.exportJobs.isActive(path: path) else {
            throw ScriptError.failed("An export to \(device.name) is already running.")
        }
        let options = model.exportPrefs.options()
        do {
            let report = try await backend.exportPlaylistToDevice(playlistID: id, destination: path, options: options)
            await model.deviceWritten(path)
            return ExportSummary.text(report, device: device.name)
        } catch {
            await model.deviceWritten(path)
            if let ffi = error as? FfiError, case .Cancelled = ffi { throw ScriptError.failed("Export stopped.") }
            throw ScriptError(error)
        }
    }

    // MARK: - Settings

    var settingNames: [String] { ScriptSettings.names }

    func settingValue(_ name: String) -> ScriptValue { ScriptSettings.value(of: name, in: model.prefs) }

    func setSetting(_ name: String, to value: ScriptValue) throws {
        try ScriptSettings.set(name, to: value, in: model.prefs)
        // The core's write gate follows Library Protection; make it follow now, not a moment later,
        // so the next line of the script sees it.
        if name == PrefKeys.protectLibrary {
            let protect = model.protectLibrary
            _ = try blocking { backend -> Bool in
                await backend.setProtectLibrary(protect)
                return true
            }
            invalidate()
        }
    }

    // MARK: - rekordbox

    static func detectRekordbox() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            let name = (app.executableURL?.lastPathComponent ?? app.localizedName ?? "").lowercased()
            return name == "rekordbox" || name == "rekordboxagent"
        }
    }
}
