import SwiftUI

struct SearchView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SongsStore.self) private var store
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(SyncStore.self) private var sync
    @Environment(PlayerStore.self) private var player

    @State private var search = ""
    @State private var scope = SearchScope.songs
    @State private var results = SearchResults()
    @State private var artistDestination: Artist?
    @State private var albumDestination: Album?
    @State private var songsDestination: Song?
    @State private var playlistDestination: PlaylistDestination?

    private struct ResultsInput: Equatable, Sendable {
        let songs: [Song]
        let scope: SearchScope
        let search: String
    }

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            Group {
                if trimmedSearch.isEmpty {
                    ContentUnavailableView(
                        "Search Your Library",
                        systemImage: "magnifyingglass",
                        description: Text("Find artists, albums and songs."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    resultList
                }
            }
            .navigationTitle("Search")
            .navigationDestination(item: $artistDestination) { artist in
                ArtistView(artist: artist)
            }
            .navigationDestination(item: $albumDestination) { album in
                AlbumView(album: album)
            }
            .navigationDestination(item: $songsDestination) { song in
                SongsView(scrollTo: song)
            }
            .navigationDestination(item: $playlistDestination) { destination in
                SongsView(playlist: destination.playlist, scrollTo: destination.song)
            }
            .searchable(text: $search, prompt: "Artists, Albums & Songs")
            .searchScopes($scope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .task {
                await store.load()
                // the context menu needs the playlists for show in playlist
                await playlists.load()
            }
            .task(id: ResultsInput(songs: store.songs, scope: scope, search: search)) {
                // filtering & sorting thousands of songs is too slow to redo in body
                let input = ResultsInput(songs: store.songs, scope: scope, search: search)
                results = await Task.detached(priority: .userInitiated) {
                    SearchListBuilder.results(input.songs, scope: input.scope, matching: input.search)
                }.value
            }
            .onChange(of: sync.completedSyncs) {
                // pick up new tracks once a sync finishes
                Task { await store.load() }
            }
            .onChange(of: sync.downloadRefreshTicks) {
                // refresh the downloaded icons periodically during long downloads
                Task { await store.load() }
            }
        }
    }

    private var resultList: some View {
        List {
            switch scope {
            case .artists:
                ForEach(results.artists) { artist in
                    NavigationLink {
                        ArtistView(artist: artist)
                    } label: {
                        Text(artist.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .playbackContextMenu(
                        play: {
                            player.play(
                                artist.albums.flatMap(\.songs),
                                token: auth.token, baseURL: auth.baseURL())
                        },
                        shuffle: {
                            player.playShuffled(
                                artist.albums.flatMap(\.songs),
                                token: auth.token, baseURL: auth.baseURL())
                        })
                }
            case .albums:
                ForEach(results.albums) { album in
                    NavigationLink {
                        AlbumView(album: album)
                    } label: {
                        AlbumRow(
                            album: album,
                            artworkURL: store.artworkURL(filename: album.artworkFilename))
                    }
                    .albumContextMenu(
                        album,
                        library: store.songs,
                        play: { player.play(album.songs, token: auth.token, baseURL: auth.baseURL()) },
                        shuffle: { player.playShuffled(album.songs, token: auth.token, baseURL: auth.baseURL()) },
                        artistDestination: $artistDestination)
                }
            case .songs:
                ForEach(results.songs) { song in
                    Button {
                        play(song)
                    } label: {
                        SongRow(
                            song: song,
                            artworkURL: store.artworkURL(song),
                            downloaded: store.isDownloaded(song))
                    }
                    .buttonStyle(.plain)
                    .songContextMenu(
                        song,
                        library: store.songs,
                        playlists: playlists.playlists,
                        play: { play(song) },
                        playNext: { player.playNext(song, token: auth.token, baseURL: auth.baseURL()) },
                        artistDestination: $artistDestination,
                        albumDestination: $albumDestination,
                        songsDestination: $songsDestination,
                        playlistDestination: $playlistDestination)
                }
            }
        }
        .listStyle(.plain)
    }

    /// plays a tapped song within the displayed search results
    private func play(_ song: Song) {
        player.play(
            results.songs, startingAt: results.songs.firstIndex(of: song) ?? 0,
            token: auth.token, baseURL: auth.baseURL())
    }
}
