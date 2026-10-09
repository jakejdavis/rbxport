import SwiftUI

/// The deck's menu (the hamburger in the header), from `deckMenu` in `contextMenus.ts`: waveform
/// colour, Analyze Track, Export Track (to a mounted device) and the waveform click. Export Loop As
/// WAV stays greyed: the core cannot render a loop to a file yet.
struct DeckMenu: View {
    let deck: DeckModel
    let player: PlayerModel
    let palette: WaveformPalette

    var body: some View {
        Menu {
            Menu("Waveform Color") {
                ForEach([WaveformPalette.mono, .colour, .bands], id: \.self) { option in
                    Toggle(option.label, isOn: Binding(get: { palette == option }, set: { _ in player.chooseWaveformPalette(option) }))
                }
            }
            Divider()
            Button("Analyze Track") { player.analyse(deck: deck.deck) }
                .disabled(deck.track == nil || !deck.canWrite())
            Divider()
            let devices = player.deviceTargets?() ?? []
            if deck.track != nil, !devices.isEmpty {
                Menu("Export Track") {
                    ForEach(devices, id: \.path) { device in
                        Button(device.name) { player.exportTrack(deck: deck.deck, to: device.path) }
                    }
                }
            } else {
                Button("Export Track") {}.disabled(true)
            }
            // The core has no loop-to-WAV export yet, so this stays greyed.
            Button("Export Loop As WAV") {}.disabled(true)
            Divider()
            Toggle("Waveform Click", isOn: Binding(get: { deck.waveformClick }, set: { deck.waveformClick = $0 }))
        } label: {
            Image(systemName: "line.3.horizontal").frame(width: 24, height: 24)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Deck menu. Export Track needs a mounted device and a loaded track; Export Loop As WAV is not available yet.")
        .accessibilityLabel("Deck menu")
    }
}
