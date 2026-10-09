import Foundation

// What a script reads and sets, kept apart from Cocoa Scripting so every mapping can be tested
// without an Apple event. The Tauri build's `src-tauri/src/scripting/model.rs` is the reference;
// error numbers, messages and four-character codes match it and `rbxport.sdef`.

/// A value on its way to or from a script.
enum ScriptValue: Equatable, Sendable {
    /// `missing value`.
    case missing
    case bool(Bool)
    case int(Int64)
    case real(Double)
    case text(String)
    case list([ScriptValue])
    /// One of the dictionary's enumerators, by its four-character code.
    case enumerator(UInt32)
    case file(String)
    /// A track; inside a playlist when it was reached through one, so that deleting it takes it out
    /// of that playlist.
    case track(id: String, playlist: String?)
    case playlist(String)
}

/// A failure a script sees: an Apple event error number and a message.
struct ScriptError: Error, Equatable, Sendable {
    var code: Int
    var message: String

    static let failedCode = -10_000
    static let notModifiableCode = -10_003
    static let noSuchObjectCode = -1_728
    static let wrongTypeCode = -1_703
    static let missingParameterCode = -1_715

    static func failed(_ message: String) -> ScriptError { ScriptError(code: failedCode, message: message) }
    static func notModifiable(_ message: String) -> ScriptError { ScriptError(code: notModifiableCode, message: message) }
    static func noSuchObject(_ message: String) -> ScriptError { ScriptError(code: noSuchObjectCode, message: message) }
    static func wrongType(_ message: String) -> ScriptError { ScriptError(code: wrongTypeCode, message: message) }
    static func missingParameter(_ message: String) -> ScriptError { ScriptError(code: missingParameterCode, message: message) }

    static let notReady = ScriptError.failed("rbxport is still starting. Try again in a moment.")

    /// A backend error as a script sees it: a refusal at the write gate is "not modifiable", a
    /// missing object is "no such object", anything else a plain failure. The message is the core's.
    init(_ error: Error) {
        if let ffi = error as? FfiError {
            switch ffi {
            case .ReadOnly(let message, _): self = .notModifiable(message)
            case .NotFound(let message, _): self = .noSuchObject(message)
            case .Malformed(let message, _), .Cancelled(let message, _), .Internal(let message, _): self = .failed(message)
            }
        } else if let script = error as? ScriptError {
            self = script
        } else {
            self = .failed(describe(error))
        }
    }

    init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

/// A four-character code as the number Cocoa carries it in.
func fourCC(_ code: String) -> UInt32 {
    code.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
}

enum ScriptCodes {
    /// `track color`'s enumerators in `ColorID` order: none, then Pink to Purple.
    static let colors: [UInt32] = ["RCno", "RCpk", "RCrd", "RCor", "RCyl", "RCgn", "RCaq", "RCbl", "RCpu"].map(fourCC)

    /// The `ColorID` a `track color` enumerator stands for: 0 for none.
    static func colorID(_ code: UInt32) -> UInt8? { colors.firstIndex(of: code).map { UInt8($0) } }

    /// `playlist kind`'s enumerators.
    static let kindPlaylist = fourCC("RKpl")
    static let kindFolder = fourCC("RKfd")
    static let kindSmart = fourCC("RKsm")
}

// MARK: - Tracks

/// A track property, by the Cocoa key the dictionary gives it.
enum TrackKey: CaseIterable, Sendable {
    case id, name, artist, album, genre, label, key, bpm, duration, year, rating, color, comment, playCount
    case dateAdded, location, analysed, bitRate, sampleRate

    static func parse(_ key: String) -> TrackKey? {
        switch key {
        case "uniqueID": .id
        case "name": .name
        case "rbxArtist": .artist
        case "rbxAlbum": .album
        case "rbxGenre": .genre
        case "rbxLabel": .label
        case "rbxKey": .key
        case "rbxBpm": .bpm
        case "rbxDuration": .duration
        case "rbxYear": .year
        case "rbxRating": .rating
        case "rbxColor": .color
        case "rbxComment": .comment
        case "rbxPlayCount": .playCount
        case "rbxDateAdded": .dateAdded
        case "rbxLocation": .location
        case "rbxAnalysed": .analysed
        case "rbxBitRate": .bitRate
        case "rbxSampleRate": .sampleRate
        default: nil
        }
    }

    /// The Info tab's field a `set` of this property writes, when it is one of those.
    var field: TrackField? {
        switch self {
        case .name: .title
        case .artist: .artist
        case .album: .album
        case .genre: .genre
        case .label: .label
        case .key: .key
        case .bpm: .bpm
        case .year: .year
        case .playCount: .playCount
        default: nil
        }
    }

    /// Only these two need the table row; the rest come from the track's details.
    var needsRow: Bool { self == .analysed || self == .dateAdded }

    fileprivate var displayName: String {
        switch self {
        case .id: "id"
        case .duration: "duration"
        case .dateAdded: "date added"
        case .location: "location"
        case .analysed: "analysed flag"
        case .bitRate: "bit rate"
        case .sampleRate: "sample rate"
        default: "value"
        }
    }
}

enum ScriptMapping {
    /// One property of one track, from its details (and its row for the two the details lack).
    static func trackValue(details d: TrackDetails, row: Row?, key: TrackKey) -> ScriptValue {
        switch key {
        case .id: return .text(d.id)
        case .name: return .text(d.title)
        case .artist: return .text(d.artist)
        case .album: return .text(d.album)
        case .genre: return .text(d.genre)
        case .label: return .text(d.label)
        case .key: return .text(d.key)
        case .bpm: return .real(Double(d.bpmX100) / 100)
        case .duration: return .real(Double(d.durationSec))
        case .year: return .int(Int64(d.year))
        case .rating: return .int(Int64(d.rating))
        case .color:
            let id = Int(d.color) ?? 0
            return .enumerator(ScriptCodes.colors.indices.contains(id) ? ScriptCodes.colors[id] : ScriptCodes.colors[0])
        case .comment: return .text(d.comment)
        case .playCount: return .int(Int64(d.playCount))
        case .dateAdded: return .text(row?.dateAdded ?? d.dateCreated)
        case .location: return d.path.isEmpty ? .missing : .file(d.path)
        case .analysed: return .bool((row?.analysed ?? 0) != 0)
        case .bitRate: return .int(Int64(d.bitrate))
        case .sampleRate: return .int(Int64(d.sampleRate))
        }
    }

    /// What a `set` of a track property sends to the backend.
    enum TrackEdit: Equatable {
        case field(TrackField, String)
        case rating(UInt8)
        case comment(String)
        /// `ColorID`: 0 for none.
        case color(UInt8)
    }

    /// Checks a value a script is setting and says what to write.
    static func trackEdit(_ key: TrackKey, _ value: ScriptValue) throws -> TrackEdit {
        func notSettable() -> ScriptError { .notModifiable("The \(key.displayName) of a track cannot be set.") }
        switch (key, value) {
        case (.rating, .int(let stars)):
            guard (0...5).contains(stars) else { throw ScriptError.wrongType("A rating is 0 to 5 stars.") }
            return .rating(UInt8(stars))
        case (.rating, _): throw ScriptError.wrongType("A rating is 0 to 5 stars.")
        case (.comment, .text(let text)): return .comment(text)
        case (.color, .enumerator(let code)):
            guard let id = ScriptCodes.colorID(code) else { throw ScriptError.wrongType("That is not a track color.") }
            return .color(id)
        case (.color, _): throw ScriptError.wrongType("That is not a track color.")
        case (.bpm, .real(let bpm)) where bpm.isFinite && bpm > 0: return .field(.bpm, String(format: "%.2f", bpm))
        case (.bpm, .int(let bpm)) where bpm > 0: return .field(.bpm, "\(bpm).00")
        case (.bpm, _): throw ScriptError.wrongType("A BPM is a number above 0.")
        case (.year, .int(let n)) where n >= 0, (.playCount, .int(let n)) where n >= 0:
            guard let field = key.field else { throw notSettable() }
            return .field(field, String(n))
        case (.year, _), (.playCount, _): throw ScriptError.wrongType("That has to be a whole number, 0 or more.")
        case (_, .text(let text)):
            guard let field = key.field else { throw notSettable() }
            return .field(field, text)
        default:
            throw key.field != nil ? ScriptError.wrongType("That has to be text.") : notSettable()
        }
    }

    /// A track or playlist id as a unique-id specifier carries it: our own text, or a number when a
    /// script wrote `track id 42` without the quotes. Nil when it is not a plain number.
    static func canonicalID(_ value: ScriptValue) -> String? {
        switch value {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return UInt64(trimmed).map(String.init)
        case .int(let n): return n >= 0 ? String(n) : nil
        case .real(let n) where n >= 0 && n.rounded() == n && n < 1.8e19: return String(UInt64(n))
        default: return nil
        }
    }
}

// MARK: - Playlists

/// A playlist as a script sees it.
struct PlaylistInfo: Equatable, Sendable {
    var id: String
    var name: String
    /// `playlist kind`'s enumerator.
    var kind: UInt32
    /// The folder it is in; nil at the top.
    var parent: String?

    var isFolder: Bool { kind == ScriptCodes.kindFolder }
}

enum ScriptPlaylists {
    /// Every playlist and folder at any depth, in the order the tree shows them: each folder
    /// followed by what is in it. Built from the core's flat, depth-ordered tree.
    static func parse(_ flat: [TreeNode]) -> [PlaylistInfo] {
        var out: [PlaylistInfo] = []
        var inPlaylists = false
        var stack: [(depth: UInt32, id: String)] = []
        for node in flat {
            if node.depth == 0 {
                inPlaylists = node.kind == .collection
                stack = []
                continue
            }
            guard inPlaylists else { continue }
            let kind: UInt32
            switch node.kind {
            case .folder: kind = ScriptCodes.kindFolder
            case .smartPlaylist: kind = ScriptCodes.kindSmart
            case .playlist: kind = ScriptCodes.kindPlaylist
            default: continue
            }
            while let top = stack.last, top.depth >= node.depth { stack.removeLast() }
            out.append(PlaylistInfo(id: node.id, name: node.name, kind: kind, parent: stack.last?.id))
            if kind == ScriptCodes.kindFolder { stack.append((node.depth, node.id)) }
        }
        return out
    }

    /// A folder's playlists one level down, or the top level's for nil.
    static func children(of parent: String?, in all: [PlaylistInfo]) -> [PlaylistInfo] {
        all.filter { $0.parent == parent }
    }
}

// MARK: - Text for messages

enum ScriptText {
    /// A value as JSON text, the way the window's error messages spell it (`JSON.stringify`).
    static func json(_ value: ScriptValue) -> String {
        switch value {
        case .missing: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return String(n)
        case .real(let n):
            if n.isFinite, n.rounded() == n, abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .text(let text):
            let data = try? JSONEncoder().encode(text)
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(text)\""
        case .list(let items): return "[" + items.map(json).joined(separator: ",") + "]"
        default: return "null"
        }
    }
}
