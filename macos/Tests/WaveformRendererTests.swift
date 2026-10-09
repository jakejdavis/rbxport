import CoreGraphics
import Foundation
import Testing

@testable import rbxport

struct WaveformRendererTests {
    /// RGBA of the pixel at `x`, `y` counting from the top-left of the image.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let data = image.dataProvider!.data! as Data
        let bytesPerPixel = image.bitsPerPixel / 8
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]), Int(data[offset + 3]))
    }

    @Test func palettesMapToTheKindsTheBackendReads() {
        #expect(WaveformPalette.bands.kind == .bands)
        #expect(WaveformPalette.mono.kind == .mono)
        #expect(WaveformPalette.colour.kind == .colour)
        #expect([WaveformPalette.bands, .mono, .colour].map(\.stride) == [3, 1, 6])
    }

    @Test func noDataRendersNothing() {
        #expect(WaveformRenderer.render(data: Data(), palette: .bands, pixelWidth: 10, pixelHeight: 10) == nil)
        #expect(WaveformRenderer.render(data: Data([1, 2, 3]), palette: .bands, pixelWidth: 0, pixelHeight: 10) == nil)
        // Fewer bytes than one column.
        #expect(WaveformRenderer.columns(data: Data([1, 2]), palette: .bands, pixelWidth: 4).isEmpty)
    }

    @Test func bandsStackBlueThenAmberThenCream() {
        // low 32 and high 32 are a quarter of their scale (128); mid 64 is a quarter of 256.
        let columns = WaveformRenderer.columns(data: Data([32, 64, 32]), palette: .bands, pixelWidth: 1)
        #expect(columns.count == 1)
        let slabs = columns[0].slabs
        #expect(slabs.map(\.colour) == [WaveformRenderer.low, WaveformRenderer.mid, WaveformRenderer.all])
        #expect(slabs.map(\.fraction) == [0.25, 0.25, 0.25])
        #expect(columns[0].total == 0.75)
    }

    @Test func aStackNeverRunsPastTheTop() {
        // A full low band leaves no room for the others.
        let columns = WaveformRenderer.columns(data: Data([128, 200, 100]), palette: .bands, pixelWidth: 1)
        #expect(columns[0].slabs.count == 1)
        #expect(columns[0].total == 1)
    }

    @Test func aLoudestColumnWinsWhenSeveralShareAPixel() {
        // Two stored columns, one pixel: the louder low band survives.
        let data = Data([10, 0, 0, 100, 0, 0])
        let columns = WaveformRenderer.columns(data: data, palette: .bands, pixelWidth: 1)
        #expect(columns[0].slabs.first?.fraction == 100.0 / 128)
    }

    @Test func monoReadsFiveBitsOfHeightAndThreeOfWhiteness() {
        // Height 31 (full), whiteness 0: pure blue. Height 16, whiteness 7: near-white.
        let data = Data([0b000_11111, 0b111_10000])
        let columns = WaveformRenderer.columns(data: data, palette: .mono, pixelWidth: 2)
        #expect(columns[0].slabs[0].fraction == 1)
        #expect(columns[0].slabs[0].colour == WaveformRenderer.low)
        #expect(columns[1].slabs[0].fraction == 16.0 / 31)
        #expect(columns[1].slabs[0].colour == WaveformRenderer.all)
    }

    @Test func colourReadsHeightFirstAndRGBFromTheLastThreeBytes() {
        // height 127, rgb (2, 4, 1): the strongest channel is scaled to 255.
        let data = Data([127, 0, 0, 2, 4, 1])
        let columns = WaveformRenderer.columns(data: data, palette: .colour, pixelWidth: 1)
        #expect(columns[0].slabs[0].fraction == 1)
        #expect(columns[0].slabs[0].colour == RGB(128, 255, 64))
    }

    @Test func silenceDrawsABaselineNotAHole() {
        let columns = WaveformRenderer.columns(data: Data([0, 0, 0, 5, 5, 5]), palette: .bands, pixelWidth: 2)
        #expect(columns[0].silent)
        #expect(!columns[1].silent)
    }

    @Test func drawnPixelsLandWhereTheColumnsSay() throws {
        // Half-height blue column on the left, nothing but a baseline on the right.
        let data = Data([64, 0, 0, 0, 0, 0])
        let image = try #require(WaveformRenderer.render(data: data, palette: .bands, pixelWidth: 2, pixelHeight: 20))
        #expect(image.width == 2 && image.height == 20)
        // Column 0: low 64/128 of 20 px is 10 px, so the bottom half is blue and the top half is clear.
        let bottom = pixel(image, 0, 19)
        #expect(bottom.a == 255)
        #expect(bottom.b > bottom.r)  // rekordbox blue 0055E1
        #expect(pixel(image, 0, 12).a == 255)
        #expect(pixel(image, 0, 8).a == 0)
        #expect(pixel(image, 0, 0).a == 0)
        // Column 1 is silent: one baseline pixel at the floor, clear above it.
        let line = pixel(image, 1, 19)
        #expect(line.a == 255)
        #expect(pixel(image, 1, 18).a == 0)
    }

    @Test func insetsLeaveTheEdgesClear() throws {
        let data = Data([127, 127, 127])
        let image = try #require(
            WaveformRenderer.render(data: data, palette: .bands, pixelWidth: 1, pixelHeight: 20, topInset: 4, bottomInset: 2))
        #expect(pixel(image, 0, 0).a == 0)  // top inset
        #expect(pixel(image, 0, 19).a == 0)  // bottom inset
        #expect(pixel(image, 0, 10).a == 255)
    }

    @Test func hexColoursParse() {
        #expect(RGB(hexString: "#3CEB50") == RGB(0x3C, 0xEB, 0x50))
        #expect(RGB(hexString: "FF0000") == RGB(255, 0, 0))
        #expect(RGB(hexString: "#12") == nil)
        #expect(RGB(hexString: "#GGGGGG") == nil)
    }
}
