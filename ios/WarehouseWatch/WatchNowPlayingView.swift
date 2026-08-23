import SwiftUI

/// the watch player screen: artwork & track info up top, transport controls
/// in the middle and the shuffle toggle, crown driven volume button & repeat
/// toggle along the bottom
struct WatchNowPlayingView: View {
    @Environment(PlayerStore.self) private var player

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
                WatchArtworkThumbnail(filename: song.artworkFilename, priority: .nowPlaying, maxPixelSize: 132)
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
                    // tracks arrive on demand & the audio session needs a
                    // bluetooth output, so say which one is missing rather
                    // than looking like a tap that did nothing
                    if let note = statusNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 8)
            transport
            Spacer(minLength: 16)
            modes
        }
        .padding(.horizontal, 4)
    }

    /// what to say under the track name when a tap can't start playback
    private var statusNote: String? {
        switch player.status {
        case .unavailable: "Unavailable Offline"
        // watchos won't play long form audio through the watch speaker
        case .needsOutput: "Connect Headphones"
        case .ready, .fetching: nil
        }
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
                Group {
                    if player.status == .fetching {
                        ProgressView()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(player.status == .fetching)
            .accessibilityLabel(playPauseLabel)
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

    private var playPauseLabel: String {
        switch player.status {
        case .fetching: "Downloading"
        case .ready, .unavailable, .needsOutput: player.isPlaying ? "Pause" : "Play"
        }
    }

    /// watchos' default accent barely separates from secondary on a small
    /// screen, so tint the on states the same blue the phone app picks up
    private static let onTint = Color.blue

    private var modes: some View {
        HStack {
            Button {
                player.setShuffled(!player.queue.isShuffled)
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.queue.isShuffled ? Self.onTint : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .accessibilityLabel(player.queue.isShuffled ? "Shuffle Off" : "Shuffle On")
            // watchkit draws its own circular button here, so pin it to the
            // same box the icon buttons get rather than letting it stretch
            WatchVolumeControl()
                .frame(width: 36, height: 36)
                .frame(maxWidth: .infinity, minHeight: 36)
            Button {
                player.cycleRepeatMode()
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Self.onTint)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .accessibilityLabel("Repeat")
        }
        .font(.title3)
        .buttonStyle(.plain)
    }
}
