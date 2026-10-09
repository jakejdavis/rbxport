import AppKit
import SwiftUI

/// The track filter bar: BPM (with its tolerance), KEY, RATING and COLOR, each a tick box over a
/// list. Click picks one value, Command-click toggles, "All" clears, and the reset button clears
/// everything. The picks live in `AppModel.filterState`; the lists come from `filter_values`.
struct FilterBar: View {
    @Bindable var model: AppModel

    private var values: FilterValues? { model.filterValues }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            bpmColumn
            Divider()
            keyColumn
            Divider()
            ratingColumn
            Divider()
            colorColumn
            Spacer(minLength: 0)
            Button("Reset") { model.resetFilter() }
                .controlSize(.small)
                .disabled(!model.filterState.hasPicks)
                .help("Clear every column")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(height: 150)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Track Filter")
    }

    // MARK: Columns

    private var bpmColumn: some View {
        HStack(alignment: .top, spacing: 8) {
            PickColumn(
                title: "BPM", enabled: $model.filterState.bpm.enabled, picked: model.filterState.bpm.picked,
                options: (values?.bpms ?? []).map { FilterOption(value: $0.value, label: String($0.value), count: $0.count) },
                width: 96, onPick: { model.filterState.bpm.pick($0, toggle: $1) })
            let applies = model.filterState.toleranceApplies(masterBPMx100: nil)
            PickColumn(
                title: "\u{00B1}%", enabled: $model.filterState.bpm.enabled,
                picked: [model.filterState.tolerancePct], showsAll: false,
                options: FilterState.tolerances.map { FilterOption(value: $0, label: "\u{00B1} \($0)%", count: nil) },
                width: 76, dimmed: !applies, showsTick: false,
                onPick: { value, _ in model.filterState.tolerancePct = value ?? 0 })
        }
    }

    private var keyColumn: some View {
        let style = model.keyStyle
        return PickColumn(
            title: "KEY", enabled: $model.filterState.key.enabled, picked: model.filterState.key.picked,
            options: FilterKeyOrder.sorted(values?.keys ?? []).map {
                FilterOption(value: $0.value, label: CellFormat.key($0.value, style: style), count: $0.count)
            },
            width: 96, onPick: { model.filterState.key.pick($0, toggle: $1) })
    }

    private var ratingColumn: some View {
        PickColumn(
            title: "RATING", enabled: $model.filterState.rating.enabled, picked: model.filterState.rating.picked,
            showsAll: false,
            options: FilterState.ratings.map { FilterOption(value: $0, label: Self.stars($0), count: nil) },
            width: 96, onPick: { model.filterState.rating.pick($0, toggle: $1) })
    }

    private var colorColumn: some View {
        PickColumn(
            title: "COLOR", enabled: $model.filterState.color.enabled, picked: model.filterState.color.picked,
            showsAll: false,
            options: FilterState.colorNames.map { FilterOption(value: $0, label: $0, count: nil, dot: Self.dot($0)) },
            width: 110, onPick: { model.filterState.color.pick($0, toggle: $1) })
    }

    static func stars(_ rating: UInt8) -> String {
        rating == 0 ? "\u{2014}" : String(repeating: "\u{2605}", count: Int(rating))
    }

    static func dot(_ name: String) -> Color {
        switch name {
        case "Pink": .pink
        case "Red": .red
        case "Orange": .orange
        case "Yellow": .yellow
        case "Green": .green
        case "Aqua": .cyan
        case "Blue": .blue
        default: .purple
        }
    }
}

/// One value on offer: what to show and how many tracks carry it.
struct FilterOption<Value: Hashable & Sendable>: Identifiable {
    let value: Value
    let label: String
    let count: UInt32?
    var dot: Color?

    var id: Value { value }
}

/// A tick box, a heading and a scrolling list with an optional "All" row.
struct PickColumn<Value: Hashable & Sendable>: View {
    let title: String
    @Binding var enabled: Bool
    let picked: [Value]
    var showsAll = true
    let options: [FilterOption<Value>]
    let width: CGFloat
    var dimmed = false
    var showsTick = true
    /// `nil` is the "All" row; the flag is the Command-click (toggle) modifier.
    let onPick: (Value?, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if showsTick {
                    Toggle(title, isOn: $enabled).toggleStyle(.checkbox).labelsHidden().controlSize(.small)
                }
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsAll {
                        row(label: "All", count: nil, dot: nil, selected: picked.isEmpty) { onPick(nil, false) }
                    }
                    ForEach(options) { option in
                        row(label: option.label, count: option.count, dot: option.dot, selected: picked.contains(option.value)) {
                            onPick(option.value, NSEvent.modifierFlags.contains(.command))
                        }
                    }
                }
            }
            .frame(width: width)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            .opacity(dimmed ? 0.45 : (enabled || !showsTick ? 1 : 0.7))
        }
    }

    private func row(label: String, count: UInt32?, dot: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(label).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 2)
            if let count { Text(String(count)).font(.system(size: 10)).foregroundStyle(selected ? .primary : .tertiary) }
        }
        .padding(.horizontal, 6).frame(height: 18)
        .background(selected ? Color.accentColor.opacity(0.35) : .clear)
        .contentShape(.rect)
        .onTapGesture(perform: action)
    }
}
