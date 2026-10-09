import Foundation

/// A label and the text beside it.
struct InfoFact: Equatable, Sendable {
    let label: String
    let value: String
}

/// What the information panel prints, worked out from a track's record. Pure, so the formatting
/// is tested without the panel. Ported from `src/views/info/fields.ts`.
enum InfoFormat {
    /// `FileType` as rekordbox prints it. Code 6 (ALAC or AAC) shows "M4A" everywhere in this app.
    static func fileType(_ code: UInt32) -> String {
        switch code {
        case 1: "MP3 File"
        case 4, 6: "M4A File"
        case 5: "FLAC File"
        case 11: "WAV File"
        case 12: "AIFF File"
        default: ""
        }
    }

    static func sampleRate(_ hz: UInt32) -> String { hz > 0 ? "\(hz) Hz" : "" }
    static func bitrate(_ kbps: UInt32) -> String { kbps > 0 ? "\(kbps) kbps" : "" }
    static func size(_ bytes: UInt64) -> String { bytes > 0 ? CellFormat.bytes(bytes) : "" }

    /// The Summary tab's table in the captured order. Every row is kept when a value is blank so
    /// the table does not jump as the selection moves. Until the record arrives the row's own
    /// duration is shown and the rest is blank, never the previous track's.
    static func summaryFacts(row: Row?, details: TrackDetails?) -> [InfoFact] {
        let d = details.flatMap { row == nil || $0.id == row?.id ? $0 : nil }
        return [
            InfoFact(label: "Time", value: CellFormat.duration(d?.durationSec ?? row?.durationSec ?? 0)),
            InfoFact(label: "File Type", value: d.map { fileType($0.fileType) } ?? ""),
            InfoFact(label: "Size", value: d.map { size($0.fileSize) } ?? ""),
            InfoFact(label: "Date Created", value: d.map { CellFormat.shortDate($0.dateCreated) } ?? ""),
            InfoFact(label: "Sample Rate", value: d.map { sampleRate($0.sampleRate) } ?? ""),
            InfoFact(label: "Bitrate", value: d.map { bitrate($0.bitrate) } ?? ""),
            InfoFact(label: "DJ Play Count", value: d.map { String($0.playCount) } ?? ""),
            InfoFact(label: "Location", value: d?.path ?? ""),
        ]
    }

    /// A group of Info-tab fields.
    struct Section: Equatable, Sendable {
        let title: String
        let facts: [InfoFact]
    }

    /// Every field of the record, grouped for the read-only Info tab. `myTagNames` maps tag ids
    /// to names (from the lookups); ids it does not know are skipped.
    static func infoSections(_ d: TrackDetails, myTagNames: [String: String] = [:]) -> [Section] {
        func text(_ n: UInt32) -> String { n > 0 ? String(n) : "" }
        func yesNo(_ b: Bool) -> String { b ? "Yes" : "No" }
        let tags = d.myTags.compactMap { myTagNames[$0] }.joined(separator: ", ")
        return [
            Section(
                title: "Track",
                facts: [
                    InfoFact(label: "Track Title", value: d.title),
                    InfoFact(label: "Artist", value: d.artist),
                    InfoFact(label: "Album", value: d.album),
                    InfoFact(label: "Album Artist", value: d.albumArtist),
                    InfoFact(label: "Original Artist", value: d.originalArtist),
                    InfoFact(label: "Composer", value: d.composer),
                    InfoFact(label: "Lyricist", value: d.lyricist),
                    InfoFact(label: "Remixer", value: d.remixer),
                    InfoFact(label: "Mix Name", value: d.mixName),
                    InfoFact(label: "Label", value: d.label),
                    InfoFact(label: "Genre", value: d.genre),
                ]),
            Section(
                title: "Musical",
                facts: [
                    InfoFact(label: "BPM", value: CellFormat.bpm(d.bpmX100)),
                    InfoFact(label: "Key", value: d.key),
                    InfoFact(label: "Year", value: text(d.year)),
                    InfoFact(label: "Release Date", value: CellFormat.shortDate(d.releaseDate)),
                    InfoFact(label: "Track Number", value: text(d.trackNumber)),
                    InfoFact(label: "Disc Number", value: text(d.discNumber)),
                    InfoFact(label: "Time", value: CellFormat.duration(d.durationSec)),
                ]),
            Section(
                title: "Library",
                facts: [
                    InfoFact(label: "Rating", value: d.rating == 0 ? "" : String(repeating: "\u{2605}", count: Int(min(d.rating, 5)))),
                    InfoFact(label: "Color", value: colorName(d.color)),
                    InfoFact(label: "DJ Play Count", value: String(d.playCount)),
                    InfoFact(label: "My Tag", value: tags),
                    InfoFact(label: "Comments", value: d.comment),
                    InfoFact(label: "Message", value: d.message),
                    InfoFact(label: "Auto load HotCue on CDJ/XDJ", value: yesNo(d.hotCueAutoLoad)),
                    InfoFact(label: "Publish track information", value: yesNo(d.publish)),
                ]),
            Section(
                title: "File",
                facts: [
                    InfoFact(label: "File Type", value: fileType(d.fileType)),
                    InfoFact(label: "Size", value: size(d.fileSize)),
                    InfoFact(label: "Sample Rate", value: sampleRate(d.sampleRate)),
                    InfoFact(label: "Bitrate", value: bitrate(d.bitrate)),
                    InfoFact(label: "Bit Depth", value: d.bitDepth > 0 ? "\(d.bitDepth) bit" : ""),
                    InfoFact(label: "Date Created", value: CellFormat.shortDate(d.dateCreated)),
                    InfoFact(label: "Location", value: d.path),
                ]),
        ]
    }

    /// The colour a `ColorID` string names; "0", empty and unknown are none.
    static func colorName(_ id: String) -> String {
        guard let n = UInt8(id) else { return "" }
        return CellFormat.color(n)
    }
}
