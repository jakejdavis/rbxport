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
        case 1: L10n.t("MP3 File")
        case 4, 6: L10n.t("M4A File")
        case 5: L10n.t("FLAC File")
        case 11: L10n.t("WAV File")
        case 12: L10n.t("AIFF File")
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
            InfoFact(label: L10n.t("Time"), value: CellFormat.duration(d?.durationSec ?? row?.durationSec ?? 0)),
            InfoFact(label: L10n.t("File Type"), value: d.map { fileType($0.fileType) } ?? ""),
            InfoFact(label: L10n.t("Size"), value: d.map { size($0.fileSize) } ?? ""),
            InfoFact(label: L10n.t("Date Created"), value: d.map { CellFormat.shortDate($0.dateCreated) } ?? ""),
            InfoFact(label: L10n.t("Sample Rate"), value: d.map { sampleRate($0.sampleRate) } ?? ""),
            InfoFact(label: L10n.t("Bitrate"), value: d.map { bitrate($0.bitrate) } ?? ""),
            InfoFact(label: L10n.t("DJ Play Count"), value: d.map { String($0.playCount) } ?? ""),
            InfoFact(label: L10n.t("Location"), value: d?.path ?? ""),
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
        func yesNo(_ b: Bool) -> String { b ? L10n.t("Yes") : L10n.t("No") }
        let tags = d.myTags.compactMap { myTagNames[$0] }.joined(separator: ", ")
        return [
            Section(
                title: L10n.t("Track"),
                facts: [
                    InfoFact(label: L10n.t("Track Title"), value: d.title),
                    InfoFact(label: L10n.t("Artist"), value: d.artist),
                    InfoFact(label: L10n.t("Album"), value: d.album),
                    InfoFact(label: L10n.t("Album Artist"), value: d.albumArtist),
                    InfoFact(label: L10n.t("Original Artist"), value: d.originalArtist),
                    InfoFact(label: L10n.t("Composer"), value: d.composer),
                    InfoFact(label: L10n.t("Lyricist"), value: d.lyricist),
                    InfoFact(label: L10n.t("Remixer"), value: d.remixer),
                    InfoFact(label: L10n.t("Mix Name"), value: d.mixName),
                    InfoFact(label: L10n.t("Label"), value: d.label),
                    InfoFact(label: L10n.t("Genre"), value: d.genre),
                ]),
            Section(
                title: "Musical",
                facts: [
                    InfoFact(label: L10n.t("BPM"), value: CellFormat.bpm(d.bpmX100)),
                    InfoFact(label: L10n.t("Key"), value: d.key),
                    InfoFact(label: L10n.t("Year"), value: text(d.year)),
                    InfoFact(label: L10n.t("Release Date"), value: CellFormat.shortDate(d.releaseDate)),
                    InfoFact(label: "Track Number", value: text(d.trackNumber)),
                    InfoFact(label: "Disc Number", value: text(d.discNumber)),
                    InfoFact(label: L10n.t("Time"), value: CellFormat.duration(d.durationSec)),
                ]),
            Section(
                title: L10n.t("Library"),
                facts: [
                    InfoFact(label: L10n.t("Rating"), value: d.rating == 0 ? "" : String(repeating: "\u{2605}", count: Int(min(d.rating, 5)))),
                    InfoFact(label: L10n.t("Color"), value: colorName(d.color)),
                    InfoFact(label: L10n.t("DJ Play Count"), value: String(d.playCount)),
                    InfoFact(label: L10n.t("My Tag"), value: tags),
                    InfoFact(label: L10n.t("Comments"), value: d.comment),
                    InfoFact(label: L10n.t("Message"), value: d.message),
                    InfoFact(label: "Auto load HotCue on CDJ/XDJ", value: yesNo(d.hotCueAutoLoad)),
                    InfoFact(label: L10n.t("Publish track information"), value: yesNo(d.publish)),
                ]),
            Section(
                title: L10n.t("File"),
                facts: [
                    InfoFact(label: L10n.t("File Type"), value: fileType(d.fileType)),
                    InfoFact(label: L10n.t("Size"), value: size(d.fileSize)),
                    InfoFact(label: L10n.t("Sample Rate"), value: sampleRate(d.sampleRate)),
                    InfoFact(label: L10n.t("Bitrate"), value: bitrate(d.bitrate)),
                    InfoFact(label: "Bit Depth", value: d.bitDepth > 0 ? "\(d.bitDepth) bit" : ""),
                    InfoFact(label: L10n.t("Date Created"), value: CellFormat.shortDate(d.dateCreated)),
                    InfoFact(label: L10n.t("Location"), value: d.path),
                ]),
        ]
    }

    /// The colour a `ColorID` string names; "0", empty and unknown are none.
    static func colorName(_ id: String) -> String {
        guard let n = UInt8(id) else { return "" }
        return CellFormat.color(n)
    }
}
