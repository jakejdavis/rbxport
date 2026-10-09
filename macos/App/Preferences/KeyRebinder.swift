import AppKit
import Observation

/// The Keyboard pane's logic: listening for a key, refusing the ones that cannot be used, asking
/// before taking a key from another binding, and resetting. The view only draws it.
@MainActor @Observable
final class KeyRebinder {
    /// A chord waiting for the person to say it may take the key from other bindings.
    struct Pending: Equatable {
        let id: String
        let chord: Chord
        let holders: [String]
    }

    let prefs: PreferencesStore
    /// The binding that is listening for its next key.
    private(set) var recording: String?
    var pending: Pending?
    /// Why the last key was not taken.
    private(set) var message: String?

    init(prefs: PreferencesStore) { self.prefs = prefs }

    /// While a row listens, the deck keys must not act on what is typed.
    var isListening: Bool { recording != nil }

    func begin(_ id: String) {
        guard BindingTable.byID[id]?.rebindable == true else { return }
        recording = id
        pending = nil
        message = nil
    }

    func cancel() {
        recording = nil
        pending = nil
    }

    /// The next key pressed while a row listens. Escape cancels; Delete or Backspace on their own
    /// unbind the row; anything else becomes its key, after a check.
    func capture(_ chord: Chord) {
        guard let id = recording else { return }
        if chord == Chord("Escape") { cancel(); return }
        if chord == Chord("Backspace") || chord == Chord("Delete") {
            recording = nil
            apply(.unbound, to: id)
            return
        }
        recording = nil
        apply(chord, to: id)
    }

    private func apply(_ chord: Chord, to id: String) {
        let map = prefs.keymap
        if let issue = map.issue(assigning: chord, to: id) {
            message = Self.text(for: issue, chord: chord)
            return
        }
        let holders = map.conflicts(assigning: chord, to: id).filter(\.rebindable)
        let fixed = map.conflicts(assigning: chord, to: id).filter { !$0.rebindable }
        if let first = fixed.first {
            message = "\(chord.display) is used by \(first.label) and cannot be changed."
            return
        }
        if !holders.isEmpty {
            pending = Pending(id: id, chord: chord, holders: holders.map(\.id))
            return
        }
        commit(chord, to: id)
    }

    /// Takes the key from the bindings that had it (as React does: they become unbound, not swapped).
    func confirmPending() {
        guard let pending else { return }
        self.pending = nil
        commit(pending.chord, to: pending.id)
    }

    private func commit(_ chord: Chord, to id: String) {
        if let next = prefs.keymap.assigning(chord, to: id) {
            prefs.keyboardOverrides = next
            message = nil
        }
    }

    func reset(_ id: String) { prefs.keyboardOverrides = prefs.keymap.resetting(id) }

    func resetAll() {
        cancel()
        message = nil
        prefs.reset(.keyboard)
    }

    static func text(for issue: AssignIssue, chord: Chord) -> String {
        switch issue {
        case .notRebindable: "This key is built in and cannot be changed."
        case .reserved: "\(chord.display) is kept by macOS and the standard commands."
        case .menuNeedsModifier: "A menu shortcut needs \u{2318} or \u{2303}, or it would take the key from text fields."
        }
    }

    // MARK: Listing

    /// The rows of a group, as the pane lists them (aliases left out).
    static func rows(in group: BindingGroup) -> [KeyBinding] {
        BindingTable.all.filter { $0.group == group && !$0.alias }
    }
}
