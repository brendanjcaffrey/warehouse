import SwiftUI

struct WatchMenuView: View {
    @Environment(\.watchLibraryRefresh) private var refresh
    @Environment(WatchLibraryStore.self) private var library
    @Environment(SongsStore.self) private var songs
    @Environment(PlaylistsStore.self) private var playlists

    let presentation: WatchRootPresentation
    let openRemote: () -> Void

    var body: some View {
        List {
            if presentation.showsRemoteNowPlaying {
                Button(action: openRemote) {
                    Label("Playing on iPhone", systemImage: "iphone")
                }
            }
            if presentation.showsLocalNowPlaying {
                NavigationLink {
                    WatchNowPlayingView()
                } label: {
                    Label("Now Playing", systemImage: "play.circle")
                }
            }
            NavigationLink {
                WatchTrackListView(
                    title: "Songs",
                    songs: SongListBuilder.orderedSongs(songs.songs, trackIds: nil, sortedBy: .title))
            } label: {
                Label("Songs", systemImage: "music.note")
            }
            ForEach(PlaylistListBuilder.watchSections(in: playlists.playlists)) { section in
                ForEach(section.playlists) { playlist in
                    NavigationLink {
                        WatchTrackListView(
                            title: playlist.name,
                            songs: SongListBuilder.playlistSongs(songs.songs, trackIds: playlist.trackIds),
                            playlist: playlist)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(playlist.name, systemImage: "music.note.list")
                            WatchLibraryProgressView(progress: library.progress(playlistID: playlist.id), compact: true)
                        }
                    }
                }
            }
            Section("Downloads") {
                WatchLibraryProgressView(progress: library.progress())
                NavigationLink {
                    WatchDiagnosticView()
                } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }
                if library.deliveryStartupError != nil {
                    Button("Retry Delivery") { Task { await refresh() } }
                }
                if library.deliveryRecovered {
                    Text("Delivery recovered. Saved music remains available.")
                        .font(.footnote)
                }
            }
        }
    }
}
