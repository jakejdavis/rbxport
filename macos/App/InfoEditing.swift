import SwiftUI

/// The Info tab with its editable fields: Enter or leaving a field commits, Escape puts the
/// stored value back. Read-only facts (Album Artist, BPM as React draws it, Mix Name, and the
/// file's own) stay as text.
struct InfoEditForm: View {
    let model: InfoPanelModel
    let details: TrackDetails

    private func commit(_ field: TrackField) -> (String) -> Void {
        { value in Task { await model.edit(.field(field, value)) } }
    }

    var body: some View {
        Form {
            Section("Track") {
                InfoTextField(label: L10n.t("Track Title"), value: details.title, commit: commit(.title))
                InfoTextField(label: L10n.t("Artist"), value: details.artist, commit: commit(.artist))
                InfoTextField(label: L10n.t("Album"), value: details.album, commit: commit(.album))
                InfoFixed(label: L10n.t("Album Artist"), value: details.albumArtist)
                InfoTextField(label: L10n.t("Original Artist"), value: details.originalArtist, commit: commit(.originalArtist))
                InfoTextField(label: L10n.t("Composer"), value: details.composer, commit: commit(.composer))
                InfoTextField(label: L10n.t("Lyricist"), value: details.lyricist, commit: commit(.lyricist))
                InfoTextField(label: L10n.t("Remixer"), value: details.remixer, commit: commit(.remixer))
                InfoFixed(label: L10n.t("Mix Name"), value: details.mixName)
                InfoTextField(label: L10n.t("Label"), value: details.label, commit: commit(.label))
                InfoTextField(label: L10n.t("Genre"), value: details.genre, commit: commit(.genre))
            }
            Section("Musical") {
                InfoFixed(label: L10n.t("BPM"), value: CellFormat.bpm(details.bpmX100))
                KeyPicker(selected: details.key, keys: model.lookups?.keys ?? [], commit: commit(.key))
                InfoTextField(label: L10n.t("Year"), value: details.year > 0 ? String(details.year) : "", numeric: true, commit: commit(.year))
                InfoFixed(label: L10n.t("Release Date"), value: CellFormat.shortDate(details.releaseDate))
                InfoTextField(
                    label: "Track Number", value: details.trackNumber > 0 ? String(details.trackNumber) : "", numeric: true,
                    commit: commit(.trackNumber))
                InfoTextField(
                    label: "Disc Number", value: details.discNumber > 0 ? String(details.discNumber) : "", numeric: true,
                    commit: commit(.discNumber))
                InfoFixed(label: L10n.t("Time"), value: CellFormat.duration(details.durationSec))
            }
            Section("Library") {
                LabeledContent("Rating") {
                    StarRating(rating: details.rating) { stars in
                        Task { await model.edit(.rating(RatingClick.result(current: details.rating, clicked: stars))) }
                    }
                }
                LabeledContent("Color") {
                    ColorChoice(selected: UInt8(details.color) ?? 0) { color in Task { await model.edit(.color(color)) } }
                }
                InfoTextField(
                    label: L10n.t("DJ Play Count"), value: String(details.playCount), numeric: true, commit: commit(.playCount))
                InfoFixed(label: L10n.t("My Tag"), value: details.myTags.compactMap { model.myTagNames[$0] }.joined(separator: ", "))
                InfoTextField(
                    label: L10n.t("Comments"), value: details.comment, multiline: true,
                    commit: { value in Task { await model.edit(.comment(value)) } })
                InfoFixed(label: L10n.t("Message"), value: details.message)
                InfoFixed(label: "Auto load HotCue on CDJ/XDJ", value: details.hotCueAutoLoad ? L10n.t("Yes") : L10n.t("No"))
                InfoFixed(label: L10n.t("Publish track information"), value: details.publish ? L10n.t("Yes") : L10n.t("No"))
            }
            ForEach(InfoFormat.infoSections(details, myTagNames: model.myTagNames).filter { $0.title == L10n.t("File") }, id: \.title) { section in
                Section(section.title) { ForEach(section.facts, id: \.label) { InfoFixed(label: $0.label, value: $0.value) } }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("info-editor")
    }
}

/// A fact the panel shows and does not write.
struct InfoFixed: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            Text(value.isEmpty ? "\u{2014}" : value)
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }
}

/// A text field that commits on Enter or when it loses focus, and reverts on Escape.
struct InfoTextField: View {
    let label: String
    let value: String
    var numeric = false
    var multiline = false
    let commit: (String) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(label: String, value: String, numeric: Bool = false, multiline: Bool = false, commit: @escaping (String) -> Void) {
        self.label = label
        self.value = value
        self.numeric = numeric
        self.multiline = multiline
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $draft, axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .lineLimit(multiline ? 1...4 : 1...1)
                .focused($focused)
                .onSubmit(finish)
                .onExitCommand { draft = value; focused = false }
                .onChange(of: focused) { _, now in if !now { finish() } }
                .onChange(of: value) { _, stored in if !focused { draft = stored } }
                .accessibilityIdentifier("info-field-\(label)")
        }
    }

    private func finish() {
        guard draft != value else { return }
        commit(draft)
    }
}

/// The key, from the keys the library knows (rekordbox refuses a name it has no row for).
struct KeyPicker: View {
    let selected: String
    let keys: [String]
    let commit: (String) -> Void

    var body: some View {
        LabeledContent("Key") {
            Picker("Key", selection: Binding(get: { selected }, set: { if $0 != selected { commit($0) } })) {
                Text("\u{2014}").tag("")
                ForEach(keys.contains(selected) || selected.isEmpty ? keys : [selected] + keys, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Five stars; clicking one sets it, clicking the lit one clears it.
struct StarRating: View {
    let rating: UInt8
    let click: (UInt8) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button { click(UInt8(star)) } label: {
                    Image(systemName: "star.fill")
                        .foregroundStyle(star <= Int(rating) ? Color.primary : Color.secondary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
            }
        }
        .accessibilityIdentifier("info-rating")
    }
}

/// The track colour: a menu of dots.
struct ColorChoice: View {
    let selected: UInt8
    let choose: (UInt8) -> Void

    var body: some View {
        Menu {
            ForEach(0...8, id: \.self) { id in
                Button { choose(UInt8(id)) } label: {
                    Label { Text(TrackColors.name(UInt8(id))) } icon: { Image(nsImage: TrackColors.dot(UInt8(id))) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: TrackColors.dot(selected))
                Text(TrackColors.name(selected))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("info-color")
    }
}
