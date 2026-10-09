import AppKit
import Foundation

// MARK: - Colours

/// rekordbox's eight track colours, 1 to 8 (0 is none).
enum TrackColors {
    static let names = ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"]

    static func name(_ id: UInt8) -> String { id >= 1 && Int(id) <= names.count ? names[Int(id) - 1] : "None" }

    static func nsColor(_ id: UInt8) -> NSColor? {
        let rgb: [(Double, Double, Double)] = [
            (1.00, 0.35, 0.65), (0.93, 0.22, 0.22), (1.00, 0.55, 0.12), (0.97, 0.80, 0.15),
            (0.30, 0.78, 0.35), (0.20, 0.78, 0.82), (0.25, 0.46, 0.96), (0.62, 0.38, 0.88),
        ]
        guard id >= 1, Int(id) <= rgb.count else { return nil }
        let c = rgb[Int(id) - 1]
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }

    /// A filled dot for a menu item; an open ring for none.
    static func dot(_ id: UInt8, diameter: CGFloat = 10) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let color = nsColor(id) {
                color.setFill()
                path.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            return true
        }
        image.accessibilityDescription = name(id)
        return image
    }
}

// MARK: - What a cell or field edit may be

/// The Info-tab and table fields a text edit can write, with the labels the status line uses.
enum FieldLabels {
    static func label(_ field: TrackField) -> String {
        switch field {
        case .title: "Track Title"
        case .artist: "Artist"
        case .album: "Album"
        case .year: "Year"
        case .trackNumber: "Track number"
        case .discNumber: "Disc number"
        case .originalArtist: "Original Artist"
        case .composer: "Composer"
        case .remixer: "Remixer"
        case .lyricist: "Lyricist"
        case .playCount: "DJ Play Count"
        case .genre: "Genre"
        case .label: "Label"
        case .key: "Key"
        case .bpm: "BPM"
        }
    }
}

/// What an inline table edit writes.
enum CellTarget: Equatable, Sendable {
    case field(TrackField)
    case comment

    var label: String {
        switch self {
        case .field(let field): FieldLabels.label(field)
        case .comment: "Comment"
        }
    }
}

/// The columns that edit in place, as `EDITABLE_FIELDS` has them in the React table, plus the comment.
enum EditableCells {
    static func target(for column: ColumnID) -> CellTarget? {
        switch column {
        case .title: .field(.title)
        case .artist: .field(.artist)
        case .album: .field(.album)
        case .genre: .field(.genre)
        case .label: .field(.label)
        case .bpm: .field(.bpm)
        case .comment: .comment
        default: nil
        }
    }

    /// Title loads on double-click (as in the React table); the others edit.
    static func editsOnDoubleClick(_ column: ColumnID) -> Bool { target(for: column) != nil && column != .title }
}

enum FieldCheck {
    static let bpmMessage = "Enter a BPM from 40 to 499."

    /// Why `text` cannot be written to `field`, or nil. Mirrors the core so a typo is caught
    /// before a round trip; the core still checks everything.
    static func problem(_ field: TrackField, _ text: String) -> String? {
        switch field {
        case .year, .trackNumber, .discNumber, .playCount:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return "\(text) is not a whole number" }
            return trimmed.allSatisfy(\.isASCII) && trimmed.allSatisfy(\.isNumber) ? nil : "\(trimmed) is not a whole number"
        case .bpm:
            guard let bpm = Double(text.trimmingCharacters(in: .whitespaces)), bpm.isFinite, (40.0...499.0).contains(bpm)
            else { return bpmMessage }
            return nil
        default:
            return nil
        }
    }
}

/// What the Info panel may write.
enum InfoEdit: Equatable, Sendable {
    case field(TrackField, String)
    case comment(String)
    case rating(UInt8)
    case color(UInt8)
}

/// The words the status line uses after a rating click.
enum RatingClick {
    /// The stars a click on star `star` (1 to 5) leaves: clicking the lit one clears it.
    static func result(current: UInt8, clicked star: UInt8) -> UInt8 { current == star ? 0 : star }

    static func message(_ stars: UInt8) -> String { stars == 0 ? "Rating cleared." : "Rated \(stars) of 5." }
}

// MARK: - The model's metadata commands

extension AppModel {
    static let looseMessage = "That file is not in the collection. Import it first."

    static func isLoose(_ id: String) -> Bool { id.hasPrefix("file:") }

    /// Rows of the collection can be edited; loose files and a locked library cannot.
    func canEditTrack(_ id: String) -> Bool { canEdit && !Self.isLoose(id) }

    private func refuseLoose(_ ids: [String]) -> Bool {
        guard ids.contains(where: Self.isLoose) else { return false }
        notice = Self.looseMessage
        return true
    }

    /// Writes a field on the tracks. The status line says what happened; false when refused.
    @discardableResult
    func setField(_ field: TrackField, to value: String, ids: [String]) async -> Bool {
        guard !ids.isEmpty, !refuseLoose(ids) else { return false }
        if let problem = FieldCheck.problem(field, value) {
            notice = problem
            return false
        }
        let backend = backend
        guard await performEdit({ try await backend.setTrackField(ids: ids, field: field, value: value) }) != nil
        else { return false }
        notice = "\(FieldLabels.label(field)) saved."
        return true
    }

    @discardableResult
    func setComment(_ text: String, ids: [String]) async -> Bool {
        guard !ids.isEmpty, !refuseLoose(ids) else { return false }
        let backend = backend
        guard await performEdit({ try await backend.setTrackComment(ids: ids, comment: text) }) != nil else { return false }
        notice = "Comment saved."
        return true
    }

    @discardableResult
    func setRating(_ stars: UInt8, ids: [String]) async -> Bool {
        guard !ids.isEmpty, !refuseLoose(ids) else { return false }
        let backend = backend
        guard await performEdit({ try await backend.setTrackRating(ids: ids, stars: stars) }) != nil else { return false }
        notice = RatingClick.message(stars)
        return true
    }

    /// A click on a star of a table row or the panel: the lit star clears.
    @discardableResult
    func clickStar(_ star: UInt8, current: UInt8, id: String) async -> Bool {
        await setRating(RatingClick.result(current: current, clicked: star), ids: [id])
    }

    @discardableResult
    func setColor(_ color: UInt8, ids: [String]) async -> Bool {
        guard !ids.isEmpty, !refuseLoose(ids) else { return false }
        let backend = backend
        guard await performEdit({ try await backend.setTrackColor(ids: ids, color: color) }) != nil else { return false }
        notice = color == 0 ? "Color cleared." : "Color saved."
        return true
    }

    /// An inline table edit: Enter or leaving the cell with a changed value.
    @discardableResult
    func commitCell(trackID: String, column: ColumnID, text: String) async -> Bool {
        guard let target = EditableCells.target(for: column) else { return false }
        switch target {
        case .comment: return await setComment(text, ids: [trackID])
        case .field(let field): return await setField(field, to: text, ids: [trackID])
        }
    }

    /// What the cell edits start from: the text as the table prints it.
    func editableText(_ column: ColumnID, row: Row) -> String {
        column == .bpm ? CellFormat.bpm(row.bpmX100) : CellFormat.text(column, row: row, keyStyle: keyStyle)
    }

    /// The Info panel's edits apply to its single subject.
    func applyInfoEdit(_ edit: InfoEdit, to id: String) async -> Bool {
        switch edit {
        case .field(let field, let value): await setField(field, to: value, ids: [id])
        case .comment(let text): await setComment(text, ids: [id])
        case .rating(let stars): await setRating(stars, ids: [id])
        case .color(let color): await setColor(color, ids: [id])
        }
    }

    // MARK: Tag List

    func addSelectionToTagList() async {
        let ids = orderedSelection
        guard !ids.isEmpty, !refuseLoose(ids) else { return }
        let backend = backend
        if await performEdit({ try await backend.addToTagList(ids: ids) }) != nil {
            notice = "Added \(Self.tracks(ids.count)) to the Tag List."
        }
    }

    func removeSelectionFromTagList() async {
        let ids = orderedSelection
        guard !ids.isEmpty else { return }
        let backend = backend
        if await performEdit({ try await backend.removeFromTagList(ids: ids) }) != nil {
            notice = "Removed \(Self.tracks(ids.count)) from the Tag List."
        }
    }

    /// Reload Tag: the files' tags read again over the rows.
    func reloadSelectionTags() async {
        let ids = orderedSelection
        guard !ids.isEmpty, !refuseLoose(ids) else { return }
        let backend = backend
        if await performEdit({ try await backend.reloadTags(ids: ids) }) != nil {
            notice = "Tags reloaded on \(Self.tracks(ids.count))."
        }
    }

    // MARK: History and collection

    func resetSelectionPlayCount() async {
        let ids = orderedSelection
        guard !ids.isEmpty, !refuseLoose(ids) else { return }
        let backend = backend
        if await performEdit({ try await backend.resetPlayCount(ids: ids) }) != nil {
            notice = "DJ Play Count reset on \(Self.tracks(ids.count))."
        }
    }

    /// The history the open view lists, when it is one.
    var openHistoryID: String? {
        guard let id = selectedNodeID, id.hasPrefix("hi:") else { return nil }
        return String(id.dropFirst(3))
    }

    func removeSelectionFromHistory() async {
        guard let history = openHistoryID else { return }
        let ids = orderedSelection
        guard !ids.isEmpty else { return }
        let backend = backend
        if await performEdit({ try await backend.removeFromHistory(historyID: history, ids: ids) }) != nil {
            notice = "Removed \(ids.count) play\(ids.count == 1 ? "" : "s") from the history."
        }
    }

    /// Remove from Collection, asked first: the tracks leave every playlist and there is no undo.
    @discardableResult
    func removeFromCollection(_ ids: [String]) async -> Bool {
        guard !ids.isEmpty, !refuseLoose(ids) else { return false }
        let count = Self.tracks(ids.count)
        guard
            await dialogs.confirm(
                "Remove \(count) from the collection?", "This can\u{2019}t be undone. The files stay where they are.",
                "Remove")
        else { return false }
        let backend = backend
        guard await performEdit({ try await backend.removeFromCollection(ids: ids) }) != nil else { return false }
        notice = "Removed \(count) from the collection."
        return true
    }

    func removeSelectionFromCollection() async { await removeFromCollection(orderedSelection) }

    static func tracks(_ n: Int) -> String { "\(n) track\(n == 1 ? "" : "s")" }

    // MARK: Tag List events

    /// The Tag List alone changed. Its sidebar row is always there; an open Tag List view reads its rows again.
    func tagListChanged() async {
        if selectedNodeID == "tag" { reopen() }
    }
}
