import SwiftUI

struct SearchView: View {
    @Environment(SongsStore.self) private var store
    @Environment(SyncStore.self) private var sync

    @State private var search = ""
    @State private var scope = SearchScope.songs
    @State private var results = SearchResults()

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
            .searchable(text: $search, prompt: "Artists, Albums & Songs")
            .searchScopes($scope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .task {
                await store.load()
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
                }
            case .songs:
                ForEach(results.songs) { song in
                    SongRow(
                        song: song,
                        artworkURL: store.artworkURL(song),
                        downloaded: store.isDownloaded(song))
                }
            }
        }
        .listStyle(.plain)
    }
}
