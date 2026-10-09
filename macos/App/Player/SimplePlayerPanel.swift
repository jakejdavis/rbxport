import SwiftUI

/// The SIMPLE PLAYER layout: one strip with the PLAY ring, the sleeve, the readouts over the
/// overview (hot cue badges, the position bar and the cue point), and the rating. No detail
/// waveform and no transport rail; everything else about deck A still works, keys included.
struct SimplePlayerPanel: View {
    let player: PlayerModel
    let deck: DeckModel
    let palette: WaveformPalette

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            playRing
            sleeve
            VStack(alignment: .leading, spacing: 6) {
                readouts.frame(height: 30)
                OverviewWaveform(deck: deck, palette: palette)
                    .frame(height: 46)
                    .overlay(alignment: .topLeading) { CueBadges(deck: deck) }
            }
            rating
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PlayerStyle.background)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottomLeading) { NoticeBanner(player: player) }
    }

    private var playRing: some View {
        Button {
            player.togglePlay(deck.deck)
        } label: {
            Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(deck.isPlaying ? PlayerStyle.playing : PlayerStyle.text)
                .frame(width: 58, height: 58)
                .background(PlayerStyle.button, in: .circle)
                .overlay(Circle().stroke(deck.isPlaying ? PlayerStyle.playing : .white.opacity(0.2), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(!deck.isLoaded)
        .opacity(deck.isLoaded ? 1 : 0.4)
        .accessibilityLabel(deck.isPlaying ? "Pause" : "Play")
        .help("Play / pause (Space)")
    }

    /// The sleeve is the eject button with a track on the deck and the load button without.
    private var sleeve: some View {
        Button {
            if deck.track != nil { deck.unload() } else { player.loadSelected?() }
        } label: {
            Sleeve(deck: deck, edge: 76)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(deck.track != nil ? "Eject" : "Load the selected track")
        .help(deck.track != nil ? "Eject" : "Load the selected track")
    }

    private var readouts: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(deck.track?.title ?? (deck.phase == .loading ? "Loading..." : "No track loaded"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(deck.track == nil ? PlayerStyle.dim : PlayerStyle.text)
                    .lineLimit(1)
                Text(deck.track?.artist ?? "Load a track, or press Return")
                    .font(.system(size: 11)).foregroundStyle(PlayerStyle.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let track = deck.track {
                cell { TimeReadout(deck: deck, compact: true) }
                if !track.key.isEmpty {
                    cell {
                        Text(deck.shiftedKey)
                            .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(PlayerStyle.cue)
                    }
                }
                cell { BpmReadout(deck: deck, track: track, compact: true) }
            }
        }
    }

    private func cell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 26)
            content().padding(.horizontal, 10)
        }
    }

    /// Read-only: the star's writer is the browser's (library edits arrive in Phase 4).
    private var rating: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: starCount >= star ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(starCount >= star ? PlayerStyle.cue : PlayerStyle.dim.opacity(0.5))
            }
        }
        .padding(8)
        .background(PlayerStyle.well, in: .rect(cornerRadius: 3))
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(starCount) of 5")
    }

    private var starCount: Int { CellFormat.stars(UInt8(clamping: deck.track?.rating ?? 0)).lit }
}

/// A coloured badge with its letter for each hot cue, along the top of the overview.
struct CueBadges: View {
    let deck: DeckModel

    var body: some View {
        GeometryReader { geometry in
            let total = deck.durationSeconds * 1000
            if total > 0 {
                ForEach(deck.hotCues) { cue in
                    Text(cue.letter)
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 11, height: 11)
                        .background(Color(cue.drawColour), in: .rect(cornerRadius: 2))
                        .offset(x: min(max(cue.positionMs / total, 0), 1) * (geometry.size.width - 11))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
