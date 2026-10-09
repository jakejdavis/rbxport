import CoreGraphics

/// How tall table rows are while the Artwork or Preview column is shown (View > Row Size).
/// Text-only tables stay compact. React's rows are 25 pt; artwork needs more to be legible.
enum RowSize: String, CaseIterable, Sendable {
    case compact, standard, large

    var label: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .large: "Large"
        }
    }

    var height: CGFloat {
        switch self {
        case .compact: 24
        case .standard: 32
        case .large: 48
        }
    }

    /// The compact height a table of text columns uses.
    static let textRowHeight: CGFloat = 22

    static func height(for layout: ColumnLayout, preference: RowSize) -> CGFloat {
        let drawsImages = layout.order.contains(.artwork) || layout.order.contains(.preview)
        return drawsImages ? preference.height : textRowHeight
    }
}
