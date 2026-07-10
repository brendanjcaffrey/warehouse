import AVKit
import MediaPlayer
import SwiftUI

/// full screen player: big artwork, track info, progress, transport controls,
/// volume and the play queue, presented as a sheet over the tab view
struct NowPlayingView: View {
    @Environment(PlayerStore.self) private var player
    @Environment(SongsStore.self) private var songs
    @Environment(AuthStore.self) private var auth
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(NavigationRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var showingQueue = false
    @State private var scrolledQueue = false

    var body: some View {
        Group {
            if let song = player.song {
                content(song)
            }
        }
        .presentationDragIndicator(.visible)
        .task {
            // the queue context menu needs the playlists for show in playlist
            await playlists.load()
        }
    }

    /// closes the modal & pushes a destination onto the library tab, so the
    /// go to menus land on top of whatever that tab is already showing
    private func navigate(to route: LibraryRoute) {
        router.navigate(to: route)
        dismiss()
    }

    /// a binding the shared song menu can set to trigger navigation; it never
    /// holds a value since the destination lives on the library tab, not here
    private func routeBinding<Value>(_ makeRoute: @escaping (Value) -> LibraryRoute) -> Binding<Value?> {
        Binding(
            get: { nil },
            set: { newValue in
                if let newValue {
                    navigate(to: makeRoute(newValue))
                }
            })
    }

    private func content(_ song: Song) -> some View {
        VStack(spacing: 28) {
            if showingQueue {
                trackInfo(song)
                queueList
            } else {
                Spacer(minLength: 0)
                ArtworkThumbnail(url: songs.artworkURL(song), maxPixelSize: 1320)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                trackInfo(song)
            }
            PlayerProgress()
            controls
            volume
            bottomButtons
            if !showingQueue {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    /// the history, current track & upcoming lists shown in place of the
    /// artwork; the current track starts at the top with the history scrolled
    /// away above it, upcoming rows drag to reorder and tap to jump ahead
    private var queueList: some View {
        ScrollViewReader { proxy in
            List {
                if !player.queue.history.isEmpty {
                    Section("History") {
                        ForEach(player.queue.history) { entry in
                            historyRow(entry.song)
                        }
                    }
                }
                if let current = player.queue.current {
                    Section("Now Playing") {
                        queueRow(current.song)
                            .id(current.id)
                    }
                }
                if !player.queue.upcoming.isEmpty {
                    Section("Playing Next") {
                        ForEach(Array(player.queue.upcoming.enumerated()), id: \.element.id) { index, entry in
                            upcomingRow(entry.song, at: index)
                        }
                        .onMove { offsets, destination in
                            player.moveUpcoming(fromOffsets: offsets, toOffset: destination)
                        }
                    }
                }
                if player.repeatMode == .all {
                    // repeat all loops the whole queue back around once it runs out
                    Section {
                        HStack(spacing: 6) {
                            Text("Repeating \(repeatingLabel)")
                            Image(systemName: "repeat")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            // always in edit mode so the upcoming rows show reorder handles
            .environment(\.editMode, .constant(.active))
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onScrollPhaseChange { _, newPhase in
                // a touch means the user scrolled, so stop snapping the
                // current track back to the top when it changes
                if newPhase == .tracking || newPhase == .interacting {
                    scrolledQueue = true
                }
            }
            .onAppear {
                scrolledQueue = false
                scrollToCurrent(proxy)
            }
            .onChange(of: player.queue.current?.id) {
                guard !scrolledQueue else { return }
                withAnimation {
                    scrollToCurrent(proxy)
                }
            }
        }
    }

    private var repeatingLabel: String {
        let count = player.queue.count
        return "\(count) \(count == 1 ? "song" : "songs")"
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let id = player.queue.current?.id else { return }
        proxy.scrollTo(id, anchor: .top)
    }

    private func queueRow(_ song: Song) -> some View {
        SongRow(song: song, artworkURL: songs.artworkURL(song), downloaded: songs.isDownloaded(song))
    }

    private func historyRow(_ song: Song) -> some View {
        Button {
            // let the queue snap back to the new current track
            scrolledQueue = false
            player.playFromHistory(song)
        } label: {
            queueRow(song)
        }
        .buttonStyle(.plain)
        .songContextMenu(
            song,
            library: songs.songs,
            playlists: playlists.playlists,
            play: {
                scrolledQueue = false
                player.playFromHistory(song)
            },
            playNext: { player.playNext(song, token: auth.token, baseURL: auth.baseURL()) },
            artistDestination: routeBinding(LibraryRoute.artist),
            albumDestination: routeBinding(LibraryRoute.album),
            songsDestination: routeBinding(LibraryRoute.songs),
            playlistDestination: routeBinding(LibraryRoute.playlist))
    }

    private func upcomingRow(_ song: Song, at index: Int) -> some View {
        Button {
            // let the queue snap back to the new current track
            scrolledQueue = false
            player.playFromUpcoming(at: index)
        } label: {
            queueRow(song)
        }
        .buttonStyle(.plain)
        .songContextMenu(
            song,
            library: songs.songs,
            playlists: playlists.playlists,
            play: {
                scrolledQueue = false
                player.playFromUpcoming(at: index)
            },
            playNext: { player.playNext(song, token: auth.token, baseURL: auth.baseURL()) },
            artistDestination: routeBinding(LibraryRoute.artist),
            albumDestination: routeBinding(LibraryRoute.album),
            songsDestination: routeBinding(LibraryRoute.songs),
            playlistDestination: routeBinding(LibraryRoute.playlist))
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
                songMenuButtons(
                    song,
                    library: songs.songs,
                    playlists: playlists.playlists,
                    artistDestination: routeBinding(LibraryRoute.artist),
                    albumDestination: routeBinding(LibraryRoute.album),
                    songsDestination: routeBinding(LibraryRoute.songs),
                    playlistDestination: routeBinding(LibraryRoute.playlist))
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("nowPlayingMenu")
        }
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
                player.setShuffled(!player.queue.isShuffled)
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(player.queue.isShuffled ? Color.accentColor : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Button {
                player.cycleRepeatMode()
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Button {
                showingQueue.toggle()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(showingQueue ? Color.accentColor : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("showQueue")
        }
    }
}

/// the progress bar & time labels, split out so the frequent currentTime
/// updates only re-render this view and don't flash the now playing menu
private struct PlayerProgress: View {
    @Environment(PlayerStore.self) private var player

    @State private var scrubTime: TimeInterval = 0
    @State private var isScrubbing = false

    var body: some View {
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
