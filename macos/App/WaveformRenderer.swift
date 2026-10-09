import CoreGraphics
import Foundation

/// Which of rekordbox's waveform palettes a row preview is drawn in. The default is the
/// three-band waveform, as in the React app (`waveformColor: "3band"`).
enum WaveformPalette: String, CaseIterable, Sendable, Codable {
    case bands, mono, colour

    var label: String {
        switch self {
        case .bands: L10n.t("3Band")
        case .mono: L10n.t("Blue")
        case .colour: L10n.t("RGB")
        }
    }

    /// The tag the backend reads for this palette (`waveform_bytes`).
    var kind: WaveformKind {
        switch self {
        case .bands: .bands
        case .mono: .mono
        case .colour: .colour
        }
    }

    /// Bytes per column of the tag.
    var stride: Int {
        switch self {
        case .bands: 3
        case .mono: 1
        case .colour: 6
        }
    }
}

struct RGB: Equatable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: UInt32) { self.init(UInt8((hex >> 16) & 255), UInt8((hex >> 8) & 255), UInt8(hex & 255)) }

    /// `#RRGGBB` (the `#` is optional); nil when it is anything else.
    init?(hexString: String) {
        let text = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    var cgColor: CGColor {
        CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

/// One drawn pixel column of a half waveform, from the floor up: a stack of coloured slabs.
struct WaveformColumn: Equatable, Sendable {
    /// Slab heights as a fraction of the drawable height (stacked bottom to top) and colours.
    var slabs: [(fraction: Double, colour: RGB)]
    /// A silent column draws a one-pixel baseline.
    var silent: Bool

    static func == (a: WaveformColumn, b: WaveformColumn) -> Bool {
        a.silent == b.silent && a.slabs.count == b.slabs.count
            && zip(a.slabs, b.slabs).allSatisfy { $0.fraction == $1.fraction && $0.colour == $1.colour }
    }

    /// Total height as a fraction of the drawable height.
    var total: Double { min(slabs.reduce(0) { $0 + $1.fraction }, 1) }
}

/// Draws a track's overview waveform for a table row: a half waveform growing up from a
/// baseline, one device pixel per column. Ported from `drawBands` / `drawColumns`
/// (`src/canvas/waveform.ts`) in their `half` mode, which is what the React Preview column uses.
enum WaveformRenderer {
    // rekordbox's 3Band colours (the `--c-wave-*` tokens).
    static let low = RGB(hex: 0x0055E1)
    static let mid = RGB(hex: 0xFFA600)
    static let all = RGB(hex: 0xF5EBD7)
    static let lowHigh = RGB(hex: 0xD2DCFA)

    /// Per band, the value that fills the whole height: the low and high bands over 128 and
    /// the mid over 256 (measured against rekordbox; see `STACK_SCALE` in waveform.ts).
    static let stackScale: [Double] = [128, 256, 128]

    /// Five bits of height, three of whiteness in a mono column.
    static let heightMask: UInt8 = 0x1F
    static let whitenessShift: UInt8 = 5

    /// The column count `data` holds for a palette.
    static func columnCount(of data: Data, palette: WaveformPalette) -> Int { data.count / palette.stride }

    /// The columns to draw for `pixelWidth` device pixels. Where several stored columns share a
    /// pixel the loudest wins, so a transient survives. Empty for no data.
    static func columns(data: Data, palette: WaveformPalette, pixelWidth: Int) -> [WaveformColumn] {
        let count = columnCount(of: data, palette: palette)
        guard count > 0, pixelWidth > 0 else { return [] }
        let bytes = [UInt8](data)
        let step = Double(count) / Double(pixelWidth)
        var out: [WaveformColumn] = []
        out.reserveCapacity(pixelWidth)
        for x in 0..<pixelWidth {
            let first = Int(Double(x) * step)
            let last = max(first + 1, Int(Double(x + 1) * step))
            let span = first..<min(last, count)
            switch palette {
            case .bands: out.append(bandsColumn(bytes, span))
            case .mono: out.append(columnOfPeak(span, height: { monoHeight(bytes[$0]) }, colour: { monoColour(bytes[$0]) }))
            case .colour:
                out.append(
                    columnOfPeak(
                        span, height: { Double(bytes[$0 * 6]) / 127 },
                        colour: { rgbOf(bytes[$0 * 6 + 3], bytes[$0 * 6 + 4], bytes[$0 * 6 + 5]) }))
            }
        }
        return out
    }

    private static func bandsColumn(_ bytes: [UInt8], _ span: Range<Int>) -> WaveformColumn {
        var peak = [0.0, 0.0, 0.0]
        for i in span {
            for band in 0..<3 { peak[band] = max(peak[band], Double(bytes[i * 3 + band])) }
        }
        if peak.allSatisfy({ $0 == 0 }) { return WaveformColumn(slabs: [], silent: true) }
        // Stacked from the floor: blue, then amber on it, then near-white.
        let colours = [low, mid, all]
        var slabs: [(fraction: Double, colour: RGB)] = []
        var used = 0.0
        for band in 0..<3 where peak[band] > 0 {
            let tall = min(peak[band] / stackScale[band], 1)
            let room = 1 - used
            guard room > 0 else { break }
            slabs.append((min(tall, room), colours[band]))
            used += tall
        }
        return WaveformColumn(slabs: slabs, silent: false)
    }

    /// The loudest column of `span` as a single slab.
    private static func columnOfPeak(
        _ span: Range<Int>, height: (Int) -> Double, colour: (Int) -> RGB
    ) -> WaveformColumn {
        var best: (height: Double, index: Int)?
        for i in span where best == nil || height(i) > best!.height { best = (height(i), i) }
        guard let best, best.height > 0 else { return WaveformColumn(slabs: [], silent: true) }
        return WaveformColumn(slabs: [(min(best.height, 1), colour(best.index))], silent: false)
    }

    static func monoHeight(_ byte: UInt8) -> Double { Double(byte & heightMask) / Double(heightMask) }

    /// Blue shading to near-white by the three whiteness bits.
    static func monoColour(_ byte: UInt8) -> RGB { ramp(low, all, t: Double(byte >> whitenessShift) / 7) }

    /// The strongest channel at full, the others in proportion.
    static func rgbOf(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> RGB {
        let peak = max(r, g, b)
        guard peak > 0 else { return RGB(0, 0, 0) }
        let scale = 255 / Double(peak)
        return RGB(UInt8((Double(r) * scale).rounded()), UInt8((Double(g) * scale).rounded()), UInt8((Double(b) * scale).rounded()))
    }

    static func ramp(_ a: RGB, _ b: RGB, t: Double) -> RGB {
        let t = min(max(t, 0), 1)
        func mix(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) + (Double(y) - Double(x)) * t).rounded()) }
        return RGB(mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b))
    }

    /// Renders `data` into a `pixelWidth` x `pixelHeight` image with `topInset` / `bottomInset`
    /// pixels left clear. Transparent where nothing is drawn. Nil for no data or a zero size.
    static func render(
        data: Data, palette: WaveformPalette, pixelWidth: Int, pixelHeight: Int, topInset: Int = 0, bottomInset: Int = 0
    ) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let columns = columns(data: data, palette: palette, pixelWidth: pixelWidth)
        guard !columns.isEmpty else { return nil }
        guard
            let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        let bottom = max(0, min(bottomInset, pixelHeight / 2 - 1))
        let top = max(0, min(topInset, pixelHeight / 2 - 1))
        let usable = Double(max(1, pixelHeight - top - bottom))
        for (x, column) in columns.enumerated() {
            if column.silent {
                context.setFillColor(lowHigh.cgColor)
                context.fill(CGRect(x: x, y: bottom, width: 1, height: 1))
                continue
            }
            var base = Double(bottom)  // CoreGraphics counts up from the bottom edge
            for slab in column.slabs {
                let tall = slab.fraction * usable
                context.setFillColor(slab.colour.cgColor)
                context.fill(CGRect(x: Double(x), y: base, width: 1, height: base == Double(bottom) ? max(tall, 1) : tall))
                base += tall
            }
        }
        return context.makeImage()
    }
}
