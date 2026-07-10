import SwiftUI

/// compact now playing strip shown in the tab view's bottom accessory,
/// tapping it opens the full screen player
struct NowPlayingBar: View {
    @Environment(PlayerStore.self) private var player
    @Environment(SongsStore.self) private var songs

    /// owned by the tab view: the accessory gets recreated when the track
    /// changes, so state kept here wouldn't survive a track change
    @Binding var showingNowPlaying: Bool

    var body: some View {
        if let song = player.song {
            HStack(spacing: 12) {
                Button {
                    showingNowPlaying = true
                } label: {
                    HStack(spacing: 12) {
                        ArtworkThumbnail(url: songs.artworkURL(song))
                            .frame(width: 30, height: 30)
                            .padding(.leading, 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.name)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if !song.artistName.isEmpty {
                                Text(song.artistName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("nowPlayingBar")
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("barPlayPause")
                Button {
                    player.skipToNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("barNext")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
        }
    }
}
