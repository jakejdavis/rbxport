import AppKit
import Foundation

// Slice 4c: writing cues, from the pads and the MEMORY cluster. Every write goes through the
// core's write gate; nothing is drawn ahead of the backend, which announces `cuesChanged` and the
// deck re-reads the track's cues.

/// The colours a cue can take, from `CueColorMenu.tsx`.
enum CueColours {
    /// rekordbox's compact 4 x 4 hot cue picker, in its displayed order: ColorTableIndex and the colour drawn.
    static let hot: [(value: UInt8, hex: UInt32)] = [
        (49, 0xDE44CF), (56, 0xB432FF), (60, 0xAA72FF), (62, 0x6473FF),
        (1, 0x305AFF), (3, 0x508CFF), (9, 0x00E0FF), (15, 0x19A08C),
        (18, 0x10B176), (22, 0x28E214), (26, 0xA5E116), (30, 0xB4BE04),
        (32, 0xC3AF04), (38, 0xE0641B), (41, 0xE02823), (46, 0xF51E8C),
    ]
    /// The eight named memory cue colours, stored as the index 0 to 7.
    static let memory: [(name: String, hex: UInt32)] = [
        ("Pink", 0xE778F1), ("Red", 0xE33122), ("Orange", 0xEBA44A), ("Yellow", 0xF4E458),
        ("Green", 0x66DD42), ("Aqua", 0x56BDF3), ("Blue", 0x204FEF), ("Purple", 0x8B1EEF),
    ]

    /// A round swatch for a menu item (not a template, so the menu keeps its colour).
    @MainActor static func swatch(_ hex: UInt32) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            ).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// What a pad press means before any write: a set pad calls its cue, an empty one is set.
enum PadPress: Equatable, Sendable {
    case call(DeckCue)
    case set
}

extension CueLookup {
    static func padPress(_ cues: [DeckCue], letter: String) -> PadPress {
        hot(cues, letter: letter).map(PadPress.call) ?? .set
    }

    /// The memory cue the playhead is standing on, if any.
    static func memoryCue(_ cues: [DeckCue], at positionMs: Double) -> DeckCue? {
        memory(cues).first { abs($0.positionMs - positionMs) <= toleranceMs }
    }
}

/// Counts the seconds a deck has really played its track, to record a play at the threshold the
/// React player uses (60 s, once per load, pauses do not count).
struct PlayClock: Equatable, Sendable {
    static let threshold = 60.0
    private(set) var seconds = 0.0
    private(set) var recorded = false
    private var last: TimeInterval?

    /// A tick at `time`. True exactly once, when the threshold is crossed.
    mutating func advance(playing: Bool, at time: TimeInterval) -> Bool {
        defer { last = time }
        guard playing, let last, time > last else { return false }
        // A long gap between ticks (a stalled app) is not listening time.
        seconds += min(time - last, 1)
        if !recorded, seconds >= Self.threshold {
            recorded = true
            return true
        }
        return false
    }

    mutating func reset() { self = PlayClock() }
}

extension DeckModel {
    /// A loaded track whose cues the library may be asked to change.
    var canEditCues: Bool { track != nil && isLoaded && canWrite() }

    /// One cue write at a time: a held key repeats thirty times a second and each repeat used
    /// to be another cue. The failure goes to `report`; a landing write clears it.
    func writeCue(_ work: @escaping @Sendable (any BackendProtocol, String) async throws -> Void) {
        guard !cueWriteInFlight, let backend, let id = track?.id else { return }
        cueWriteInFlight = true
        writeTask = Task { [weak self] in
            do {
                try await work(backend, id)
                self?.report("")
            } catch {
                self?.report(describe(error))
            }
            self?.cueWriteInFlight = false
        }
    }

    /// Waits for the write in flight. For tests.
    func settleWrites() async { await writeTask?.value }

    /// Set Hot Cue: an empty pad takes the playhead (on the grid when Q is on).
    func setHotCue(_ letter: String) {
        guard canEditCues, CueLookup.hot(cues, letter: letter) == nil else { return }
        let at = UInt32(max(snapped(position(at: now()) * 1000), 0).rounded())
        writeCue { backend, id in _ = try await backend.addCue(trackID: id, slot: .hot(letter: letter), positionMs: at) }
    }

    /// Clear Hot Cue.
    func clearHotCue(_ letter: String) {
        guard canEditCues, let cue = CueLookup.hot(cues, letter: letter), !cue.id.isEmpty else { return }
        deleteCue(cue)
    }

    func deleteCue(_ cue: DeckCue) {
        guard canEditCues, !cue.id.isEmpty else { return }
        let id = cue.id
        writeCue { backend, _ in try await backend.deleteCue(cueID: id) }
    }

    /// Recolours a cue: a hot cue's ColorTableIndex, or a memory cue's index 0 to 7; nil resets.
    func recolour(_ cue: DeckCue, to colour: UInt8?) {
        guard canEditCues, !cue.id.isEmpty else { return }
        let id = cue.id
        writeCue { backend, _ in try await backend.setCueColour(cueID: id, colour: colour) }
    }

    /// Set Memory Cue: the cue point, or the active loop as a memory loop. Nothing is written
    /// where a memory cue already sits.
    func storeMemoryCue() {
        guard canEditCues else { return }
        if let loop, loop.active, loop.outMs > loop.inMs {
            if CueLookup.memory(cues).contains(where: { abs($0.positionMs - loop.inMs) <= CueLookup.toleranceMs && $0.isLoop }) { return }
            let (a, b) = (UInt32(loop.inMs.rounded()), UInt32(loop.outMs.rounded()))
            let beats = UInt16(clamping: Int(loopLength.rounded()))
            writeCue { backend, id in _ = try await backend.addLoop(trackID: id, slot: .memory, inMs: a, outMs: b, beats: beats) }
            return
        }
        let at = max(cue.cueMs, 0)
        if CueLookup.memoryCue(cues, at: at) != nil { return }
        let ms = UInt32(at.rounded())
        writeCue { backend, id in _ = try await backend.addCue(trackID: id, slot: .memory, positionMs: ms) }
    }

    /// Delete Memory Cue: the one under the playhead.
    func deleteMemoryAtHead() {
        guard let target = CueLookup.memoryCue(cues, at: position(at: now()) * 1000) else { return }
        deleteCue(target)
    }

    /// Convert Memory Cues to Hot Cues for the loaded track.
    func convertMemoryToHot() {
        guard canEditCues else { return }
        writeCue { backend, id in _ = try await backend.convertMemoryCuesToHot(trackID: id) }
    }

    // MARK: Library events

    /// `cuesChanged` named this deck's track: read the cues again.
    func refreshCues() {
        guard let backend, let id = track?.id else { return }
        cuesRefresh?.cancel()
        cuesRefresh = Task { [weak self] in
            guard let list = try? await backend.trackCues(id: id), !Task.isCancelled, let self, self.track?.id == id else { return }
            self.install(cues: list.map(DeckCue.init))
        }
    }

    /// Waits for a refresh in flight. For tests.
    func settleRefresh() async { await cuesRefresh?.value }

    /// `gridChanged`: the beats again, the grid editor's state, and the metronome's grid.
    func refreshGrid() {
        guard let backend, let id = track?.id else { return }
        gridRefresh?.cancel()
        gridRefresh = Task { [weak self] in
            if let beats = try? await backend.trackBeats(id: id), !Task.isCancelled, let self, self.track?.id == id {
                self.install(beats: BeatGrid(beats: beats))
                self.playback.refreshMetronomeGrid(deck: self.deck)
            }
            await self?.grid.refresh()
        }
    }

    func settleGridRefresh() async { await gridRefresh?.value }

    /// A play counts once its track has been heard for a minute. Fed by the engine's ticks.
    func notePlayTime(at time: TimeInterval) {
        guard playClock.advance(playing: anchor.playing, at: time), let backend, let id = track?.id,
            canWrite(), recordsHistory
        else { return }
        playRecord = Task { _ = try? await backend.recordPlay(trackID: id) }
    }
}
