import SwiftUI

// The deck's control clusters from slice 3b: pads, memory cues, loops, beat jump, key shift,
// quantize, metronome, zoom and the phrase strip.

private let readOnlyReason = "The library is read-only. Check Library Protection in Settings, and quit rekordbox to edit."

extension Color {
    init(_ rgb: RGB) { self.init(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255) }
}

// MARK: - Hot cue pads

/// Pads A to H. A set pad jumps to its cue (playing from it while held, from a pause); an empty
/// pad sets a hot cue at the playhead. Right-click a set pad to delete it or recolour it.
struct PadRow: View {
    let deck: DeckModel
    var compact = false
    /// Overrides the pad width (the narrow two-deck rows squeeze the pads).
    var padWidth: CGFloat?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(CueLookup.padLetters, id: \.self) { letter in
                Pad(deck: deck, letter: letter, cue: CueLookup.hot(deck.cues, letter: letter), compact: compact, width: padWidth)
            }
        }
    }
}

private struct Pad: View {
    let deck: DeckModel
    let letter: String
    let cue: DeckCue?
    var compact = false
    var width: CGFloat?
    @State private var pressed = false

    var body: some View {
        let held = deck.heldPad == letter
        let colour = cue.map { Color($0.drawColour) } ?? PlayerStyle.button
        Text(letter)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(cue == nil ? PlayerStyle.dim.opacity(0.5) : .black)
            .frame(width: width ?? (compact ? 26 : 30), height: compact ? 28 : 34)
            .background(
                cue == nil ? colour : colour.opacity(held ? 1 : 0.82), in: .rect(cornerRadius: 4)
            )
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(held ? 0.9 : 0.12), lineWidth: held ? 1.5 : 0.5))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        deck.padPressed(letter)
                    }
                    .onEnded { _ in
                        pressed = false
                        deck.padReleased()
                    }
            )
            .contextMenu {
                if let cue, !cue.id.isEmpty {
                    Button("Delete") { deck.deleteCue(cue) }
                    Menu("Color") {
                        ForEach(CueColours.hot, id: \.value) { entry in
                            Button { deck.recolour(cue, to: entry.value) } label: {
                                Label { Text("Color \(entry.value)") } icon: { Image(nsImage: CueColours.swatch(entry.hex)) }
                            }
                        }
                        Divider()
                        Button("Reset") { deck.recolour(cue, to: nil) }
                    }
                    .disabled(!deck.canEditCues)
                }
            }
            .help(cue == nil
                ? "Hot cue \(letter) is empty: press to set it at the playhead\(deck.canWrite() ? "" : ". \(readOnlyReason)")"
                : "Hot cue \(letter): hold to play from it (\(letter == "A" ? "1" : letter == "B" ? "2" : letter == "C" ? "3" : "click")); right-click to delete or recolour")
            .accessibilityLabel("Hot cue \(letter)")
            .accessibilityValue(cue == nil ? "empty" : "set")
            .accessibilityAddTraits(.isButton)
            .opacity(deck.isLoaded ? 1 : 0.4)
    }
}

/// Memory cue navigation, store and delete.
struct MemoryCueButtons: View {
    let deck: DeckModel

    var body: some View {
        HStack(spacing: 4) {
            Button { deck.callPreviousMemory() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(ControlButtonStyle(width: 26))
                .disabled(!deck.isLoaded || deck.memoryCues.isEmpty)
                .help("Previous memory cue (B)")
            Text("MEMORY").font(.system(size: 8, weight: .bold)).foregroundStyle(PlayerStyle.dim)
            Button { deck.callNextMemory() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(ControlButtonStyle(width: 26))
                .disabled(!deck.isLoaded || deck.memoryCues.isEmpty)
                .help("Next memory cue (N)")
            Button("SET") { deck.storeMemoryCue() }
                .buttonStyle(ControlButtonStyle(width: 30))
                .disabled(!deck.canEditCues)
                .help(deck.loop?.active == true ? "Store the active loop as a memory loop (M)" : "Set memory cue at the cue point (M)")
            Button("DEL") { deck.deleteMemoryAtHead() }
                .buttonStyle(ControlButtonStyle(width: 30))
                .disabled(!deck.canEditCues || CueLookup.memoryCue(deck.cues, at: deck.position(at: deck.now()) * 1000) == nil)
                .help("Delete the memory cue under the playhead (X)")
        }
    }
}

// MARK: - Loops

struct LoopControls: View {
    let deck: DeckModel
    /// Narrow rows leave out the halve and double buttons (the keys still work).
    var condensed = false

    var body: some View {
        let active = deck.loop?.active == true
        HStack(spacing: 4) {
            Button("IN") { deck.markLoopIn() }
                .buttonStyle(ControlButtonStyle(width: 30, lit: deck.pendingLoopIn != nil))
                .help("Loop in (I)")
            Button("OUT") { deck.markLoopOut() }
                .buttonStyle(ControlButtonStyle(width: 34))
                .disabled(deck.pendingLoopIn == nil)
                .help("Loop out (O)")
            Button(active ? "EXIT" : "RELOOP") { deck.reloopOrExit() }
                .buttonStyle(ControlButtonStyle(width: 50, lit: active))
                .disabled(deck.loop == nil)
                .help("Exit or re-enter the loop (R)")
            if !condensed {
                Button { deck.halveLoop() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(ControlButtonStyle(width: 22))
                    .help("Halve the loop length (/)")
            }
            Menu {
                ForEach(LoopLength.sizes, id: \.self) { size in
                    Button("\(LoopLength.label(size)) beat\(size == 1 ? "" : "s")") { deck.beatLoop(size) }
                }
            } label: {
                Text(LoopLength.label(deck.loopLength))
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .frame(width: 30, height: 24)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .background(PlayerStyle.button, in: .rect(cornerRadius: 3))
            .help("Auto-loop length in beats (4 to 9 start 1 to 32 beat loops)")
            if !condensed {
                Button { deck.doubleLoop() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(ControlButtonStyle(width: 22))
                    .help("Double the loop length (Option-\\)")
            }
            Button("LOOP") { deck.autoLoop() }
                .buttonStyle(ControlButtonStyle(width: 44, lit: active))
                .help("Loop the chosen length from the playhead, or exit the active loop")
        }
        .disabled(!deck.isLoaded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loop")
    }
}

// MARK: - Beat jump

struct JumpControls: View {
    let deck: DeckModel
    /// False hides the size menu, leaving the two arrows (the size stays as chosen).
    var showsSize = true

    var body: some View {
        @Bindable var deck = deck
        HStack(spacing: 4) {
            Button { deck.jump(direction: -1) } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(ControlButtonStyle(width: 28))
                .help("Jump back (Left Arrow)")
            if showsSize {
                Menu {
                    ForEach(JumpSize.all) { size in
                        Button(size.label) { deck.jumpSize = size }
                    }
                } label: {
                    Text(deck.jumpSize.label).font(.system(size: 10, weight: .bold)).frame(width: 56, height: 24)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .background(PlayerStyle.button, in: .rect(cornerRadius: 3))
                .help("Beat jump size")
            }
            Button { deck.jump(direction: 1) } label: { Image(systemName: "forward.end.fill") }
                .buttonStyle(ControlButtonStyle(width: 28))
                .help("Jump forward (Right Arrow)")
        }
        .disabled(!deck.isLoaded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Beat jump")
    }
}

// MARK: - Quantize, metronome, key shift

struct ModeChips: View {
    let deck: DeckModel

    var body: some View {
        HStack(spacing: 4) {
            Button("Q") { deck.toggleQuantize() }
                .buttonStyle(ControlButtonStyle(width: 28, lit: deck.quantize))
                .help("Quantize: cue and loop points snap to the beat (Q)")
                .accessibilityLabel("Quantize")
                .accessibilityValue(deck.quantize ? "on" : "off")
            Button { deck.toggleMetronome() } label: { Image(systemName: "metronome") }
                .buttonStyle(ControlButtonStyle(width: 28, lit: deck.metronome))
                .help("Metronome: a click on every beat of the grid")
                .accessibilityLabel("Metronome")
                .accessibilityValue(deck.metronome ? "on" : "off")
        }
        .disabled(!deck.isLoaded)
    }
}

/// The track's key with the key shift arrows either side. Click the key to put it back.
struct KeyShiftView: View {
    let deck: DeckModel

    var body: some View {
        let key = deck.shiftedKey
        HStack(spacing: 2) {
            Button { deck.nudgeKeyShift(by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(ControlButtonStyle(width: 16, height: 30))
                .help("Key down a semitone")
            Button { deck.setKeyShift(0) } label: {
                VStack(spacing: 0) {
                    Text("KEY").font(.system(size: 8, weight: .bold)).foregroundStyle(PlayerStyle.dim)
                    Text(key.isEmpty ? "-" : key)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(deck.keyShift == 0 ? PlayerStyle.cue : PlayerStyle.accent)
                    if deck.keyShift != 0 {
                        Text(String(format: "%+d", deck.keyShift)).font(.system(size: 8, weight: .bold)).foregroundStyle(PlayerStyle.accent)
                    }
                }
                .frame(minWidth: 40)
            }
            .buttonStyle(.plain)
            .help(deck.keyShift == 0 ? "The track's key" : "Click to reset the key shift")
            Button { deck.nudgeKeyShift(by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(ControlButtonStyle(width: 16, height: 30))
                .help("Key up a semitone")
        }
        .disabled(!deck.shiftsKey || !deck.isLoaded)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(PlayerStyle.panel, in: .rect(cornerRadius: 3))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Key \(key)")
    }
}

// MARK: - Zoom

struct ZoomColumn: View {
    let deck: DeckModel
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 2 : 4) {
            Button { deck.zoom(direction: -1) } label: { Image(systemName: "plus") }
                .buttonStyle(ControlButtonStyle(width: 24, height: compact ? 18 : 24))
                .disabled(deck.zoomBars <= DetailZoom.steps[0])
                .help("Zoom in (+)")
            Text(DetailZoom.label(deck.zoomBars))
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(PlayerStyle.text)
            if !compact { Text("BARS").font(.system(size: 7, weight: .bold)).foregroundStyle(PlayerStyle.dim) }
            Button { deck.zoom(direction: 1) } label: { Image(systemName: "minus") }
                .buttonStyle(ControlButtonStyle(width: 24, height: compact ? 18 : 24))
                .disabled(deck.zoomBars >= (DetailZoom.steps.last ?? 64))
                .help("Zoom out (-)")
        }
        .frame(width: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waveform zoom")
    }
}

// MARK: - Phrases and vocals

/// The vocal ticks and the phrase bar above the overview, on the whole track's time axis.
struct PhraseStrip: View {
    let deck: DeckModel

    private static let vocalColour = Color(red: 0.247, green: 0.663, blue: 0.961)

    var body: some View {
        Canvas { context, size in
            let phraseHeight = size.height - (deck.vocals.isEmpty ? 0 : 3)
            for phrase in deck.phrases {
                let span: CGFloat = CGFloat(phrase.to - phrase.from) * size.width
                let rect = CGRect(
                    x: CGFloat(phrase.from) * size.width, y: size.height - phraseHeight, width: span - 1,
                    height: phraseHeight)
                context.fill(Path(rect), with: .color(Color(phrase.kind.colour)))
                if rect.width > 34 {
                    context.draw(
                        Text(phrase.label.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.white),
                        at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
                }
            }
            if !deck.vocals.isEmpty, deck.durationSeconds > 0 {
                // One byte per 46.44 ms, drawn where it is present (>= 128, unverified).
                let columnSeconds = 0.04644
                let pixels = Int(size.width)
                var x = 0
                while x < pixels {
                    let from = Int(Double(x) / size.width * deck.durationSeconds / columnSeconds)
                    let to = max(from + 1, Int(Double(x + 1) / size.width * deck.durationSeconds / columnSeconds))
                    let end = min(to, deck.vocals.count)
                    if from < end, deck.vocals[from..<end].contains(where: { $0 >= 128 }) {
                        context.fill(Path(CGRect(x: Double(x), y: 0, width: 1, height: 2)), with: .color(Self.vocalColour))
                    }
                    x += 1
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Styles

struct ControlButtonStyle: ButtonStyle {
    var width: CGFloat = 40
    var height: CGFloat = 24
    var lit = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(lit ? .white : PlayerStyle.text)
            .frame(width: width, height: height)
            .background(lit ? PlayerStyle.accent : PlayerStyle.button, in: .rect(cornerRadius: 3))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
    }
}


// MARK: - Beat grid editing

/// The GRID panel's buttons: shift, MARK, double and halve, tempo, TAP, undo and the analysis lock.
struct GridControls: View {
    let deck: DeckModel
    var body: some View {
        let grid = deck.grid
        HStack(spacing: 4) {
            Text("GRID").font(.system(size: 8, weight: .bold)).foregroundStyle(PlayerStyle.dim)
            Button { grid.shift(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(ControlButtonStyle(width: 22))
                .help("Shift the beat grid 1 ms earlier (Command-Left)")
            Button("MARK") { grid.mark() }
                .buttonStyle(ControlButtonStyle(width: 42))
                .help("Make the beat nearest the playhead the downbeat")
            Button { grid.shift(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(ControlButtonStyle(width: 22))
                .help("Shift the beat grid 1 ms later (Command-Right)")
            Button("x2") { grid.double() }.buttonStyle(ControlButtonStyle(width: 26)).help("Double the tempo")
            Button("\u{00F7}2") { grid.halve() }.buttonStyle(ControlButtonStyle(width: 26)).help("Halve the tempo")
            Button(grid.tapBpmX100.map { String(format: "TAP %.1f", Double($0) / 100) } ?? "TAP") { grid.tap() }
                .buttonStyle(ControlButtonStyle(width: grid.tapBpmX100 == nil ? 34 : 64, lit: grid.tapBpmX100 != nil))
                .help("Tap the tempo")
            Button { grid.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(ControlButtonStyle(width: 22))
                .disabled(grid.state?.canUndo != true)
                .help(grid.state?.undoLabel.map { "Undo \($0)" } ?? "Undo grid edit")
            Button { grid.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(ControlButtonStyle(width: 22))
                .disabled(grid.state?.canRedo != true)
                .help(grid.state?.redoLabel.map { "Redo \($0)" } ?? "Redo grid edit")
            Button { grid.toggleLock() } label: { Image(systemName: grid.locked ? "lock.fill" : "lock.open") }
                .buttonStyle(ControlButtonStyle(width: 24, lit: grid.locked))
                .help(grid.locked ? "Analysis is locked: unlock to edit" : "Lock the analysis")
        }
        .disabled(!deck.isLoaded || !grid.hasGrid)
        .opacity(grid.hasGrid ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Beat grid")
    }
}
