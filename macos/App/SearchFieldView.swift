import AppKit
import SwiftUI

extension SearchField {
    /// The scopes in the order the search menu shows them.
    static let scopes: [SearchField] = [
        .all, .title, .artist, .album, .genre, .year, .bpm, .composer, .albumArtist, .remixer, .label,
        .comment, .originalArtist, .mixName,
    ]

    var label: String {
        switch self {
        case .all: "All"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .genre: "Genre"
        case .year: "Year"
        case .bpm: "BPM"
        case .composer: "Composer"
        case .albumArtist: "Album Artist"
        case .remixer: "Remixer"
        case .label: "Label"
        case .comment: "Comments"
        case .originalArtist: "Original Artist"
        case .mixName: "Mix Name"
        }
    }
}

/// A search field whose magnifier menu picks the scope. Command-F focuses it (through
/// `AppModel.focusSearch`) and Escape clears it, the way `NSSearchField` does.
struct SearchFieldView: NSViewRepresentable {
    let model: AppModel
    let query: String
    let scope: SearchField
    let focusRequests: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        context.coordinator.field = field
        context.coordinator.focusRequests = focusRequests
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        if field.stringValue != query { field.stringValue = query }
        field.placeholderString = scope == .all ? "Search" : "Search \(scope.label)"
        field.searchMenuTemplate = coordinator.menu(selected: scope)
        if coordinator.focusRequests != focusRequests {
            coordinator.focusRequests = focusRequests
            field.window?.makeFirstResponder(field)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: AppModel
        weak var field: NSSearchField?
        var focusRequests = 0

        init(model: AppModel) { self.model = model }

        func menu(selected: SearchField) -> NSMenu {
            let menu = NSMenu(title: "Search In")
            let header = NSMenuItem(title: "Search In", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (index, scope) in SearchField.scopes.enumerated() {
                let item = NSMenuItem(title: scope.label, action: #selector(scopeChosen(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.state = scope == selected ? .on : .off
                menu.addItem(item)
            }
            return menu
        }

        @objc func scopeChosen(_ item: NSMenuItem) {
            model.searchField = SearchField.scopes[item.tag]
        }

        @objc func changed(_ sender: NSSearchField) {
            model.query = sender.stringValue
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field { model.query = field.stringValue }
        }
    }
}
