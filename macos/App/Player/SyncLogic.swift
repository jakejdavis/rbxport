import Foundation

// Matching one deck to another: the tempo, and then the bar. Ported from `src/lib/sync.ts`.
// Two numbers come out, a tempo ratio and a distance to move the follower's playhead, because
// that is all sync is once the grids are known. 4/4 throughout, as rekordbox's grid is.

/// What a deck brings to the calculation.
struct SyncDeck: Equatable, Sendable {
    /// Hundredths of a BPM, as the library stores it: the file's own tempo.
    var bpmX100: Double
    /// The multiple of the file's speed the deck is playing at. A leader that has been nudged
    /// is followed at the tempo it is playing, not the one printed on its file.
    var tempo = 1.0
    /// Whether the deck is running; a leader that is not has no next beat to wait for.
    var playing = false
    /// Where the playhead is, in seconds.
    var position = 0.0
    var grid = BeatGrid.empty
}

enum SyncLogic {
    static let beatsPerBar = 4.0
    static let minTempo = 0.5
    static let maxTempo = 2.0
    /// Closer than this to a beat is on it, in seconds: about a callback.
    static let onTheBeat = 0.005

    /// The tempo that makes the follower play at the leader's BPM; 1 when either has no BPM.
    /// With `doubleHalf` the nearest of the ratio, its double and its half wins, so a 140 next
    /// to a 70 is a match at twice the tempo and not a track slowed to half speed.
    static func tempoFor(leader: SyncDeck, follower: SyncDeck, doubleHalf: Bool = true) -> Double {
        guard leader.bpmX100 > 0, follower.bpmX100 > 0 else { return 1 }
        var ratio = leader.bpmX100 * leader.tempo / follower.bpmX100
        guard ratio.isFinite, ratio > 0 else { return 1 }
        if doubleHalf {
            for candidate in [ratio * 2, ratio / 2] where abs(log(candidate)) < abs(log(ratio)) { ratio = candidate }
        }
        return min(max(ratio, minTempo), maxTempo)
    }

    /// Where the bar containing `seconds` began, and how long a bar lasts there. From the grid
    /// where there is one, else from the BPM.
    static func barAt(_ deck: SyncDeck, _ seconds: Double) -> (start: Double, length: Double)? {
        let ms = seconds * 1000
        let times = deck.grid.times
        let beatSeconds = deck.bpmX100 > 0 ? 6000 / deck.bpmX100 : 0
        if times.count < 2 {
            guard beatSeconds > 0 else { return nil }
            let length = beatSeconds * beatsPerBar
            return ((seconds / length).rounded(.down) * length, length)
        }
        // The last beat at or before the position.
        var low = 0
        var high = times.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if Double(times[middle]) <= ms { low = middle } else { high = middle - 1 }
        }
        let within = Int(deck.grid.numbers[low]) - 1
        let downbeat = max(0, low - within)
        let start = Double(times[downbeat]) / 1000
        let nextIndex = downbeat + Int(beatsPerBar)
        let length = nextIndex < times.count ? Double(times[nextIndex]) / 1000 - start : beatSeconds * beatsPerBar
        return length > 0 ? (start, length) : nil
    }

    /// How far to move the follower so its bar starts where the leader's does: the shortest
    /// way, at most half a bar.
    static func nudgeFor(leader: SyncDeck, follower: SyncDeck) -> Double {
        guard let lead = barAt(leader, leader.position), let follow = barAt(follower, follower.position), lead.length > 0
        else { return 0 }
        func into(_ bar: (start: Double, length: Double), _ at: Double) -> Double {
            bar.length > 0 ? (at - bar.start) / bar.length : 0
        }
        let gap = into(lead, leader.position) - into(follow, follower.position)
        return (gap - gap.rounded()) * follow.length
    }

    /// How far to move the follower so its beat falls where the leader's does: at most half a
    /// beat either way. What quantized play on a synced deck lines up.
    static func beatNudgeFor(leader: SyncDeck, follower: SyncDeck) -> Double {
        guard let lead = barAt(leader, leader.position), let follow = barAt(follower, follower.position),
            lead.length > 0, follow.length > 0
        else { return 0 }
        func beatOf(_ bar: (start: Double, length: Double), _ at: Double) -> (fraction: Double, beat: Double) {
            let beat = bar.length / beatsPerBar
            let into = (at - bar.start) / beat
            return (into - into.rounded(.down), beat)
        }
        let leadBeat = beatOf(lead, leader.position)
        let followBeat = beatOf(follow, follower.position)
        let gap = leadBeat.fraction - followBeat.fraction
        return (gap - gap.rounded()) * followBeat.beat
    }

    /// How long until the leader's next beat, in real seconds (its file time to the beat over
    /// the tempo it plays at), or nil with no grid and no BPM. A leader already on a beat
    /// answers a whole beat: the press came too late for that one.
    static func beatWait(leader: SyncDeck) -> Double? {
        guard let bar = barAt(leader, leader.position), bar.length > 0 else { return nil }
        let beat = bar.length / beatsPerBar
        let into = (leader.position - bar.start).truncatingRemainder(dividingBy: beat)
        var left = beat - into
        if left < onTheBeat { left += beat }
        return left / (leader.tempo > 0 ? leader.tempo : 1)
    }

    /// Both halves: the follower's new tempo and how far its playhead moves. BPM sync (not
    /// beat sync) leaves the playhead where it is.
    static func syncTo(
        leader: SyncDeck, follower: SyncDeck, matchBeat: Bool = true, doubleHalf: Bool = true
    ) -> (tempo: Double, nudge: Double) {
        (
            tempoFor(leader: leader, follower: follower, doubleHalf: doubleHalf),
            matchBeat ? nudgeFor(leader: leader, follower: follower) : 0
        )
    }
}
