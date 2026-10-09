import AppKit
import QuartzCore

/// Geometry and drawing for the Preview column, kept apart from the view so tests can check it.
enum PreviewLayout {
    static let sidePadding: CGFloat = 3
    static let topInset: CGFloat = 3
    static let bottomInset: CGFloat = 2

    /// The strip the waveform and its cue marks occupy inside a cell.
    static func band(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + sidePadding, y: bounds.minY + bottomInset,
            width: max(bounds.width - sidePadding * 2, 0), height: max(bounds.height - topInset - bottomInset, 0))
    }

    /// Hot cue badge edge, in points: 7 as in the React table, larger in tall rows.
    static func badgeSize(rowHeight: CGFloat) -> CGFloat { rowHeight >= 30 ? 9 : 7 }

    /// The badge's left edge for a cue at `positionMs`, pulled back inside the strip at the far end.
    static func badgeX(positionMs: UInt32, durationMs: Double, band: CGRect, size: CGFloat) -> CGFloat {
        guard durationMs > 0 else { return band.minX }
        let fraction = min(max(Double(positionMs) / durationMs, 0), 1)
        return (band.minX + min(CGFloat(fraction) * band.width, band.width - size)).rounded()
    }

    /// The x of a memory cue's marker, or nil if it lies outside the track.
    static func memoryX(positionMs: UInt32, durationMs: Double, band: CGRect) -> CGFloat? {
        guard durationMs > 0, Double(positionMs) <= durationMs else { return nil }
        return (band.minX + CGFloat(Double(positionMs) / durationMs) * band.width).rounded()
    }

    /// The time a click at `point` (in the cell's unflipped coordinates) asks to preview, clamped
    /// to the strip. A click on a hot cue's badge, in the strip's top rows, means that cue's own
    /// time instead; where badges overlap the last drawn wins. Nil when the track has no length.
    static func clickPositionMs(
        at point: CGPoint, band: CGRect, durationMs: Double, hotCues: [HotCue], rowHeight: CGFloat
    ) -> Double? {
        guard durationMs > 0, band.width > 0 else { return nil }
        let size = badgeSize(rowHeight: rowHeight)
        if point.y >= band.maxY - size {
            for cue in hotCues.reversed() {
                let x = badgeX(positionMs: cue.positionMs, durationMs: durationMs, band: band, size: size)
                if point.x >= x && point.x < x + size { return Double(cue.positionMs) }
            }
        }
        let fraction = min(max((point.x - band.minX) / band.width, 0), 1)
        return Double(fraction) * durationMs
    }

    static let hotCueDefault = NSColor(srgbRed: 0x3C / 255, green: 0xEB / 255, blue: 0x50 / 255, alpha: 1)
    static let memoryCue = NSColor(srgbRed: 0xEA / 255, green: 0x33 / 255, blue: 0x23 / 255, alpha: 1)

    static func cueColour(_ hex: String?) -> NSColor {
        guard let hex, let rgb = RGB(hexString: hex) else { return hotCueDefault }
        return NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}

/// The Preview column: a row's waveform on a dark well, with hot cue badges and memory cue
/// markers drawn over it at paint time (so cue edits never leave a stale cached bitmap).
/// The waveform is fetched once the row has stayed on screen briefly, and cancelled if the
/// row scrolls away first. A plain click plays the track from that point (the preview player).
final class PreviewCellView: NSTableCellView {
    private var row: Row?
    private var image: CGImage?
    private var palette = WaveformPalette.bands
    private var service: WaveformService?
    private var ticket: WaveformService.Ticket?
    private var requestedStyle: WaveformService.Style?
    private var requestedID: String?
    private var preview: PreviewModel?
    private var link: CADisplayLink?
    /// A plain click on the waveform: the row and the time asked for, in milliseconds.
    var onPreviewClick: ((Row, Double) -> Void)?

    override var isFlipped: Bool { false }

    func show(row: Row?, palette: WaveformPalette, service: WaveformService, preview: PreviewModel? = nil) {
        self.preview = preview
        if self.row?.id != row?.id || self.palette != palette {
            cancelLoad()
            image = nil
            requestedStyle = nil
            requestedID = nil
        }
        self.row = row
        self.palette = palette
        self.service = service
        needsDisplay = true
        requestIfNeeded()
        refreshPlayhead()
    }

    func cancelLoad() {
        service?.cancel(ticket)
        ticket = nil
        requestedStyle = nil
        requestedID = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoad()
        stopLink()
        row = nil
        image = nil
    }

    // MARK: Click-to-preview

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .command, .control])
        if event.clickCount == 1, flags.isEmpty, let row, row.analysed != 0 {
            let point = convert(event.locationInWindow, from: nil)
            if let ms = PreviewLayout.clickPositionMs(
                at: point, band: PreviewLayout.band(in: bounds), durationMs: Double(row.durationSec) * 1000,
                hotCues: row.hotCues, rowHeight: bounds.height)
            {
                onPreviewClick?(row, ms)
            }
        }
        // The table still selects the row and sees double-clicks.
        super.mouseDown(with: event)
    }

    // MARK: Playhead

    /// Whether this row is the one previewing, and so draws a playhead.
    private var previewing: Bool {
        guard let row, let preview else { return false }
        return preview.isPlaying && preview.trackID == row.id
    }

    /// Starts or stops the per-frame redraw to match whether this row is previewing.
    func refreshPlayhead() {
        if previewing {
            if link == nil, window != nil {
                let link = displayLink(target: self, selector: #selector(frame(_:)))
                link.add(to: .main, forMode: .common)
                self.link = link
            }
        } else {
            stopLink()
        }
        needsDisplay = true
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard previewing else {
            stopLink()
            needsDisplay = true
            return
        }
        needsDisplay = true
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLink() } else { refreshPlayhead() }
    }


    override func layout() {
        super.layout()
        requestIfNeeded()
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func requestIfNeeded() {
        guard let row, row.analysed != 0, let service else { return }
        let band = PreviewLayout.band(in: bounds)
        let style = WaveformService.Style(
            palette: palette, pixelWidth: Int((band.width * scale).rounded()), pixelHeight: Int((band.height * scale).rounded()),
            topInset: 0, bottomInset: 0)
        guard style.pixelWidth > 0, style.pixelHeight > 0 else { return }
        guard requestedID != row.id || requestedStyle != style else { return }
        // A resize keeps the old bitmap on screen (stretched) until the new one lands.
        service.cancel(ticket)
        requestedID = row.id
        requestedStyle = style
        let id = row.id
        ticket = service.request(id: id, style: style, scale: scale) { [weak self] rendered in
            guard let self, self.row?.id == id, self.requestedStyle == style else { return }
            self.ticket = nil
            if let rendered { self.image = rendered }
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row, row.analysed != 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let band = PreviewLayout.band(in: bounds)
        guard band.width > 0, band.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if let image {
            context.interpolationQuality = .none
            context.draw(image, in: band)
        }
        let durationMs = Double(row.durationSec) * 1000
        drawMemoryCues(row.memoryCues, durationMs: durationMs, band: band, in: context)
        drawHotCues(row.hotCues, durationMs: durationMs, band: band, in: context)
        drawPlayhead(row: row, durationMs: durationMs, band: band, in: context)
    }

    private func drawPlayhead(row: Row, durationMs: Double, band: CGRect, in context: CGContext) {
        guard durationMs > 0, let preview, let ms = preview.positionMs(of: row.id, at: CACurrentMediaTime()) else { return }
        let x = (band.minX + CGFloat(min(ms / durationMs, 1)) * band.width).rounded()
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.fill(CGRect(x: band.minX, y: band.minY, width: max(x - band.minX, 0), height: band.height))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: x - 1, y: band.minY - 1, width: 2, height: band.height + 2))
    }

    private func drawMemoryCues(_ cues: [UInt32], durationMs: Double, band: CGRect, in context: CGContext) {
        context.setFillColor(PreviewLayout.memoryCue.cgColor)
        let half: CGFloat = 3
        let height: CGFloat = 4
        for cue in cues {
            guard let x = PreviewLayout.memoryX(positionMs: cue, durationMs: durationMs, band: band) else { continue }
            let top = band.maxY
            context.beginPath()
            context.move(to: CGPoint(x: x - half, y: top))
            context.addLine(to: CGPoint(x: x + half, y: top))
            context.addLine(to: CGPoint(x: x, y: top - height))
            context.closePath()
            context.fillPath()
        }
    }

    private func drawHotCues(_ cues: [HotCue], durationMs: Double, band: CGRect, in context: CGContext) {
        let size = PreviewLayout.badgeSize(rowHeight: bounds.height)
        let font = NSFont.systemFont(ofSize: size - 1.5, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        for cue in cues {
            let x = PreviewLayout.badgeX(positionMs: cue.positionMs, durationMs: durationMs, band: band, size: size)
            let box = CGRect(x: x, y: band.maxY - size, width: size, height: size)
            context.setFillColor(PreviewLayout.cueColour(cue.color).cgColor)
            context.fill(box)
            let letter = NSAttributedString(string: cue.slot, attributes: attributes)
            let measured = letter.size()
            letter.draw(at: CGPoint(x: box.midX - measured.width / 2, y: box.midY - measured.height / 2))
        }
    }
}

/// The Artwork column: the sleeve as a square thumbnail, a record when the track has none.
final class ArtworkCellView: NSTableCellView {
    private var row: Row?
    private var image: NSImage?
    private var failed = false
    private var service: ArtworkService?
    private var ticket: ArtworkService.Ticket?
    private var requestedID: String?
    private var requestedBucket = 0

    override var isFlipped: Bool { false }

    /// The square the thumbnail fills, in points.
    private var square: CGRect {
        let edge = max(min(bounds.height - 4, bounds.width - 8), 0)
        return CGRect(x: 4, y: (bounds.height - edge) / 2, width: edge, height: edge)
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    func show(row: Row?, service: ArtworkService) {
        if self.row?.id != row?.id {
            cancelLoad()
            image = nil
            failed = false
        }
        self.row = row
        self.service = service
        needsDisplay = true
        requestIfNeeded()
    }

    func cancelLoad() {
        service?.cancel(ticket)
        ticket = nil
        requestedID = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoad()
        row = nil
        image = nil
        failed = false
    }

    override func layout() {
        super.layout()
        requestIfNeeded()
    }

    private func requestIfNeeded() {
        guard let row, row.hasArtwork, let service, !failed else { return }
        let pixels = Int((square.width * scale).rounded(.up))
        guard pixels > 0 else { return }
        let bucket = ArtworkService.bucket(for: pixels)
        // Already showing an image at least this sharp for this track.
        if requestedID == row.id && requestedBucket >= bucket { return }
        service.cancel(ticket)
        requestedID = row.id
        requestedBucket = bucket
        let id = row.id
        ticket = service.request(id: id, pixels: pixels) { [weak self] loaded in
            guard let self, self.row?.id == id else { return }
            self.ticket = nil
            if let loaded { self.image = loaded } else { self.failed = true }
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = square
        guard rect.width > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let clip = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        context.addPath(clip)
        context.clip()
        if let image {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else if row.hasArtwork && !failed {
            // Decoding: an empty well rather than a record about to be covered by the sleeve.
            context.setFillColor(NSColor.quaternaryLabelColor.cgColor)
            context.fill(rect)
        } else {
            RecordArt.draw(in: context, rect: rect, hue: Double(row.artworkHue))
        }
        context.resetClip()
        context.addPath(clip)
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.5)
        context.strokePath()
    }
}
