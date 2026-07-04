import AVKit
import MediaPlayer
import SwiftUI

/// full screen player: big artwork, track info, progress, transport controls
/// and volume, presented as a sheet over the tab view
struct NowPlayingView: View {
    @Environment(PlayerStore.self) private var player
    @Environment(SongsStore.self) private var songs

    @State private var artistDestination: Artist?
    @State private var albumDestination: Album?
    @State private var scrubTime: TimeInterval = 0
    @State private var isScrubbing = false

    var body: some View {
        NavigationStack {
            Group {
                if let song = player.song {
                    content(song)
                }
            }
            .navigationDestination(item: $artistDestination) { artist in
                ArtistView(artist: artist)
            }
            .navigationDestination(item: $albumDestination) { album in
                AlbumView(album: album)
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func content(_ song: Song) -> some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            ArtworkThumbnail(url: songs.artworkURL(song), maxPixelSize: 1320)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
            trackInfo(song)
            progress
            controls
            volume
            bottomButtons
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func trackInfo(_ song: Song) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !song.artistName.isEmpty {
                    Text(song.artistName)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Menu {
                if !song.albumName.isEmpty {
                    Button("Go to Album", systemImage: "square.stack") {
                        albumDestination = AlbumListBuilder.album(for: song, in: songs.songs)
                    }
                }
                if !song.artistName.isEmpty {
                    Button("Go to Artist", systemImage: "music.microphone") {
                        artistDestination = ArtistListBuilder.artist(named: song.artistName, in: songs.songs)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    progressBar(width: geometry.size.width)
                    if player.window.startsLate {
                        windowMarker(at: player.window.start, width: geometry.size.width)
                    }
                    if player.window.stopsEarly {
                        windowMarker(at: player.window.end, width: geometry.size.width)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            scrubTime = player.window.time(
                                atFraction: value.location.x / geometry.size.width)
                        }
                        .onEnded { _ in
                            player.seek(to: scrubTime)
                            isScrubbing = false
                        })
            }
            .frame(height: 24)
            HStack {
                Text(PlaybackTime.label(shownTime))
                Spacer()
                Text("-" + PlaybackTime.label(player.window.duration - shownTime))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    /// the full file's bar with the parts outside the track's start/stop
    /// times dimmed and the played part filled
    private func progressBar(width: CGFloat) -> some View {
        let window = player.window
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color(.systemGray4))
            if window.startsLate {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(width: width * window.fraction(atTime: window.start))
            }
            if window.stopsEarly {
                let endFraction = window.fraction(atTime: window.end)
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(width: width * (1 - endFraction))
                    .offset(x: width * endFraction)
            }
            Capsule()
                .fill(Color(.systemGray))
                .frame(width: width * window.fraction(atTime: shownTime))
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }

    private func windowMarker(at time: TimeInterval, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color(.systemGray2))
            .frame(width: 2, height: 12)
            .offset(x: width * player.window.fraction(atTime: time) - 1)
    }

    private var shownTime: TimeInterval {
        isScrubbing ? scrubTime : player.currentTime
    }

    private var controls: some View {
        HStack {
            Spacer()
            Button {
                player.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
            }
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
            }
            Spacer()
            Button {
                player.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
            }
            Spacer()
        }
        .buttonStyle(.plain)
    }

    private var volume: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            SystemVolumeSlider()
                .frame(height: 34)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var bottomButtons: some View {
        HStack {
            AudioRoutePicker()
                .frame(width: 44, height: 44)
            Spacer()
            Button {
                // history & up next aren't implemented yet
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .disabled(true)
        }
    }
}

/// the system volume slider; renders empty on the simulator
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = CenteredVolumeView()
        // an empty image hides the thumb, matching the thumbless progress bar
        view.setVolumeThumbImage(UIImage(), for: .normal)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

/// mpvolumeview draws its slider near the top of its bounds, center it so it
/// lines up with the speaker icons next to it
private final class CenteredVolumeView: MPVolumeView {
    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
        var rect = super.volumeSliderRect(forBounds: bounds)
        rect.origin.y = bounds.midY - rect.height / 2
        return rect
    }
}

/// the system audio output picker (airplay, bluetooth, etc)
private struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .secondaryLabel
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
