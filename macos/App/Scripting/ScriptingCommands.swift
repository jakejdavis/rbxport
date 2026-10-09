import AppKit
import Foundation

// The six commands of `rbxport.sdef` and the application's keys. Commands that need the library
// to answer after a wait suspend through `Deferred`; the rest finish inside the call.

enum ScriptingCommands {
    // MARK: Failing

    @MainActor
    private static func fail(_ error: ScriptError) { failCommand(error) }

    // MARK: play, pause

    /// PLAY or pause on the deck the command names, deck 1 when it names none.
    @MainActor
    static func transport(_ command: NSScriptCommand, play: Bool) {
        let named = command.directParameter != nil
        let deck = command.directObjects.compactMap { $0 as? RbxDeck }.first?.index
        let index: Int
        switch (named, deck) {
        case (false, _): index = 1
        case (true, let deck?): index = deck
        case (true, nil): return fail(.noSuchObject("There is no such deck: deck 1 or deck 2."))
        }
        _ = scripted { host -> Bool? in
            try host.setPlaying(deck: index, play)
            return true
        }
    }

    // MARK: load

    @MainActor
    static func load(_ command: NSScriptCommand) {
        guard let track = command.directObjects.compactMap({ $0 as? RbxTrack }).first else {
            return fail(.noSuchObject("Say which track to load: `load track 1 into deck 1`."))
        }
        let into = command.argument("into")
        if command.given("into"), into == nil { return fail(.noSuchObject("There is no such deck or player.")) }
        let id = track.id
        if let player = into as? RbxLinkPlayer {
            let number = player.number
            return Deferred.run {
                guard let host = ScriptHost.current else { throw ScriptError.notReady }
                try await host.loadOnLinkPlayer(track: id, player: number)
                return .missing
            }
        }
        let deck = (into as? RbxDeck)?.index ?? 1
        Deferred.run {
            guard let host = ScriptHost.current else { throw ScriptError.notReady }
            try await host.load(track: id, onDeck: deck)
            return .missing
        }
    }

    // MARK: add, remove

    @MainActor
    static func add(_ command: NSScriptCommand) {
        guard let (playlist, tracks) = tracksAndPlaylist(command, key: "to") else { return }
        Deferred.run {
            guard let host = ScriptHost.current else { throw ScriptError.notReady }
            try await host.addTracks(tracks, to: playlist)
            return .missing
        }
    }

    @MainActor
    static func remove(_ command: NSScriptCommand) {
        guard let (playlist, tracks) = tracksAndPlaylist(command, key: "from") else { return }
        Deferred.run {
            guard let host = ScriptHost.current else { throw ScriptError.notReady }
            try await host.removeTracks(tracks, from: playlist)
            return .missing
        }
    }

    /// The tracks `add` or `remove` names, and the regular playlist they go on or come off; fails
    /// the command and returns nil when either is wrong.
    @MainActor
    private static func tracksAndPlaylist(_ command: NSScriptCommand, key: String) -> (String, [String])? {
        let tracks = command.directObjects.compactMap { ($0 as? RbxTrack)?.id }
        guard !tracks.isEmpty else {
            fail(.missingParameter("Say which tracks."))
            return nil
        }
        guard let playlist = (command.argument(key) as? RbxPlaylist)?.id, !playlist.isEmpty else {
            fail(.noSuchObject("There is no such playlist: `\(key) playlist \"...\"`."))
            return nil
        }
        let ok: Bool? = scripted { host in
            try host.requireRegularPlaylist(playlist)
            return true
        }
        return ok == nil ? nil : (playlist, tracks)
    }

    // MARK: export

    @MainActor
    static func export(_ command: NSScriptCommand) {
        guard let playlist = (command.directObjects.compactMap { $0 as? RbxPlaylist }.first)?.id else {
            return fail(.missingParameter("Say which playlist to export."))
        }
        guard let target = command.argument("to") else {
            return fail(.noSuchObject("Say which device: `to device \"...\"`."))
        }
        guard let device = target as? RbxDevice else {
            return fail(.wrongType("A playlist is exported to a device."))
        }
        let path = device.path
        Deferred.run {
            guard let host = ScriptHost.current else { throw ScriptError.notReady }
            return .text(try await host.export(playlist: playlist, devicePath: path))
        }
    }

    // MARK: make, move

    /// A playlist going into a folder, or to the top for `root`: one `make` built, or an existing
    /// one `move` is moving. Cocoa's `move` takes the object out of its old container and inserts
    /// it into the new one. For a playlist that would be a delete and an empty new one, so the
    /// removal does nothing while a move runs and the insert moves the playlist instead.
    @MainActor
    static func insertPlaylist(_ value: Any, parent: String, index: Int?, host: ScriptHost) throws {
        guard let playlist = value as? RbxPlaylist else { throw ScriptError.failed("Only playlists and folders go there.") }
        if !playlist.id.isEmpty {
            guard NSScriptCommand.current() is NSMoveCommand else {
                throw ScriptError.failed("That playlist is already in the library.")
            }
            try host.movePlaylist(playlist.id, into: parent, at: index)
            return
        }
        // `make` answers with the object it built, which now names the playlist it was written as.
        playlist.id = try host.createPlaylist(
            name: playlist.pendingName, kind: playlist.pendingKind, parent: parent, at: index)
    }
}

// MARK: - The application

/// The dictionary's application keys, added to `NSApplication` (the object is AppKit's, not ours).
/// Reads answer from the backend; inserts and removes are refused where the library does not allow
/// them.
extension NSApplication {
    @objc var rbxTracks: NSArray {
        let ids: [String]? = scripted { try $0.trackIDs() }
        return (ids ?? []).map { RbxTrack(id: $0) } as NSArray
    }

    @objc(valueInRbxTracksWithUniqueID:) func valueInRbxTracks(withUniqueID id: Any) -> Any? {
        guard let id = ScriptingValues.id(id) else { return nil }
        let found: Bool? = scripted { try $0.hasTrack(id) ? true : nil }
        return found == nil ? nil : RbxTrack(id: id)
    }

    @objc(insertInRbxTracks:) func insertInRbxTracks(_ value: Any) {
        failCommand(.failed("Tracks come into the collection by importing files in the window."))
    }

    @objc(insertObject:inRbxTracksAtIndex:) func insertObject(_ value: Any, inRbxTracksAt index: Int) {
        insertInRbxTracks(value)
    }

    @objc(removeObjectFromRbxTracksAtIndex:) func removeObjectFromRbxTracks(at index: Int) {
        failCommand(
            .failed(
                "A track cannot be removed from the collection by a script. Delete it from a playlist to take it off that playlist."
            ))
    }

    @objc var rbxPlaylists: NSArray {
        let ids: [String]? = scripted { try $0.allPlaylistIDs() }
        return (ids ?? []).map { RbxPlaylist(id: $0) } as NSArray
    }

    @objc(valueInRbxPlaylistsWithUniqueID:) func valueInRbxPlaylists(withUniqueID id: Any) -> Any? {
        guard let id = ScriptingValues.id(id) else { return nil }
        let found: Bool? = scripted { try $0.playlist(id) != nil ? true : nil }
        return found == nil ? nil : RbxPlaylist(id: id)
    }

    @objc(insertInRbxPlaylists:) func insertInRbxPlaylists(_ value: Any) {
        _ = scripted { host -> Bool? in
            try ScriptingCommands.insertPlaylist(value, parent: "root", index: nil, host: host)
            return true
        }
    }

    /// The application's playlists are every playlist at any depth, so an index into them says
    /// nothing about where at the top one goes.
    @objc(insertObject:inRbxPlaylistsAtIndex:) func insertObject(_ value: Any, inRbxPlaylistsAt index: Int) {
        insertInRbxPlaylists(value)
    }

    @objc(removeObjectFromRbxPlaylistsAtIndex:) func removeObjectFromRbxPlaylists(at index: Int) {
        // A move's removal; the insert that follows moves it.
        if NSScriptCommand.current() is NSMoveCommand { return }
        _ = scripted { host -> Bool? in
            let ids = try host.allPlaylistIDs()
            guard ids.indices.contains(index) else { throw ScriptError.noSuchObject("There is no such playlist.") }
            try host.deletePlaylist(ids[index])
            return true
        }
    }

    @objc var rbxDecks: NSArray { [RbxDeck(index: 1), RbxDeck(index: 2)] as NSArray }

    @objc var rbxDevices: NSArray {
        let devices: [Device]? = scripted { $0.devices }
        return (devices ?? []).map { RbxDevice($0) } as NSArray
    }

    @objc var rbxLinkPlayers: NSArray {
        let peers: [LinkPeer]? = scripted { $0.linkPlayers }
        return (peers ?? []).map { RbxLinkPlayer($0) } as NSArray
    }

    @objc(valueInRbxLinkPlayersWithUniqueID:) func valueInRbxLinkPlayers(withUniqueID id: Any) -> Any? {
        guard let wanted = ScriptingValues.id(id).flatMap(UInt8.init) else { return nil }
        let peers: [LinkPeer]? = scripted { $0.linkPlayers }
        return peers?.first { $0.number == wanted }.map { RbxLinkPlayer($0) }
    }

    @objc var rbxSettings: NSArray {
        let names: [String]? = scripted { $0.settingNames }
        return (names ?? []).map { RbxSetting(name: $0) } as NSArray
    }

    @objc var rbxLinkExport: Bool {
        get { scripted { $0.linkExport } ?? false }
        set {
            Deferred.run {
                guard let host = ScriptHost.current else { throw ScriptError.notReady }
                try await host.setLinkExport(newValue)
                return .missing
            }
        }
    }

    @objc var rbxRekordboxRunning: Bool {
        scripted { $0.rekordboxRunning() } ?? false
    }
}

// MARK: - Command classes

// One NSScriptCommand subclass per command in the dictionary. Cocoa calls
// `performDefaultImplementation` when no object named in the command handles it itself (a command
// with no direct parameter, or one whose receiver is not a scripting class).

@objc(RbxPlayCommand)
final class RbxPlayCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        nonisolated(unsafe) let command = self
        onMain { Once.run(command) { ScriptingCommands.transport(command, play: true) } }
        return nil
    }
}

@objc(RbxPauseCommand)
final class RbxPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        nonisolated(unsafe) let command = self
        onMain { Once.run(command) { ScriptingCommands.transport(command, play: false) } }
        return nil
    }
}

@objc(RbxLoadCommand)
final class RbxLoadCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        nonisolated(unsafe) let command = self
        onMain { Once.run(command) { ScriptingCommands.load(command) } }
        return nil
    }
}

@objc(RbxAddCommand)
final class RbxAddCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        nonisolated(unsafe) let command = self
        onMain { Once.run(command) { ScriptingCommands.add(command) } }
        return nil
    }
}

@objc(RbxRemoveCommand)
final class RbxRemoveCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        nonisolated(unsafe) let command = self
        onMain { Once.run(command) { ScriptingCommands.remove(command) } }
        return nil
    }
}

@objc(RbxExportCommand)
final class RbxExportCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        nonisolated(unsafe) let command = self
        onMain { Once.run(command) { ScriptingCommands.export(command) } }
        return nil
    }
}
