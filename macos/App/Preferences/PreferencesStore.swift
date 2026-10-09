import Foundation
import Observation

// MARK: - Choices

/// Analysis › Analysis mode (`analysis.mode`): rbxport's own analyser, or rekordbox's settings.
enum AnalysisMode: String, CaseIterable, Sendable {
    case rbxport, rekordbox
}

/// Advanced › Quantize beat value (`advanced.quantizeBeat`).
enum QuantizeBeat: String, CaseIterable, Sendable {
    case whole = "1/1", half = "1/2", quarter = "1/4", eighth = "1/8"

    /// How many steps one beat is split into.
    var divisions: Int {
        switch self {
        case .whole: 1
        case .half: 2
        case .quarter: 4
        case .eighth: 8
        }
    }
}

/// Advanced › BEAT SYNC or BPM SYNC (`advanced.syncType`).
enum SyncType: String, CaseIterable, Sendable {
    case beat, bpm
}

/// DJ System › the defaults a stick gets on its first export (`djSystem.*`).
enum DjWaveformColor: String, CaseIterable, Sendable {
    case blue, rgb
    case threeBand = "3band"
}
enum DjWaveformPosition: String, CaseIterable, Sendable { case center, left }
enum DjOverview: String, CaseIterable, Sendable { case half, full }
enum DjKeyDisplay: String, CaseIterable, Sendable { case classic, alphanumeric }

/// USB Export › Convert to (`usbExport.conversionFormat`).
enum ConversionChoice: String, CaseIterable, Sendable { case wav, aiff, mp3 }

/// The groups Settings can reset, named as React's `PreferencePane`.
enum PreferencePane: String, CaseIterable, Sendable {
    case view, audio, analysis, djSystem, advanced, usbExport, keyboard
}

// MARK: - Keys

/// Every stored name. The dotted ones are React's (`src/lib/preferences.ts`); `legacy` names are what
/// phases 2 to 5 stored before the store existed. They are read once, on migration, and left in place.
enum PrefKeys {
    static let keyDisplay = "view.keyDisplay"
    static let waveformColor = "view.waveformColor"
    static let playlistCounts = "view.playlistCounts"
    static let waveformClick = "view.waveformClick"
    /// Not a React pref (React sizes rows with FontSize and Line Space); kept under its native name.
    static let rowSize = "rowSize"

    static let sampleRate = "audio.sampleRate"
    static let bufferSize = "audio.bufferSize"
    static let metronomeSound = "audio.metronomeSound"

    static let analysisMode = "analysis.mode"
    static let concurrentTracks = "analysis.concurrentTracks"

    static let djWaveformColor = "djSystem.waveformColor"
    static let djWaveformPosition = "djSystem.waveformPosition"
    static let djOverview = "djSystem.overviewWaveform"
    static let djKeyDisplay = "djSystem.keyDisplay"
    static let linkInterface = "djSystem.linkInterface"
    static let autoJoinLink = "djSystem.autoJoinLink"
    static let linkKeySort = "djSystem.linkKeySort"

    static let protectLibrary = "advanced.protectLibrary"
    static let recordHistory = "advanced.recordHistory"
    static let quantizeBeat = "advanced.quantizeBeat"
    static let syncType = "advanced.syncType"
    static let syncDoubleHalf = "advanced.syncDoubleHalf"

    static let deleteUnlistedMusic = "usbExport.deleteUnlistedMusic"
    static let maximumCompatibility = "usbExport.maximumCompatibility"
    static let conversionFormat = "usbExport.conversionFormat"
    static let importButtonCues = "usbExport.importButtonCues"
    static let importButtonHistory = "usbExport.importButtonHistory"
    static let importButtonSettings = "usbExport.importButtonSettings"
    /// Native only: eject the stick after a sync.
    static let ejectAfterSync = "usbExport.ejectAfterSync"

    static let keyboardOverrides = "keyboard.overrides"

    /// Names stored before the store existed, and what replaced them.
    enum Legacy {
        static let keyStyle = "keyStyle"
        static let waveformPalette = "waveformPalette"
        static let childCounts = "sidebar.childCounts"
        static let waveformClick = "deck.waveformClick"
        static let protectLibrary = "protectLibrary"
        static let recordHistory = "recordHistory"
        static let slots = "analysis.slots"
        static let metronomeSound = "player.metronomeSound"
    }
}

// MARK: - Store

/// Everything Settings changes, over one `UserDefaults`. Keeps React's names and defaults, checks
/// every value on the way in (a hand-edited or stale value comes back as the default), and tells
/// the models that act on a change. Panes bind to it; the models read it.
///
/// Migration is non-destructive: a native name from an earlier phase is copied to its React name
/// the first time, only when the React name is absent, and the old entry is left where it was.
@MainActor @Observable
final class PreferencesStore {
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var listeners: [@MainActor (String) -> Void] = []

    // View
    var keyDisplay: KeyStyle = .classic { didSet { changed(PrefKeys.keyDisplay, keyDisplay != oldValue, Self.name(of: keyDisplay)) } }
    var waveformColor: WaveformPalette = .bands { didSet { changed(PrefKeys.waveformColor, waveformColor != oldValue, Self.name(of: waveformColor)) } }
    var playlistCounts = false { didSet { changed(PrefKeys.playlistCounts, playlistCounts != oldValue, playlistCounts) } }
    var waveformClick = true { didSet { changed(PrefKeys.waveformClick, waveformClick != oldValue, waveformClick) } }
    var rowSize: RowSize = .standard { didSet { changed(PrefKeys.rowSize, rowSize != oldValue, rowSize.rawValue) } }

    // Audio
    var sampleRate = 48_000 { didSet { changed(PrefKeys.sampleRate, sampleRate != oldValue, sampleRate) } }
    var bufferSize = 512 { didSet { changed(PrefKeys.bufferSize, bufferSize != oldValue, bufferSize) } }
    var metronomeSound = 2 { didSet { changed(PrefKeys.metronomeSound, metronomeSound != oldValue, metronomeSound) } }

    // Analysis
    var analysisMode: AnalysisMode = .rbxport { didSet { changed(PrefKeys.analysisMode, analysisMode != oldValue, analysisMode.rawValue) } }
    var concurrentTracks = 3 { didSet { changed(PrefKeys.concurrentTracks, concurrentTracks != oldValue, concurrentTracks) } }

    // DJ System (what a stick is given on its first export), and the LINK choices that live beside them
    var djWaveformColor: DjWaveformColor = .threeBand { didSet { changed(PrefKeys.djWaveformColor, djWaveformColor != oldValue, djWaveformColor.rawValue) } }
    var djWaveformPosition: DjWaveformPosition = .center { didSet { changed(PrefKeys.djWaveformPosition, djWaveformPosition != oldValue, djWaveformPosition.rawValue) } }
    var djOverview: DjOverview = .half { didSet { changed(PrefKeys.djOverview, djOverview != oldValue, djOverview.rawValue) } }
    var djKeyDisplay: DjKeyDisplay = .classic { didSet { changed(PrefKeys.djKeyDisplay, djKeyDisplay != oldValue, djKeyDisplay.rawValue) } }
    var linkInterface: String? {
        didSet {
            guard !loading, linkInterface != oldValue else { return }
            if let linkInterface { defaults.set(linkInterface, forKey: PrefKeys.linkInterface) } else { defaults.removeObject(forKey: PrefKeys.linkInterface) }
            notify(PrefKeys.linkInterface)
        }
    }
    var autoJoinLink = false { didSet { changed(PrefKeys.autoJoinLink, autoJoinLink != oldValue, autoJoinLink) } }
    var linkKeySort: LinkKeySort = .musical { didSet { changed(PrefKeys.linkKeySort, linkKeySort != oldValue, linkKeySort.rawValue) } }

    // Advanced
    var protectLibrary = true { didSet { changed(PrefKeys.protectLibrary, protectLibrary != oldValue, protectLibrary) } }
    var recordHistory = true { didSet { changed(PrefKeys.recordHistory, recordHistory != oldValue, recordHistory) } }
    var quantizeBeat: QuantizeBeat = .whole { didSet { changed(PrefKeys.quantizeBeat, quantizeBeat != oldValue, quantizeBeat.rawValue) } }
    var syncType: SyncType = .beat { didSet { changed(PrefKeys.syncType, syncType != oldValue, syncType.rawValue) } }
    var syncDoubleHalf = true { didSet { changed(PrefKeys.syncDoubleHalf, syncDoubleHalf != oldValue, syncDoubleHalf) } }

    // USB Export
    var deleteUnlistedMusic = false { didSet { changed(PrefKeys.deleteUnlistedMusic, deleteUnlistedMusic != oldValue, deleteUnlistedMusic) } }
    var maximumCompatibility = false { didSet { changed(PrefKeys.maximumCompatibility, maximumCompatibility != oldValue, maximumCompatibility) } }
    var conversionFormat: ConversionChoice = .wav { didSet { changed(PrefKeys.conversionFormat, conversionFormat != oldValue, conversionFormat.rawValue) } }
    var importButtonCues = true { didSet { changed(PrefKeys.importButtonCues, importButtonCues != oldValue, importButtonCues) } }
    var importButtonHistory = true { didSet { changed(PrefKeys.importButtonHistory, importButtonHistory != oldValue, importButtonHistory) } }
    var importButtonSettings = false { didSet { changed(PrefKeys.importButtonSettings, importButtonSettings != oldValue, importButtonSettings) } }
    var ejectAfterSync = false { didSet { changed(PrefKeys.ejectAfterSync, ejectAfterSync != oldValue, ejectAfterSync) } }

    // Keyboard
    /// The keys changed from the preset, by binding id. An unbound key is a chord with an empty key.
    var keyboardOverrides: [String: Chord] = [:] {
        didSet {
            guard keyboardOverrides != oldValue else { return }
            keymap = Keymap(overrides: keyboardOverrides)
            if keyboardOverrides.isEmpty {
                defaults.removeObject(forKey: PrefKeys.keyboardOverrides)
            } else if let data = try? JSONEncoder.sorted.encode(keyboardOverrides), let text = String(data: data, encoding: .utf8) {
                defaults.set(text, forKey: PrefKeys.keyboardOverrides)
            }
            notify(PrefKeys.keyboardOverrides)
        }
    }
    /// The binding table with the overrides applied (rebuilt when they change).
    private(set) var keymap = Keymap()

    init(defaults: UserDefaults) {
        self.defaults = defaults
        Self.migrate(defaults)
        load()
    }

    // MARK: Listening

    /// Calls `body` with the key's name after any value changes, from the Settings window or code.
    func onChange(_ body: @escaping @MainActor (String) -> Void) { listeners.append(body) }

    private func notify(_ key: String) { listeners.forEach { $0(key) } }

    /// Writes one value under its name and tells the listeners. Does nothing when nothing changed.
    private func changed(_ key: String, _ differs: Bool, _ value: Any) {
        guard !loading, differs else { return }
        defaults.set(value, forKey: key)
        notify(key)
    }
    @ObservationIgnored private var loading = false

    // MARK: Reading (sanitising)

    private func load() {
        loading = true
        defer { loading = false }
        let d = defaults
        keyDisplay = Self.pick(d.string(forKey: PrefKeys.keyDisplay), Self.keyDisplayNames, else: .classic)
        waveformColor = Self.pick(d.string(forKey: PrefKeys.waveformColor), Self.waveformNames, else: .bands)
        playlistCounts = Self.bool(d, PrefKeys.playlistCounts, false)
        waveformClick = Self.bool(d, PrefKeys.waveformClick, true)
        rowSize = d.string(forKey: PrefKeys.rowSize).flatMap(RowSize.init) ?? .standard

        sampleRate = Self.member(d, PrefKeys.sampleRate, [44_100, 48_000, 88_200, 96_000], 48_000)
        bufferSize = Self.member(d, PrefKeys.bufferSize, [64, 128, 256, 512, 1_024, 2_048], 512)
        metronomeSound = Self.member(d, PrefKeys.metronomeSound, [1, 2, 3], 2)

        analysisMode = d.string(forKey: PrefKeys.analysisMode).flatMap(AnalysisMode.init) ?? .rbxport
        concurrentTracks = Self.member(d, PrefKeys.concurrentTracks, [1, 2, 3, 4], 3)

        djWaveformColor = d.string(forKey: PrefKeys.djWaveformColor).flatMap(DjWaveformColor.init) ?? .threeBand
        djWaveformPosition = d.string(forKey: PrefKeys.djWaveformPosition).flatMap(DjWaveformPosition.init) ?? .center
        djOverview = d.string(forKey: PrefKeys.djOverview).flatMap(DjOverview.init) ?? .half
        djKeyDisplay = d.string(forKey: PrefKeys.djKeyDisplay).flatMap(DjKeyDisplay.init) ?? .classic
        linkInterface = d.string(forKey: PrefKeys.linkInterface).flatMap { $0.isEmpty ? nil : $0 }
        autoJoinLink = Self.bool(d, PrefKeys.autoJoinLink, false)
        linkKeySort = d.string(forKey: PrefKeys.linkKeySort).flatMap(LinkKeySort.init) ?? .musical

        protectLibrary = Self.bool(d, PrefKeys.protectLibrary, true)
        recordHistory = Self.bool(d, PrefKeys.recordHistory, true)
        quantizeBeat = d.string(forKey: PrefKeys.quantizeBeat).flatMap(QuantizeBeat.init) ?? .whole
        syncType = d.string(forKey: PrefKeys.syncType).flatMap(SyncType.init) ?? .beat
        syncDoubleHalf = Self.bool(d, PrefKeys.syncDoubleHalf, true)

        deleteUnlistedMusic = Self.bool(d, PrefKeys.deleteUnlistedMusic, false)
        maximumCompatibility = Self.bool(d, PrefKeys.maximumCompatibility, false)
        conversionFormat = d.string(forKey: PrefKeys.conversionFormat).flatMap(ConversionChoice.init) ?? .wav
        importButtonCues = Self.bool(d, PrefKeys.importButtonCues, true)
        importButtonHistory = Self.bool(d, PrefKeys.importButtonHistory, true)
        importButtonSettings = Self.bool(d, PrefKeys.importButtonSettings, false)
        ejectAfterSync = Self.bool(d, PrefKeys.ejectAfterSync, false)

        keyboardOverrides = Chord.sanitisedOverrides(d.string(forKey: PrefKeys.keyboardOverrides))
        keymap = Keymap(overrides: keyboardOverrides)
    }

    private static func bool(_ d: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        d.object(forKey: key) as? Bool ?? fallback
    }

    /// An integer from a fixed set, or the fallback.
    private static func member(_ d: UserDefaults, _ key: String, _ allowed: [Int], _ fallback: Int) -> Int {
        guard let value = d.object(forKey: key) as? Int, allowed.contains(value) else { return fallback }
        return value
    }

    private static func pick<T>(_ name: String?, _ table: [String: T], else fallback: T) -> T {
        name.flatMap { table[$0] } ?? fallback
    }

    // Native enums, stored under React's spellings.
    private static let keyDisplayNames: [String: KeyStyle] = ["classic": .classic, "alphanumeric": .camelot]
    private static let waveformNames: [String: WaveformPalette] = ["3band": .bands, "blue": .mono, "rgb": .colour]
    static func name(of style: KeyStyle) -> String { style == .camelot ? "alphanumeric" : "classic" }
    static func name(of palette: WaveformPalette) -> String {
        switch palette {
        case .bands: "3band"
        case .mono: "blue"
        case .colour: "rgb"
        }
    }

    // MARK: Migration

    /// Copies each earlier native name to its React name when the React name is not there yet.
    /// The earlier entry stays, so nothing is lost if a build that reads it is run again.
    static func migrate(_ d: UserDefaults) {
        func move(_ old: String, to new: String, _ map: (Any) -> Any? = { $0 }) {
            guard d.object(forKey: new) == nil, let value = d.object(forKey: old), let mapped = map(value) else { return }
            d.set(mapped, forKey: new)
        }
        move(PrefKeys.Legacy.keyStyle, to: PrefKeys.keyDisplay) { ($0 as? String) == "camelot" ? "alphanumeric" : "classic" }
        move(PrefKeys.Legacy.waveformPalette, to: PrefKeys.waveformColor) {
            switch $0 as? String {
            case "mono": "blue"
            case "colour": "rgb"
            default: "3band"
            }
        }
        move(PrefKeys.Legacy.childCounts, to: PrefKeys.playlistCounts)
        move(PrefKeys.Legacy.waveformClick, to: PrefKeys.waveformClick)
        move(PrefKeys.Legacy.protectLibrary, to: PrefKeys.protectLibrary)
        move(PrefKeys.Legacy.recordHistory, to: PrefKeys.recordHistory)
        move(PrefKeys.Legacy.slots, to: PrefKeys.concurrentTracks)
        move(PrefKeys.Legacy.metronomeSound, to: PrefKeys.metronomeSound)
    }

    // MARK: Reset

    /// Writes a pane's defaults back (Settings › Reset to defaults), as React's `reset(pane)`.
    func reset(_ pane: PreferencePane) {
        switch pane {
        case .view:
            keyDisplay = .classic
            waveformColor = .bands
            playlistCounts = false
            waveformClick = true
            rowSize = .standard
        case .audio:
            sampleRate = 48_000
            bufferSize = 512
            metronomeSound = 2
        case .analysis:
            analysisMode = .rbxport
            concurrentTracks = 3
        case .djSystem:
            djWaveformColor = .threeBand
            djWaveformPosition = .center
            djOverview = .half
            djKeyDisplay = .classic
            linkInterface = nil
            autoJoinLink = false
            linkKeySort = .musical
        case .advanced:
            protectLibrary = true
            recordHistory = true
            quantizeBeat = .whole
            syncType = .beat
            syncDoubleHalf = true
        case .usbExport:
            deleteUnlistedMusic = false
            maximumCompatibility = false
            conversionFormat = .wav
            importButtonCues = true
            importButtonHistory = true
            importButtonSettings = false
            ejectAfterSync = false
        case .keyboard:
            keyboardOverrides = [:]
        }
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
