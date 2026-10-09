import AppKit

/// What a dragged track row puts on the pasteboard: the audio file as a `public.file-url` (so
/// Finder, a mail message or another DJ app takes it as a file), and, while the library may be
/// edited, the track id for drops inside the app (playlists and reordering).
enum TrackDrag {
    /// The pasteboard item for one row. `path` is the audio file when it is known; `id` is
    /// empty for a row whose page has not loaded. Nil when there is nothing to carry.
    @MainActor
    static func pasteboardItem(id: String, path: String?, canEdit: Bool) -> NSPasteboardItem? {
        let fileURL = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        guard canEdit || fileURL != nil else { return nil }
        let item = NSPasteboardItem()
        if canEdit { item.setString(id, forType: .rbxportTracks) }
        if let fileURL { item.setString(fileURL.absoluteString, forType: .fileURL) }
        return item
    }

    /// The file a row's id stands for: a loose Explorer file carries its path; a collection
    /// track is looked up in the library.
    static func path(for id: String, lookup: (String) -> String?) -> String? {
        guard !id.isEmpty else { return nil }
        if id.hasPrefix("file:") { return String(id.dropFirst("file:".count)) }
        return lookup(id)
    }
}
