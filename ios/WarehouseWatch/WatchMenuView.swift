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
                            let progress = library.progress(playlistID: playlist.id)
                            if progress.showsPlaylistDownloadStatus {
                                WatchLibraryProgressView(progress: progress, compact: true)
                            }
                        }
                    }
                }
            }
            Section("Downloads") {
                WatchLibraryProgressView(progress: library.progress())
                Button("Sync Downloaded Status") { library.content?.syncDownloadedStatus() }
                    .disabled(library.content == nil || library.content?.inventoryPending == true)
                if let feedback = library.content?.inventoryFeedback ?? library.content?.errorMessage {
                    Text(feedback).font(.footnote)
                }
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
