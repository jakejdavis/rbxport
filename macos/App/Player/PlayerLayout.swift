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

    /// Command-7, 8, 9 and 0.
    var keyEquivalent: Character {
        switch self {
        case .one: "7"
        case .two: "8"
        case .simple: "9"
        case .browser: "0"
        }
    }
}
