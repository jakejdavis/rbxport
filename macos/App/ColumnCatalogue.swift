import Foundation

/// A column of the track table. Raw values match the React app's column keys, so
/// persisted layouts and the spec stay comparable.
enum ColumnID: String, CaseIterable, Codable, Hashable, Sendable {
    case trackNo, attr, preview, artwork, title, key, bpm, duration, rating, artist, comment, label
    case size, discNo, albumArtist, composer, lyricist, fileType, year, mixName, remixer
    case originalArtist, sampleRate, bitrate, bitDepth, location, dateAdded, releaseDate
    case dateCreated, hotCue, publishTrackInfo, message, color, djPlayCount, myTag
    case album, genre, trackNumber, cloud, fileName
}

/// Where a table is shown; each context keeps its own layout.
enum ColumnContext: String, CaseIterable, Sendable {
    case collection, playlist, history, folder
}

/// How the Key column is written.
enum KeyStyle: String, CaseIterable, Sendable {
    case classic, camelot

    var label: String {
        switch self {
        case .classic: "Classic (Am, Ebm)"
        case .camelot: "Camelot (8A, 2A)"
        }
    }
}

struct ColumnSpec: Sendable {
    let id: ColumnID
    let label: String
    /// rekordbox's own width where one is known, otherwise a sensible default.
    let width: Double
    let rightAligned: Bool
    /// The sort this column's header applies, or nil when it cannot sort.
    let sortKey: SortKey?
    /// Fetched by `fetch_rows` only while the column is shown.
    let extra: ExtraColumn?
    /// Always shown and absent from the header menu (`#`).
    let fixed: Bool

    var sortable: Bool { sortKey != nil }

    /// The sort key at a given key style (Camelot sorts the Key column by wheel position).
    func sortKey(for style: KeyStyle) -> SortKey? {
        id == .key && style == .camelot ? .keyCamelot : sortKey
    }
}

enum ColumnCatalogue {
    static let minWidth = 32.0
    static let maxWidth = 1200.0

    private static func spec(
        _ id: ColumnID, _ label: String, _ width: Double, right: Bool = false,
        sort: SortKey?, extra: ExtraColumn? = nil, fixed: Bool = false
    ) -> ColumnSpec {
        ColumnSpec(
            id: id, label: label, width: width, rightAligned: right, sortKey: sort, extra: extra, fixed: fixed)
    }

    /// Every column, in the catalogue's own order (which is also the default order).
    static let all: [ColumnSpec] = [
        spec(.trackNo, "#", 47, right: true, sort: .trackNo, fixed: true),
        spec(.attr, "Attribute", 67, sort: nil),
        spec(.preview, "Preview", 128, sort: nil),
        spec(.artwork, "Artwork", 80, sort: nil),
        spec(.title, "Track Title", 387, sort: .title),
        spec(.key, "Key", 73, sort: .key),
        spec(.bpm, "BPM", 80, right: true, sort: .bpm),
        spec(.duration, "Time", 80, right: true, sort: .duration),
        spec(.rating, "Rating", 101, sort: .rating),
        spec(.artist, "Artist", 301, sort: .artist),
        spec(.comment, "Comments", 210, sort: .comment),
        spec(.label, "Label", 128, sort: .label),
        spec(.size, "Size", 90, right: true, sort: .size, extra: .size),
        spec(.discNo, "Disc number", 90, right: true, sort: .discNo, extra: .discNo),
        spec(.albumArtist, "Album Artist", 200, sort: .albumArtist, extra: .albumArtist),
        spec(.composer, "Composer", 180, sort: .composer, extra: .composer),
        spec(.lyricist, "Lyricist", 180, sort: .lyricist, extra: .lyricist),
        spec(.fileType, "File Type", 90, sort: .fileType, extra: .fileType),
        spec(.year, "Year", 70, right: true, sort: .year, extra: .year),
        spec(.mixName, "Mix Name", 180, sort: .mixName, extra: .mixName),
        spec(.remixer, "Remixer", 180, sort: .remixer, extra: .remixer),
        spec(.originalArtist, "Original Artist", 200, sort: .originalArtist, extra: .originalArtist),
        spec(.sampleRate, "Sample Rate", 110, right: true, sort: .sampleRate, extra: .sampleRate),
        spec(.bitrate, "Bitrate", 90, right: true, sort: .bitrate, extra: .bitrate),
        spec(.bitDepth, "Bitdepth", 90, right: true, sort: .bitDepth, extra: .bitDepth),
        spec(.location, "Location", 320, sort: .location, extra: .location),
        spec(.dateAdded, "Date Added", 128, right: true, sort: .dateAdded),
        spec(.releaseDate, "Release Date", 128, right: true, sort: .releaseDate),
        spec(.dateCreated, "Date Created", 128, right: true, sort: .dateCreated, extra: .dateCreated),
        spec(.hotCue, "Hot Cue", 110, sort: nil),
        spec(.publishTrackInfo, "Publish track information", 180, sort: .publishTrackInfo, extra: .publishTrackInfo),
        spec(.message, "Message", 180, sort: .message, extra: .message),
        spec(.color, "Color", 90, sort: .color, extra: .color),
        spec(.djPlayCount, "DJ Play Count", 120, right: true, sort: .playCount, extra: .djPlayCount),
        spec(.myTag, "My Tag", 180, sort: nil, extra: .myTag),
        spec(.album, "Album", 240, sort: .album),
        spec(.genre, "Genre", 160, sort: .genre),
        spec(.trackNumber, "Track number", 90, right: true, sort: .trackNumber, extra: .trackNumber),
        spec(.cloud, "Cloud", 80, sort: nil, extra: .cloud),
        spec(.fileName, "File Name", 260, sort: .fileName),
    ]

    private static let byID: [ColumnID: ColumnSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func spec(for id: ColumnID) -> ColumnSpec {
        // Every ColumnID is in `all`; a test pins that.
        byID[id]!
    }

    /// The columns that are always shown, in front.
    static let fixed: [ColumnID] = all.filter(\.fixed).map(\.id)

    /// Columns the header menu cannot hide.
    static let required: [ColumnID] = fixed + [.title]

    /// The header menu's order (from the rekordbox capture); `#` is not in it.
    static let menuOrder: [ColumnID] = [
        .attr, .preview, .artwork, .title, .releaseDate, .artist, .genre, .comment,
        .size, .discNo, .albumArtist, .trackNumber, .bpm, .rating, .composer,
        .lyricist, .duration, .fileType, .year, .mixName, .remixer, .label,
        .originalArtist, .key, .sampleRate, .bitrate, .bitDepth, .fileName,
        .location, .dateAdded, .dateCreated, .hotCue, .publishTrackInfo, .message,
        .color, .djPlayCount, .myTag, .album, .cloud,
    ]

    static let defaultVisible: [ColumnID] = [
        .preview, .artwork, .title, .key, .bpm, .duration, .rating,
        .artist, .comment, .label, .dateAdded, .releaseDate,
    ]

    static let folderVisible: [ColumnID] = [
        .preview, .artwork, .title, .artist, .album, .genre, .bpm, .rating, .duration, .key, .fileName,
    ]

    static let folderWidths: [ColumnID: Double] = [
        .preview: 200, .artwork: 80, .title: 128, .artist: 128, .album: 128, .genre: 128, .bpm: 80,
        .rating: 90, .duration: 80, .key: 128, .fileName: 128,
    ]

    static func clamp(_ width: Double) -> Double {
        let w = width.isFinite ? width : minWidth
        return min(max(w, minWidth), maxWidth).rounded()
    }
}

/// Which columns, in what order, how wide. `order` holds the visible columns left to
/// right, without the fixed `#`.
struct ColumnLayout: Codable, Equatable, Sendable {
    var order: [ColumnID]
    /// Overrides of the catalogue width.
    var widths: [ColumnID: Double]

    static func defaults(for context: ColumnContext) -> ColumnLayout {
        context == .folder
            ? ColumnLayout(order: ColumnCatalogue.folderVisible, widths: ColumnCatalogue.folderWidths)
            : ColumnLayout(order: ColumnCatalogue.defaultVisible, widths: [:])
    }

    func width(of id: ColumnID) -> Double {
        widths[id] ?? ColumnCatalogue.spec(for: id).width
    }

    /// The columns as shown: fixed ones first, then `order`.
    var shown: [ColumnID] { ColumnCatalogue.fixed + order }

    /// The extra columns the shown columns need.
    var extraColumns: [ExtraColumn] {
        order.compactMap { ColumnCatalogue.spec(for: $0).extra }
    }

    /// Restores a missing title at its catalogue position.
    private static func withTitle(_ order: [ColumnID]) -> [ColumnID] {
        guard !order.contains(.title) else { return order }
        let catalogue = ColumnCatalogue.all.map(\.id)
        let titleRank = catalogue.firstIndex(of: .title) ?? 0
        let at = order.firstIndex { (catalogue.firstIndex(of: $0) ?? 0) > titleRank }
        var restored = order
        restored.insert(.title, at: at ?? restored.count)
        return restored
    }

    /// Repairs a layout read back from storage: drops unknown and repeated columns and
    /// the fixed ones, restores the title, clamps widths, and falls back to the
    /// context's defaults when nothing is left.
    static func sanitised(order rawOrder: [String]?, widths rawWidths: [String: Double]?, for context: ColumnContext)
        -> ColumnLayout
    {
        var seen = Set<ColumnID>()
        var order: [ColumnID] = []
        for raw in rawOrder ?? [] {
            guard let id = ColumnID(rawValue: raw), !ColumnCatalogue.fixed.contains(id), seen.insert(id).inserted
            else { continue }
            order.append(id)
        }
        guard !order.isEmpty else { return defaults(for: context) }
        var widths: [ColumnID: Double] = [:]
        for (raw, width) in rawWidths ?? [:] {
            guard let id = ColumnID(rawValue: raw), width.isFinite else { continue }
            widths[id] = ColumnCatalogue.clamp(width)
        }
        return ColumnLayout(order: withTitle(order), widths: widths)
    }

    /// Shows or hides a column. A newly shown one goes where the catalogue puts it.
    /// Required columns are left alone.
    func toggling(_ id: ColumnID) -> ColumnLayout {
        guard !ColumnCatalogue.required.contains(id) else { return self }
        var next = self
        if let existing = next.order.firstIndex(of: id) {
            next.order.remove(at: existing)
            return next
        }
        let catalogue = ColumnCatalogue.all.map(\.id)
        let wanted = catalogue.firstIndex(of: id) ?? 0
        let at = next.order.firstIndex { (catalogue.firstIndex(of: $0) ?? 0) > wanted }
        next.order.insert(id, at: at ?? next.order.count)
        return next
    }

    func resized(_ id: ColumnID, to width: Double) -> ColumnLayout {
        var next = self
        next.widths[id] = ColumnCatalogue.clamp(width)
        return next
    }
}

/// Persists a layout per context in `UserDefaults`.
struct ColumnLayoutStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ context: ColumnContext) -> String { "columns.\(context.rawValue)" }

    func load(_ context: ColumnContext) -> ColumnLayout {
        let stored = defaults.dictionary(forKey: key(context))
        return ColumnLayout.sanitised(
            order: stored?["order"] as? [String],
            widths: (stored?["widths"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue },
            for: context)
    }

    func save(_ layout: ColumnLayout, for context: ColumnContext) {
        defaults.set(
            [
                "order": layout.order.map(\.rawValue),
                "widths": Dictionary(uniqueKeysWithValues: layout.widths.map { ($0.key.rawValue, $0.value) }),
            ] as [String: Any], forKey: key(context))
    }

    func reset(_ context: ColumnContext) {
        defaults.removeObject(forKey: key(context))
    }
}

/// The sort a header click leads to: ascending, then descending, then off (the view's own order).
enum SortCycle {
    static let off = (key: SortKey.trackNo, descending: false)

    static func next(
        current: (key: SortKey, descending: Bool), clicked: SortKey
    ) -> (key: SortKey, descending: Bool) {
        if clicked != current.key { return (clicked, false) }
        if clicked == .trackNo { return (.trackNo, !current.descending) }  // `#` has no "off" beyond ascending
        return current.descending ? off : (clicked, true)
    }
}
