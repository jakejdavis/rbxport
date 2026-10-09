import Foundation
import Observation

/// Tap tempo, ported from `lib/gridEdit.ts` (rekordbox's TapButton: a cumulative mean with a
/// 16% outlier gate and no rolling window).
enum TapTempo {
    static let gapMs = 1500.0
    static let minIntervalMs = 120.0

    /// The BPM x100 the taps say, or nil with fewer than two.
    static func bpmX100(_ taps: [Double]) -> Int? {
        guard taps.count >= 2, let first = taps.first, let last = taps.last else { return nil }
        let interval = (last - first) / Double(taps.count - 1)
        return interval > minIntervalMs && interval <= gapMs ? roundEven(6_000_000 / interval) : nil
    }

    /// How long to wait for the next tap before the run is dropped.
    static func timeout(_ taps: [Double]) -> Double {
        guard taps.count >= 2, let first = taps.first, let last = taps.last else { return gapMs }
        return min(gapMs, (1.5 * (last - first) / Double(taps.count - 1)).rounded(.down))
    }

    /// The taps after one more at `now` (ms).
    static func adding(_ taps: [Double], now: Double) -> [Double] {
        guard let last = taps.last, now >= last, now - last < timeout(taps) else { return [now] }
        let interval = now - last
        if taps.count == 1 { return interval > minIntervalMs && interval <= gapMs ? taps + [now] : [] }
        let mean = (last - (taps.first ?? last)) / Double(taps.count - 1)
        let checked = max(minIntervalMs, min(gapMs, interval))
        return checked >= mean * 0.84 && checked <= mean * 1.16 ? taps + [now] : []
    }

    static func roundEven(_ value: Double) -> Int {
        let low = value.rounded(.down)
        return value - low == 0.5 ? Int(low) + (Int(low) % 2) : Int(value.rounded())
    }
}

/// The beat-grid editor of one deck: the GRID panel's shift, MARK, double/halve, tempo, tap, undo
/// and lock. Every edit goes through the core's write gate and one at a time; the deck redraws
/// from `gridChanged`, never ahead of it.
@MainActor @Observable
final class GridEditModel {
    static let shiftMs: Int32 = 1
    static let heldShiftMs: Int32 = 10
    static let bpmMessage = "Enter a BPM from 40 to 499."

    private(set) var state: GridState?
    /// The BPM the taps say so far (x100), for the TAP button's readout.
    private(set) var tapBpmX100: Int?
    private(set) var busy = false

    @ObservationIgnored private weak var owner: DeckModel?
    @ObservationIgnored private var taps: [Double] = []
    @ObservationIgnored private var tapAnchor = 0.0
    @ObservationIgnored private var tapRun = 0
    @ObservationIgnored private let session = UUID().uuidString
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var tapTimer: Task<Void, Never>?

    init(deck: DeckModel) { owner = deck }

    var hasGrid: Bool { owner?.track != nil && (state?.beats ?? 0) > 0 }
    var canEdit: Bool { hasGrid && owner?.canWrite() == true && state?.locked != true }
    var locked: Bool { state?.locked == true }

    /// The playhead as the grid's unsigned milliseconds (before the start is the start).
    private var playheadMs: UInt32 {
        guard let deck = owner else { return 0 }
        return UInt32(max(0, (deck.position(at: deck.now()) * 1000).rounded()))
    }

    func trackChanged() {
        state = nil
        cancelTaps()
        Task { await refresh() }
    }

    func refresh() async {
        guard let deck = owner, let backend = deck.backend, let id = deck.track?.id, deck.track?.analysed == true else {
            state = nil
            return
        }
        let fresh = try? await backend.gridState(trackID: id)
        if owner?.track?.id == id { state = fresh }
    }

    /// Waits for the edits queued so far. For tests.
    func settle() async { await queue?.value }

    private func run(_ work: @escaping @Sendable (any BackendProtocol, String) async throws -> GridState) {
        guard let backend = owner?.backend, let id = owner?.track?.id else { return }
        let previous = queue
        busy = true
        queue = Task { [weak self] in
            await previous?.value
            guard let self, self.owner?.track?.id == id else { return }
            do {
                let next = try await work(backend, id)
                if self.owner?.track?.id == id { self.state = next }
                self.owner?.report("")
            } catch {
                self.owner?.report(describe(error))
            }
            self.busy = false
        }
    }

    private func edit(_ change: GridEdit, transaction: String? = nil) {
        guard canEdit else { return }
        run { backend, id in
            try await backend.gridEdit(trackID: id, edit: change, fromMs: nil, transaction: transaction)
        }
    }

    /// Shift the whole grid 1 ms (10 ms when held); positive is later.
    func shift(_ direction: Int, held: Bool = false) {
        edit(.nudge(ms: Int32(direction) * (held ? Self.heldShiftMs : Self.shiftMs)))
    }

    /// MARK: the beat nearest the playhead becomes the downbeat.
    func mark() { edit(.downbeat(timeMs: playheadMs)) }

    /// Shift Beatgrid to the center: the beat nearest the playhead lands on it.
    func alignToPlayhead() { edit(.align(timeMs: playheadMs)) }

    func double() { edit(.double) }
    func halve() { edit(.halve) }

    /// A typed BPM, 40 to 499.
    func setBPM(_ text: String) {
        guard let bpm = Double(text.trimmingCharacters(in: .whitespaces)), bpm.isFinite, bpm >= 40, bpm <= 499 else {
            owner?.report(Self.bpmMessage)
            return
        }
        edit(.tempo(bpmX100: UInt16((bpm * 100).rounded()), anchorMs: 0))
    }

    /// One tap of TAP. Two or more taps in a run set the tempo; a run is one undo step.
    func tap(nowMs: Double = ProcessInfo.processInfo.systemUptime * 1000) {
        guard canEdit else { return }
        taps = TapTempo.adding(taps, now: nowMs)
        if taps.count == 1 {
            tapAnchor = Double(playheadMs)
            tapRun += 1
        }
        tapBpmX100 = TapTempo.bpmX100(taps)
        tapTimer?.cancel()
        if !taps.isEmpty {
            let wait = TapTempo.timeout(taps)
            tapTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(wait))
                if !Task.isCancelled { self?.cancelTaps() }
            }
        }
        guard tapBpmX100 != nil, let first = taps.first, let last = taps.last else { return }
        let bpm = 60_000 * Double(taps.count - 1) / (last - first)
        let anchor = UInt32(tapAnchor)
        edit(.tap(bpm: bpm, anchorMs: anchor), transaction: "\(session):\(owner?.deck == .b ? "B" : "A"):\(owner?.track?.id ?? ""):\(tapRun)")
    }

    func cancelTaps() {
        tapTimer?.cancel()
        tapTimer = nil
        taps = []
        tapBpmX100 = nil
    }

    func undo() {
        guard hasGrid, owner?.canWrite() == true else { return }
        cancelTaps()
        run { backend, id in try await backend.gridUndo(trackID: id) }
    }

    func redo() {
        guard hasGrid, owner?.canWrite() == true else { return }
        cancelTaps()
        run { backend, id in try await backend.gridRedo(trackID: id) }
    }

    /// Analysis Lock on or off for the loaded track.
    func toggleLock() {
        guard hasGrid, owner?.canWrite() == true, let state else { return }
        cancelTaps()
        let on = !state.locked
        run { backend, id in try await backend.gridLock(trackID: id, on: on) }
    }
}
