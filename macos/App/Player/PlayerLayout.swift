import Foundation

/// How much of the window the decks take (`src/lib/layout.ts`). The browser is the same in all
/// of them; a layout changes what is drawn above it, never what is playing.
enum PlayerLayout: String, CaseIterable, Identifiable, Sendable {
    case one, two, simple, browser

    var id: String { rawValue }

    static let `default` = PlayerLayout.one
    /// UserDefaults key for the chosen layout.
    static let key = "player.layout"

    var label: String {
        switch self {
        case .one: "1 PLAYER"
        case .two: "2 PLAYER"
        case .simple: "SIMPLE PLAYER"
        case .browser: "FULL BROWSER"
        }
    }

    /// The menu's wording, React's menu labels (translated by the catalog).
    var menuLabel: String {
        switch self {
        case .one: L10n.t("1 Player")
        case .two: L10n.t("2 Players")
        case .simple: L10n.t("Simple Player")
        case .browser: L10n.t("Full Browser")
        }
    }

    /// How many decks are drawn: none in the full browser, two in the 2 player layout, else one.
    var deckCount: Int {
        switch self {
        case .browser: 0
        case .two: 2
        case .one, .simple: 1
        }
    }

    /// False only for the simple player (no detail waveform, no transport rail).
    var isFullDeck: Bool { self != .simple }

    /// The binding-table row whose key switches to this layout (Command-7, 8, 9 and 0 by default).
    var bindingID: String {
        switch self {
        case .one: "menu.layout-one"
        case .two: "menu.layout-two"
        case .simple: "menu.layout-simple"
        case .browser: "menu.layout-browser"
        }
    }
}
