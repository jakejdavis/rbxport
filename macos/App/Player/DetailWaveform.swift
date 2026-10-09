import AppKit
import QuartzCore
import SwiftUI

/// The scrolling waveform: the track centred on a fixed playhead, in Core Animation.
///
/// The track is drawn once into 1024-pixel tiles (`DetailRenderer`) that sit side by side in one
/// content layer; each display frame only moves that layer, which the compositor does at the
/// display's own rate. Tiles, beat grid and markers share the layer, so they cannot drift apart.
@MainActor
final class DetailWaveformNSView: NSView {
    // MARK: Inputs

    private(set) var deck: DeckModel?
    private var palette: WaveformPalette = .bands

    // MARK: Layers

    private let content = CALayer()
    private let loopLayer = CALayer()
    private let playhead = CALayer()
    private let barsLayer = CATextLayer()
    private var tileLayers: [Int: CALayer] = [:]
    private var markerLayers: [CALayer] = []

    // MARK: State

    private var displayLink: CADisplayLink?
    private let tiles = NSCache<NSString, TileBox>()
    private var drawnKey = ""
    private var markerKey = ""
    private var barsText = ""
    private var loopSignature = ""
    private var gate = WheelZoomGate()
    // Drag
    private var pressX: CGFloat = 0
    private var dragging = false
    private var grabX: CGFloat = 0
    private var grabAt = 0.0

    final class TileBox { let image: CGImage; init(_ image: CGImage) { self.image = image } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        root.masksToBounds = true
        root.backgroundColor = CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        content.anchorPoint = .zero
        root.addSublayer(content)
        loopLayer.zPosition = 1
        content.addSublayer(loopLayer)
        playhead.backgroundColor = CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        playhead.zPosition = 10
        root.addSublayer(playhead)
        barsLayer.zPosition = 11
        barsLayer.fontSize = 12
        barsLayer.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        barsLayer.foregroundColor = CGColor(gray: 1, alpha: 1)
        barsLayer.backgroundColor = CGColor(gray: 0, alpha: 0.85)
        barsLayer.alignmentMode = .center
        root.addSublayer(barsLayer)
        tiles.countLimit = 48
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
        refresh(at: CACurrentMediaTime())
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh(at: CACurrentMediaTime())
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Next turn: laying out is no time to be changing layers and asking SwiftUI for more.
        DispatchQueue.main.async { [weak self] in self?.refresh(at: CACurrentMediaTime()) }
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard let deck else { return }
        refresh(at: link.targetTimestamp)
        if !deck.isPlaying && !deck.scrubbing { link.isPaused = true }
    }

    // MARK: Updates from SwiftUI

    /// SwiftUI says something the strip shows has changed.
    func configure(deck: DeckModel, palette: WaveformPalette) {
        self.deck = deck
        if self.palette != palette { self.palette = palette }
        deck.requestDetail(palette: palette)
        displayLink?.isPaused = !(deck.isPlaying || deck.scrubbing)
        refresh(at: CACurrentMediaTime())
    }

    // MARK: Drawing

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Lays everything out for the playhead at `time`: picks the tiles, slides the content.
    func refresh(at time: TimeInterval) {
        guard let deck, bounds.width > 1, bounds.height > 1 else { return }
        let scale = scale
        let width = bounds.width
        let height = bounds.height
        let duration = deck.durationSeconds
        let bpm = Double(deck.track?.bpmX100 ?? 0)
        let span = DetailGeometry.spanSeconds(bars: deck.zoomBars, bpmX100: bpm, durationSec: duration)
        let ppsPt = width / span
        let pps = ppsPt * scale
        let position = deck.isLoaded ? deck.position(at: time) : 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Fixed layers.
        playhead.frame = CGRect(x: (width / 2 * scale).rounded() / scale - 0.5, y: 0, width: 1, height: height)
        playhead.isHidden = !deck.isLoaded
        let text = deck.isLoaded ? deck.beats.barText(seconds: position, fallbackBpm: bpm) : ""
        if text != barsText {
            barsText = text
            barsLayer.string = text
        }
        barsLayer.contentsScale = scale
        barsLayer.isHidden = text.isEmpty
        barsLayer.frame = CGRect(x: width / 2 - 86, y: height - 20, width: 80, height: 16)

        // The tiles for this zoom.
        guard let bytes = deck.detailBytes, !bytes.isEmpty, deck.detailPalette == palette, duration > 0 else {
            clearTiles()
            content.frame.origin.x = width / 2
            updateMarkers(deck: deck, ppsPt: ppsPt, height: height, key: "none")
            updateLoop(deck: deck, ppsPt: ppsPt, height: height)
            return
        }
        let stride = palette.detailStride
        let origin = DetailGeometry.originMs(
            firstBeatMs: deck.beats.isEmpty ? nil : Double(deck.beats.times[0]), bytes: bytes, stride: stride) / 1000
        let heightPx = Int((height * scale).rounded())
        let everyBeat = DetailZoom.showsEveryBeat(deck.zoomBars)
        let drawKey = "\(deck.track?.id ?? "")|\(palette.rawValue)|\(Int(pps * 100))|\(heightPx)|\(deck.beatsVersion)|\(everyBeat)|\(bytes.count)"
        if drawKey != drawnKey {
            clearTiles()
            drawnKey = drawKey
        }

        content.frame.origin.x = ((DetailGeometry.contentOffset(position: position, pixelsPerSecond: ppsPt, viewWidth: width)) * scale)
            .rounded() / scale
        content.frame.origin.y = 0

        if let range = DetailGeometry.visibleTiles(
            position: position, pixelsPerSecond: pps, viewWidthPx: width * scale, duration: duration)
        {
            for stale in tileLayers.keys where !range.contains(stale) {
                tileLayers[stale]?.removeFromSuperlayer()
                tileLayers[stale] = nil
            }
            // The tiles on screen first, so a seek never shows a gap while the margins render.
            let needed = Array(range).sorted { abs($0 - Int(position * pps) / DetailGeometry.tileWidth) < abs($1 - Int(position * pps) / DetailGeometry.tileWidth) }
            var rendered = 0
            for index in needed where tileLayers[index] == nil {
                let cacheKey = "\(drawKey)|\(index)" as NSString
                var image = tiles.object(forKey: cacheKey)?.image
                if image == nil {
                    // A frame's budget: the visible tiles always, the margins a couple at a time.
                    let onScreen = abs(index - Int(position * pps) / DetailGeometry.tileWidth) <= 1
                    if !onScreen && rendered >= 1 { continue }
                    image = DetailRenderer.render(
                        .init(
                            bytes: bytes, palette: palette, originSec: origin, pps: pps, tileIndex: index,
                            tileWidth: DetailGeometry.tileWidth, heightPx: heightPx, scale: scale, grid: deck.beats,
                            everyBeat: everyBeat))
                    rendered += 1
                    if let image { tiles.setObject(TileBox(image), forKey: cacheKey) }
                }
                guard let image else { continue }
                let layer = CALayer()
                layer.contents = image
                layer.contentsScale = scale
                layer.magnificationFilter = .nearest
                layer.minificationFilter = .nearest
                layer.anchorPoint = .zero
                layer.frame = CGRect(
                    x: CGFloat(index * DetailGeometry.tileWidth) / scale, y: 0,
                    width: CGFloat(DetailGeometry.tileWidth) / scale, height: height)
                content.insertSublayer(layer, at: 0)
                tileLayers[index] = layer
            }
        }
        updateMarkers(deck: deck, ppsPt: ppsPt, height: height, key: drawKey)
        updateLoop(deck: deck, ppsPt: ppsPt, height: height)
    }

    private func clearTiles() {
        for layer in tileLayers.values { layer.removeFromSuperlayer() }
        tileLayers.removeAll()
    }

    // MARK: Markers

    private func updateLoop(deck: DeckModel, ppsPt: CGFloat, height: CGFloat) {
        let loop = deck.loop
        loopLayer.isHidden = loop == nil
        guard let loop else {
            loopSignature = ""
            return
        }
        let signature = "\(loop.inMs)|\(loop.outMs)|\(loop.active)|\(Int(ppsPt * 100))|\(Int(height))"
        if signature == loopSignature { return }
        loopSignature = signature
        loopLayer.backgroundColor = NSColor(red: 0.075, green: 0.451, blue: 0.922, alpha: 1).cgColor
        loopLayer.opacity = loop.active ? 0.38 : 0.18
        loopLayer.frame = CGRect(
            x: loop.inMs / 1000 * ppsPt, y: 0, width: max((loop.outMs - loop.inMs) / 1000 * ppsPt, 1), height: height)
    }

    /// Cue badges, memory heads and the loop-in mark, at their positions on the content layer.
    private func updateMarkers(deck: DeckModel, ppsPt: CGFloat, height: CGFloat, key: String) {
        let signature =
            "\(key)|\(Int(ppsPt * 100))|\(Int(height))|\(deck.pendingLoopIn ?? -1)|"
            + deck.cues.map { "\($0.letter)\($0.memory)\($0.positionMs)\($0.colour?.r ?? 0)" }.joined(separator: ",")
        if signature == markerKey { return }
        markerKey = signature
        for layer in markerLayers { layer.removeFromSuperlayer() }
        markerLayers.removeAll()
        let scale = scale
        // Memory cues first so a hot cue's badge sits over the head beside it.
        for cue in deck.cues.sorted(by: { $0.memory && !$1.memory }) {
            let x = cue.positionMs / 1000 * ppsPt
            let colour = cue.drawColour
            if cue.memory {
                let head = CAShapeLayer()
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x - 7, y: height - 4))
                path.addLine(to: CGPoint(x: x + 7, y: height - 4))
                path.addLine(to: CGPoint(x: x, y: height - 14))
                path.closeSubpath()
                head.path = path
                head.fillColor = colour.cgColor
                head.zPosition = 2
                content.addSublayer(head)
                markerLayers.append(head)
            } else {
                let line = CALayer()
                line.backgroundColor = CGColor(gray: 1, alpha: 0.55)
                line.frame = CGRect(x: x - 0.5, y: 0, width: 1, height: height - 16)
                line.zPosition = 2
                content.addSublayer(line)
                markerLayers.append(line)
                let badge = CATextLayer()
                badge.string = cue.letter
                badge.fontSize = 10
                badge.font = NSFont.systemFont(ofSize: 10, weight: .bold)
                badge.alignmentMode = .center
                badge.foregroundColor = CGColor(gray: 0, alpha: 1)
                badge.backgroundColor = colour.cgColor
                badge.contentsScale = scale
                badge.frame = CGRect(x: x - 7, y: height - 18, width: 14, height: 14)
                badge.zPosition = 3
                content.addSublayer(badge)
                markerLayers.append(badge)
            }
        }
        if let pending = deck.pendingLoopIn {
            let mark = CALayer()
            mark.backgroundColor = NSColor(red: 0.075, green: 0.451, blue: 0.922, alpha: 1).cgColor
            mark.frame = CGRect(x: pending / 1000 * ppsPt - 1, y: 0, width: 2, height: height)
            mark.zPosition = 2
            content.addSublayer(mark)
            markerLayers.append(mark)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        pressX = convert(event.locationInWindow, from: nil).x
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let deck, deck.isLoaded else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if !dragging {
            guard abs(x - pressX) > DetailGeometry.clickSlop else { return }
            dragging = true
            grabX = x
            grabAt = deck.position(at: CACurrentMediaTime())
            deck.scrubBegin()
            displayLink?.isPaused = false
        }
        let span = DetailGeometry.spanSeconds(
            bars: deck.zoomBars, bpmX100: Double(deck.track?.bpmX100 ?? 0), durationSec: deck.durationSeconds)
        deck.scrub(toSeconds: grabAt + DetailGeometry.dragSeconds(dx: x - grabX, width: bounds.width, spanSeconds: span))
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { deck?.scrubEnd() }
        dragging = false
        displayLink?.isPaused = !(deck?.isPlaying ?? false)
        refresh(at: CACurrentMediaTime())
    }

    override func scrollWheel(with event: NSEvent) {
        guard let deck else { return }
        // A browser's wheel reports lines as ~33 px and up as negative; match it.
        let raw = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 33
        let step = gate.feed(deltaPx: -raw, nowMs: event.timestamp * 1000)
        if step != 0 { deck.zoom(direction: step) }
    }
}

/// The detail waveform in SwiftUI.
struct DetailWaveform: NSViewRepresentable {
    let deck: DeckModel
    let palette: WaveformPalette

    func makeNSView(context: Context) -> DetailWaveformNSView { DetailWaveformNSView(frame: .zero) }

    /// Takes whatever it is offered: the strip has no size of its own, and answering from the
    /// view's fitting size made the hosting view's constraints chase each other.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DetailWaveformNSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 110))
    }

    func updateNSView(_ view: DetailWaveformNSView, context: Context) {
        // Reading these here is what makes SwiftUI call this again when they change.
        _ = (deck.anchor, deck.zoomBars, deck.beatsVersion, deck.cues, deck.loop, deck.detailBytes?.count)
        _ = (deck.isPlaying, deck.scrubbing, deck.pendingLoopIn, deck.phase, deck.track?.id)
        view.configure(deck: deck, palette: palette)
    }
}
