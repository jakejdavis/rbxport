import Foundation

/// One filter-bar column's picks. An empty `picked` is "All".
struct FilterColumn<Value: Hashable & Sendable>: Equatable, Sendable {
    var enabled = false
    var picked: [Value] = []

    /// A plain click picks that one value; with the toggle modifier the value is added or
    /// removed. `nil` is the "All" row and clears the picks. Picking ticks the column.
    mutating func pick(_ value: Value?, toggle: Bool) {
        guard let value else {
            picked = []
            return
        }
        if toggle {
            if let at = picked.firstIndex(of: value) { picked.remove(at: at) } else { picked.append(value) }
        } else {
            picked = [value]
        }
        enabled = true
    }
}

/// The filter bar's state, and what it asks the core for.
///
/// Only ticked columns with picks are sent, as `ViewSpec.filter`. The picks of an unticked
/// column are kept so ticking it again restores them.
struct FilterState: Equatable, Sendable {
    static let colorNames = ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"]
    static let tolerances: [UInt8] = [0, 1, 2, 3, 4, 5, 6]
    static let ratings: [UInt8] = [0, 1, 2, 3, 4, 5]

    var bpm = FilterColumn<UInt32>()
    var tolerancePct: UInt8 = 0
    var key = FilterColumn<String>()
    var rating = FilterColumn<UInt8>()
    var color = FilterColumn<String>()

    /// Whether any column is ticked, which is when the bar narrows the list.
    var isNarrowing: Bool { bpm.enabled || key.enabled || rating.enabled || color.enabled }

    /// A tolerance needs a centre: a picked BPM, or the master player's.
    func toleranceApplies(masterBPMx100: UInt32?) -> Bool {
        !bpm.picked.isEmpty || (masterBPMx100 ?? 0) > 0
    }

    /// The wire filter. The master BPM stays nil until the player exists (Phase 3).
    func wire(masterBPMx100: UInt32? = nil) -> TrackFilter {
        let master = (masterBPMx100 ?? 0) > 0 ? masterBPMx100 : nil
        var filter = TrackFilter(bpm: nil, keys: nil, ratings: nil, colors: nil)
        // A ticked BPM column at "All" is no constraint unless a master BPM centres it.
        if bpm.enabled && (!bpm.picked.isEmpty || master != nil) {
            filter.bpm = BpmFilter(values: bpm.picked, tolerancePct: tolerancePct, masterBpmX100: master)
        }
        if key.enabled && !key.picked.isEmpty { filter.keys = key.picked }
        if rating.enabled && !rating.picked.isEmpty { filter.ratings = Data(rating.picked) }
        if color.enabled && !color.picked.isEmpty { filter.colors = color.picked }
        return filter
    }

    var hasPicks: Bool {
        !bpm.picked.isEmpty || tolerancePct != 0 || !key.picked.isEmpty || !rating.picked.isEmpty || !color.picked.isEmpty
            || isNarrowing
    }

    mutating func reset() { self = FilterState() }
}

extension TrackFilter {
    /// Nothing ticked: the same as an absent filter.
    var isEmpty: Bool { bpm == nil && keys == nil && ratings == nil && colors == nil }
}

enum FilterKeyOrder {
    /// Library key names in Camelot order (1A, 1B, 2A ...). Keys off the wheel come last, by name.
    static func sorted(_ counted: [CountedKey]) -> [CountedKey] {
        func rank(_ key: String) -> (Int, Int, String) {
            let code = CellFormat.camelot(key)
            guard let letter = code.last, let number = Int(code.dropLast()) else { return (1, 0, key) }
            return (0, number * 2 + (letter == "B" ? 1 : 0), key)
        }
        return counted.sorted { rank($0.value) < rank($1.value) }
    }
}
