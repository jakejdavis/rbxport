import Observation
import SwiftUI

// MARK: - Vocabulary (src/views/tree/SmartPlaylistEditor.tsx)

enum SmartKind: Sendable { case text, number, date, tag }

struct SmartProperty: Equatable, Sendable {
    let value: String
    let label: String
    let kind: SmartKind
}

struct SmartOperator: Equatable, Sendable {
    let value: String
    let label: String
    let kinds: [SmartKind]
}

/// rekordbox's properties and operators, in its order and words.
enum SmartCatalogue {
    static let properties: [SmartProperty] = [
        .init(value: "album", label: "Album", kind: .text),
        .init(value: "albumArtist", label: "Album artist", kind: .text),
        .init(value: "artist", label: "Artist", kind: .text),
        .init(value: "bpm", label: "BPM", kind: .number),
        .init(value: "grouping", label: "Color", kind: .text),
        .init(value: "comments", label: "Comments", kind: .text),
        .init(value: "producer", label: "Composer", kind: .text),
        .init(value: "stockDate", label: "Date Added", kind: .date),
        .init(value: "dateCreated", label: "Date Created", kind: .date),
        .init(value: "counter", label: "DJ play count", kind: .number),
        .init(value: "fileName", label: "File name", kind: .text),
        .init(value: "genre", label: "Genre", kind: .text),
        .init(value: "key", label: "Key", kind: .text),
        .init(value: "label", label: "Label", kind: .text),
        .init(value: "mixName", label: "Mix name", kind: .text),
        .init(value: "myTag", label: "My Tag", kind: .tag),
        .init(value: "originalArtist", label: "Original artist", kind: .text),
        .init(value: "rating", label: "Rating", kind: .number),
        .init(value: "dateReleased", label: "Release Date", kind: .date),
        .init(value: "remixedBy", label: "Remixer", kind: .text),
        .init(value: "duration", label: "Time", kind: .number),
        .init(value: "name", label: "Track Title", kind: .text),
        .init(value: "year", label: "Year", kind: .number),
    ]

    static let operators: [SmartOperator] = [
        .init(value: "1", label: "=", kinds: [.text, .number, .date]),
        .init(value: "2", label: "\u{2260}", kinds: [.text, .number, .date]),
        .init(value: "3", label: ">", kinds: [.number, .date]),
        .init(value: "4", label: "<", kinds: [.number, .date]),
        .init(value: "6", label: "is in the last", kinds: [.date]),
        .init(value: "7", label: "is not in the last", kinds: [.date]),
        .init(value: "5", label: "is in the range", kinds: [.number, .date]),
        .init(value: "8", label: "contains", kinds: [.text, .tag]),
        .init(value: "9", label: "does not contain", kinds: [.text, .tag]),
        .init(value: "10", label: "starts with", kinds: [.text]),
        .init(value: "11", label: "ends with", kinds: [.text]),
    ]

    static let units: [(value: String, label: String)] = [
        ("day", "day(s)"), ("week", "week(s)"), ("month", "month(s)"), ("year", "year(s)"),
    ]

    static func property(_ value: String) -> SmartProperty? { properties.first { $0.value == value } }

    static func operators(for kind: SmartKind) -> [SmartOperator] { operators.filter { $0.kinds.contains(kind) } }

    static func isRelative(_ op: String) -> Bool { op == "6" || op == "7" }
}

// MARK: - Model

struct SmartRow: Identifiable, Equatable {
    let id = UUID()
    var property: String
    var op: String
    var left: String
    var right: String
    var unit: String

    /// A fresh row: Artist = (empty), as rekordbox's new row is.
    static func empty() -> SmartRow { SmartRow(property: "artist", op: "1", left: "", right: "", unit: "") }

    init(property: String, op: String, left: String, right: String, unit: String) {
        self.property = property
        self.op = op
        self.left = left
        self.right = right
        self.unit = unit
    }

    init(_ condition: SmartCondition) {
        self.init(
            property: condition.property, op: condition.operator, left: condition.left, right: condition.right,
            unit: condition.unit)
    }

    var condition: SmartCondition {
        SmartCondition(
            property: property, operator: op, left: left.trimmingCharacters(in: .whitespaces),
            right: right.trimmingCharacters(in: .whitespaces), unit: unit)
    }

    var kind: SmartKind { SmartCatalogue.property(property)?.kind ?? .text }
}

/// The smart-playlist editor's state. A rule using a property this app cannot write
/// (`readOnlyRules`) is shown as it is and cannot be changed; the name still can.
@MainActor @Observable
final class SmartEditorModel: Identifiable {
    enum Mode: Equatable {
        case create(parent: String)
        case edit(id: String)
    }

    @ObservationIgnored let id = UUID()
    let mode: Mode
    let originalName: String
    let readOnlyRules: Bool
    var name: String
    var logic: SmartLogic
    var rows: [SmartRow]
    /// The tags a My Tag row can pick from, filled in when the sheet opens.
    var myTags: [MyTagCategory] = []
    /// The core's refusal, shown in the sheet.
    var error: String?
    @ObservationIgnored private let original: SmartRule

    init(mode: Mode, name: String, rule: SmartRule) {
        self.mode = mode
        self.name = name
        originalName = name
        original = rule
        logic = rule.logic
        readOnlyRules = rule.conditions.contains { SmartCatalogue.property($0.property) == nil }
        rows = rule.conditions.isEmpty ? [SmartRow.empty()] : rule.conditions.map(SmartRow.init)
    }

    var title: String {
        switch mode {
        case .create: "Create New Intelligent Playlist"
        case .edit: "Edit the Intelligent Playlist"
        }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A name, and (unless the rule is only displayed) a value on every row.
    var canSave: Bool {
        guard !trimmedName.isEmpty else { return false }
        if readOnlyRules { return true }
        return rows.allSatisfy { !$0.left.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var saveTitle: String { readOnlyRules ? "Rename" : "OK" }

    /// What is saved. A rule that is only displayed goes back untouched.
    var rule: SmartRule {
        readOnlyRules ? original : SmartRule(logic: logic, conditions: rows.map(\.condition))
    }

    func addRow() {
        guard !readOnlyRules else { return }
        rows.append(.empty())
    }

    func removeRow(_ id: UUID) {
        guard !readOnlyRules, rows.count > 1 else { return }
        rows.removeAll { $0.id == id }
    }

    /// Keeps the operator when the new property takes it, else the first it takes. Crossing into
    /// or out of My Tag clears the values: a typed word names no tag, and a tag id is no word.
    func changeProperty(_ id: UUID, to property: String) {
        guard !readOnlyRules, let at = rows.firstIndex(where: { $0.id == id }),
            let new = SmartCatalogue.property(property)
        else { return }
        var row = rows[at]
        let crossesTag = (new.kind == .tag) != (row.kind == .tag)
        let keeps = SmartCatalogue.operators(for: new.kind).contains { $0.value == row.op }
        row.property = property
        if !keeps { row.op = SmartCatalogue.operators(for: new.kind).first?.value ?? "1" }
        row.unit = SmartCatalogue.isRelative(row.op) ? "day" : ""
        if row.op != "5" { row.right = "" }
        if crossesTag { row.left = ""; row.right = "" }
        rows[at] = row
    }

    func changeOperator(_ id: UUID, to op: String) {
        guard !readOnlyRules, let at = rows.firstIndex(where: { $0.id == id }) else { return }
        var row = rows[at]
        row.op = op
        row.unit = SmartCatalogue.isRelative(op) ? (row.unit.isEmpty ? "day" : row.unit) : ""
        if op != "5" { row.right = "" }
        rows[at] = row
    }

    func binding(_ id: UUID, _ keyPath: WritableKeyPath<SmartRow, String>) -> Binding<String> {
        Binding(
            get: { self.rows.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                if let at = self.rows.firstIndex(where: { $0.id == id }) { self.rows[at][keyPath: keyPath] = value }
            })
    }
}

// MARK: - Sheet

struct SmartEditorSheet: View {
    @Bindable var editor: SmartEditorModel
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editor.title).font(.headline)
            LabeledContent("List name") {
                TextField("List name", text: $editor.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("List name")
            }
            HStack {
                if editor.rows.count > 1 {
                    Text("Match")
                    Picker("Match", selection: $editor.logic) {
                        Text("all of the").tag(SmartLogic.all)
                        Text("any of the").tag(SmartLogic.any)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(editor.readOnlyRules)
                    Text("following conditions:")
                } else {
                    Text("Match the following condition:")
                }
                Spacer()
                Button("Add condition", systemImage: "plus") { editor.addRow() }
                    .labelStyle(.iconOnly)
                    .disabled(editor.readOnlyRules)
                    .help("Add a condition")
            }
            if editor.readOnlyRules {
                Text(
                    "This list uses a condition rbxport cannot edit, so its rules are shown as they are. You can still rename it."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(editor.rows) { row in
                    SmartRowView(editor: editor, row: row)
                }
            }
            .disabled(editor.readOnlyRules)
            if let error = editor.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(editor.saveTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editor.canSave)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

private struct SmartRowView: View {
    @Bindable var editor: SmartEditorModel
    let row: SmartRow

    var body: some View {
        let known = SmartCatalogue.property(row.property) != nil
        HStack(spacing: 6) {
            if known {
                Picker(
                    "Property",
                    selection: Binding(get: { row.property }, set: { editor.changeProperty(row.id, to: $0) })
                ) {
                    ForEach(SmartCatalogue.properties, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden().frame(width: 140)
                Picker(
                    "Operator",
                    selection: Binding(get: { row.op }, set: { editor.changeOperator(row.id, to: $0) })
                ) {
                    ForEach(SmartCatalogue.operators(for: row.kind), id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden().frame(width: 150)
                value
            } else {
                // A property this build cannot write: the rule as stored.
                Text(row.property.isEmpty ? "(unknown condition)" : row.property).frame(width: 140, alignment: .leading)
                Text("operator \(row.op)").frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
                Text(row.left).foregroundStyle(.secondary)
                Spacer()
            }
            Button("Remove condition", systemImage: "minus") { editor.removeRow(row.id) }
                .labelStyle(.iconOnly)
                .disabled(editor.rows.count < 2)
                .help("Remove this condition")
        }
    }

    @ViewBuilder private var value: some View {
        if row.kind == .tag {
            Picker("Tag", selection: editor.binding(row.id, \.left)) {
                Text("Choose a tag").tag("")
                ForEach(editor.myTags, id: \.name) { category in
                    Section(category.name) {
                        ForEach(category.tags, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
            }
            .labelsHidden()
        } else {
            TextField("Value", text: editor.binding(row.id, \.left)).textFieldStyle(.roundedBorder)
            if row.op == "5" {
                Text("to")
                TextField("Upper value", text: editor.binding(row.id, \.right)).textFieldStyle(.roundedBorder)
            }
            if SmartCatalogue.isRelative(row.op) {
                Picker("Unit", selection: editor.binding(row.id, \.unit)) {
                    ForEach(SmartCatalogue.units, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden().frame(width: 90)
            }
        }
    }
}
