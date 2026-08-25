import SwiftUI

/// the remote screen: what the phone is playing & the transport controls that
/// drive it. the watch's own player is untouched here — this is the phone's
/// queue, its audio route & its volume
struct WatchRemoteNowPlayingView: View {
    @Environment(WatchRemoteStore.self) private var remote

    var body: some View {
        Group {
            if let song = remote.nowPlaying {
                content(song)
            } else if remote.isReachable {
                ContentUnavailableView("Nothing Playing on iPhone", systemImage: "iphone")
            } else {
                ContentUnavailableView("iPhone Not Reachable", systemImage: "iphone.slash")
            }
        }
        // the badge in the header carries the device identity now, so the
        // title is free to track what's playing as the header scrolls away
        .navigationTitle(remote.nowPlaying?.name ?? "iPhone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ song: RemotePlaybackPayload) -> some View {
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
                }
                Spacer(minLength: 0)
                // a badge, not a button: says whose queue these controls drive
                Image(systemName: "iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Playing on iPhone")
            }
            Spacer(minLength: 8)
            transport(song)
            Spacer(minLength: 16)
            modes(song)
        }
        .padding(.horizontal, 4)
        // the phone's own screen may have moved on while this one was open
        .disabled(!remote.isReachable)
    }

    private func transport(_ song: RemotePlaybackPayload) -> some View {
        HStack {
            Button {
                remote.command(.previous)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            Button {
                remote.command(.playPause)
            } label: {
                Image(systemName: song.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel(song.isPlaying ? "Pause" : "Play")
            Button {
                remote.command(.next)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .buttonStyle(.plain)
    }

    /// the same blue the local now playing screen tints its on states with,
    /// since watchos' accent barely separates from secondary here
    private static let onTint = Color.blue

    private func modes(_ song: RemotePlaybackPayload) -> some View {
        HStack {
            Button {
                remote.command(.toggleShuffle)
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(song.isShuffled ? Self.onTint : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .accessibilityLabel(song.isShuffled ? "Shuffle Off" : "Shuffle On")
            // no volume control: the sound is coming out of the phone, and
            // watchos' volume control only ever moves this device's
            Button {
                remote.command(.cycleRepeat)
            } label: {
                Image(systemName: song.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(song.repeatMode == .off ? Color.secondary : Self.onTint)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .accessibilityLabel("Repeat")
        }
        .font(.title3)
        .buttonStyle(.plain)
    }
}
