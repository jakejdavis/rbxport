import AppKit
import Foundation
import Testing

@testable import rbxport

// MARK: - Beat grid math

@Suite(.scratchDefaults)
struct BeatGridTests {
    /// 120 BPM from 500 ms: a beat every 500 ms, beats numbered 1 to 4.
    static func grid(beats: Int = 64, startMs: UInt32 = 500, periodMs: UInt32 = 500) -> BeatGrid {
        BeatGrid(
            times: (0..<beats).map { startMs + UInt32($0) * periodMs },
            numbers: (0..<beats).map { UInt8($0 % 4 + 1) }, tempos: Array(repeating: 12_000, count: beats))
    }

    @Test func beatsInAWindowAreFoundByBinarySearch() {
        let grid = Self.grid()
        let window = grid.beats(from: 1_000, to: 3_000)
        #expect(window.map(\.timeMs) == [1_000, 1_500, 2_000, 2_500, 3_000])
        #expect(window.map(\.downbeat) == [false, false, false, true, false])
        #expect(grid.beats(from: 5, to: 1).isEmpty)
        #expect(BeatGrid.empty.beats(from: 0, to: 10_000).isEmpty)
    }

    @Test func tempoAndNearestBeat() {
        let grid = Self.grid()
        #expect(grid.tempoAt(0) == 12_000)
        #expect(grid.nearestBeatMs(1_240) == 1_000)
        #expect(grid.nearestBeatMs(1_260) == 1_500)
        #expect(grid.nearestBeatMs(10) == 500)
        #expect(grid.nearestBeatMs(999_999) == Double(grid.times.last!))
        #expect(BeatGrid.empty.nearestBeatMs(123) == 123)
    }

    @Test func subdividingAddsTheOffBeats() {
        let grid = BeatGrid(times: [0, 500, 1_000], numbers: [1, 2, 3], tempos: [12_000, 12_000, 12_000])
        let half = grid.subdivided(2)
        #expect(half.times == [0, 250, 500, 750, 1_000])
        #expect(half.numbers == [1, 1, 2, 2, 3])
        #expect(grid.subdivided(1) == grid)
        #expect(BeatGrid.empty.subdivided(4) == .empty)
    }

    @Test func barPositionReadsBarsAndBeats() {
        // First downbeat at 500 ms.
        let grid = Self.grid()
        #expect(grid.barText(seconds: 0.5, fallbackBpm: 120) == "1.1 Bars")
        #expect(grid.barText(seconds: 0.99, fallbackBpm: 120) == "1.1 Bars")
        #expect(grid.barText(seconds: 1.0, fallbackBpm: 120) == "1.2 Bars")
        #expect(grid.barText(seconds: 2.5, fallbackBpm: 120) == "2.1 Bars")
        #expect(grid.barText(seconds: 6.75, fallbackBpm: 120) == "4.1 Bars")
        // The beat before 1.1 reads -1.4; there is no bar zero.
        #expect(grid.barText(seconds: 0.2, fallbackBpm: 120) == "-1.4 Bars")
        // Without a grid the file's BPM counts from zero; with neither, blank.
        #expect(BeatGrid.empty.barText(seconds: 2.5, fallbackBpm: 120) == "2.2 Bars")
        #expect(BeatGrid.empty.barText(seconds: 2.5, fallbackBpm: 0) == "")
    }

    @Test func beatPositionAndTimeAreInverses() throws {
        let grid = Self.grid()
        #expect(grid.beatPosition(ms: 500) == 0)
        #expect(grid.beatPosition(ms: 750) == 0.5)
        #expect(try #require(grid.time(atBeatPosition: 2.25)) == 1_625)
        // Beyond the ends the first and last beat's own length carries on.
        #expect(grid.beatPosition(ms: 0) == -1)
        #expect(try #require(grid.time(atBeatPosition: -2)) == -500)
        let last = Double(grid.times.last!)
        #expect(try #require(grid.time(atBeatPosition: 64)) == last + 500)
        #expect(BeatGrid(times: [1], numbers: [1], tempos: [1]).beatPosition(ms: 5) == nil)
    }

    @Test func jumpsLandOnTheBeat() {
        let grid = Self.grid()
        let four = JumpSize.byID("4beats")
        // From mid-beat, a 4 beat jump keeps the offset into the beat.
        #expect(BeatJump.target(fromMs: 1_250, direction: 1, size: four, grid: grid, bpmX100: 12_000, durationMs: 200_000) == 3_250)
        #expect(BeatJump.target(fromMs: 3_250, direction: -1, size: four, grid: grid, bpmX100: 12_000, durationMs: 200_000) == 1_250)
        // Clamped to the track.
        #expect(BeatJump.target(fromMs: 1_000, direction: -1, size: four, grid: grid, bpmX100: 12_000, durationMs: 200_000) == 0)
        #expect(BeatJump.target(fromMs: 199_000, direction: 1, size: JumpSize.byID("32bars"), grid: grid, bpmX100: 12_000, durationMs: 200_000) == 200_000)
        // Fine is a flat 10 ms.
        #expect(BeatJump.target(fromMs: 1_000, direction: 1, size: JumpSize.byID("fine"), grid: grid, bpmX100: 12_000, durationMs: 200_000) == 1_010)
        // No grid: the file's BPM sets the distance (120 BPM: a beat is 500 ms).
        #expect(BeatJump.target(fromMs: 10_000, direction: 1, size: JumpSize.byID("8beats"), grid: .empty, bpmX100: 12_000, durationMs: 200_000) == 14_000)
        // No grid and no tempo: stay put.
        #expect(BeatJump.target(fromMs: 10_000, direction: 1, size: four, grid: .empty, bpmX100: 0, durationMs: 200_000) == 10_000)
    }

    @Test func jumpSizesFollowRekordbox() {
        #expect(JumpSize.all.map(\.label) == ["Fine", "4Beats", "8Beats", "16Beats", "8Bars", "16Bars", "32Bars"])
        #expect(JumpSize.all.map(\.beats) == [0, 4, 8, 16, 32, 64, 128])
        #expect(JumpSize.byID("nonsense") == JumpSize.default)
        #expect(JumpSize.default.id == "4beats")
    }

    @Test func beatLoopsSnapToTheGridWhenQuantized() throws {
        let grid = Self.grid()
        // Q on: the in point goes to the nearest beat and the out is four beats later on the grid.
        let snapped = try #require(grid.beatLoopRange(snapTo: grid, atMs: 1_240, beats: 4))
        #expect(snapped.inMs == 1_000 && snapped.outMs == 3_000)
        // Q off: from where the head is, a grid-length later.
        let free = try #require(grid.beatLoopRange(snapTo: nil, atMs: 1_240, beats: 4))
        #expect(free.inMs == 1_240 && free.outMs == 3_240)
        // Fractions of a beat.
        let quarter = try #require(grid.beatLoopRange(snapTo: grid, atMs: 1_000, beats: 0.25))
        #expect(quarter.inMs == 1_000 && quarter.outMs == 1_125)
        // Quantize at half a beat snaps to the off-beats.
        let halves = grid.subdivided(2)
        let off = try #require(grid.beatLoopRange(snapTo: halves, atMs: 1_240, beats: 1))
        #expect(off.inMs == 1_250)
        #expect(BeatGrid.empty.beatLoopRange(snapTo: nil, atMs: 0, beats: 4) == nil)
        #expect(grid.beatLoopRange(snapTo: nil, atMs: 0, beats: 0) == nil)
    }
}

// MARK: - Loops, zoom, pads, cues, keys

@Suite(.scratchDefaults)
struct ControlLogicTests {
    @Test func loopLengthsHalveAndDoubleWithinTheirLimits() {
        #expect(LoopLength.sizes == [0.25, 0.5, 1, 2, 4, 8, 16, 32])
        #expect(LoopLength.halved(4) == 2)
        #expect(LoopLength.halved(0.25) == 0.25)
        #expect(LoopLength.doubled(4) == 8)
        #expect(LoopLength.doubled(32) == 32)
        #expect(LoopLength.label(0.25) == "1/4")
        #expect(LoopLength.label(0.5) == "1/2")
        #expect(LoopLength.label(16) == "16")
        #expect((4...9).compactMap(LoopLength.beats(forDigit:)) == [1, 2, 4, 8, 16, 32])
        #expect(LoopLength.beats(forDigit: 3) == nil)
    }

    @Test func zoomStepsFollowReactAndClamp() {
        #expect(DetailZoom.steps == [0.25, 0.5, 1, 2, 4, 8, 12, 16, 32, 64])
        #expect(DetailZoom.default == 12)
        #expect(DetailZoom.step(12, direction: -1) == 8)
        #expect(DetailZoom.step(12, direction: 1) == 16)
        #expect(DetailZoom.step(0.25, direction: -1) == 0.25)
        #expect(DetailZoom.step(64, direction: 1) == 64)
        #expect(DetailZoom.step(5, direction: 1) == 16)  // not a step: from the default
        #expect(DetailZoom.clamped(9) == 8)
        #expect(DetailZoom.clamped(.nan) == 12)
        #expect(DetailZoom.showsEveryBeat(32))
        #expect(!DetailZoom.showsEveryBeat(64))
    }

    @Test func theWheelGateStepsLikeAMouseNotchOrATrackpadSwipe() {
        var gate = WheelZoomGate()
        // A notch always steps, whatever the cooldown.
        #expect(gate.feed(deltaPx: 120, nowMs: 1_000) == 1)
        #expect(gate.feed(deltaPx: -120, nowMs: 1_010) == -1)
        // Small trackpad deltas accumulate to a step, then cool down.
        var steps = 0
        for i in 0..<10 { steps += gate.feed(deltaPx: 30, nowMs: 2_000 + Double(i) * 5) }
        #expect(steps == 1)
        // Reversing discards travel; a pause starts a new gesture.
        #expect(gate.feed(deltaPx: -60, nowMs: 3_000) == 0)
        #expect(gate.feed(deltaPx: 60, nowMs: 3_010) == 0)
        #expect(gate.feed(deltaPx: 60, nowMs: 3_020) == 1)
        #expect(gate.feed(deltaPx: 0, nowMs: 4_000) == 0)
    }

    @Test func detailGeometry() {
        // 12 bars at 120 BPM is 24 s.
        #expect(DetailGeometry.spanSeconds(bars: 12, bpmX100: 12_000, durationSec: 200) == 24)
        // Never more than the track.
        #expect(DetailGeometry.spanSeconds(bars: 64, bpmX100: 12_000, durationSec: 30) == 30)
        // No tempo: eight percent of the track.
        #expect(DetailGeometry.spanSeconds(bars: 12, bpmX100: 0, durationSec: 200) == 16)
        // Dragging right pulls earlier music in, so the head goes back; the span sets the rate.
        #expect(abs(DetailGeometry.dragSeconds(dx: 100, width: 1_000, spanSeconds: 24) - -2.4) < 1e-9)
        #expect(abs(DetailGeometry.dragSeconds(dx: -100, width: 1_000, spanSeconds: 24) - 2.4) < 1e-9)
        #expect(DetailGeometry.dragSeconds(dx: 5, width: 0, spanSeconds: 24) == 0)
        #expect(DetailGeometry.contentOffset(position: 10, pixelsPerSecond: 40, viewWidth: 800) == 0)
        #expect(DetailGeometry.contentOffset(position: 0, pixelsPerSecond: 40, viewWidth: 800) == 400)
    }

    @Test func tilesCoverTheWindowAndStayInsideTheTrack() throws {
        // 100 px/s, 1000 px view: the window is 10 s; a tile is 1024 px.
        let mid = try #require(DetailGeometry.visibleTiles(position: 50, pixelsPerSecond: 100, viewWidthPx: 1_000, duration: 200, margin: 0))
        #expect(mid == 4...5)  // 4500...5500 px
        let wide = try #require(DetailGeometry.visibleTiles(position: 50, pixelsPerSecond: 100, viewWidthPx: 1_000, duration: 200, margin: 1))
        #expect(wide == 3...6)
        let start = try #require(DetailGeometry.visibleTiles(position: 0, pixelsPerSecond: 100, viewWidthPx: 1_000, duration: 200, margin: 1))
        #expect(start.lowerBound == 0)
        // The last tile of a 200 s track at 100 px/s is floor(20000 / 1024) = 19.
        let end = try #require(DetailGeometry.visibleTiles(position: 200, pixelsPerSecond: 100, viewWidthPx: 1_000, duration: 200, margin: 2))
        #expect(end.upperBound == 19)
        #expect(DetailGeometry.visibleTiles(position: 0, pixelsPerSecond: 0, viewWidthPx: 1_000, duration: 200) == nil)
    }

    @Test func columnsMapToPixelsOnTheWaveformsClock() {
        // 150 columns a second: at 300 px/s two pixels share a column, at 75 two columns share a pixel.
        let zoomedIn = DetailRenderer.columnWindow(pixel: 300, pps: 300, originSec: 0)
        #expect(zoomedIn.first == 150 && zoomedIn.step == 0.5)
        let zoomedOut = DetailRenderer.columnWindow(pixel: 75, pps: 75, originSec: 0)
        #expect(zoomedOut.first == 150 && zoomedOut.step == 2)
        // A waveform whose clock runs 20 ms ahead shows the same column earlier.
        let shifted = DetailRenderer.columnWindow(pixel: 0, pps: 150, originSec: 0.02)
        #expect(abs(shifted.first - 3) < 1e-9)
    }

    @Test func theWaveformsOriginIsOnlyCorrectedAtTheStartOfTheFile() {
        // Silent for 3 columns (20 ms) then an attack, first beat at 0: the audio starts 3.5 columns in.
        var bytes = Data(count: 3 * 3)
        bytes.append(contentsOf: [10, 0, 0])
        bytes.append(Data(count: 30))
        let correction = DetailGeometry.originMs(firstBeatMs: 0, bytes: bytes, stride: 3)
        #expect(abs(correction - 3.5 / 150 * 1000) < 1e-9)
        // An intro before the first beat is not an encoder delay.
        #expect(DetailGeometry.originMs(firstBeatMs: 500, bytes: bytes, stride: 3) == 0)
        #expect(DetailGeometry.originMs(firstBeatMs: nil, bytes: bytes, stride: 3) == 0)
        // Nothing silent first: nothing to correct.
        #expect(DetailGeometry.originMs(firstBeatMs: 0, bytes: Data([1, 0, 0, 1, 0, 0]), stride: 3) == 0)
    }

    @Test func bandSegmentsLayerTheColoursByReach() {
        let all = DetailRenderer.segments(low: 127, mid: 127, high: 127, full: 50)
        #expect(all.count == 1 && all[0].reach == 50 && all[0].bands == 7)
        // Low reaches furthest, then mid, then high: outside in, each stretch the bands that reach it.
        let layered = DetailRenderer.segments(low: 100, mid: 60, high: 20, full: 100)
        #expect(layered.map(\.bands) == [1, 3, 7])
        #expect(layered.map(\.reach).first! > layered.map(\.reach).last!)
        // A quiet band still draws half a pixel; a silent one nothing.
        #expect(DetailRenderer.segments(low: 1, mid: 0, high: 0, full: 10)[0].reach == 0.5)
        #expect(DetailRenderer.segments(low: 0, mid: 0, high: 0, full: 10).isEmpty)
    }

    @Test func aTileDrawsTheWaveformAndTheGridWhereTheyBelong() throws {
        // A loud second then silence, at 150 columns a second.
        var bytes = Data()
        for column in 0..<450 { bytes.append(contentsOf: column < 150 ? [127, 127, 127] : [0, 0, 0]) }
        let grid = BeatGridTests.grid(beats: 8, startMs: 0, periodMs: 500)
        let image = try #require(
            DetailRenderer.render(
                .init(
                    bytes: bytes, palette: .bands, originSec: 0, pps: 150, tileIndex: 0, tileWidth: 512, heightPx: 120,
                    scale: 1, grid: grid, everyBeat: true)))
        #expect(image.width == 512 && image.height == 120)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let data = image.dataProvider!.data! as Data
            let o = y * image.bytesPerRow + x * 4
            return Array(data[o..<(o + 4)])
        }
        // Loud: cream core in the middle, opaque. Silent part: only the reference line.
        #expect(pixel(40, 60) == [0xF5, 0xEB, 0xD7, 255])
        #expect(pixel(200, 30)[3] == 0)
        // The beat at 500 ms is x = 75: a grey line; the downbeat at 0 is white.
        #expect(pixel(75, 30) == [0x4C, 0x4C, 0x4C, 255])
        #expect(pixel(0, 30) == [255, 255, 255, 255])
        #expect(DetailRenderer.render(.init(bytes: Data(), palette: .bands, originSec: 0, pps: 0, tileIndex: 0, tileWidth: 512, heightPx: 120, scale: 1, grid: .empty, everyBeat: true)) == nil)
    }

    @Test func colourDetailColumnsDecode() {
        // rrrgggbbhhhhh00: red 7, green 0, blue 0, height 31.
        let column = DetailRenderer.colourDetailColumn(0b1110_0000, 0b0111_1100)
        #expect(column.height == 1)
        #expect(column.colour == RGB(255, 0, 0))
    }

    @Test func palettesReadTheirDetailTags() {
        #expect(WaveformPalette.bands.detailKind == .bandsDetail && WaveformPalette.bands.detailStride == 3)
        #expect(WaveformPalette.mono.detailKind == .monoDetail && WaveformPalette.mono.detailStride == 1)
        #expect(WaveformPalette.colour.detailKind == .colourDetail && WaveformPalette.colour.detailStride == 2)
    }

    // MARK: Pads and cues

    @Test func aPadPressedWhilePlayingJumpsAndKeepsPlaying() {
        var pad = PadMachine()
        #expect(pad.press(letter: "B", cueMs: 8_000, playing: true) == [.seek(8_000)])
        #expect(pad.heldLetter == nil)
        #expect(pad.release().isEmpty)
    }

    @Test func aPadPressedFromAPausePlaysWhileHeldThenReturns() {
        var pad = PadMachine()
        #expect(pad.press(letter: "A", cueMs: 4_000, playing: false) == [.seek(4_000), .play])
        #expect(pad.heldLetter == "A")
        #expect(pad.release() == [.seek(4_000), .pause])
        #expect(pad.heldLetter == nil)
        #expect(pad.release().isEmpty)
    }

    @Test func takingOverFromAHeldPadLatchesIt() {
        var pad = PadMachine()
        _ = pad.press(letter: "C", cueMs: 1_000, playing: false)
        pad.latch()
        #expect(pad.release().isEmpty)
    }

    @Test func cuesAreLookedUpByLetterAndOrderedByPosition() {
        let cues = [
            DeckCue(positionMs: 30_000, memory: true), DeckCue(positionMs: 10_000, memory: true),
            DeckCue(positionMs: 20_000, letter: "B", memory: false), DeckCue(positionMs: 5_000, letter: "B", memory: false),
            DeckCue(positionMs: 1_000, letter: "A", memory: false, colour: RGB(1, 2, 3)),
            DeckCue(positionMs: 50_000, outMs: 60_000, memory: true),
        ]
        #expect(CueLookup.hot(cues, letter: "B")?.positionMs == 5_000)  // the earlier of a doubled slot
        #expect(CueLookup.hot(cues, letter: "C") == nil)
        #expect(CueLookup.hot(cues, letter: "A")?.drawColour == RGB(1, 2, 3))
        #expect(CueLookup.hot(cues, letter: "B")?.drawColour == DeckCue.defaultHotColour)
        #expect(CueLookup.memory(cues).map(\.positionMs) == [10_000, 30_000, 50_000])
        #expect(CueLookup.memory(cues, number: 2)?.positionMs == 30_000)
        #expect(CueLookup.memory(cues, number: 0) == nil && CueLookup.memory(cues, number: 4) == nil)
        #expect(CueLookup.memory(cues).last?.isLoop == true)
        // Strictly beyond the tolerance, so calling a cue and pressing again moves on.
        #expect(CueLookup.nextMemory(cues, positionMs: 10_000)?.positionMs == 30_000)
        #expect(CueLookup.nextMemory(cues, positionMs: 10_015)?.positionMs == 30_000)
        #expect(CueLookup.previousMemory(cues, positionMs: 30_000)?.positionMs == 10_000)
        #expect(CueLookup.previousMemory(cues, positionMs: 10_010) == nil)
        #expect(CueLookup.nextMemory(cues, positionMs: 60_000) == nil)
    }

    @Test func aLibraryCueBecomesADeckCue() {
        let cue = DeckCue(Cue(id: "9", positionMs: 1_500, outMs: 0, letter: "D", memory: false, colour: "#DE44CF", comment: "drop"))
        #expect(cue.letter == "D" && cue.positionMs == 1_500 && cue.colour == RGB(0xDE, 0x44, 0xCF) && cue.comment == "drop")
        let hot = DeckCue(HotCue(slot: "E", positionMs: 90, color: nil))
        #expect(hot.letter == "E" && hot.colour == nil && !hot.memory)
    }

    // MARK: Key shift, phrases, meters

    @Test func keysTransposeInTheirOwnNotation() {
        #expect(KeyTranspose.transpose("Am", semitones: 2) == "Bm")
        #expect(KeyTranspose.transpose("Am", semitones: -1) == "G#m")
        #expect(KeyTranspose.transpose("C", semitones: 7) == "G")
        #expect(KeyTranspose.transpose("Ebm", semitones: 12) == "Ebm")
        // Camelot stays Camelot: 8A is Am, +2 is Bm, 10A.
        #expect(KeyTranspose.transpose("8A", semitones: 2) == "10A")
        #expect(KeyTranspose.transpose("8B", semitones: 7) == "9B")
        #expect(KeyTranspose.transpose("", semitones: 3) == "")
        #expect(KeyTranspose.transpose("nonsense", semitones: 3) == "nonsense")
    }

    @Test func phraseLabelsMapToKindsAndSpans() {
        #expect(PhraseKind.of(label: "UP 2") == .up2)
        #expect(PhraseKind.of(label: "UP 3") == .up3)
        #expect(PhraseKind.of(label: "UP") == .up)
        #expect(PhraseKind.of(label: "Chorus 1") == .chorus)
        #expect(PhraseKind.of(label: "OUTRO") == .outro)
        #expect(PhraseKind.of(label: "???") == .verse)
        let phrases = [
            Phrase(beat: 9, label: "VERSE 1", kind: 1, timeMs: nil), Phrase(beat: 1, label: "INTRO", kind: 1, timeMs: 0),
            Phrase(beat: 33, label: "CHORUS", kind: 1, timeMs: 16_000),
        ]
        // The unresolved one (beat 9) is placed at 1 s a beat; each runs to the next.
        let spans = PhraseSpan.spans(phrases, totalMs: 32_000, beatMs: 1_000)
        #expect(spans.map(\.label) == ["INTRO", "VERSE 1", "CHORUS"])
        #expect(spans.map(\.from) == [0, 0.25, 0.5])
        #expect(spans.map(\.to) == [0.25, 0.5, 1])
        // No time and no tempo: dropped rather than stacked at zero.
        #expect(PhraseSpan.spans(phrases, totalMs: 32_000, beatMs: 0).map(\.label) == ["INTRO", "CHORUS"])
        #expect(PhraseSpan.spans(phrases, totalMs: 0, beatMs: 1_000).isEmpty)
    }

    @Test func meterBallisticsAttackAtOnceAndFallTwentyDecibelsASecond() {
        var meter = MeterBallistics()
        meter.step(peak: 1, dt: 0.016)
        #expect(meter.db == 0 && meter.height == 1)
        meter.step(peak: 0, dt: 0.5)
        #expect(abs(meter.db - -10) < 1e-9)
        // The marker holds for two seconds, then follows.
        #expect(meter.markerDb == 0)
        meter.step(peak: 0, dt: 1.4)
        #expect(meter.markerDb == 0)
        meter.step(peak: 0, dt: 0.2)
        meter.step(peak: 0, dt: 0.5)
        #expect(meter.markerDb < 0)
        // Below -44 dB the bar is empty; silence is below the threshold.
        #expect(MeterBallistics.height(db: -44) == 0)
        #expect(MeterBallistics.height(db: -22) == 0.5)
        #expect(MeterBallistics.db(of: 0.0005) == -100)
        var quiet = MeterBallistics()
        quiet.step(peak: 0, dt: 1)
        #expect(!quiet.isActive)
    }

    // MARK: Keymap

    private func action(_ char: String, _ code: UInt16 = 0, mods: NSEvent.ModifierFlags = [], up: Bool = false, repeating: Bool = false, typing: Bool = false, loaded: Bool = true) -> PlayerKeyAction? {
        PlayerKeymap.action(
            for: KeyChord(character: char, keyCode: code, modifiers: mods), isUp: up, isRepeat: repeating, typing: typing,
            loaded: loaded)
    }

    @Test func thePlayerGroupMapsToDeckA() {
        #expect(action("q") == .quantize)
        #expect(action("b") == .memoryPrevious && action("n") == .memoryNext)
        #expect(action("i") == .loopIn && action("o") == .loopOut && action("r") == .reloop)
        #expect(action("/") == .loopHalve)
        #expect(action("\\", mods: .option) == .loopDouble)
        #expect(action("\\") == nil)
        #expect(["4", "5", "6", "7", "8", "9"].compactMap { action($0) } == [1, 2, 4, 8, 16, 32].map { .beatLoop($0) })
        #expect(["a", "s", "d", "f", "g", "h", "j", "k", "l", ";"].compactMap { action($0) } == (1...10).map { .memoryNumber($0) })
        #expect(action("1") == .hotCueDown("A") && action("2") == .hotCueDown("B") && action("3") == .hotCueDown("C"))
        #expect(action("1", up: true) == .hotCueUp)
        #expect(action("=") == .zoom(-1) && action("-") == .zoom(1))
        #expect(action("", PlayerKeymap.left) == .jump(-1) && action("", PlayerKeymap.right) == .jump(1))
        #expect(action("", PlayerKeymap.f2) == .masterTempo && action("", PlayerKeymap.f3) == .tempoReset)
        #expect(action("", PlayerKeymap.f6) == .bpmDown && action("", PlayerKeymap.f7) == .bpmUp)
        #expect(action("", PlayerKeymap.f9) == .metronomeSound)
    }

    @Test func writesAreSwallowedNotPerformed() {
        // M (store) and X (delete) are library writes: consumed, nothing done.
        #expect(action("m") == .swallow && action("x") == .swallow)
        // Cmd+1..3 (clear hot cue) and the grid editor's Cmd chords belong to the menus.
        #expect(action("1", mods: .command) == nil)
        #expect(action("", PlayerKeymap.left, mods: .command) == nil)
        // Shift is deck B.
        #expect(action("q", mods: .shift) == nil)
    }

    @Test func anIdleDeckAndATextFieldLeaveKeysAlone() {
        #expect(action("q", loaded: false) == nil)
        #expect(action("", PlayerKeymap.left, loaded: false) == nil)
        #expect(action("", PlayerKeymap.space, loaded: false) == .togglePlay)
        #expect(action("c", loaded: false) == .cueDown)
        #expect(action("q", typing: true) == nil)
        #expect(action("1", typing: true) == nil)
        #expect(action("", PlayerKeymap.left, typing: true) == nil)
        // But a pad or CUE let go is always heard.
        #expect(action("1", up: true, typing: true) == .hotCueUp)
        #expect(action("c", up: true, typing: true) == .cueUp)
    }

    @Test func oneShotKeysDoNotRepeat() {
        #expect(action("i", repeating: true) == .swallow)
        #expect(action("1", repeating: true) == .swallow)
        #expect(action("4", repeating: true) == .swallow)
        // Stepping keys do.
        #expect(action("b", repeating: true) == .memoryPrevious)
        #expect(action("", PlayerKeymap.right, repeating: true) == .jump(1))
    }
}

// MARK: - The deck with its controls

@MainActor
@Suite(.scratchDefaults)
struct DeckControlsTests {
    final class Clock { var now = 100.0 }

    struct Fixture {
        let deck: DeckModel
        let playback: MockPlayback
        let clock: Clock
        let defaults: UserDefaults
    }

    func make(bpmX100: UInt32 = 12_000, hot: [HotCue] = [], memory: [UInt32] = [], beats: [Beat]? = nil, defaults: UserDefaults? = nil) -> Fixture {
        let playback = MockPlayback()
        let clock = Clock()
        let defaults = defaults ?? scratchDefaults()
        let deck = DeckModel(deck: .a, playback: playback, defaults: defaults, now: { clock.now })
        var row = MockBackend.row(track: 6, position: 1)
        row.bpmX100 = bpmX100
        row.hotCues = hot
        row.memoryCues = memory
        deck.load(DeckTrack(row: row))
        deck.handle(deckEvent: DeckEvent(deck: .a, loadId: 1, totalFrames: 48_000 * 200, sampleRate: 48_000, message: nil))
        if let beats { deck.install(beats: BeatGrid(beats: beats)) }
        return Fixture(deck: deck, playback: playback, clock: clock, defaults: defaults)
    }

    static let beats120: [Beat] = (0..<400).map { Beat(timeMs: 500 + UInt32($0) * 500, number: UInt8($0 % 4 + 1), tempoX100: 12_000) }

    func tick(frames: Int64, playing: Bool, looping: Bool = false, loopIn: UInt64 = 0, loopOut: UInt64 = 0, generation: UInt32 = 1) -> DeckTick {
        DeckTick(
            frames: frames, totalFrames: 48_000 * 200, generation: generation, playing: playing, loaded: true, loadId: 1,
            tempo: 1, masterTempo: false, keyShift: 0, startInFrames: 0, loopInFrames: loopIn, loopOutFrames: loopOut,
            looping: looping)
    }

    func at(_ f: Fixture, seconds: Double, playing: Bool = false) {
        // Past any landing window from the last seek.
        f.clock.now += 1
        f.deck.apply(tick: tick(frames: Int64(seconds * 48_000), playing: playing), sampleRate: 48_000, at: f.clock.now)
    }

    @Test func zoomPersistsAndClamps() {
        let defaults = scratchDefaults()
        let a = make(defaults: defaults)
        #expect(a.deck.zoomBars == 12)
        a.deck.zoom(direction: -1)
        a.deck.zoom(direction: -1)
        #expect(a.deck.zoomBars == 4)
        let again = DeckModel(deck: .a, playback: MockPlayback(), defaults: defaults)
        #expect(again.zoomBars == 4)
        // A corrupt stored value falls to the nearest step.
        defaults.set(9.5, forKey: "deckA.zoomBars")
        #expect(DeckModel(deck: .a, playback: MockPlayback(), defaults: defaults).zoomBars == 8)
        for _ in 0..<20 { a.deck.zoom(direction: 1) }
        #expect(a.deck.zoomBars == 64)
    }

    @Test func aSetPadJumpsAndPlaysWhileHeldFromAPause() {
        let f = make(hot: [HotCue(slot: "A", positionMs: 20_000, color: nil)])
        at(f, seconds: 5)
        f.deck.padPressed("A")
        #expect(f.playback.calls.suffix(2) == [.seek(.a, 20_000), .play(.a)])
        #expect(f.deck.isPlaying && f.deck.heldPad == "A")
        f.deck.padReleased()
        #expect(f.playback.calls.suffix(2) == [.seek(.a, 20_000), .pause(.a)])
        #expect(!f.deck.isPlaying && f.deck.heldPad == nil)
        // The cue point is untouched by a pad.
        #expect(f.deck.cue.cueMs == 0)
    }

    @Test func aSetPadWhilePlayingJustJumps() {
        let f = make(hot: [HotCue(slot: "C", positionMs: 60_000, color: "#305AFF")])
        at(f, seconds: 5, playing: true)
        f.deck.padPressed("C")
        #expect(f.playback.calls.last == .seek(.a, 60_000))
        #expect(!f.playback.calls.contains(.pause(.a)))
        f.deck.padReleased()
        #expect(f.playback.calls.last == .seek(.a, 60_000))
        #expect(f.deck.isPlaying)
    }

    @Test func anEmptyPadDoesNothing() {
        let f = make()
        let before = f.playback.calls.count
        f.deck.padPressed("D")
        f.deck.padReleased()
        #expect(f.playback.calls.count == before)
    }

    @Test func pressingPlayWhileAPadIsHeldLatchesIt() {
        let f = make(hot: [HotCue(slot: "A", positionMs: 20_000, color: nil)])
        f.deck.padPressed("A")
        f.deck.play()
        f.deck.padReleased()
        #expect(!f.playback.calls.suffix(2).contains(.pause(.a)))
        #expect(f.deck.isPlaying)
    }

    @Test func memoryCuesAreCalledPreviousNextAndByNumber() {
        let f = make(memory: [10_000, 30_000, 50_000])
        at(f, seconds: 20)
        f.deck.callNextMemory()
        #expect(f.playback.calls.last == .seek(.a, 30_000))
        #expect(f.deck.cue.cueMs == 30_000)
        at(f, seconds: 30)
        f.deck.callPreviousMemory()
        #expect(f.playback.calls.last == .seek(.a, 10_000))
        f.deck.callMemory(number: 3)
        #expect(f.playback.calls.last == .seek(.a, 50_000))
        let before = f.playback.calls.count
        f.deck.callMemory(number: 9)
        #expect(f.playback.calls.count == before)
    }

    @Test func aMemoryLoopIsCalledAsALoop() {
        let f = make()
        f.deck.install(cues: [DeckCue(positionMs: 8_000, outMs: 12_000, memory: true)])
        at(f, seconds: 1)
        f.deck.callMemory(number: 1)
        #expect(f.playback.calls.contains(.loop(.a, 8_000, 12_000)))
        #expect(f.deck.loop == DeckLoop(inMs: 8_000, outMs: 12_000, active: true))
    }

    @Test func anAutoLoopSnapsToTheGridWhenQuantizedAndExitsWhenActive() {
        let f = make(beats: Self.beats120)
        at(f, seconds: 10.125)
        #expect(f.deck.quantize)
        f.deck.autoLoop()  // 4 beats from the nearest beat, 10.0 s
        #expect(f.playback.calls.last == .loop(.a, 10_000, 12_000))
        #expect(f.deck.loop?.active == true)
        f.deck.autoLoop()  // active: exit
        #expect(f.playback.calls.last == .looping(.a, false))
        #expect(f.deck.loop?.active == false)
        f.deck.reloopOrExit()  // RELOOP
        #expect(f.playback.calls.last == .looping(.a, true))
        // Q off: from where the head is.
        f.deck.toggleQuantize()
        f.deck.beatLoop(1)
        #expect(f.playback.calls.last == .loop(.a, 10_125, 10_625))
    }

    @Test func halveAndDoubleResizeAnActiveLoopFromItsInPoint() {
        let f = make(beats: Self.beats120)
        at(f, seconds: 10)
        f.deck.beatLoop(4)
        #expect(f.playback.calls.last == .loop(.a, 10_000, 12_000))
        f.deck.halveLoop()
        #expect(f.deck.loopLength == 2)
        #expect(f.playback.calls.last == .loop(.a, 10_000, 11_000))
        f.deck.doubleLoop()
        f.deck.doubleLoop()
        #expect(f.deck.loopLength == 8)
        #expect(f.playback.calls.last == .loop(.a, 10_000, 14_000))
        // Not looping: only the length changes.
        f.deck.setLooping(false)
        let count = f.playback.calls.count
        f.deck.halveLoop()
        #expect(f.deck.loopLength == 4)
        #expect(f.playback.calls.count == count)
        for _ in 0..<10 { f.deck.halveLoop() }
        #expect(f.deck.loopLength == 0.25)
    }

    @Test func manualLoopInAndOut() {
        let f = make(beats: Self.beats120)
        f.deck.toggleQuantize()  // off: raw positions
        at(f, seconds: 4.25)
        f.deck.markLoopIn()
        #expect(f.deck.pendingLoopIn == 4_250)
        at(f, seconds: 4.0)
        f.deck.markLoopOut()  // before the in point: no loop, and the IN is spent, as in the React player
        #expect(f.deck.loop == nil && f.deck.pendingLoopIn == nil)
        at(f, seconds: 4.25)
        f.deck.markLoopIn()
        at(f, seconds: 6.5)
        f.deck.markLoopOut()
        #expect(f.playback.calls.last == .loop(.a, 4_250, 6_500))
        #expect(f.deck.pendingLoopIn == nil)
    }

    @Test func aLoopWithoutAGridUsesTheFilesBpm() {
        let f = make(bpmX100: 12_000)
        at(f, seconds: 10)
        f.deck.beatLoop(4)
        #expect(f.playback.calls.last == .loop(.a, 10_000, 12_000))
    }

    @Test func ticksReportTheLoopOnceTheHoldLapses() {
        let f = make()
        f.deck.setLoop(inMs: 2_000, outMs: 4_000)
        // A tick straight after (the engine has not caught up) does not blank the loop.
        f.deck.apply(tick: tick(frames: 0, playing: false), sampleRate: 48_000, at: f.clock.now + 0.1)
        #expect(f.deck.loop?.active == true)
        f.deck.apply(tick: tick(frames: 0, playing: false), sampleRate: 48_000, at: f.clock.now + 1)
        #expect(f.deck.loop == nil)
        f.deck.apply(tick: tick(frames: 0, playing: false, looping: true, loopIn: 96_000, loopOut: 192_000), sampleRate: 48_000, at: f.clock.now + 1.2)
        #expect(f.deck.loop == DeckLoop(inMs: 2_000, outMs: 4_000, active: true))
        f.deck.apply(tick: tick(frames: 0, playing: false, looping: false, loopIn: 96_000, loopOut: 192_000), sampleRate: 48_000, at: f.clock.now + 1.4)
        #expect(f.deck.loop?.active == false)
    }

    @Test func beatJumpSeeksOnTheGrid() {
        let f = make(beats: Self.beats120)
        at(f, seconds: 10.25)
        f.deck.jump(direction: 1)
        #expect(f.playback.calls.last == .seek(.a, 12_250))
        f.deck.jumpSize = JumpSize.byID("16beats")
        at(f, seconds: 12.25)
        f.deck.jump(direction: -1)
        #expect(f.playback.calls.last == .seek(.a, 4_250))
        at(f, seconds: 3)
        f.deck.jump(direction: -1)
        #expect(f.playback.calls.last == .seek(.a, 0))
    }

    @Test func keyShiftClampsAndTransposesTheKey() {
        let f = make()
        #expect(f.deck.shiftedKey == "8A")
        f.deck.setKeyShift(2)
        #expect(f.playback.calls.last == .keyShift(.a, 2))
        #expect(f.deck.shiftedKey == "10A")
        f.deck.nudgeKeyShift(by: 40)
        #expect(f.deck.keyShift == 12)
        f.deck.setKeyShift(-99)
        #expect(f.deck.keyShift == -12)
        f.deck.setKeyShift(0)
        #expect(f.deck.shiftedKey == "8A")
        // A build that cannot shift a key leaves it alone.
        f.deck.apply(tick: tick(frames: 0, playing: false), sampleRate: 48_000, at: f.clock.now, shiftsKey: false)
        f.deck.setKeyShift(5)
        #expect(f.deck.keyShift == 0)
    }

    @Test func quantizeAndMetronomeToggle() {
        let f = make()
        #expect(f.deck.quantize)
        f.deck.toggleQuantize()
        #expect(!f.deck.quantize)
        #expect(f.deck.snapped(1_234) == 1_234)
        f.deck.toggleMetronome()
        #expect(f.playback.calls.last == .metronome(.a, true))
        f.deck.toggleMetronome()
        #expect(f.playback.calls.last == .metronome(.a, false))
    }

    @Test func aMetronomeAndKeyShiftSurviveAReload() {
        let f = make()
        f.deck.toggleMetronome()
        f.deck.setKeyShift(3)
        var row = MockBackend.row(track: 7, position: 1)
        row.bpmX100 = 12_000
        f.deck.load(DeckTrack(row: row))
        f.deck.handle(deckEvent: DeckEvent(deck: .a, loadId: 2, totalFrames: 48_000 * 200, sampleRate: 48_000, message: nil))
        #expect(f.playback.calls.suffix(2).contains(.keyShift(.a, 3)))
        #expect(f.playback.calls.suffix(2).contains(.metronome(.a, true)))
    }

    @Test func scrubbingPinsThePlayheadAndIgnoresTicksUntilItLetsGo() {
        let f = make()
        at(f, seconds: 10, playing: true)
        f.deck.scrubBegin()
        #expect(f.deck.scrubbing)
        #expect(f.playback.calls.last == .scrubBegin(.a))
        #expect(!f.deck.isPlaying)
        f.deck.scrub(toSeconds: 42)
        #expect(f.playback.calls.last == .scrubTo(.a, 42_000))
        #expect(f.deck.position(at: f.clock.now) == 42)
        // The engine's ticks lag the pointer: they must not pull the head back.
        at(f, seconds: 11, playing: true)
        #expect(f.deck.position(at: f.clock.now) == 42)
        // Out of range is clamped.
        f.deck.scrub(toSeconds: -5)
        #expect(f.playback.calls.last == .scrubTo(.a, 0))
        f.deck.scrub(toSeconds: 9_999)
        #expect(f.playback.calls.last == .scrubTo(.a, 200_000))
        f.deck.scrubEnd()
        #expect(!f.deck.scrubbing)
        #expect(f.playback.calls.last == .scrubEnd(.a))
        // A deck that was playing carries on.
        #expect(f.deck.isPlaying)
        // A moment later the engine is heard again.
        f.clock.now += 1
        f.deck.apply(tick: tick(frames: 48_000 * 100, playing: true, generation: 2), sampleRate: 48_000, at: f.clock.now)
        #expect(abs(f.deck.anchor.extrapolate(at: f.clock.now) - 100) < 0.001)
    }

    @Test func scrubbingOutsideADragDoesNothing() {
        let f = make()
        let count = f.playback.calls.count
        f.deck.scrub(toSeconds: 50)
        f.deck.scrubEnd()
        #expect(f.playback.calls.count == count)
    }

    @Test func theAnalysisArrivesFromTheBackend() async {
        let backend = MockBackend()
        await backend.setAnalysis(
            for: "7", beats: Self.beats120.prefix(8).map { $0 },
            cues: [
                Cue(id: "1", positionMs: 2_000, outMs: 0, letter: "A", memory: false, colour: "#3CEB50", comment: ""),
                Cue(id: "2", positionMs: 9_000, outMs: 0, letter: "", memory: true, colour: nil, comment: ""),
            ],
            phrases: [Phrase(beat: 1, label: "INTRO", kind: 1, timeMs: 500)], vocals: Data([0, 200, 0]))
        let deck = DeckModel(
            deck: .a, playback: backend.mockPlayback, backend: backend, defaults: scratchDefaults())
        var row = MockBackend.row(track: 6, position: 1)
        row.analysed = 1
        deck.load(DeckTrack(row: row))
        #expect(await eventually { deck.beats.count == 8 && deck.cues.count == 2 && deck.vocals.count == 3 })
        #expect(deck.hotCues.map(\.letter) == ["A"])
        #expect(deck.memoryCues.map(\.positionMs) == [9_000])
        deck.handle(deckEvent: DeckEvent(deck: .a, loadId: 1, totalFrames: 48_000 * 200, sampleRate: 48_000, message: nil))
        #expect(await eventually { !deck.phrases.isEmpty })
        // A track change drops the old track's analysis at once.
        var other = MockBackend.row(track: 7, position: 2)
        other.analysed = 0
        deck.load(DeckTrack(row: other))
        #expect(deck.beats.isEmpty && deck.vocals.isEmpty && deck.phrases.isEmpty)
    }

    @Test func detailBytesAreFetchedOncePerPaletteAndTrack() async {
        let backend = MockBackend()
        await backend.setWaveform(Data(repeating: 9, count: 30), for: "7")
        let deck = DeckModel(deck: .a, playback: backend.mockPlayback, backend: backend, defaults: scratchDefaults())
        deck.load(DeckTrack(row: MockBackend.row(track: 6, position: 1)))
        deck.requestDetail(palette: .bands)
        deck.requestDetail(palette: .bands)
        #expect(await eventually { deck.detailBytes?.count == 30 })
        #expect(deck.detailPalette == .bands)
        let kinds = await backend.waveformCalls.map(\.kind)
        #expect(kinds == [.bandsDetail])
        deck.requestDetail(palette: .mono)
        #expect(await eventually { deck.detailPalette == .mono })
    }

    @Test func theHotCuesOnARowShowBeforeTheFullListArrives() {
        let f = make(hot: [HotCue(slot: "B", positionMs: 7_000, color: "#305AFF")], memory: [3_000])
        #expect(f.deck.hotCues.map(\.letter) == ["B"])
        #expect(f.deck.hotCues[0].colour == RGB(0x30, 0x5A, 0xFF))
        #expect(f.deck.memoryCues.map(\.positionMs) == [3_000])
    }
}

// MARK: - Through the player

@MainActor
@Suite(.scratchDefaults)
struct PlayerKeysThroughTheModelTests {
    func makePlayer() async -> (PlayerModel, MockBackend) {
        let backend = MockBackend(trackCount: 20)
        let waveforms = WaveformService(backend: backend, settle: .zero)
        let artwork = ArtworkService(backend: backend, settle: .zero)
        let player = PlayerModel(backend: backend, waveforms: waveforms, artwork: artwork, defaults: scratchDefaults())
        return (player, backend)
    }

    @Test func keysDriveDeckA() async {
        let (player, backend) = await makePlayer()
        player.load(trackID: "7", row: MockBackend.row(track: 6, position: 1))
        player.handle(.deck(DeckEvent(deck: .a, loadId: 1, totalFrames: 48_000 * 200, sampleRate: 48_000, message: nil)))
        player.perform(.quantize)
        #expect(!player.deckA.quantize)
        player.perform(.zoom(-1))
        #expect(player.deckA.zoomBars == 8)
        player.perform(.jump(1))
        player.perform(.beatLoop(4))
        #expect(player.deckA.loopLength == 4)
        player.perform(.loopHalve)
        #expect(player.deckA.loopLength == 2)
        player.perform(.bpmUp)
        #expect(abs(player.deckA.tempo - 1.001) < 1e-9)
        player.perform(.masterTempo)
        #expect(player.deckA.masterTempo)
        player.perform(.tempoReset)
        #expect(player.deckA.tempo == 1)
        player.perform(.metronomeSound)
        player.perform(.metronomeSound)
        player.perform(.metronomeSound)
        let calls = backend.mockPlayback.calls
        #expect(calls.contains(.metronomeSound(3)) && calls.contains(.metronomeSound(1)) && calls.contains(.metronomeSound(2)))
    }

    @Test func theMetronomeSoundIsRemembered() async {
        let defaults = scratchDefaults()
        let backend = MockBackend(trackCount: 5)
        let make = {
            PlayerModel(
                backend: backend, waveforms: WaveformService(backend: backend, settle: .zero),
                artwork: ArtworkService(backend: backend, settle: .zero), defaults: defaults)
        }
        let player = make()
        #expect(player.metronomeSound == 2)
        player.cycleMetronomeSound()
        #expect(make().metronomeSound == 3)
    }
}
