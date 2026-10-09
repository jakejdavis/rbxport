import SwiftUI

/// The dark, rekordbox-like palette the player draws in (from `src/styles/tokens.css`).
enum PlayerStyle {
    static let background = Color(red: 0.047, green: 0.047, blue: 0.055)
    static let panel = Color(red: 0.118, green: 0.118, blue: 0.118)
    static let button = Color(red: 0.169, green: 0.169, blue: 0.169)
    static let raised = Color(red: 0.196, green: 0.196, blue: 0.196)
    static let accent = Color(red: 0.075, green: 0.451, blue: 0.922)
    static let text = Color(red: 0.902, green: 0.902, blue: 0.902)
    static let dim = Color(red: 0.604, green: 0.604, blue: 0.604)
    static let well = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let cue = Color(red: 1.0, green: 0.6, blue: 0.0)
    static let playing = Color(red: 0.18, green: 0.75, blue: 0.31)
    static let playhead = Color.white
    static let scrub = Color(red: 0.42, green: 0.42, blue: 0.42)
    static let scrubPlayed = Color(red: 0.784, green: 0.784, blue: 0.784)
}

/// The panel above the browser: deck A's sleeve, title, key and BPM, time, transport, the
/// overview waveform and the tempo fader.
struct DeckPanel: View {
    let deck: DeckModel
    let player: PlayerModel
    let palette: WaveformPalette

    /// Narrower than this and the panel scrolls sideways: its controls never ask the window for
    /// more room (a content minimum wider than the detail column set the split view's size
    /// constraints chasing each other).
    static let contentWidth = 800.0

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                content
                    .frame(width: max(geometry.size.width, Self.contentWidth), height: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(PlayerStyle.background)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottomLeading) { noticeBanner }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                Sleeve(deck: deck)
                VUMeters(player: player, deck: deck)
                    .frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 6) {
                header
                PhraseStrip(deck: deck)
                    .frame(height: 14)
                OverviewWaveform(deck: deck, palette: palette)
                    .frame(height: 46)
                HStack(spacing: 6) {
                    ZoomColumn(deck: deck)
                    DetailWaveform(deck: deck, palette: palette)
                        .clipShape(.rect(cornerRadius: 2))
                        .frame(minHeight: 110, maxHeight: .infinity)
                        .accessibilityLabel("Waveform")
                }
                controls
            }
            TempoColumn(deck: deck)
        }
        .padding(12)
    }

    @ViewBuilder private var noticeBanner: some View {
        do {
            if let notice = player.notice {
                HStack(spacing: 6) {
                    Text(notice).lineLimit(1)
                    Button("Dismiss", systemImage: "xmark.circle.fill") { player.dismissNotice() }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.red.opacity(0.35), in: .rect(cornerRadius: 4))
                .padding(6)
            }
        }
    }

    // MARK: Header: track info, key, BPM

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(deck.track == nil ? PlayerStyle.dim : PlayerStyle.text)
                    .lineLimit(1)
                Text(subtitleText)
                    .font(.system(size: 12))
                    .foregroundStyle(PlayerStyle.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let track = deck.track {
                if !track.key.isEmpty { KeyShiftView(deck: deck) }
                BpmReadout(deck: deck, track: track)
            }
        }
        .frame(height: 40)
    }

    private var titleText: String {
        switch deck.phase {
        case .empty: "No track loaded"
        case .loading: deck.track?.title ?? "Loading..."
        case .ready: deck.track?.title ?? ""
        case .failed: deck.track?.title ?? "Could not load"
        }
    }

    private var subtitleText: String {
        switch deck.phase {
        case .empty: "Double-click a track, or press Return, to load it"
        case .loading: "Loading..."
        case .ready: deck.track?.artist ?? ""
        case .failed(let message): message
        }
    }

    // MARK: Transport and time

    /// The transport, pads, memory cues, loops, jump, Q and metronome. In two rows when the
    /// column is wide enough, in three when it is not; the narrowest still has to fit the window.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    CueButton(deck: deck)
                    PlayButton(deck: deck)
                    PadRow(deck: deck)
                    MemoryCueButtons(deck: deck)
                    Spacer(minLength: 8)
                    TimeReadout(deck: deck)
                }
                .frame(height: 40)
                HStack(spacing: 16) {
                    LoopControls(deck: deck)
                    JumpControls(deck: deck)
                    ModeChips(deck: deck)
                    Spacer(minLength: 0)
                }
                .frame(height: 26)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    CueButton(deck: deck)
                    PlayButton(deck: deck)
                    PadRow(deck: deck)
                    Spacer(minLength: 8)
                    TimeReadout(deck: deck)
                }
                .frame(height: 40)
                HStack(spacing: 16) {
                    MemoryCueButtons(deck: deck)
                    ModeChips(deck: deck)
                    Spacer(minLength: 0)
                }
                .frame(height: 26)
                HStack(spacing: 16) {
                    LoopControls(deck: deck)
                    JumpControls(deck: deck)
                    Spacer(minLength: 0)
                }
                .frame(height: 26)
            }
        }
    }
}

// MARK: - Pieces

private struct Sleeve: View {
    let deck: DeckModel

    var body: some View {
        ZStack {
            if let image = deck.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: RecordArt.image(hue: deck.track?.artworkHue ?? 210, edge: 120))
                    .resizable()
                    .opacity(deck.track == nil ? 0.25 : 1)
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(.rect(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityLabel("Artwork")
    }
}

private struct BpmReadout: View {
    let deck: DeckModel
    let track: DeckTrack

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(PlayerFormat.bpm(x100: deck.playingBpmX100))
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(PlayerStyle.text)
                Text("BPM").font(.system(size: 9, weight: .bold)).foregroundStyle(PlayerStyle.dim)
            }
            Text(
                abs(deck.tempo - 1) < 0.0005
                    ? "TRACK \(PlayerFormat.bpm(x100: Double(track.bpmX100)))"
                    : "TRACK \(PlayerFormat.bpm(x100: Double(track.bpmX100)))  \(PlayerFormat.tempoPercent(deck.tempo))"
            )
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(PlayerStyle.dim)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tempo \(PlayerFormat.bpm(x100: deck.playingBpmX100)) BPM")
    }
}

private struct TimeReadout: View {
    let deck: DeckModel

    var body: some View {
        // Redrawn per display frame while playing; the readout only changes by the tenth.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !deck.isPlaying)) { _ in
            let position = deck.position(at: CACurrentMediaTime())
            let total = deck.durationSeconds
            let primary = deck.timeMode == .elapsed ? PlayerFormat.elapsed(position) : PlayerFormat.remaining(total: total, position: position)
            let secondary = deck.timeMode == .elapsed ? PlayerFormat.remaining(total: total, position: position) : PlayerFormat.elapsed(position)
            VStack(alignment: .trailing, spacing: 0) {
                Text(primary)
                    .font(.system(size: 28, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(PlayerStyle.text)
                Text(secondary)
                    .font(.system(size: 11, weight: .regular).monospacedDigit())
                    .foregroundStyle(PlayerStyle.dim)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { deck.toggleTimeMode() }
        .help("Click to switch elapsed and remaining time")
        .accessibilityLabel("Time")
    }
}

/// CUE is held, not clicked: down is the press, up the release (see `CueMachine`).
private struct CueButton: View {
    let deck: DeckModel
    @State private var pressed = false

    var body: some View {
        let held = pressed
        Text("CUE")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(held ? .black : PlayerStyle.cue)
            .frame(width: 56, height: 40)
            .background(held ? PlayerStyle.cue : PlayerStyle.button, in: .rect(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(PlayerStyle.cue.opacity(0.6), lineWidth: 1))
            .opacity(deck.isLoaded ? 1 : 0.4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        deck.cuePressed()
                    }
                    .onEnded { _ in
                        pressed = false
                        deck.cueReleased()
                    })
            .accessibilityLabel("Cue")
            .accessibilityAddTraits(.isButton)
            .help("Hold to preview from the cue point (C)")
    }
}

private struct PlayButton: View {
    let deck: DeckModel

    var body: some View {
        Button {
            deck.togglePlay()
        } label: {
            Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(deck.isPlaying ? PlayerStyle.playing : PlayerStyle.text)
                .frame(width: 56, height: 40)
                .background(PlayerStyle.button, in: .rect(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(deck.isPlaying ? PlayerStyle.playing.opacity(0.7) : .white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!deck.isLoaded)
        .opacity(deck.isLoaded ? 1 : 0.4)
        .accessibilityLabel(deck.isPlaying ? "Pause" : "Play")
        .help("Play / pause (Space)")
    }
}

// MARK: - Tempo

private struct TempoColumn: View {
    let deck: DeckModel

    var body: some View {
        VStack(spacing: 6) {
            Button(deck.tempoRange.label) { deck.cycleTempoRange() }
                .buttonStyle(PlayerChipStyle(on: false))
                .help("Tempo range")
            Button("MASTER\nTEMPO") { deck.toggleMasterTempo() }
                .buttonStyle(PlayerChipStyle(on: deck.masterTempo, multiline: true))
                .disabled(!deck.isLoaded)
                .help("Master Tempo holds the key while the tempo changes")
            TempoFader(deck: deck)
                .frame(width: 44)
                .frame(minHeight: 70)
            Text(PlayerFormat.tempoPercent(deck.tempo))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(PlayerStyle.text)
            Button("RESET") { deck.resetTempo() }
                .buttonStyle(PlayerChipStyle(on: false))
                .disabled(!deck.isLoaded || deck.tempo == 1)
                .help("Reset the tempo to the track's own")
        }
        .frame(width: 64)
    }
}

/// A vertical fader: top is slower, bottom faster, the file's own speed in the middle.
private struct TempoFader: View {
    let deck: DeckModel

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let at = deck.tempoRange.fader(forTempo: deck.tempo)
            let y = (at + 1) / 2 * height
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2).fill(PlayerStyle.well)
                    .frame(width: 6).frame(maxWidth: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.1), lineWidth: 0.5).frame(width: 6))
                Rectangle().fill(PlayerStyle.dim).frame(width: 18, height: 1).offset(y: height / 2)
                RoundedRectangle(cornerRadius: 2)
                    .fill(deck.isLoaded ? PlayerStyle.text : PlayerStyle.dim)
                    .frame(width: 26, height: 12)
                    .overlay(Rectangle().fill(.black.opacity(0.7)).frame(height: 1))
                    .offset(y: min(max(y - 6, 0), height - 12))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard deck.isLoaded, height > 0 else { return }
                    deck.setFader(2 * min(max(value.location.y, 0), height) / height - 1)
                })
            .onTapGesture(count: 2) { if deck.isLoaded { deck.resetTempo() } }
        }
        .accessibilityElement()
        .accessibilityLabel("Tempo")
        .accessibilityValue(PlayerFormat.tempoPercent(deck.tempo))
        .accessibilityAdjustableAction { direction in
            deck.nudgeTempo(steps: direction == .increment ? 1 : -1)
        }
    }
}

struct PlayerChipStyle: ButtonStyle {
    let on: Bool
    var multiline = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: multiline ? 8 : 10, weight: .bold))
            .multilineTextAlignment(.center)
            .foregroundStyle(on ? .white : PlayerStyle.dim)
            .frame(maxWidth: .infinity, minHeight: multiline ? 28 : 20)
            .background(on ? PlayerStyle.accent : PlayerStyle.button, in: .rect(cornerRadius: 3))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Overview

/// The whole track as a waveform with the playhead on it. Click or drag to seek.
struct OverviewWaveform: View {
    let deck: DeckModel
    let palette: WaveformPalette
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                PlayerStyle.well
                if let image = deck.overview {
                    Image(decorative: image, scale: scale)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: size.width, height: max(size.height - 6, 0))
                        .frame(maxHeight: .infinity, alignment: .top)
                } else if deck.phase == .loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let track = deck.track, !track.analysed {
                    Text("Not analysed").font(.caption).foregroundStyle(PlayerStyle.dim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                PlayheadLayer(deck: deck, size: size)
            }
            .clipShape(.rect(cornerRadius: 2))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard deck.isLoaded, size.width > 0 else { return }
                    deck.seek(toFraction: value.location.x / size.width)
                })
            .onChange(of: request(size), initial: true) { _, wanted in
                deck.requestOverview(
                    palette: wanted.palette, pixelWidth: wanted.width, pixelHeight: wanted.height, scale: scale)
            }
            .accessibilityElement()
            .accessibilityLabel("Track overview")
            .accessibilityValue(
                deck.durationSeconds > 0
                    ? "\(Int(deck.position(at: CACurrentMediaTime()) / deck.durationSeconds * 100)) percent" : "")
        }
    }

    private struct Request: Equatable {
        var palette: WaveformPalette
        var width: Int
        var height: Int
        var trackID: String?
    }

    private func request(_ size: CGSize) -> Request {
        Request(
            palette: palette, width: Int((size.width * scale).rounded()),
            height: Int((max(size.height - 6, 0) * scale).rounded()), trackID: deck.track?.id)
    }
}

/// The played-region bar under the waveform and the playhead over it, redrawn each frame while
/// the deck plays.
private struct PlayheadLayer: View {
    let deck: DeckModel
    let size: CGSize

    var body: some View {
        TimelineView(.animation(paused: !deck.isPlaying)) { _ in
            let total = deck.durationSeconds
            let fraction = total > 0 ? min(max(deck.position(at: CACurrentMediaTime()) / total, 0), 1) : 0
            let x = fraction * size.width
            Canvas { context, canvas in
                guard deck.isLoaded else { return }
                // The scrub bar: grey ahead of the head, bright behind it.
                let bar = CGRect(x: 0, y: canvas.height - 4, width: canvas.width, height: 4)
                context.fill(Path(bar), with: .color(PlayerStyle.scrub.opacity(0.55)))
                context.fill(Path(CGRect(x: 0, y: bar.minY, width: x, height: bar.height)), with: .color(PlayerStyle.scrubPlayed))
                // The played part of the waveform is dimmed a little.
                context.fill(
                    Path(CGRect(x: 0, y: 0, width: x, height: canvas.height - 6)), with: .color(.black.opacity(0.28)))
                context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: canvas.height)), with: .color(PlayerStyle.playhead))
                // The cue point.
                if total > 0 {
                    let cueX = min(max(deck.cue.cueMs / 1000 / total, 0), 1) * canvas.width
                    var head = Path()
                    head.move(to: CGPoint(x: cueX - 3, y: 0))
                    head.addLine(to: CGPoint(x: cueX + 3, y: 0))
                    head.addLine(to: CGPoint(x: cueX, y: 5))
                    head.closeSubpath()
                    context.fill(head, with: .color(PlayerStyle.cue))
                }
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
        }
    }
}
