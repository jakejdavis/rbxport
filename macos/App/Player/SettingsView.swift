import SwiftUI

/// The Settings window. Phase 6 adds the other panes; so far General (Library Protection), Audio and LINK.
struct SettingsView: View {
    let player: PlayerModel
    let model: AppModel
    /// `RBXPORT_SETTINGS_TAB=general|audio|link` opens a tab, for screenshots.
    @State private var tab = ProcessInfo.processInfo.environment["RBXPORT_SETTINGS_TAB"] ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            AudioPane(player: player)
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
                .tag("audio")
            LinkPane(model: model.link)
                .tabItem { Label("LINK", systemImage: "link") }
                .tag("link")
        }
        .frame(width: 520)
        .scenePadding()
    }
}

/// Library Protection: the one setting the editing gate reads.
struct GeneralPane: View {
    let model: AppModel
    @State private var confirmingUnlock = false

    var body: some View {
        Form {
            Section("Library") {
                Toggle(
                    "Protect library",
                    isOn: Binding(
                        get: { model.protectLibrary },
                        set: { on in
                            if on { model.protectLibrary = true } else { confirmingUnlock = true }
                        })
                )
                Text(
                    "While on, rbxport will not change your rekordbox library: no playlists, tags or ratings are written, and undo is off. Turn it off to edit. rekordbox must be closed while you edit."
                )
                .font(.caption).foregroundStyle(.secondary)
                if model.isReadOnly && !model.protectLibrary {
                    Text("Editing is still locked while rekordbox is running. Quit rekordbox to enable editing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Turn off Library Protection?", isPresented: $confirmingUnlock) {
            Button("Turn Off Protection", role: .destructive) { model.protectLibrary = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Edits are written to your rekordbox library. Make a backup first if you have not.")
        }
    }
}

/// Output device, sample rate, buffer size and the master limiter (`AudioPane.tsx`).
struct AudioPane: View {
    let player: PlayerModel

    var body: some View {
        let audio = player.audio
        Form {
            Section("Output") {
                Picker(
                    "Output device",
                    selection: Binding(get: { audio.chosen }, set: { audio.choose(device: $0) })
                ) {
                    ForEach(audio.choices) { choice in Text(choice.title).tag(choice.id) }
                }
                Picker(
                    "Sample rate",
                    selection: Binding(get: { audio.sampleRate }, set: { audio.setSampleRate($0) })
                ) {
                    ForEach(AudioSettingsModel.sampleRates, id: \.self) { rate in Text("\(rate) Hz").tag(rate) }
                }
                LabeledContent("Buffer size") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Slider(
                            value: Binding(
                                get: { Double(AudioSettingsModel.bufferSizes.firstIndex(of: audio.bufferSize) ?? 3) },
                                set: { audio.setBufferSize(AudioSettingsModel.bufferSizes[min(max(Int($0.rounded()), 0), AudioSettingsModel.bufferSizes.count - 1)]) }),
                            in: 0...Double(AudioSettingsModel.bufferSizes.count - 1), step: 1
                        )
                        .accessibilityLabel("Buffer size")
                        Text(audio.bufferCaption).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text("A change takes effect at once: the loaded tracks are reloaded where they were.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LimiterSection(player: player)
        }
        .formStyle(.grouped)
        .task { await audio.refresh() }
    }
}

/// The master limiter (RBXport's own; rekordbox's pane has none).
struct LimiterSection: View {
    let player: PlayerModel

    var body: some View {
        let limiter = player.limiter
        let settings = limiter.settings
        Section("Master limiter") {
            Toggle("Enable limiter", isOn: Binding(get: { settings.enabled }, set: { on in limiter.set { $0.enabled = on } }))
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !settings.enabled)) { _ in
                let reduction = settings.enabled && fresh ? Double(player.meters?.reduction ?? 0) : 0
                LabeledContent("Reduction") {
                    Text(reduction > 0.05 ? String(format: "\u{2212}%.1f dB", reduction) : "0.0 dB")
                        .monospacedDigit()
                    Text(!settings.enabled ? "Off" : reduction >= 0.1 ? "Limiting" : "Ready")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            slider(
                "Input gain", value: settings.inputGainDb, range: LimiterSettings.inputGainRange,
                step: LimiterSettings.inputGainStep, text: String(format: "%+.1f dB", settings.inputGainDb)
            ) { value in limiter.set { $0.inputGainDb = value } }
            slider(
                "Ceiling", value: settings.ceilingDb, range: LimiterSettings.ceilingRange,
                step: LimiterSettings.ceilingStep, text: String(format: "%.1f dBFS", settings.ceilingDb)
            ) { value in limiter.set { $0.ceilingDb = value } }
            slider(
                "Release", value: settings.releaseMs, range: LimiterSettings.releaseRange,
                step: LimiterSettings.releaseStep, text: String(format: "%.0f ms", settings.releaseMs)
            ) { value in limiter.set { $0.releaseMs = value } }
        }
    }

    private var fresh: Bool { CACurrentMediaTime() - player.metersAt < 0.25 }

    private func slider(
        _ title: String, value: Double, range: ClosedRange<Double>, step: Double, text: String,
        set: @escaping @MainActor (Double) -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(
                    value: Binding(get: { value }, set: { new in MainActor.assumeIsolated { set(new) } }), in: range,
                    step: step)
                    .accessibilityLabel(title)
                Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            }
        }
        .disabled(!player.limiter.settings.enabled)
    }
}
