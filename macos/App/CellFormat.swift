import Foundation

/// Display formatting that matches rekordbox's own column rendering (ported from
/// `src/lib/format.ts` and `cellText` in `TrackTable.tsx`).
enum CellFormat {
    static let colorNames = ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"]
    static let fileTypes: [UInt32: String] = [1: "MP3", 4: "M4A", 5: "FLAC", 6: "M4A", 11: "WAV", 12: "AIFF"]

    /// `04:26`: two digits each, never hours.
    static func duration(_ seconds: UInt32) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// BPM is stored x100: 12800 is "128.00". Zero is blank.
    static func bpm(_ x100: UInt32) -> String {
        x100 == 0 ? "" : String(format: "%.2f", Double(x100) / 100)
    }

    /// `2026-09-06` as `9/6/26`; anything else is blank.
    static func shortDate(_ iso: String) -> String {
        let parts = iso.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, iso.count >= 10, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let month = Int(parts[1]), let day = Int(parts[2]), Int(parts[0]) != nil
        else { return "" }
        return "\(month)/\(day)/\(parts[0].suffix(2))"
    }

    /// `144.8 GB` / `15.2 MB`.
    static func bytes(_ count: UInt64) -> String {
        let gb = Double(count) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.1f MB", Double(count) / 1_048_576)
    }

    /// `821 hours 32 minutes`: how rekordbox reports a selection's total time.
    static func totalTime(_ seconds: UInt64) -> String {
        guard seconds > 0 else { return "0 minutes" }
        let h = seconds / 3600
        let m = seconds % 3600 / 60
        let minutes = "\(m) minute\(m == 1 ? "" : "s")"
        return h == 0 ? minutes : "\(h) hour\(h == 1 ? "" : "s") \(minutes)"
    }

    /// 44100 is "44.1 kHz", 48000 is "48 kHz".
    static func sampleRate(_ hz: UInt32) -> String {
        guard hz > 0 else { return "" }
        var text = String(format: "%.3f", Double(hz) / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text) kHz"
    }

    static func fileType(_ code: UInt32) -> String {
        fileTypes[code] ?? (code == 0 ? "" : String(code))
    }

    static func color(_ value: UInt8) -> String {
        value > 0 && Int(value) <= colorNames.count ? L10n.t(colorNames[Int(value) - 1]) : ""
    }

    /// A positive number as text; zero is blank (disc, year, play count...).
    static func positive(_ value: UInt32?) -> String {
        guard let value, value > 0 else { return "" }
        return String(value)
    }

    /// `Ebm` to `2A`, `C` to `8B`; unrecognised keys come back empty.
    static func camelot(_ key: String) -> String {
        let minors = ["Abm", "Ebm", "Bbm", "Fm", "Cm", "Gm", "Dm", "Am", "Em", "Bm", "F#m", "Dbm"]
        let majors = ["B", "F#", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E"]
        let aliases = [
            "G#m": "Abm", "D#m": "Ebm", "A#m": "Bbm", "C#m": "Dbm", "Gbm": "F#m",
            "Gb": "F#", "C#": "Db", "G#": "Ab", "D#": "Eb", "A#": "Bb",
        ]
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        let name = aliases[trimmed] ?? trimmed
        if let i = minors.firstIndex(of: name) { return "\(i + 1)A" }
        if let i = majors.firstIndex(of: name) { return "\(i + 1)B" }
        return ""
    }

    /// The Key column's text. Camelot shows the wheel code, and the raw key when it is
    /// not on the wheel (so nothing disappears).
    static func key(_ key: String, style: KeyStyle) -> String {
        guard style == .camelot else { return key }
        let code = camelot(key)
        return code.isEmpty ? key : code
    }

    /// The text of one cell. Attribute, Rating, Preview and Artwork have their own
    /// drawing and return blank here.
    static func text(_ id: ColumnID, row: Row, keyStyle: KeyStyle = .classic) -> String {
        let extra = row.extra
        switch id {
        case .trackNo: return String(row.trackNo)
        case .title: return row.title
        case .artist: return row.artist
        case .album: return row.album
        case .genre: return row.genre
        case .label: return row.label
        case .comment: return row.comment
        case .key: return key(row.key, style: keyStyle)
        case .bpm: return bpm(row.bpmX100)
        case .duration: return duration(row.durationSec)
        case .dateAdded: return shortDate(row.dateAdded)
        case .releaseDate: return shortDate(row.releaseDate)
        case .fileName: return row.fileName
        case .hotCue: return row.hotCues.map(\.slot).joined(separator: ", ")
        case .size: return extra.size.flatMap { $0 > 0 ? bytes($0) : nil } ?? ""
        case .dateCreated: return extra.dateCreated.map(shortDate) ?? ""
        case .fileType: return extra.fileType.map(fileType) ?? ""
        case .color: return extra.color.map(color) ?? ""
        case .publishTrackInfo: return extra.publishTrackInfo.map { $0 ? "On" : "Off" } ?? ""
        case .cloud: return extra.cloud == true ? "Cloud" : ""
        case .sampleRate: return extra.sampleRate.map(sampleRate) ?? ""
        case .bitrate: return extra.bitrate.flatMap { $0 > 0 ? "\($0) kbps" : nil } ?? ""
        case .bitDepth: return extra.bitDepth.flatMap { $0 > 0 ? "\($0) bit" : nil } ?? ""
        case .year: return positive(extra.year)
        case .discNo: return positive(extra.discNo)
        case .djPlayCount: return positive(extra.djPlayCount)
        case .trackNumber: return positive(extra.trackNumber)
        case .albumArtist: return extra.albumArtist ?? ""
        case .composer: return extra.composer ?? ""
        case .lyricist: return extra.lyricist ?? ""
        case .mixName: return extra.mixName ?? ""
        case .remixer: return extra.remixer ?? ""
        case .originalArtist: return extra.originalArtist ?? ""
        case .location: return extra.location ?? ""
        case .message: return extra.message ?? ""
        case .myTag: return extra.myTag ?? ""
        case .attr, .rating, .preview, .artwork: return ""
        }
    }

    /// Five stars, `rating` of them filled.
    static func stars(_ rating: UInt8) -> (lit: Int, total: Int) { (Int(min(rating, 5)), 5) }
}
