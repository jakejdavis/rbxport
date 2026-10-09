import AppKit
import SwiftUI

/// The Settings window: one tab per pane of the React Preferences window, in its order (View, Audio,
/// Analysis, DJ System, Keyboard, Advanced, PRO DJ LINK, USB Export, About). Every control writes
/// to the preferences store; the panes with something to reset have a Reset to Defaults button.
/// Backups arrive with phase 6b. Rekordbox's "keep browse settings synchronized" has nothing behind
/// it here yet, so it is not drawn.
struct SettingsView: View {
    let model: AppModel
    /// `RBXPORT_SETTINGS_TAB=view|audio|analysis|dj|keyboard|advanced|link|usb|about` opens a tab, for screenshots.
    @State private var tab = ProcessInfo.processInfo.environment["RBXPORT_SETTINGS_TAB"] ?? SettingsTab.view.rawValue

    var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases) { item in
                pane(item)
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item.rawValue)
            }
        }
        .frame(minWidth: SettingsTab.minSize.width, idealWidth: SettingsTab.idealSize.width,
               minHeight: SettingsTab.minSize.height, idealHeight: SettingsTab.idealSize.height)
        .scenePadding()
    }

    @ViewBuilder private func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .view: ViewPane(prefs: model.prefs)
        case .audio: AudioPane(player: model.player).paneFooter(model.prefs, .audio)
        case .analysis: AnalysisPane(prefs: model.prefs)
        case .dj: DjSystemPane(prefs: model.prefs)
        case .keyboard: KeyboardPane(prefs: model.prefs)
        case .advanced: AdvancedPane(model: model)
        case .link: LinkPane(model: model.link)
        case .usb: UsbExportPane(prefs: model.prefs)
        case .about: AboutPane()
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case view, audio, analysis, dj, keyboard, advanced, link, usb, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .view: "View"
        case .audio: "Audio"
        case .analysis: "Analysis"
        case .dj: "DJ System"
        case .keyboard: "Keyboard"
        case .advanced: "Advanced"
        case .link: "PRO DJ LINK"
        case .usb: "USB Export"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .view: "eye"
        case .audio: "speaker.wave.2"
        case .analysis: "waveform.path.ecg"
        case .dj: "opticaldisc"
        case .keyboard: "keyboard"
        case .advanced: "gearshape.2"
        case .link: "link"
        case .usb: "externaldrive"
        case .about: "info.circle"
        }
    }

    /// The window never opens smaller than this (the LINK pane was clipped at 520 by 400).
    static let minSize = CGSize(width: 640, height: 520)
    static let idealSize = CGSize(width: 720, height: 640)
}

extension View {
    /// A pane with a Reset to Defaults button under it, as React's Preferences window has.
    func paneFooter(_ prefs: PreferencesStore, _ pane: PreferencePane) -> some View {
        VStack(spacing: 0) {
            self
            Divider()
            HStack {
                Spacer()
                Button("Reset to Defaults") { prefs.reset(pane) }
                    .accessibilityIdentifier("reset-\(pane.rawValue)")
            }
            .padding(.vertical, 10).padding(.horizontal, 20)
        }
    }
}

private func note(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
}

// MARK: - View

struct ViewPane: View {
    @Bindable var prefs: PreferencesStore

    var body: some View {
        Form {
            Section("Display") {
                Picker("Key display format", selection: $prefs.keyDisplay) {
                    Text("Classic (Am, Ebm)").tag(KeyStyle.classic)
                    Text("Alphanumeric (8A, 2A)").tag(KeyStyle.camelot)
                }
                .pickerStyle(.radioGroup)
                Picker("Waveform color", selection: $prefs.waveformColor) {
                    ForEach(WaveformPalette.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Row size (artwork and preview columns)", selection: $prefs.rowSize) {
                    ForEach(RowSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section("Browser") {
                Toggle("Display the number of tracks in a playlist on the Tree View", isOn: $prefs.playlistCounts)
            }
            Section("Player") {
                Toggle("Click on the waveform for PLAY and CUE", isOn: $prefs.waveformClick)
                note("A click on the enlarged waveform moves the playhead there, and plays.")
            }
        }
        .formStyle(.grouped)
        .paneFooter(prefs, .view)
    }
}

// MARK: - Analysis

struct AnalysisPane: View {
    @Bindable var prefs: PreferencesStore

    var body: some View {
        Form {
            Section("Analysis") {
                Picker("Analysis mode", selection: $prefs.analysisMode) {
                    Text("Rekordbox \u{00B7} Normal").tag(AnalysisMode.rekordbox)
                    Text("RBXport (for Electronic Music)").tag(AnalysisMode.rbxport)
                }
                note(
                    prefs.analysisMode == .rbxport
                        ? "RBXport's own analyser, tuned for electronic music."
                        : "Analyses with rekordbox's settings.")
                Picker("Tracks analysed at once", selection: $prefs.concurrentTracks) {
                    ForEach(AnalysisQueue.slotChoices, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section {
                Toggle("Automatic analysis", isOn: .constant(false)).disabled(true)
                note("Analysing imported tracks automatically is not available in the native app yet.")
            }
        }
        .formStyle(.grouped)
        .paneFooter(prefs, .analysis)
    }
}

// MARK: - DJ System

struct DjSystemPane: View {
    @Bindable var prefs: PreferencesStore

    var body: some View {
        Form {
            Section("Defaults for a new USB drive") {
                Picker("Waveform color on CDJ", selection: $prefs.djWaveformColor) {
                    Text("Blue").tag(DjWaveformColor.blue)
                    Text("RGB").tag(DjWaveformColor.rgb)
                    Text("3 Band").tag(DjWaveformColor.threeBand)
                }
                Picker("Waveform current position", selection: $prefs.djWaveformPosition) {
                    Text("Center").tag(DjWaveformPosition.center)
                    Text("Left").tag(DjWaveformPosition.left)
                }
                Picker("Overview", selection: $prefs.djOverview) {
                    Text("Half waveform").tag(DjOverview.half)
                    Text("Full waveform").tag(DjOverview.full)
                }
                Picker("Key display", selection: $prefs.djKeyDisplay) {
                    Text("Classic").tag(DjKeyDisplay.classic)
                    Text("Alphanumeric").tag(DjKeyDisplay.alphanumeric)
                }
                note("A drive that already carries settings keeps its own; its device panel edits them.")
            }
        }
        .formStyle(.grouped)
        .paneFooter(prefs, .djSystem)
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    let model: AppModel
    @State private var confirmingUnlock = false

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Library protection") {
                Toggle(
                    "Protect library edit.",
                    isOn: Binding(
                        get: { model.protectLibrary },
                        set: { on in
                            if on { model.protectLibrary = true } else { confirmingUnlock = true }
                        })
                )
                .accessibilityIdentifier("protect-library")
                note(
                    "While on, rbxport will not change your rekordbox library: no playlists, tags or ratings are written, and undo is off. Turn it off to edit. rekordbox must be closed while you edit."
                )
                if model.isReadOnly && !model.protectLibrary {
                    note("Editing is still locked while rekordbox is running. Quit rekordbox to enable editing.")
                }
            }
            Section("History") {
                Toggle("Record play history", isOn: $prefs.recordHistory)
            }
            Section("Quantize") {
                Picker("Quantize beat value", selection: $prefs.quantizeBeat) {
                    ForEach(QuantizeBeat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("BEAT/BPM sync") {
                Picker("Sync type", selection: $prefs.syncType) {
                    Text("BEAT SYNC").tag(SyncType.beat)
                    Text("BPM SYNC").tag(SyncType.bpm)
                }
                .pickerStyle(.radioGroup)
                Toggle("Allow BEAT/BPM SYNC with double/half BPM", isOn: $prefs.syncDoubleHalf)
            }
            Section {
                Toggle("Double-click to edit", isOn: .constant(false)).disabled(true)
                note("Editing a cell with a click on a selected row is not available in the native app yet.")
            }
        }
        .formStyle(.grouped)
        .paneFooter(prefs, .advanced)
        .confirmationDialog("Turn off Library Protection?", isPresented: $confirmingUnlock) {
            Button("Turn Off Protection", role: .destructive) { model.protectLibrary = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Edits are written to your rekordbox library. Make a backup first if you have not.")
        }
    }
}

// MARK: - USB Export

struct UsbExportPane: View {
    @Bindable var prefs: PreferencesStore

    var body: some View {
        Form {
            Section("Exporting") {
                Toggle("Delete music not in any playlist", isOn: $prefs.deleteUnlistedMusic)
                Toggle("Eject the drive after a sync", isOn: $prefs.ejectAfterSync)
                Toggle("Maximum CDJ compatibility", isOn: $prefs.maximumCompatibility)
                Picker("Convert to", selection: $prefs.conversionFormat) {
                    Text("WAV").tag(ConversionChoice.wav)
                    Text("AIFF").tag(ConversionChoice.aiff)
                    Text("MP3").tag(ConversionChoice.mp3)
                }
                .pickerStyle(.segmented)
                .disabled(!prefs.maximumCompatibility)
                note("Formats a player cannot read are converted as they are copied.")
            }
            Section("Ticked when Import from USB opens") {
                Toggle("Import cues and beat grids", isOn: $prefs.importButtonCues)
                Toggle("Import play history", isOn: $prefs.importButtonHistory)
                Toggle("Import CDJ/mixer settings", isOn: $prefs.importButtonSettings)
            }
        }
        .formStyle(.grouped)
        .paneFooter(prefs, .usbExport)
    }
}

// MARK: - About

struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "\u{2014}"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("rbxport", value: version)
                LabeledContent("Licence", value: "GPL-2.0-or-later")
                note("Time stretching uses the Rubber Band Library under the same licence.")
            }
            Section("Disclaimer") {
                note(
                    "rbxport is not affiliated with AlphaTheta or Pioneer DJ. rekordbox, CDJ and PRO DJ LINK are their trademarks. Back up your library before you write to it.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keyboard

/// Every binding in its group; click a key to change it, Delete to unbind, Escape to cancel.
struct KeyboardPane: View {
    let prefs: PreferencesStore
    @State private var rebinder: KeyRebinder
    @State private var capture = KeyCaptureMonitor()
    @State private var open: Set<BindingGroup> = [.browse]

    init(prefs: PreferencesStore) {
        self.prefs = prefs
        _rebinder = State(initialValue: KeyRebinder(prefs: prefs))
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(BindingGroup.allCases, id: \.self) { group in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { open.contains(group) },
                            set: { if $0 { open.insert(group) } else { open.remove(group) } })
                    ) {
                        ForEach(KeyRebinder.rows(in: group)) { binding in row(binding) }
                    } label: {
                        Text(group.title).font(.headline)
                    }
                }
            }
            if let message = rebinder.message {
                Text(message).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 6)
                    .accessibilityIdentifier("key-message")
            }
            Divider()
            HStack {
                Text("Changed keys are marked. A key taken from another binding leaves that one unbound.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset to the Preset") { rebinder.resetAll() }
                    .disabled(prefs.keyboardOverrides.isEmpty)
                    .accessibilityIdentifier("reset-keyboard")
            }
            .padding(.vertical, 10).padding(.horizontal, 20)
        }
        .onChange(of: rebinder.recording) { _, id in
            if id == nil { capture.stop() } else { capture.start { rebinder.capture($0) } }
        }
        .onDisappear {
            rebinder.cancel()
            capture.stop()
        }
        .alert(
            "Use this key?",
            isPresented: Binding(get: { rebinder.pending != nil }, set: { if !$0 { rebinder.cancel() } }),
            presenting: rebinder.pending
        ) { _ in
            Button("Reassign") { rebinder.confirmPending() }
            Button("Cancel", role: .cancel) { rebinder.cancel() }
        } message: { pending in
            let names = pending.holders.compactMap { BindingTable.byID[$0]?.label }.joined(separator: ", ")
            Text("\(pending.chord.display) is used by \(names). Reassigning leaves that unbound.")
        }
    }

    @ViewBuilder private func row(_ binding: KeyBinding) -> some View {
        let chord = prefs.keymap.chord(for: binding.id)
        let changed = prefs.keymap.isChanged(binding.id)
        let listening = rebinder.recording == binding.id
        HStack {
            Text(binding.label)
            if changed { Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("Changed from the preset") }
            Spacer()
            if binding.rebindable {
                Button(listening ? "Press a key\u{2026}" : chord.display) {
                    listening ? rebinder.cancel() : rebinder.begin(binding.id)
                }
                .buttonStyle(.bordered)
                .monospacedDigit()
                .accessibilityIdentifier("key-\(binding.id)")
                Button {
                    rebinder.reset(binding.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to the preset")
                .disabled(!changed)
            } else {
                Text(chord.display).foregroundStyle(.secondary).help("Built in")
            }
        }
    }
}

/// Listens for the next key while a row is recording, and keeps it from the decks and the menus.
@MainActor
final class KeyCaptureMonitor {
    private var monitor: Any?

    func start(_ body: @escaping @MainActor (Chord) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { body(Chord(event: event)) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
