import SwiftUI

/// The deck's menu (the hamburger in the header), from `deckMenu` in `contextMenus.ts`: waveform
/// colour, Analyze Track and the waveform click. Export Track and Export Loop As WAV are Phase 5.
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
            Button("Export Track") {}.disabled(true)
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
        .help("Deck menu. Export Track and Export Loop As WAV arrive with devices (Phase 5).")
        .accessibilityLabel("Deck menu")
    }
}
