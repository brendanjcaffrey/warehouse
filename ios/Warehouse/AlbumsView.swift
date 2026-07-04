import SwiftUI

struct AlbumsView: View {
    @Environment(SongsStore.self) private var store
    @Environment(SyncStore.self) private var sync

    @AppStorage("albumsSortOption") private var sortRaw = AlbumSortOption.title.rawValue
    @State private var search = ""
    @State private var sections = [AlbumSection]()
    @State private var artistDestination: Artist?

    private var sort: AlbumSortOption {
        AlbumSortOption(rawValue: sortRaw) ?? .title
    }

    private struct SectionInput: Equatable, Sendable {
        let songs: [Song]
        let sort: AlbumSortOption
        let search: String
    }

    var body: some View {
        Group {
            if store.songs.isEmpty {
                ContentUnavailableView(
                    "No Albums",
                    systemImage: "square.stack",
                    description: Text("Sync your library from the Settings tab."))
            } else {
                albumList
            }
        }
        .navigationTitle("Albums")
        .navigationDestination(item: $artistDestination) { artist in
            ArtistView(artist: artist)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
        }
        .task {
            await store.load()
        }
        .task(id: SectionInput(songs: store.songs, sort: sort, search: search)) {
            // grouping & sorting thousands of songs is too slow to redo in body
            let input = SectionInput(songs: store.songs, sort: sort, search: search)
            sections = await Task.detached(priority: .userInitiated) {
                let albums = AlbumListBuilder.albums(from: input.songs)
                return AlbumListBuilder.sections(albums, sortedBy: input.sort, matching: input.search)
            }.value
        }
        .onChange(of: sync.completedSyncs) {
            // pick up new albums once a sync finishes
            Task { await store.load() }
        }
    }

    private var albumList: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.albums) { album in
                        NavigationLink {
                            AlbumView(album: album)
                        } label: {
                            AlbumRow(
                                album: album,
                                artworkURL: store.artworkURL(filename: album.artworkFilename))
                        }
                        .albumContextMenu(album, library: store.songs, artistDestination: $artistDestination)
                    }
                }
                .sectionIndexLabel(Text(section.title))
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(sort == .year ? .hidden : .visible)
        .searchable(text: $search, prompt: "Search")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortRaw) {
                ForEach(AlbumSortOption.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}

struct AlbumRow: View {
    let album: Album
    let artworkURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: artworkURL)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(album.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
