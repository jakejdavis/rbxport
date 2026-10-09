import AppKit
import Foundation
import Testing

@testable import rbxport

/// A PNG of `edge` x `edge` pixels.
func pngData(edge: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

@MainActor
struct ArtworkServiceTests {
    @Test func bucketsRoundUpToTheNextSize() {
        #expect(ArtworkService.bucket(for: 10) == 64)
        #expect(ArtworkService.bucket(for: 64) == 64)
        #expect(ArtworkService.bucket(for: 65) == 128)
        #expect(ArtworkService.bucket(for: 900) == 1024)
        #expect(ArtworkService.bucket(for: 5000) == 1024)
    }

    @Test func thumbnailsAreDownscaledToTheBucket() throws {
        let big = pngData(edge: 800)
        let thumb = try #require(ArtworkService.thumbnail(from: big, maxPixels: 128))
        #expect(max(thumb.width, thumb.height) == 128)
        // Never inflated past the original.
        let small = try #require(ArtworkService.thumbnail(from: pngData(edge: 40), maxPixels: 128))
        #expect(small.width <= 128)
        #expect(ArtworkService.thumbnail(from: Data("not an image".utf8), maxPixels: 64) == nil)
    }

    @Test func aLoadedImageIsCachedPerTrackAndSize() async {
        let backend = MockBackend()
        await backend.setArtwork(pngData(edge: 300), for: "5")
        let service = ArtworkService(backend: backend, settle: .zero)
        var first: NSImage?
        var done = false
        _ = service.request(id: "5", pixels: 60) { first = $0; done = true }
        #expect(await eventually { done })
        #expect(first != nil)
        #expect(await backend.artworkCalls == ["5"])

        // The same track and size completes at once, without another backend call.
        var again: NSImage?
        let ticket = service.request(id: "5", pixels: 60) { again = $0 }
        #expect(ticket == nil)
        #expect(again != nil)
        #expect(await backend.artworkCalls == ["5"])
        #expect(service.cached(id: "5", pixels: 50) != nil)

        // A much bigger size is a different entry.
        #expect(service.cached(id: "5", pixels: 500) == nil)
    }

    @Test func aTrackWithoutArtworkCompletesNilAndIsNotCached() async {
        let backend = MockBackend()
        let service = ArtworkService(backend: backend, settle: .zero)
        var result: NSImage? = NSImage()
        var done = false
        _ = service.request(id: "9", pixels: 64) { result = $0; done = true }
        #expect(await eventually { done })
        #expect(result == nil)
        #expect(service.cached(id: "9", pixels: 64) == nil)
    }

    @Test func loadsAreThrottled() async {
        let backend = MockBackend()
        await backend.setArtworkDelay(.milliseconds(60))
        for i in 0..<30 { await backend.setArtwork(pngData(edge: 20), for: String(i)) }
        let service = ArtworkService(backend: backend, maxConcurrent: 4, settle: .zero)
        var done = 0
        for i in 0..<30 { _ = service.request(id: String(i), pixels: 64) { _ in done += 1 } }
        #expect(await eventually(timeout: .seconds(10)) { done == 30 })
        #expect(await backend.peakArtworkCalls <= 4)
    }

    @Test func aScrolledAwayRequestIsCancelled() async {
        let backend = MockBackend()
        await backend.setArtworkDelay(.milliseconds(40))
        await backend.setArtwork(pngData(edge: 20), for: "1")
        let service = ArtworkService(backend: backend, maxConcurrent: 1, settle: .milliseconds(100))
        var delivered = false
        let ticket = service.request(id: "1", pixels: 64) { _ in delivered = true }
        service.cancel(ticket)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(!delivered)
        #expect(await backend.artworkCalls.isEmpty)
        #expect(service.inFlightCount == 0)
    }
}

@MainActor
struct WaveformServiceTests {
    private func style(width: Int = 100) -> WaveformService.Style {
        WaveformService.Style(palette: .bands, pixelWidth: width, pixelHeight: 20, topInset: 0, bottomInset: 0)
    }

    private func bytes() -> Data { Data((0..<300).map { UInt8($0 % 100) }) }

    @Test func fetchesAfterTheSettleDelayAndCaches() async {
        let backend = MockBackend()
        await backend.setWaveform(bytes(), for: "3")
        let service = WaveformService(backend: backend, settle: .milliseconds(35))
        var image: CGImage?
        var done = false
        _ = service.request(id: "3", style: style(), scale: 2) { image = $0; done = true }
        try? await Task.sleep(for: .milliseconds(10))
        #expect(await backend.waveformCalls.isEmpty)  // not yet: the row has not settled
        #expect(await eventually { done })
        #expect(image?.width == 100 && image?.height == 20)
        #expect(await backend.waveformCalls.map(\.kind) == [.bands])

        var cachedHit = false
        let ticket = service.request(id: "3", style: style(), scale: 2) { _ in cachedHit = true }
        #expect(ticket == nil && cachedHit)
        #expect(await backend.waveformCalls.count == 1)
    }

    @Test func aResizeRerendersWithoutFetchingAgain() async {
        let backend = MockBackend()
        await backend.setWaveform(bytes(), for: "3")
        let service = WaveformService(backend: backend, settle: .zero)
        var widths: [Int] = []
        var done = 0
        for width in [100, 150] {
            _ = service.request(id: "3", style: style(width: width), scale: 2) { image in
                widths.append(image?.width ?? -1)
                done += 1
            }
            #expect(await eventually { done == (width == 100 ? 1 : 2) })
        }
        #expect(widths == [100, 150])
        #expect(await backend.waveformCalls.count == 1)
        #expect(service.fetchesStarted == 1)
    }

    @Test func aPaletteChangeIsADifferentEntryAndAFreshFetch() async {
        let backend = MockBackend()
        await backend.setWaveform(Data([0b000_11111, 0b111_10000]), for: "3")
        let service = WaveformService(backend: backend, settle: .zero)
        let mono = WaveformService.Style(palette: .mono, pixelWidth: 2, pixelHeight: 10, topInset: 0, bottomInset: 0)
        var done = false
        _ = service.request(id: "3", style: mono, scale: 2) { _ in done = true }
        #expect(await eventually { done })
        #expect(await backend.waveformCalls.map(\.kind) == [.mono])
        #expect(service.cached(id: "3", style: mono, scale: 2) != nil)
        #expect(service.cached(id: "3", style: style(), scale: 2) == nil)
    }

    @Test func noMoreThanSixteenFetchesAreInFlight() async {
        let backend = MockBackend()
        await backend.setWaveformDelay(.milliseconds(40))
        for i in 0..<60 { await backend.setWaveform(bytes(), for: String(i)) }
        let service = WaveformService(backend: backend, settle: .zero)
        var done = 0
        for i in 0..<60 { _ = service.request(id: String(i), style: style(), scale: 2) { _ in done += 1 } }
        #expect(await eventually(timeout: .seconds(15)) { done == 60 })
        let peak = await backend.peakWaveformCalls
        #expect(peak <= 16 && peak > 1)
    }

    @Test func unanalysedTracksCompleteNil() async {
        let backend = MockBackend()
        let service = WaveformService(backend: backend, settle: .zero)
        var result: CGImage?
        var done = false
        _ = service.request(id: "none", style: style(), scale: 2) { result = $0; done = true }
        #expect(await eventually { done })
        #expect(result == nil)
    }
}

struct PreviewLayoutTests {
    private let band = CGRect(x: 3, y: 2, width: 100, height: 20)

    @Test func theBandInsetsTheCell() {
        let band = PreviewLayout.band(in: CGRect(x: 0, y: 0, width: 128, height: 32))
        #expect(band == CGRect(x: 3, y: 2, width: 122, height: 27))
    }

    @Test func badgesSitOnTheirCueAndStayInsideTheStrip() {
        #expect(PreviewLayout.badgeX(positionMs: 0, durationMs: 1000, band: band, size: 7) == 3)
        #expect(PreviewLayout.badgeX(positionMs: 500, durationMs: 1000, band: band, size: 7) == 53)
        // A cue at the very end is pulled back so the letter stays visible.
        #expect(PreviewLayout.badgeX(positionMs: 1000, durationMs: 1000, band: band, size: 7) == 96)
        #expect(PreviewLayout.badgeX(positionMs: 5000, durationMs: 1000, band: band, size: 7) == 96)
        #expect(PreviewLayout.badgeX(positionMs: 5, durationMs: 0, band: band, size: 7) == 3)
    }

    @Test func memoryMarkersOutsideTheTrackAreSkipped() {
        #expect(PreviewLayout.memoryX(positionMs: 500, durationMs: 1000, band: band) == 53)
        #expect(PreviewLayout.memoryX(positionMs: 1500, durationMs: 1000, band: band) == nil)
        #expect(PreviewLayout.memoryX(positionMs: 5, durationMs: 0, band: band) == nil)
    }

    @Test func cueColoursFallBackToTheDefaultGreen() {
        #expect(PreviewLayout.cueColour(nil) == PreviewLayout.hotCueDefault)
        #expect(PreviewLayout.cueColour("junk") == PreviewLayout.hotCueDefault)
        #expect(PreviewLayout.cueColour("#FF0000") != PreviewLayout.hotCueDefault)
    }

    @Test func rowHeightGrowsOnlyWhenImagesAreShown() {
        var layout = ColumnLayout.defaults(for: .collection)
        #expect(RowSize.height(for: layout, preference: .standard) == RowSize.standard.height)
        layout.order.removeAll { $0 == .artwork || $0 == .preview }
        #expect(RowSize.height(for: layout, preference: .large) == RowSize.textRowHeight)
        layout.order.append(.preview)
        #expect(RowSize.height(for: layout, preference: .large) == RowSize.large.height)
    }
}
