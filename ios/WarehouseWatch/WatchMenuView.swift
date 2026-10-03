import SwiftUI

struct WatchMenuView: View {
    @Environment(WatchLibraryStore.self) private var library
    @Environment(SongsStore.self) private var songs
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(PlayerStore.self) private var player
    @Environment(WatchRemoteStore.self) private var remote

    @State private var showingRemote = false
    @State private var autoOpen = RemoteAutoOpen()

    var body: some View {
        NavigationStack {
            List {
                if remote.isAvailable {
                    Button {
                        autoOpen.noteOpened()
                        showingRemote = true
                    } label: {
                        Label("Playing on iPhone", systemImage: "iphone")
                    }
                }
                if player.song != nil {
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
                NavigationLink {
                    WatchDiagnosticView()
                } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }
                ForEach(PlaylistListBuilder.watchSections(in: playlists.playlists)) { section in
                    Section(section.title) {
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
                }
                Section("Downloads") {
                    WatchLibraryProgressView(progress: library.progress())
                }
            }
            .navigationTitle("Warehouse")
            .navigationDestination(isPresented: $showingRemote) {
                WatchRemoteNowPlayingView()
            }
            .onChange(of: remote.isAvailable, initial: true) { updateRemoteOpen() }
            .onChange(of: remote.isPhonePlaying) { updateRemoteOpen() }
        }
    }

    private func updateRemoteOpen() {
        guard autoOpen.shouldOpen(
            isRemoteAvailable: remote.isAvailable,
            isRemotePlaying: remote.isPhonePlaying,
            isPlayingLocally: player.isPlaying)
        else { return }
        showingRemote = true
    }
}
