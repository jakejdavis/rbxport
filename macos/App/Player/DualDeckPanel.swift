import SwiftUI

/// The 2 PLAYER layout: deck A on top, the mixer strip across the seam, deck B under it. Each
/// deck is the compact dual body (title row, overview, a control row, the detail waveform);
/// deck B is flipped, its rows in the reverse order so the detail waveforms meet the seam.
struct DualDeckPanel: View {
    let player: PlayerModel
    let palette: WaveformPalette

    /// Narrower than this and the panel scrolls sideways, as the one-deck panel does.
    static let contentWidth = 720.0

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    CompactDeck(player: player, deck: player.deckA, palette: palette, flipped: false)
                    MixerSeam(player: player)
                    CompactDeck(player: player, deck: player.deckB, palette: palette, flipped: true)
                }
                .frame(width: max(geometry.size.width, Self.contentWidth), height: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(PlayerStyle.background)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottomLeading) { NoticeBanner(player: player) }
    }
}

/// One deck of the 2 PLAYER layout.
struct CompactDeck: View {
    let player: PlayerModel
    let deck: DeckModel
    let palette: WaveformPalette
    /// Deck B: the rows run bottom-up.
    let flipped: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                if flipped {
                    detail
                    controls
                    overviewGroup
                    head
                } else {
                    head
                    overviewGroup
                    controls
                    detail
                }
            }
            TempoColumn(deck: deck)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deck \(deck.deck == .a ? "A" : "B")")
    }

    // MARK: Rows

    /// The sleeve, title over artist, and at the right the sync buttons, key, BPM and time.
    private var head: some View {
        HStack(alignment: .center, spacing: 10) {
            Sleeve(deck: deck, edge: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(deck.track == nil ? PlayerStyle.dim : PlayerStyle.text)
                    .lineLimit(1)
                Text(subtitleText).font(.system(size: 11)).foregroundStyle(PlayerStyle.dim).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let track = deck.track {
                SyncButtons(player: player, deck: deck)
                if !track.key.isEmpty { KeyShiftView(deck: deck) }
                BpmReadout(deck: deck, track: track, compact: true)
                TimeReadout(deck: deck, compact: true).frame(width: 96, alignment: .trailing)
            }
        }
        .frame(height: 40)
    }

    private var titleText: String {
        switch deck.phase {
        case .empty: "No track loaded"
        case .loading: deck.track?.title ?? "Loading..."
        case .ready: deck.track?.title ?? ""
        case .failed: deck.track?.title ?? "Could not load"
        }
    }

    private var subtitleText: String {
        switch deck.phase {
        case .empty: deck.deck == .a ? "Load a track to player 1" : "Load a track to player 2 (Shift-Return)"
        case .loading: "Loading..."
        case .ready: deck.track?.artist ?? ""
        case .failed(let message): message
        }
    }

    private var overviewGroup: some View {
        VStack(spacing: 2) {
            if !flipped { PhraseStrip(deck: deck).frame(height: 8) }
            OverviewWaveform(deck: deck, palette: palette).frame(height: 36)
            if flipped { PhraseStrip(deck: deck).frame(height: 8) }
        }
    }

    /// Transport, hot cue pads, loops, beat jump, Q and the metronome: the pads and loop buttons
    /// are native additions (the React dual deck leaves them out).
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(pad: nil, condensed: false, jumpSize: true, chips: true)
            controlRow(pad: 24, condensed: true, jumpSize: false, chips: true)
            controlRow(pad: 24, condensed: true, jumpSize: false, chips: false)
        }
        .frame(height: 32)
    }

    /// One row of controls; the narrower variants drop the loop halve and double buttons, the
    /// jump size menu and then the mode chips, in that order, to keep the deck on one row.
    private func controlRow(pad: CGFloat?, condensed: Bool, jumpSize: Bool, chips: Bool) -> some View {
        HStack(spacing: condensed ? 6 : 8) {
            CueButton(deck: deck, compact: true)
            PlayButton(deck: deck, compact: true, toggle: { player.togglePlay(deck.deck) })
            PadRow(deck: deck, compact: true, padWidth: pad)
            LoopControls(deck: deck, condensed: condensed)
            JumpControls(deck: deck, showsSize: jumpSize)
            if chips { ModeChips(deck: deck) }
            Spacer(minLength: 0)
        }
    }

    private var detail: some View {
        HStack(spacing: 6) {
            ZoomColumn(deck: deck, compact: true)
            DetailWaveform(deck: deck, palette: palette)
                .clipShape(.rect(cornerRadius: 2))
                .frame(minHeight: 36, maxHeight: .infinity)
                .accessibilityLabel("Waveform")
        }
    }
}

/// BEAT SYNC and MASTER for one deck. The master never follows, so its BEAT SYNC is greyed.
struct SyncButtons: View {
    let player: PlayerModel
    let deck: DeckModel

    var body: some View {
        let isMaster = player.syncMaster == deck.deck
        VStack(spacing: 3) {
            Button("BEAT SYNC") { player.beatSync(deck.deck) }
                .buttonStyle(ControlButtonStyle(width: 70, height: 17, lit: deck.synced))
                .disabled(isMaster || !deck.isLoaded)
                .help(isMaster ? "This deck is the master" : "Match this deck to the master's tempo and bar (F1)")
                .accessibilityValue(deck.synced ? "on" : "off")
            Button("MASTER") { player.setSyncMaster(deck.deck) }
                .buttonStyle(ControlButtonStyle(width: 70, height: 17, lit: isMaster))
                .help("Make this the deck the other follows")
                .accessibilityValue(isMaster ? "on" : "off")
        }
    }
}
