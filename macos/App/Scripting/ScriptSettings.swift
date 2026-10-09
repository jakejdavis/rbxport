import Foundation

/// The preferences a script can read and set, by `pane.field` name: the store's own keys, in the
/// order Settings lists them. The keyboard overrides are records with an editor of their own and
/// are left out, as the DJ System's category and sort rows are in the Tauri build.
@MainActor
enum ScriptSettings {
    struct Entry {
        let name: String
        let read: @MainActor (PreferencesStore) -> ScriptValue
        /// False when the value is not one the choice keeps.
        let write: @MainActor (PreferencesStore, ScriptValue) -> Bool
    }

    static func entry(named name: String) -> Entry? { all.first { $0.name == name } }

    /// Names in order, as `setting` elements.
    static var names: [String] { all.map(\.name) }

    // MARK: Building blocks

    private static func flag(_ name: String, _ path: ReferenceWritableKeyPath<PreferencesStore, Bool>) -> Entry {
        Entry(
            name: name, read: { .bool($0[keyPath: path]) },
            write: { store, value in
                guard case .bool(let on) = value else { return false }
                store[keyPath: path] = on
                return true
            })
    }

    private static func number(_ name: String, _ path: ReferenceWritableKeyPath<PreferencesStore, Int>, allowed: [Int]) -> Entry {
        Entry(
            name: name, read: { .int(Int64($0[keyPath: path])) },
            write: { store, value in
                guard let n = integer(value), allowed.contains(n) else { return false }
                store[keyPath: path] = n
                return true
            })
    }

    /// A choice stored under a string; `names` pairs each spelling with the value it stands for.
    private static func choice<T: Equatable>(
        _ name: String, _ path: ReferenceWritableKeyPath<PreferencesStore, T>, _ names: [(String, T)]
    ) -> Entry {
        Entry(
            name: name,
            read: { store in
                let current = store[keyPath: path]
                return .text(names.first { $0.1 == current }?.0 ?? names[0].0)
            },
            write: { store, value in
                guard case .text(let text) = value, let hit = names.first(where: { $0.0 == text }) else { return false }
                store[keyPath: path] = hit.1
                return true
            })
    }

    private static func raw<T: RawRepresentable & CaseIterable & Equatable>(
        _ name: String, _ path: ReferenceWritableKeyPath<PreferencesStore, T>
    ) -> Entry where T.RawValue == String {
        choice(name, path, T.allCases.map { ($0.rawValue, $0) })
    }

    /// A whole number a script may have written as `512` or `512.0`.
    private static func integer(_ value: ScriptValue) -> Int? {
        switch value {
        case .int(let n): return Int(exactly: n)
        case .real(let n) where n.rounded() == n && abs(n) < 1e15: return Int(n)
        default: return nil
        }
    }

    // MARK: The table

    static let all: [Entry] = [
        choice("view.keyDisplay", \.keyDisplay, [("classic", .classic), ("alphanumeric", .camelot)]),
        choice("view.waveformColor", \.waveformColor, [("3band", .bands), ("blue", .mono), ("rgb", .colour)]),
        flag("view.playlistCounts", \.playlistCounts),
        flag("view.waveformClick", \.waveformClick),

        number("audio.sampleRate", \.sampleRate, allowed: [44_100, 48_000, 88_200, 96_000]),
        number("audio.bufferSize", \.bufferSize, allowed: [64, 128, 256, 512, 1_024, 2_048]),
        number("audio.metronomeSound", \.metronomeSound, allowed: [1, 2, 3]),

        raw("analysis.mode", \.analysisMode),
        number("analysis.concurrentTracks", \.concurrentTracks, allowed: [1, 2, 3, 4]),

        raw("djSystem.waveformColor", \.djWaveformColor),
        raw("djSystem.waveformPosition", \.djWaveformPosition),
        raw("djSystem.overviewWaveform", \.djOverview),
        raw("djSystem.keyDisplay", \.djKeyDisplay),
        Entry(
            name: "djSystem.linkInterface", read: { $0.linkInterface.map(ScriptValue.text) ?? .missing },
            write: { store, value in
                switch value {
                case .missing: store.linkInterface = nil
                case .text(let text): store.linkInterface = text.isEmpty ? nil : text
                default: return false
                }
                return true
            }),
        flag("djSystem.autoJoinLink", \.autoJoinLink),
        raw("djSystem.linkKeySort", \.linkKeySort),

        flag("advanced.protectLibrary", \.protectLibrary),
        flag("advanced.recordHistory", \.recordHistory),
        raw("advanced.quantizeBeat", \.quantizeBeat),
        raw("advanced.syncType", \.syncType),
        flag("advanced.syncDoubleHalf", \.syncDoubleHalf),

        flag("usbExport.deleteUnlistedMusic", \.deleteUnlistedMusic),
        flag("usbExport.maximumCompatibility", \.maximumCompatibility),
        raw("usbExport.conversionFormat", \.conversionFormat),
        flag("usbExport.importButtonCues", \.importButtonCues),
        flag("usbExport.importButtonHistory", \.importButtonHistory),
        flag("usbExport.importButtonSettings", \.importButtonSettings),
        flag("usbExport.ejectAfterSync", \.ejectAfterSync),
    ]

    // MARK: Reading and setting

    static func value(of name: String, in store: PreferencesStore) -> ScriptValue {
        entry(named: name)?.read(store) ?? .missing
    }

    /// Sets one choice, or says why not. Changes nothing for a name that is not a setting or a
    /// value the choice would not keep (the messages are the Tauri build's).
    static func set(_ name: String, to value: ScriptValue, in store: PreferencesStore) throws {
        guard let entry = entry(named: name) else { throw ScriptError.failed("There is no setting called \(name).") }
        guard entry.write(store, value) else {
            throw ScriptError.failed("\(name) cannot be set to \(ScriptText.json(value)).")
        }
    }
}
