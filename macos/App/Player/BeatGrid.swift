import Foundation

/// A track's beat grid as parallel arrays (a three-hour mix is 23,000 beats). Ported from
/// `BeatGrid` and its helpers in `src/lib/player.ts`. The times already carry the PQTZ grid
/// offset (the Rust side applies it), so everything drawn from here agrees with the editor.
struct BeatGrid: Equatable, Sendable {
    /// Each beat's position in milliseconds, ascending.
    var times: [UInt32]
    /// Each beat's number in its bar, 1 to 4.
    var numbers: [UInt8]
    /// The tempo x100 at each beat.
    var tempos: [UInt16]

    static let empty = BeatGrid(times: [], numbers: [], tempos: [])

    /// The most beats one window draws; the widest zoom is 64 bars, 256 beats.
    static let maxDrawn = 1024

    init(times: [UInt32], numbers: [UInt8], tempos: [UInt16]) {
        self.times = times
        self.numbers = numbers
        self.tempos = tempos
    }

    init(beats: [Beat]) {
        times = beats.map(\.timeMs)
        numbers = beats.map(\.number)
        tempos = beats.map(\.tempoX100)
    }

    var isEmpty: Bool { times.isEmpty }
    var count: Int { times.count }

    /// The index of the first beat at or after `ms`.
    func lowerBound(_ ms: Double) -> Int {
        var lo = 0
        var hi = times.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if Double(times[mid]) < ms { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The beats inside a window, as the grid is drawn: a binary search, not a scan.
    func beats(from: Double, to: Double) -> [(timeMs: Double, downbeat: Bool)] {
        var out: [(timeMs: Double, downbeat: Bool)] = []
        guard to >= from else { return out }
        var i = lowerBound(from)
        while i < times.count {
            let t = Double(times[i])
            if t > to || out.count >= Self.maxDrawn { break }
            out.append((t, numbers[i] == 1))
            i += 1
        }
        return out
    }

    /// The tempo x100 the grid holds at `ms`, or 0 with no grid.
    func tempoAt(_ ms: Double) -> Int {
        guard !times.isEmpty else { return 0 }
        let at = lowerBound(ms)
        let beat = at < times.count && Double(times[at]) <= ms ? at : max(at - 1, 0)
        return Int(tempos[beat])
    }

    /// The beat nearest `ms`, or `ms` itself with no grid: what Q snaps to.
    func nearestBeatMs(_ ms: Double) -> Double {
        guard !times.isEmpty else { return ms }
        let at = lowerBound(ms)
        let after = Double(times[min(at, times.count - 1)])
        let before = Double(times[max(at - 1, 0)])
        return abs(ms - before) <= abs(after - ms) ? before : after
    }

    /// The grid with each beat split into `divisions` equal steps (quantize 1/2, 1/4, 1/8).
    /// One or fewer divisions, or too few beats, is the grid itself.
    func subdivided(_ divisions: Int) -> BeatGrid {
        guard divisions > 1, times.count >= 2 else { return self }
        var t: [UInt32] = []
        var n: [UInt8] = []
        var p: [UInt16] = []
        t.reserveCapacity((times.count - 1) * divisions + 1)
        for i in 0..<(times.count - 1) {
            let from = Double(times[i])
            let to = Double(times[i + 1])
            for step in 0..<divisions {
                t.append(UInt32((from + (to - from) * Double(step) / Double(divisions)).rounded()))
                n.append(numbers[i])
                p.append(tempos[i])
            }
        }
        t.append(times[times.count - 1])
        n.append(numbers[times.count - 1])
        p.append(tempos[times.count - 1])
        return BeatGrid(times: t, numbers: n, tempos: p)
    }

    // MARK: Beat arithmetic

    /// The average beat length in ms, for running past either end of the grid.
    private var period: Double? {
        guard times.count >= 2 else { return nil }
        let p = Double(times[times.count - 1] - times[0]) / Double(times.count - 1)
        return p > 0 ? p : nil
    }

    /// Where `ms` falls on the grid as a fractional beat index (0 is the first beat, 1.5 is half
    /// way between the second and third). Before and after the grid the first and last beat's own
    /// length carries on. Nil with fewer than two beats.
    func beatPosition(ms: Double) -> Double? {
        guard times.count >= 2 else { return nil }
        let first = Double(times[0])
        let last = Double(times[times.count - 1])
        if ms <= first {
            let length = Double(times[1]) - first
            return length > 0 ? (ms - first) / length : nil
        }
        if ms >= last {
            let length = last - Double(times[times.count - 2])
            return length > 0 ? Double(times.count - 1) + (ms - last) / length : nil
        }
        // The last beat at or before ms.
        var i = lowerBound(ms)
        if i >= times.count || Double(times[i]) > ms { i -= 1 }
        let a = Double(times[i])
        let b = Double(times[i + 1])
        return b > a ? Double(i) + (ms - a) / (b - a) : Double(i)
    }

    /// The inverse of `beatPosition(ms:)`.
    func time(atBeatPosition position: Double) -> Double? {
        guard times.count >= 2 else { return nil }
        if position <= 0 {
            return Double(times[0]) + position * (Double(times[1]) - Double(times[0]))
        }
        let top = Double(times.count - 1)
        if position >= top {
            let length = Double(times[times.count - 1]) - Double(times[times.count - 2])
            return Double(times[times.count - 1]) + (position - top) * length
        }
        let i = Int(position.rounded(.down))
        let a = Double(times[i])
        let b = Double(times[i + 1])
        return a + (position - Double(i)) * (b - a)
    }

    /// Where a beat jump of `beats` (negative goes back) from `fromMs` lands, in ms, not
    /// clamped. Counted on the grid so a jump stays on the beat; without a grid it is the file's
    /// BPM that sets the distance. Nil with neither.
    func jumpTarget(fromMs: Double, beats: Double, bpmX100: Double) -> Double? {
        if let position = beatPosition(ms: fromMs), let target = time(atBeatPosition: position + beats) {
            return target
        }
        guard bpmX100 > 0 else { return nil }
        return fromMs + beats * 60_000 / (bpmX100 / 100)
    }

    /// A beat loop of `beats` from `atMs`: the in point snapped to `snapTo` when quantize is on,
    /// the out point `beats` later on this grid. Past the end the average beat carries on. Nil
    /// with no grid to count on, or a length that is not positive.
    func beatLoopRange(snapTo: BeatGrid?, atMs: Double, beats: Double) -> (inMs: Double, outMs: Double)? {
        guard times.count >= 2, beats > 0, let period else { return nil }
        let start = snapTo.map { $0.nearestBeatMs(atMs) } ?? atMs
        let at = lowerBound(start)
        let onBeat = at < times.count && Double(times[at]) == start
        let target = at + Int(beats)
        let end: Double
        if onBeat, beats == beats.rounded(), target < times.count {
            end = Double(times[target])
        } else {
            end = start + beats * period
        }
        return end > start ? (start, end) : nil
    }

    // MARK: Bars

    /// The beat counter beside the playhead: `12.3 Bars`, the third beat of the twelfth bar. A
    /// beat becomes current at its timestamp, and the beat before 1.1 reads -1.4. Without a grid
    /// the file's BPM counts from zero; with neither, blank.
    func barText(seconds: Double, fallbackBpm: Double) -> String {
        guard seconds.isFinite else { return "" }
        if !times.isEmpty {
            let ms = seconds * 1000
            let next = lowerBound(ms)
            let index = next < times.count && Double(times[next]) == ms ? next : next - 1
            let firstNumber = Int(numbers[0] == 0 ? 1 : numbers[0])
            let ordinal = index + firstNumber - 1
            let bar = Int((Double(ordinal) / 4).rounded(.down))
            let number = index >= 0 ? Int(numbers[index] == 0 ? 1 : numbers[index]) : ((ordinal % 4) + 4) % 4 + 1
            return "\(bar < 0 ? bar : bar + 1).\(number) Bars"
        }
        guard fallbackBpm > 0 else { return "" }
        let elapsed = max(0, Int((seconds * fallbackBpm / 60 + 1e-9).rounded(.down)))
        return "\(elapsed / 4 + 1).\(elapsed % 4 + 1) Bars"
    }
}
