import AppKit
import Foundation

// The classes `rbxport.sdef` names. Cocoa reads and writes a scripting object through key-value
// coding, so each overrides `value(forKey:)` and `setValue(_:forKey:)`, answers the dictionary's
// keys itself and passes anything else to `NSObject`. Every call arrives on the main thread.

// MARK: - Track

@objc(RbxTrack)
final class RbxTrack: NSObject {
    let id: String
    /// The playlist the track was reached through, if any.
    let playlist: String?

    init(id: String, playlist: String? = nil) {
        self.id = id
        self.playlist = playlist
        super.init()
    }

    override convenience init() { self.init(id: "") }

    override func value(forKey key: String) -> Any? {
        guard let which = TrackKey.parse(key) else { return super.value(forKey: key) }
        let id = id
        return onMain {
            let value = scripted { try $0.trackValue(id, which) }
            return value.flatMap { ScriptingValues.object($0) }
        }
    }

    override func setValue(_ value: Any?, forKey key: String) {
        guard let which = TrackKey.parse(key) else { return super.setValue(value, forKey: key) }
        var converted = ScriptingValues.value(value)
        // An enumerator arrives as its code, a plain number.
        if which == .color, case .int(let code) = converted {
            converted = UInt32(exactly: code).map(ScriptValue.enumerator) ?? .missing
        }
        let id = id
        let edited = converted
        _ = onMain { scripted { try $0.setTrack(id, which, to: edited) } }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        let id = id
        let playlist = playlist
        return onMain { RbxTrack.specifier(id: id, playlist: playlist) }
    }

    /// `track id "..."`, or `track id "..." of playlist id "..."` for one reached through a playlist.
    static func specifier(id: String, playlist: String?) -> NSScriptObjectSpecifier? {
        guard let playlist else { return ScriptingSpecifiers.uniqueID(key: "rbxTracks", id: id as NSString) }
        guard let description = ScriptingSpecifiers.description(of: RbxPlaylist.self),
            let container = RbxPlaylist(id: playlist).objectSpecifier
        else { return nil }
        return ScriptingSpecifiers.uniqueID(container: (description, container), key: "rbxTracks", id: id as NSString)
    }

    @objc(scriptLoad:) func scriptLoad(_ command: NSScriptCommand) -> Any? {
        nonisolated(unsafe) let command = command
        onMain { Once.run(command) { ScriptingCommands.load(command) } }
        return nil
    }

    @objc(scriptAdd:) func scriptAdd(_ command: NSScriptCommand) -> Any? {
        nonisolated(unsafe) let command = command
        onMain { Once.run(command) { ScriptingCommands.add(command) } }
        return nil
    }

    @objc(scriptRemove:) func scriptRemove(_ command: NSScriptCommand) -> Any? {
        nonisolated(unsafe) let command = command
        onMain { Once.run(command) { ScriptingCommands.remove(command) } }
        return nil
    }

    /// `duplicate track ...` builds a new track from this one's properties before anything is
    /// inserted; refused here, where it starts, rather than with Cocoa's own puzzling message after.
    override var scriptingProperties: [String: Any]? {
        get { super.scriptingProperties }
        set { applyScriptingProperties(newValue) }
    }

    private func applyScriptingProperties(_ properties: [String: Any]?) {
        if NSScriptCommand.current() is NSCloneCommand {
            return failCommand(.failed("A track cannot be duplicated. Use `add` to put it on a playlist."))
        }
        for (key, value) in properties ?? [:] { setValue(value, forKey: key) }
    }
}

// MARK: - Playlist

@objc(RbxPlaylist)
final class RbxPlaylist: NSObject {
    /// Empty for one `make` is still building, which has no id until it is written.
    var id: String
    /// What `make` gave it before it was written.
    var pendingName: String?
    var pendingKind: UInt32 = ScriptCodes.kindPlaylist

    override init() {
        id = ""
        super.init()
    }

    convenience init(id: String) {
        self.init()
        self.id = id
    }

    override func value(forKey key: String) -> Any? {
        let id = id
        let pendingName = pendingName
        let pendingKind = pendingKind
        let known = ["uniqueID", "name", "rbxKind", "rbxParent", "rbxTracks", "rbxPlaylists"]
        guard known.contains(key) else { return super.value(forKey: key) }
        return onMain {
            if id.isEmpty {
                switch key {
                case "uniqueID": return ScriptingValues.object(.text(""))
                case "name": return pendingName.flatMap { ScriptingValues.object(.text($0)) }
                case "rbxKind": return ScriptingValues.object(.enumerator(pendingKind))
                default: return NSArray()
                }
            }
            let value: ScriptValue? = scripted { host in
                switch key {
                case "uniqueID": return .text(id)
                case "name", "rbxKind", "rbxParent":
                    guard let info = try host.playlist(id) else { return .missing }
                    switch key {
                    case "name": return .text(info.name)
                    case "rbxKind": return .enumerator(info.kind)
                    default: return info.parent.map(ScriptValue.playlist) ?? .missing
                    }
                case "rbxTracks":
                    return .list(try host.playlistTrackIDs(id).map { .track(id: $0, playlist: id) })
                default:
                    return .list(try host.childIDs(of: id).map(ScriptValue.playlist))
                }
            }
            // An empty list is still a list: `every track of` an empty playlist is `{}`.
            guard let value else { return nil }
            return ScriptingValues.object(value)
        }
    }

    override func setValue(_ value: Any?, forKey key: String) {
        let converted = ScriptingValues.value(value)
        let id = id
        switch (key, converted) {
        case ("name", .text(let name)) where id.isEmpty: pendingName = name
        case ("name", .text(let name)): _ = onMain { scripted { try $0.renamePlaylist(id, to: name) } }
        case ("name", _): failCommand(.wrongType("A playlist's name is text."))
        case ("rbxKind", .int(let code)) where id.isEmpty:
            pendingKind = UInt32(exactly: code) ?? ScriptCodes.kindPlaylist
        case ("rbxKind", _): failCommand(.notModifiable("A playlist's kind is set when it is made."))
        default: super.setValue(value, forKey: key)
        }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard !id.isEmpty else { return nil }
        let id = id
        return onMain { ScriptingSpecifiers.uniqueID(key: "rbxPlaylists", id: id as NSString) }
    }

    /// `track id "..." of playlist ...` and `playlist id "..." of playlist ...`, whether the id was
    /// written as text or as a number.
    override func value(withUniqueID uniqueID: Any, inPropertyWithKey key: String) -> Any? {
        let parent = id
        let wanted = ScriptingValues.id(uniqueID)
        return onMain {
            guard let wanted else { return nil }
            let found: ScriptValue? = scripted { host in
                switch key {
                case "rbxTracks":
                    return try host.playlistTrackIDs(parent).contains(wanted) ? .track(id: wanted, playlist: parent) : nil
                case "rbxPlaylists":
                    return try host.childIDs(of: parent).contains(wanted) ? .playlist(wanted) : nil
                default: return nil
                }
            }
            return found.flatMap { ScriptingValues.object($0) }
        }
    }

    /// `make new playlist at playlist "Folder"`: the end of the folder.
    override func insertValue(_ value: Any, inPropertyWithKey key: String) {
        insert(value, key: key, index: nil)
    }

    override func insertValue(_ value: Any, at index: Int, inPropertyWithKey key: String) {
        insert(value, key: key, index: index)
    }

    private func insert(_ value: Any, key: String, index: Int?) {
        let id = id
        nonisolated(unsafe) let value = value
        guard key == "rbxPlaylists" else { return failCommand(.failed("Use `add` to put tracks on a playlist.")) }
        onMain {
            _ = scripted { host -> Bool? in
                guard try host.playlist(id)?.isFolder == true else {
                    throw ScriptError.failed("Playlists can only go inside a folder.")
                }
                try ScriptingCommands.insertPlaylist(value, parent: id, index: index, host: host)
                return true
            }
        }
    }

    /// `delete track 3 of playlist "..."` takes it out of the playlist; `delete playlist 2 of
    /// playlist "Folder"` deletes that playlist.
    override func removeValue(at index: Int, fromPropertyWithKey key: String) {
        // `move` takes the playlist out here and puts it in where it goes; the insert does the
        // whole move (see `ScriptingCommands.insertPlaylist`).
        if NSScriptCommand.current() is NSMoveCommand { return }
        let id = id
        onMain {
            _ = scripted { host -> Bool? in
                switch key {
                case "rbxTracks":
                    let tracks = try host.playlistTrackIDs(id)
                    guard tracks.indices.contains(index) else { throw ScriptError.noSuchObject("That track is not on the playlist.") }
                    try host.removeTrackBlocking(tracks[index], from: id)
                case "rbxPlaylists":
                    let children = try host.childIDs(of: id)
                    guard children.indices.contains(index) else { throw ScriptError.noSuchObject("That playlist is not in the folder.") }
                    try host.deletePlaylist(children[index])
                default: throw ScriptError.notModifiable("That cannot be deleted.")
                }
                return true
            }
        }
    }

    @objc(scriptExport:) func scriptExport(_ command: NSScriptCommand) -> Any? {
        nonisolated(unsafe) let command = command
        onMain { Once.run(command) { ScriptingCommands.export(command) } }
        return nil
    }

    /// As a track's: `duplicate` is refused where it starts.
    override var scriptingProperties: [String: Any]? {
        get { super.scriptingProperties }
        set { applyScriptingProperties(newValue) }
    }

    private func applyScriptingProperties(_ properties: [String: Any]?) {
        if NSScriptCommand.current() is NSCloneCommand {
            return failCommand(.failed("A playlist cannot be duplicated from a script."))
        }
        for (key, value) in properties ?? [:] { setValue(value, forKey: key) }
    }
}

// MARK: - Deck

@objc(RbxDeck)
final class RbxDeck: NSObject {
    /// 1 or 2: player A or player B.
    let index: Int

    init(index: Int) {
        self.index = index
        super.init()
    }

    override convenience init() { self.init(index: 1) }

    override func value(forKey key: String) -> Any? {
        let known = ["rbxIndex", "rbxCurrentTrack", "rbxPlaying", "rbxPosition", "rbxDuration", "rbxTempo"]
        guard known.contains(key) else { return super.value(forKey: key) }
        let index = index
        return onMain {
            guard let host = ScriptHost.current else { return nil }
            let reading = host.reading(ofDeck: index)
            let value: ScriptValue
            switch key {
            case "rbxIndex": value = .int(Int64(index))
            case "rbxCurrentTrack": value = reading.currentTrack.map { .track(id: $0, playlist: nil) } ?? .missing
            case "rbxPlaying": value = .bool(reading.playing)
            case "rbxPosition": value = .real(reading.position)
            case "rbxDuration": value = .real(reading.duration)
            default: value = .real(reading.tempo)
            }
            return ScriptingValues.object(value)
        }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        ScriptingSpecifiers.index(key: "rbxDecks", index - 1)
    }

    @objc(scriptPlay:) func scriptPlay(_ command: NSScriptCommand) -> Any? {
        nonisolated(unsafe) let command = command
        onMain { Once.run(command) { ScriptingCommands.transport(command, play: true) } }
        return nil
    }

    @objc(scriptPause:) func scriptPause(_ command: NSScriptCommand) -> Any? {
        nonisolated(unsafe) let command = command
        onMain { Once.run(command) { ScriptingCommands.transport(command, play: false) } }
        return nil
    }
}

// MARK: - Device

@objc(RbxDevice)
final class RbxDevice: NSObject {
    let name: String
    let path: String
    let removable: Bool
    let capacity: UInt64
    let free: UInt64

    init(name: String, path: String, removable: Bool, capacity: UInt64, free: UInt64) {
        self.name = name
        self.path = path
        self.removable = removable
        self.capacity = capacity
        self.free = free
        super.init()
    }

    override convenience init() { self.init(name: "", path: "", removable: false, capacity: 0, free: 0) }

    convenience init(_ device: Device) {
        self.init(
            name: device.name, path: device.path, removable: device.removable, capacity: device.totalBytes,
            free: device.freeBytes)
    }

    override func value(forKey key: String) -> Any? {
        let value: ScriptValue
        switch key {
        case "name": value = .text(name)
        case "rbxLocation": value = .file(path)
        case "rbxRemovable": value = .bool(removable)
        case "rbxCapacity": value = .real(Double(capacity))
        case "rbxFreeSpace": value = .real(Double(free))
        default: return super.value(forKey: key)
        }
        return onMain { ScriptingValues.object(value) }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        ScriptingSpecifiers.name(key: "rbxDevices", name)
    }
}

// MARK: - Link player

@objc(RbxLinkPlayer)
final class RbxLinkPlayer: NSObject {
    let number: UInt8
    let model: String
    let address: String

    init(number: UInt8, model: String, address: String) {
        self.number = number
        self.model = model
        self.address = address
        super.init()
    }

    override convenience init() { self.init(number: 0, model: "", address: "") }

    convenience init(_ peer: LinkPeer) { self.init(number: peer.number, model: peer.name, address: peer.address) }

    override func value(forKey key: String) -> Any? {
        let value: ScriptValue
        switch key {
        case "uniqueID": value = .int(Int64(number))
        case "name": value = .text(model)
        case "rbxAddress": value = .text(address)
        default: return super.value(forKey: key)
        }
        return onMain { ScriptingValues.object(value) }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        ScriptingSpecifiers.uniqueID(key: "rbxLinkPlayers", id: NSNumber(value: number))
    }
}

// MARK: - Setting

@objc(RbxSetting)
final class RbxSetting: NSObject {
    /// `pane.field`, as `ScriptSettings` names it.
    let name: String

    init(name: String) {
        self.name = name
        super.init()
    }

    override convenience init() { self.init(name: "") }

    override func value(forKey key: String) -> Any? {
        let name = name
        switch key {
        case "name": return name as NSString
        // Handed over as an Apple event value already: Cocoa fails a property typed `any` with a
        // number or a string in it (-10000), where it passes a descriptor straight through.
        case "rbxValue":
            return onMain {
                let value = ScriptHost.current?.settingValue(name) ?? .missing
                return ScriptingValues.descriptor(value)
            }
        default: return super.value(forKey: key)
        }
    }

    override func setValue(_ value: Any?, forKey key: String) {
        guard key == "rbxValue" else { return super.setValue(value, forKey: key) }
        let name = name
        let converted = ScriptingValues.value(value)
        _ = onMain { scripted { try $0.setSetting(name, to: converted) } }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        ScriptingSpecifiers.name(key: "rbxSettings", name)
    }
}
