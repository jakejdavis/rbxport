import CoreGraphics
import Foundation

/// Draws tiles of the scrolling detail waveform: a fixed-width slice of the whole track at the
/// current zoom, with the beat grid on it. The view lays tiles side by side and slides them under
/// a fixed playhead, so nothing is redrawn as the track plays. Ported from `drawBands` /
/// `drawColumns` (centred mode) in `src/canvas/waveform.ts` and `BeatGrid` in `Player.tsx`.
enum DetailRenderer {
    // The 3Band colours by which bands reach a pixel: low = 1, mid = 2, high = 4.
    static let bandColours: [RGB] = [
        RGB(hex: 0x0055E1),  // 0: falls back to low
        RGB(hex: 0x0055E1),  // 1 low
        RGB(hex: 0xFFA600),  // 2 mid
        RGB(hex: 0xB4690A),  // 3 low+mid
        RGB(hex: 0xFFFFFF),  // 4 high
        RGB(hex: 0xD2DCFA),  // 5 low+high
        RGB(hex: 0xFFF0D7),  // 6 mid+high
        RGB(hex: 0xF5EBD7),  // 7 all
    ]
    static let beatColour = RGB(hex: 0x4C4C4C)
    static let beatHeadColour = RGB(hex: 0x7C7C7C)
    static let downbeatColour = RGB(hex: 0xFFFFFF)
    static let downbeatHeadColour = RGB(hex: 0xEA3323)
    /// Full scale of a 3Band column.
    static let bandFullScale = 127.0

    /// Rows left clear above and below the waveform, in points: the strip above carries the bar
    /// count and the cue badges (`--s-wave-inset-top`, `--s-wave-inset-bottom`).
    static let insetTop = 20.0
    static let insetBottom = 16.0

    // MARK: Pure helpers (tested)

    /// A column as stretches from the outside in: each band's reach, furthest first, paired with
    /// the bands (bit set) that reach at least that far. Bands of equal reach share a stretch.
    static func segments(low: Double, mid: Double, high: Double, full: Double) -> [(reach: Double, bands: Int)] {
        func reach(_ value: Double) -> Double {
            value == 0 ? 0 : max(0.5, min(value, bandFullScale) / bandFullScale * full)
        }
        let reaches = [(reach(low), 1), (reach(mid), 2), (reach(high), 4)].sorted { $0.0 > $1.0 }
        var out: [(reach: Double, bands: Int)] = []
        var combination = 0
        for (r, band) in reaches {
            if r == 0 { break }
            combination |= band
            if let last = out.last, last.reach == r {
                out[out.count - 1].bands = combination
            } else {
                out.append((r, combination))
            }
        }
        return out
    }

    /// The stored columns a device pixel covers: `first` and `step` (columns per pixel) for the
    /// absolute pixel `x` of a timeline drawn at `pps` pixels a second, with the waveform's own
    /// clock `originSec` ahead of the audio's.
    static func columnWindow(pixel x: Int, pps: Double, originSec: Double) -> (first: Double, step: Double) {
        let step = DetailGeometry.columnsPerSecond / pps
        return ((Double(x) / pps + originSec) * DetailGeometry.columnsPerSecond, step)
    }

    /// A column of PWV5: `rrrgggbbhhhhh00`, big-endian.
    static func colourDetailColumn(_ hi: UInt8, _ lo: UInt8) -> (height: Double, colour: RGB) {
        let word = (Int(hi) << 8) | Int(lo)
        let height = Double((word >> 2) & 0x1F) / 31
        return (height, WaveformRenderer.rgbOf(UInt8((word >> 13) & 7), UInt8((word >> 10) & 7), UInt8((word >> 7) & 7)))
    }

    // MARK: Tile

    struct Input {
        var bytes: Data
        var palette: WaveformPalette
        var originSec: Double
        var pps: Double
        var tileIndex: Int
        var tileWidth: Int
        var heightPx: Int
        /// Device pixels per point, to size the insets, lines and heads.
        var scale: Double
        var grid: BeatGrid
        var everyBeat: Bool
    }

    /// One tile as an opaque-where-drawn bitmap, or nil for no data.
    static func render(_ input: Input) -> CGImage? {
        let w = input.tileWidth
        let h = input.heightPx
        guard w > 0, h > 0, input.pps > 0 else { return nil }
        let stride = input.palette.detailStride
        let columns = input.bytes.count / stride
        let scale = input.scale

        var buffer = Buffer(width: w, height: h)
        let top = max(0, min(Int((insetTop * scale).rounded()), h / 2 - 1))
        let bottom = max(0, min(Int((insetBottom * scale).rounded()), h / 2 - 1))
        let usable = Double(max(1, h - top - bottom))
        let centre = Double(top) + usable / 2

        let x0 = input.tileIndex * w
        if columns > 0 {
            input.bytes.withUnsafeBytes { raw in
                let data = raw.bindMemory(to: UInt8.self)
                for px in 0..<w {
                    let win = columnWindow(pixel: x0 + px, pps: input.pps, originSec: input.originSec)
                    // The waveform starts at its first column and ends at its last.
                    if win.first + win.step <= 0 || win.first >= Double(columns) { continue }
                    switch input.palette {
                    case .bands:
                        drawBandsColumn(
                            &buffer, x: px, data: data, columns: columns, first: win.first, step: win.step,
                            centre: centre, usable: usable)
                    case .mono, .colour:
                        drawPeakColumn(
                            &buffer, x: px, data: data, columns: columns, first: win.first, step: win.step,
                            palette: input.palette, centre: centre, usable: usable)
                    }
                }
            }
        }
        drawGrid(&buffer, input: input, x0: x0, top: top, bottom: bottom)
        return buffer.image()
    }

    private static func drawBandsColumn(
        _ b: inout Buffer, x: Int, data: UnsafeBufferPointer<UInt8>, columns: Int, first: Double, step: Double,
        centre: Double, usable: Double
    ) {
        var low = 0.0, mid = 0.0, high = 0.0
        let start = Int(first.rounded(.down))
        if step < 1 {
            // Zoomed in past one column a pixel: interpolate small variations, keep sharp attacks
            // vertical (ramping a kick early turns it into a diamond).
            let i = min(max(start, 0), columns - 1)
            let next = min(i + 1, columns - 1)
            let fraction = first - Double(i)
            func lerp(_ channel: Int) -> Double {
                let a = Double(data[i * 3 + channel])
                let c = Double(data[next * 3 + channel])
                let sharp = (a == 0 && c > 0) || (c - a >= 16 && c >= a * 2)
                return sharp ? a : a + (c - a) * fraction
            }
            low = lerp(0)
            mid = lerp(1)
            high = lerp(2)
        } else {
            let last = max(start + 1, Int((first + step).rounded(.down)))
            var i = max(start, 0)
            while i < last && i < columns {
                low = max(low, Double(data[i * 3]))
                mid = max(mid, Double(data[i * 3 + 1]))
                high = max(high, Double(data[i * 3 + 2]))
                i += 1
            }
        }
        if low == 0, mid == 0, high == 0 {
            // A silent stretch of the file is still a signal: its reference line.
            b.fill(x: x, y0: Int(centre.rounded(.down)), y1: Int(centre.rounded(.down)) + 1, bandColours[5])
            return
        }
        for segment in segments(low: low, mid: mid, high: high, full: usable / 2) {
            let y0 = Int((centre - segment.reach).rounded())
            let y1 = max(Int((centre + segment.reach).rounded()), y0 + 1)
            b.fill(x: x, y0: y0, y1: y1, bandColours[segment.bands])
        }
    }

    private static func drawPeakColumn(
        _ b: inout Buffer, x: Int, data: UnsafeBufferPointer<UInt8>, columns: Int, first: Double, step: Double,
        palette: WaveformPalette, centre: Double, usable: Double
    ) {
        let stride = palette.detailStride
        func read(_ i: Int) -> (height: Double, colour: RGB) {
            if palette == .mono {
                let byte = data[i]
                return (WaveformRenderer.monoHeight(byte), WaveformRenderer.monoColour(byte))
            }
            return colourDetailColumn(data[i * stride], data[i * stride + 1])
        }
        let start = max(Int(first.rounded(.down)), 0)
        let last = max(start + 1, Int((first + step).rounded(.down)))
        var best: (height: Double, colour: RGB)?
        var i = start
        while i < last && i < columns {
            let column = read(i)
            if best == nil || column.height > best!.height { best = column }
            i += 1
        }
        guard let best, best.height > 0 else {
            b.fill(x: x, y0: Int(centre.rounded(.down)), y1: Int(centre.rounded(.down)) + 1, bandColours[5])
            return
        }
        let reach = max(0.5, min(best.height, 1) * usable / 2)
        let y0 = Int((centre - reach).rounded())
        b.fill(x: x, y0: y0, y1: max(Int((centre + reach).rounded()), y0 + 1), best.colour)
    }

    /// Beat lines with small triangular heads at each end; every fourth is white with red heads.
    /// Beats sit at `time x pps` on the audio's clock, whatever the waveform's own origin.
    private static func drawGrid(_ b: inout Buffer, input: Input, x0: Int, top: Int, bottom: Int) {
        guard !input.grid.isEmpty else { return }
        let scale = input.scale
        let fromMs = (Double(x0) / input.pps - 0.05) * 1000
        let toMs = (Double(x0 + input.tileWidth) / input.pps + 0.05) * 1000
        let lineWidth = max(1, Int(scale.rounded()))
        let headH = max(2, Int((4 * scale).rounded()))
        let headHalf = max(2, Int((3 * scale).rounded()))
        // Heads hang in the clear strips above and below the waveform.
        let headTop = max(0, top - headH - Int(scale.rounded()))
        let headBottom = b.height - Int((3 * scale).rounded()) - 1
        guard headBottom - headTop > headH * 3 else { return }
        for beat in input.grid.beats(from: fromMs, to: toMs) {
            if !input.everyBeat && !beat.downbeat { continue }
            let centre = Int((beat.timeMs / 1000 * input.pps).rounded()) - x0
            let line = beat.downbeat ? downbeatColour : beatColour
            let head = beat.downbeat ? downbeatHeadColour : beatHeadColour
            let left = centre - lineWidth / 2
            for dx in 0..<lineWidth {
                b.fill(x: left + dx, y0: headTop + headH + 1, y1: headBottom - headH, line)
            }
            // Triangles pointing inward: the wide end outside, the apex towards the waveform.
            for row in 0..<headH {
                let half = Int((Double(headHalf) * Double(headH - row) / Double(headH)).rounded(.up))
                for dx in -half..<(half + lineWidth) {
                    b.set(x: left + dx, y: headTop + row, head)
                    b.set(x: left + dx, y: headBottom - row, head)
                }
            }
        }
    }

    // MARK: Pixel buffer

    /// Top-down RGBA, opaque where drawn.
    struct Buffer {
        let width: Int
        let height: Int
        var bytes: [UInt8]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            bytes = [UInt8](repeating: 0, count: width * height * 4)
        }

        mutating func set(x: Int, y: Int, _ c: RGB) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let o = (y * width + x) * 4
            bytes[o] = c.r
            bytes[o + 1] = c.g
            bytes[o + 2] = c.b
            bytes[o + 3] = 255
        }

        mutating func fill(x: Int, y0: Int, y1: Int, _ c: RGB) {
            guard x >= 0, x < width else { return }
            for y in max(y0, 0)..<max(min(y1, height), max(y0, 0)) {
                let o = (y * width + x) * 4
                bytes[o] = c.r
                bytes[o + 1] = c.g
                bytes[o + 2] = c.b
                bytes[o + 3] = 255
            }
        }

        func image() -> CGImage? {
            let provider = CGDataProvider(data: Data(bytes) as CFData)
            return provider.flatMap {
                CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: $0,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            }
        }
    }
}
