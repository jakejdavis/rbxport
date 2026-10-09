import SwiftUI

// The two-deck layout's mixer, laid across the seam between the decks: each channel's trim,
// three band knobs with kills and level, and the crossfader with DUAL CONTROL between them.

/// A small knob: drag vertically (120 points sweeps the whole range), double-click to reset, up
/// and down arrows step it when it has the focus.
struct MixerKnob: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let readout: String
    var accent: Color = PlayerStyle.accent
    let set: (Double) -> Void
    let reset: () -> Void
    let nudge: (Int) -> Void
    @State private var dragStart: Double?

    private let diameter: CGFloat = 28

    var body: some View {
        let span = range.upperBound - range.lowerBound
        let fraction = span > 0 ? (value - range.lowerBound) / span : 0
        VStack(spacing: 1) {
            Text(title).font(.system(size: 8, weight: .bold)).foregroundStyle(PlayerStyle.dim)
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius: CGFloat = min(size.width, size.height) / 2 - 1
                let arcRadius: CGFloat = radius - 1
                let sweep = Angle.degrees(270)
                let start = Angle.degrees(135)
                let end: Angle = start + sweep * fraction
                var track = Path()
                track.addArc(center: centre, radius: arcRadius, startAngle: start, endAngle: start + sweep, clockwise: false)
                context.stroke(track, with: .color(PlayerStyle.well), lineWidth: 3)
                var lit = Path()
                lit.addArc(center: centre, radius: arcRadius, startAngle: start, endAngle: end, clockwise: false)
                context.stroke(lit, with: .color(accent), lineWidth: 3)
                let knobRadius: CGFloat = radius - 4
                let knob = CGRect(x: centre.x - knobRadius, y: centre.y - knobRadius, width: knobRadius * 2, height: knobRadius * 2)
                context.fill(Path(ellipseIn: knob), with: .color(PlayerStyle.raised))
                let angle: CGFloat = CGFloat(end.radians)
                let direction = CGPoint(x: cos(angle), y: sin(angle))
                let inner: CGFloat = radius - 9
                let outer: CGFloat = radius - 4
                var needle = Path()
                needle.move(to: CGPoint(x: centre.x + direction.x * inner, y: centre.y + direction.y * inner))
                needle.addLine(to: CGPoint(x: centre.x + direction.x * outer, y: centre.y + direction.y * outer))
                context.stroke(needle, with: .color(PlayerStyle.text), lineWidth: 1.5)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = dragStart ?? value
                        dragStart = start
                        set(ChannelStrip.dragged(from: start, dy: -drag.translation.height, span: span) )
                    }
                    .onEnded { _ in dragStart = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
            Text(readout).font(.system(size: 8, weight: .medium).monospacedDigit()).foregroundStyle(PlayerStyle.dim)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            nudge(1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            nudge(-1)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(readout)
        .accessibilityAdjustableAction { direction in nudge(direction == .increment ? 1 : -1) }
        .help("\(title): drag up or down, double-click to reset")
    }
}

/// One deck's channel: trim, LOW, MID and HIGH with a kill under each, and the level.
struct ChannelStripView: View {
    let player: PlayerModel
    let which: Deck

    var body: some View {
        let mixer = player.mixer
        let strip = mixer.strip(which)
        let letter = which == .a ? "A" : "B"
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 3) {
                Text(letter).font(.system(size: 13, weight: .heavy)).foregroundStyle(PlayerStyle.text)
                    .frame(width: 20, height: 20).background(PlayerStyle.button, in: .rect(cornerRadius: 3))
                ChannelMeter(player: player, deck: player.deck(which))
                    .frame(width: 20, height: 5)
            }
            MixerKnob(
                title: "TRIM", value: strip.trim, range: ChannelStrip.trimRange, readout: ChannelStrip.trimLabel(strip.trim),
                set: { mixer.setTrim(which, $0) }, reset: { mixer.resetTrim(which) }, nudge: { mixer.nudgeTrim(which, steps: $0) })
            ForEach(MixerBand.allCases, id: \.self) { band in
                VStack(spacing: 2) {
                    MixerKnob(
                        title: band.label, value: strip.bands[band.rawValue], range: ChannelStrip.bandRange,
                        readout: strip.kills[band.rawValue] ? "KILL" : String(format: "%+.0f", (strip.bands[band.rawValue] - 0.5) * 24),
                        accent: strip.kills[band.rawValue] ? .red : PlayerStyle.accent,
                        set: { mixer.setBand(which, band, $0) }, reset: { mixer.resetBand(which, band) },
                        nudge: { mixer.nudgeBand(which, band, steps: $0) })
                    Button("KILL") { mixer.toggleKill(which, band) }
                        .buttonStyle(KillButtonStyle(on: strip.kills[band.rawValue]))
                        .accessibilityLabel("Kill \(band.label) deck \(letter)")
                        .accessibilityValue(strip.kills[band.rawValue] ? "on" : "off")
                }
            }
        }
    }
}

struct KillButtonStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 7, weight: .heavy))
            .foregroundStyle(on ? .white : PlayerStyle.dim)
            .frame(width: 30, height: 12)
            .background(on ? Color.red.opacity(0.85) : PlayerStyle.button, in: .rect(cornerRadius: 2))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The crossfader: horizontal, A on the left. Within three points of the middle it snaps to the
/// centre; double-click puts it back; arrow keys step it by 0.05.
struct CrossfaderView: View {
    let mixer: MixerModel

    private let height: CGFloat = 22
    private let thumbWidth: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let travel = max(width - thumbWidth, 1)
            let x = mixer.crossfade * travel
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(PlayerStyle.well).frame(height: 6)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.1), lineWidth: 0.5))
                Rectangle().fill(PlayerStyle.dim).frame(width: 1, height: 14).offset(x: width / 2)
                RoundedRectangle(cornerRadius: 2).fill(PlayerStyle.text)
                    .frame(width: thumbWidth, height: height)
                    .overlay(Rectangle().fill(.black.opacity(0.7)).frame(width: 1))
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    mixer.dragCrossfade(toFraction: (drag.location.x - thumbWidth / 2) / travel, length: travel)
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded { mixer.resetCrossfade() })
        }
        .frame(height: height)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            mixer.nudgeCrossfade(steps: 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            mixer.nudgeCrossfade(steps: -1)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Crossfader")
        .accessibilityValue(String(format: "%.2f", mixer.crossfade))
        .accessibilityAdjustableAction { direction in mixer.nudgeCrossfade(steps: direction == .increment ? 1 : -1) }
        .help("Crossfader: A on the left, B on the right. Double-click to centre.")
    }
}

/// The strip between the two decks.
struct MixerSeam: View {
    let player: PlayerModel

    var body: some View {
        @Bindable var player = player
        HStack(alignment: .center, spacing: 8) {
            ChannelStripView(player: player, which: .a)
            Spacer(minLength: 4)
            VStack(spacing: 4) {
                Button("DUAL CONTROL") { player.dualControl.toggle() }
                    .buttonStyle(ControlButtonStyle(width: 104, height: 18, lit: player.dualControl))
                    .help("Link the two waveforms' zoom and the two beat jump sizes")
                    .accessibilityLabel("Dual control")
                    .accessibilityValue(player.dualControl ? "on" : "off")
                HStack(spacing: 6) {
                    Text("A").font(.system(size: 10, weight: .bold)).foregroundStyle(PlayerStyle.dim)
                    CrossfaderView(mixer: player.mixer).frame(minWidth: 100, idealWidth: 190, maxWidth: 190)
                    Text("B").font(.system(size: 10, weight: .bold)).foregroundStyle(PlayerStyle.dim)
                }
            }
            Spacer(minLength: 4)
            ChannelStripView(player: player, which: .b)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .frame(height: 74)
        .background(PlayerStyle.panel)
    }
}
