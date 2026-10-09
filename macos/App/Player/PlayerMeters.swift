import SwiftUI

/// The ballistics of one meter bar: instant attack, a fall of 20 dB a second, and a peak marker
/// held for two seconds (`FALL_DB_PER_SECOND` in `store/useMaster.ts`, `lib/vuMeter.ts`).
struct MeterBallistics: Equatable, Sendable {
    static let fallDbPerSecond = 20.0
    static let floorDb = -44.0
    static let holdSeconds = 2.0
    /// Below this the signal is silence.
    static let silence = 0.001

    private(set) var db = -100.0
    private(set) var markerDb = -100.0
    private var markerAge = 0.0

    static func db(of peak: Double) -> Double {
        peak.isFinite && peak >= silence ? 20 * log10(peak) : -100
    }

    /// 0 to 1: the bar's height for a level in dB, rekordbox's 44 dB scale.
    static func height(db: Double) -> Double { min(1, max(0, (db - floorDb) / -floorDb)) }

    var height: Double { Self.height(db: db) }
    var markerHeight: Double { Self.height(db: markerDb) }

    /// Moves on `dt` seconds with the latest peak (linear, 0 to 1+).
    mutating func step(peak: Double, dt: Double) {
        let dt = max(dt, 0)
        let reading = Self.db(of: peak)
        db = reading >= db ? reading : max(reading, db - Self.fallDbPerSecond * dt)
        if db >= markerDb {
            markerDb = db
            markerAge = 0
        } else {
            markerAge += dt
            // After the hold the marker falls with the same ballistics.
            if markerAge > Self.holdSeconds { markerDb = max(db, markerDb - Self.fallDbPerSecond * dt) }
        }
    }

    var isActive: Bool { db > Self.floorDb || markerDb > Self.floorDb }
}

/// A deck's channel meter and the master pair. The channel bar reads that deck's own peak, taken
/// after its strip (trim, EQ, crossfader) and before the master level; the pair is the master.
struct VUMeters: View {
    let player: PlayerModel
    let deck: DeckModel
    @State private var bars = Bars()
    @State private var tail = false

    final class Bars {
        var channel = MeterBallistics()
        var left = MeterBallistics()
        var right = MeterBallistics()
        var last: TimeInterval?
    }

    var body: some View {
        let running = deck.isPlaying || tail || bars.channel.isActive
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !running)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                step(now: now)
                let barWidth = (size.width - 8) / 3
                let labels = [deck.deck == .a ? "A" : "B", "L", "R"]
                let values = [bars.channel, bars.left, bars.right]
                for (i, bar) in values.enumerated() {
                    let x = CGFloat(i) * (barWidth + 4)
                    let well = CGRect(x: x, y: 0, width: barWidth, height: size.height - 12)
                    context.fill(Path(roundedRect: well, cornerRadius: 1.5), with: .color(PlayerStyle.well))
                    let tall = well.height * bar.height
                    if tall > 0 {
                        let fill = CGRect(x: x, y: well.maxY - tall, width: barWidth, height: tall)
                        context.fill(
                            Path(fill),
                            with: .linearGradient(
                                Gradient(stops: [
                                    .init(color: .red, location: 0), .init(color: .yellow, location: 0.18),
                                    .init(color: PlayerStyle.playing, location: 0.45),
                                ]), startPoint: CGPoint(x: x, y: well.minY), endPoint: CGPoint(x: x, y: well.maxY)))
                    }
                    if bar.markerHeight > 0 {
                        let y = well.maxY - well.height * bar.markerHeight
                        context.fill(Path(CGRect(x: x, y: y - 1, width: barWidth, height: 1.5)), with: .color(.white.opacity(0.85)))
                    }
                    context.draw(
                        Text(labels[i]).font(.system(size: 8, weight: .bold)).foregroundStyle(PlayerStyle.dim),
                        at: CGPoint(x: x + barWidth / 2, y: size.height - 5))
                }
            }
        }
        .frame(width: 34)
        .onChange(of: deck.isPlaying) { _, playing in
            if playing {
                tail = true
            } else {
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    tail = false
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Level meters")
    }

    private func step(now: TimeInterval) {
        let dt = bars.last.map { min(now - $0, 0.25) } ?? 0
        bars.last = now
        // A reading older than a tenth of a second is stale: the bar falls on its own.
        let fresh = (player.meters != nil) && (CACurrentMediaTime() - player.metersAt) < 0.1
        let left = fresh ? Double(player.meters?.peakLeft ?? 0) : 0
        let right = fresh ? Double(player.meters?.peakRight ?? 0) : 0
        bars.left.step(peak: left, dt: dt)
        bars.right.step(peak: right, dt: dt)
        bars.channel.step(peak: player.channelPeak(deck.deck), dt: dt)
    }
}

/// A deck's channel level as a thin horizontal bar: the mixer strip's meter in the two-deck layout.
struct ChannelMeter: View {
    let player: PlayerModel
    let deck: DeckModel
    @State private var bars = Bars()

    final class Bars {
        var channel = MeterBallistics()
        var last: TimeInterval?
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !(deck.isPlaying || bars.channel.isActive))) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dt = bars.last.map { min(now - $0, 0.25) } ?? 0
                bars.last = now
                bars.channel.step(peak: player.channelPeak(deck.deck), dt: dt)
                let well = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: well, cornerRadius: 1.5), with: .color(PlayerStyle.well))
                let wide = size.width * bars.channel.height
                if wide > 0 {
                    context.fill(
                        Path(CGRect(x: 0, y: 0, width: wide, height: size.height)),
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: PlayerStyle.playing, location: 0.55), .init(color: .yellow, location: 0.82),
                                .init(color: .red, location: 1),
                            ]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                }
                if bars.channel.markerHeight > 0 {
                    let x = size.width * bars.channel.markerHeight
                    context.fill(Path(CGRect(x: x - 1, y: 0, width: 1.5, height: size.height)), with: .color(.white.opacity(0.85)))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Deck \(deck.deck == .a ? "A" : "B") level")
    }
}
