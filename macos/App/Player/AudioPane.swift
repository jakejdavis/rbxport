import SwiftUI

/// Output device, sample rate, buffer size, the metronome's click and the master limiter (`AudioPane.tsx`).
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
            Section("Metronome") {
                Picker(
                    "Click sound",
                    selection: Binding(get: { player.prefs.metronomeSound }, set: { player.prefs.metronomeSound = $0 })
                ) {
                    ForEach(1...3, id: \.self) { Text("Click Sound 0\($0)").tag($0) }
                }
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
