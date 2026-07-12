import SwiftUI

/// the watch player screen: artwork & track info up top, transport controls
/// in the middle and the shuffle & repeat toggles along the bottom
struct WatchNowPlayingView: View {
    @Environment(PlayerStore.self) private var player
    @Environment(SongsStore.self) private var songs

    var body: some View {
        Group {
            if let song = player.song {
                content(song)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "music.note")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ song: Song) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                WatchArtworkThumbnail(url: songs.artworkURL(song), maxPixelSize: 132)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(2)
                    if !song.artistName.isEmpty {
                        Text(song.artistName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 8)
            transport
            Spacer(minLength: 8)
            modes
        }
        .padding(.horizontal, 4)
    }

    private var transport: some View {
        HStack {
            Button {
                player.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button {
                player.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .buttonStyle(.plain)
    }

    private var modes: some View {
        HStack {
            Button {
                player.setShuffled(!player.queue.isShuffled)
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.queue.isShuffled ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .accessibilityLabel(player.queue.isShuffled ? "Shuffle Off" : "Shuffle On")
            Button {
                player.cycleRepeatMode()
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .accessibilityLabel("Repeat")
        }
        .font(.footnote)
        .buttonStyle(.plain)
    }
}
