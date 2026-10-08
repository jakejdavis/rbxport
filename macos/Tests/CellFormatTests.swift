import Testing

@testable import rbxport

struct CellFormatTests {
    private func row(_ configure: (inout Row) -> Void = { _ in }) -> Row {
        var row = MockBackend.row(track: 4, position: 5)
        configure(&row)
        return row
    }

    @Test func bpmIsTwoDecimalsAndZeroIsBlank() {
        #expect(CellFormat.bpm(12800) == "128.00")
        #expect(CellFormat.bpm(12345) == "123.45")
        #expect(CellFormat.bpm(0) == "")
    }

    @Test func timeIsPaddedMinutesAndSeconds() {
        #expect(CellFormat.duration(266) == "04:26")
        #expect(CellFormat.duration(0) == "00:00")
        #expect(CellFormat.duration(3725) == "62:05")
    }

    @Test func datesAreShortUS() {
        #expect(CellFormat.shortDate("2026-09-06") == "9/6/26")
        #expect(CellFormat.shortDate("2026-12-31 10:00:00") == "12/31/26")
        #expect(CellFormat.shortDate("") == "")
        #expect(CellFormat.shortDate("soon") == "")
    }

    @Test func sizesAreMegabytesOrGigabytes() {
        #expect(CellFormat.bytes(5_242_880) == "5.0 MB")
        #expect(CellFormat.bytes(1_610_612_736) == "1.5 GB")
    }

    @Test func totalTimeReadsLikeRekordbox() {
        #expect(CellFormat.totalTime(0) == "0 minutes")
        #expect(CellFormat.totalTime(60) == "1 minute")
        #expect(CellFormat.totalTime(3660) == "1 hour 1 minute")
        #expect(CellFormat.totalTime(821 * 3600 + 32 * 60) == "821 hours 32 minutes")
    }

    @Test func sampleRateIsKilohertz() {
        #expect(CellFormat.sampleRate(44100) == "44.1 kHz")
        #expect(CellFormat.sampleRate(48000) == "48 kHz")
        #expect(CellFormat.sampleRate(0) == "")
    }

    @Test func fileTypeCodes() {
        #expect(CellFormat.fileType(1) == "MP3")
        #expect(CellFormat.fileType(6) == "M4A")  // the same name as 4, by decision
        #expect(CellFormat.fileType(4) == "M4A")
        #expect(CellFormat.fileType(5) == "FLAC")
        #expect(CellFormat.fileType(11) == "WAV")
        #expect(CellFormat.fileType(12) == "AIFF")
        #expect(CellFormat.fileType(99) == "99")
        #expect(CellFormat.fileType(0) == "")
    }

    @Test func colorsAreNamedFromOne() {
        #expect(CellFormat.color(0) == "")
        #expect(CellFormat.color(1) == "Pink")
        #expect(CellFormat.color(8) == "Purple")
        #expect(CellFormat.color(9) == "")
    }

    @Test func camelotKeys() {
        #expect(CellFormat.camelot("Ebm") == "2A")
        #expect(CellFormat.camelot("Am") == "8A")
        #expect(CellFormat.camelot("C") == "8B")
        #expect(CellFormat.camelot("D#m") == "2A")  // alias
        #expect(CellFormat.camelot("nonsense") == "")
        #expect(CellFormat.key("Ebm", style: .classic) == "Ebm")
        #expect(CellFormat.key("Ebm", style: .camelot) == "2A")
        #expect(CellFormat.key("nonsense", style: .camelot) == "nonsense")
    }

    @Test func extraColumnsFormatTheirValues() {
        let r = row {
            $0.extra.size = 5_242_880
            $0.extra.fileType = 5
            $0.extra.sampleRate = 44100
            $0.extra.bitrate = 320
            $0.extra.bitDepth = 24
            $0.extra.discNo = 0
            $0.extra.year = 2019
            $0.extra.color = 3
            $0.extra.publishTrackInfo = false
            $0.extra.cloud = true
            $0.extra.dateCreated = "2024-01-02"
            $0.extra.location = "/Music/a.flac"
            $0.extra.djPlayCount = 7
        }
        #expect(CellFormat.text(.size, row: r) == "5.0 MB")
        #expect(CellFormat.text(.fileType, row: r) == "FLAC")
        #expect(CellFormat.text(.sampleRate, row: r) == "44.1 kHz")
        #expect(CellFormat.text(.bitrate, row: r) == "320 kbps")
        #expect(CellFormat.text(.bitDepth, row: r) == "24 bit")
        #expect(CellFormat.text(.discNo, row: r) == "")
        #expect(CellFormat.text(.year, row: r) == "2019")
        #expect(CellFormat.text(.color, row: r) == "Orange")
        #expect(CellFormat.text(.publishTrackInfo, row: r) == "Off")
        #expect(CellFormat.text(.cloud, row: r) == "Cloud")
        #expect(CellFormat.text(.dateCreated, row: r) == "1/2/24")
        #expect(CellFormat.text(.location, row: r) == "/Music/a.flac")
        #expect(CellFormat.text(.djPlayCount, row: r) == "7")
    }

    @Test func unfetchedExtrasAreBlank() {
        let r = row()
        for id in [ColumnID.size, .fileType, .color, .publishTrackInfo, .cloud, .location, .composer, .myTag] {
            #expect(CellFormat.text(id, row: r) == "")
        }
    }

    @Test func hotCuesAreLettersJoinedByCommas() {
        let r = row {
            $0.hotCues = [
                HotCue(slot: "A", positionMs: 0, color: nil), HotCue(slot: "C", positionMs: 1, color: "#fff"),
            ]
        }
        #expect(CellFormat.text(.hotCue, row: r) == "A, C")
        #expect(CellFormat.text(.hotCue, row: row()) == "")
    }

    @Test func basicColumnsComeFromTheRow() {
        let r = row()
        #expect(CellFormat.text(.trackNo, row: r) == "5")
        #expect(CellFormat.text(.title, row: r) == "Track 004")
        #expect(CellFormat.text(.bpm, row: r) == "120.04")
        #expect(CellFormat.text(.duration, row: r) == "03:20")
        #expect(CellFormat.text(.dateAdded, row: r) == "1/1/26")
        #expect(CellFormat.text(.releaseDate, row: r) == "")
        #expect(CellFormat.text(.rating, row: r) == "")  // drawn as stars
        #expect(CellFormat.stars(7).lit == 5)
    }
}
