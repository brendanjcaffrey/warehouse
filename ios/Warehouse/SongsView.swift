import SwiftUI

struct SongsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SongsStore.self) private var store
    @Environment(SyncStore.self) private var sync
    @Environment(PlayerStore.self) private var player

    /// nil shows every song in the library
    private let playlist: PlaylistItem?
    @AppStorage private var sortRaw: String
    @State private var search = ""
    @State private var sections = [SongSection]()
    @State private var artistDestination: Artist?
    @State private var albumDestination: Album?

    init(playlist: PlaylistItem? = nil) {
        self.playlist = playlist
        // playlists remember their own sort separately from the all songs list
        if playlist == nil {
            _sortRaw = AppStorage(wrappedValue: SongSortOption.title.rawValue, "songsSortOption")
        } else {
            _sortRaw = AppStorage(wrappedValue: SongSortOption.playlistOrder.rawValue, "playlistSortOption")
        }
    }

    private var sortOptions: [SongSortOption] {
        playlist == nil ? SongSortOption.libraryOptions : SongSortOption.playlistOptions
    }

    private var sort: SongSortOption {
        guard let stored = SongSortOption(rawValue: sortRaw), sortOptions.contains(stored) else {
            return sortOptions[0]
        }
        return stored
    }

    private var isEmpty: Bool {
        guard let playlist else { return store.songs.isEmpty }
        return store.songs.isEmpty || playlist.trackIds.isEmpty
    }

    private struct SectionInput: Equatable, Sendable {
        let songs: [Song]
        let trackIds: [String]?
        let sort: SongSortOption
        let search: String
    }

    var body: some View {
        Group {
            if isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "music.note",
                    description: Text(playlist == nil
                        ? "Sync your library from the Settings tab."
                        : "This playlist has no songs."))
            } else {
                songList
            }
        }
        .navigationTitle(playlist?.name ?? "Songs")
        .navigationDestination(item: $artistDestination) { artist in
            ArtistView(artist: artist)
        }
        .navigationDestination(item: $albumDestination) { album in
            AlbumView(album: album)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
        }
        .task {
            await store.load()
        }
        .task(id: SectionInput(songs: store.songs, trackIds: playlist?.trackIds, sort: sort, search: search)) {
            // sorting & sectioning thousands of songs is too slow to redo in body
            let input = SectionInput(songs: store.songs, trackIds: playlist?.trackIds, sort: sort, search: search)
            sections = await Task.detached(priority: .userInitiated) {
                var songs = input.songs
                if let trackIds = input.trackIds {
                    songs = SongListBuilder.playlistSongs(songs, trackIds: trackIds)
                }
                return SongListBuilder.sections(songs, sortedBy: input.sort, matching: input.search)
            }.value
        }
        .onChange(of: sync.completedSyncs) {
            // pick up new tracks & downloaded files once a sync finishes
            Task { await store.load() }
        }
        .onChange(of: sync.downloadRefreshTicks) {
            // refresh the downloaded icons periodically during long downloads
            Task { await store.load() }
        }
    }

    private var songList: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    playbackButton("Play", systemImage: "play.fill") {
                        player.play(sections.flatMap(\.songs), token: auth.token, baseURL: auth.baseURL())
                    }
                    playbackButton("Shuffle", systemImage: "shuffle") {
                        player.playShuffled(sections.flatMap(\.songs), token: auth.token, baseURL: auth.baseURL())
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(sections) { section in
                if section.title.isEmpty {
                    Section {
                        songRows(section)
                    }
                } else {
                    Section(section.title) {
                        songRows(section)
                    }
                    .sectionIndexLabel(Text(section.title))
                }
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(sort == .playlistOrder ? .hidden : .visible)
        .searchable(text: $search, prompt: "Search")
    }

    private func songRows(_ section: SongSection) -> some View {
        ForEach(section.songs) { song in
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
                play: { play(song) },
                playNext: { player.playNext(song, token: auth.token, baseURL: auth.baseURL()) },
                artistDestination: $artistDestination,
                albumDestination: $albumDestination)
        }
    }

    /// plays a tapped song within the whole displayed list
    private func play(_ song: Song) {
        let songs = sections.flatMap(\.songs)
        player.play(songs, startingAt: songs.firstIndex(of: song) ?? 0, token: auth.token, baseURL: auth.baseURL())
    }

    private func playbackButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortRaw) {
                ForEach(sortOptions) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}

struct SongRow: View {
    let song: Song
    let artworkURL: URL?
    let downloaded: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: artworkURL)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(song.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if downloaded {
                Image(systemName: "arrow.down.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        // taps anywhere on the row should register, not just on its content
        .contentShape(Rectangle())
    }
}
