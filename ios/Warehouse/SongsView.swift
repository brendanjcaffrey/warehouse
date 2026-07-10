import SwiftUI

struct SongsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SongsStore.self) private var store
    @Environment(PlaylistsStore.self) private var playlistsStore
    @Environment(SyncStore.self) private var sync
    @Environment(PlayerStore.self) private var player
    @Environment(UpdatesStore.self) private var updates

    /// nil shows every song in the library
    private let playlist: PlaylistItem?
    @AppStorage private var sortRaw: String
    @State private var search = ""
    @State private var sections = [SongSection]()
    @State private var artistDestination: Artist?
    @State private var albumDestination: Album?
    @State private var songsDestination: Song?
    @State private var playlistDestination: PlaylistDestination?
    @State private var editingSong: Song?
    /// a track to scroll to once the list is built, for show in playlist
    @State private var pendingScroll: Song?
    @State private var listScroller = ListScroller()

    init(playlist: PlaylistItem? = nil, scrollTo: Song? = nil) {
        self.playlist = playlist
        _pendingScroll = State(initialValue: scrollTo)
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
        .navigationDestination(item: $songsDestination) { song in
            SongsView(scrollTo: song)
        }
        .navigationDestination(item: $playlistDestination) { destination in
            SongsView(playlist: destination.playlist, scrollTo: destination.song)
        }
        .sheet(item: $editingSong) { song in
            EditTrackView(song: song)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
        }
        .task {
            await store.load()
            // the context menu needs the playlists for show in playlist
            await playlistsStore.load()
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
        ScrollViewReader { proxy in
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
            .background(ListScrollerAnchor(scroller: listScroller))
            .onChange(of: sections) {
                scrollToPending(proxy)
            }
        }
    }

    /// jumps to the track show in playlist asked for once it's in the list;
    /// the jump goes through uikit because scrollviewreader's scrollto
    /// builds every row on the way there, which takes seconds on big lists
    private func scrollToPending(_ proxy: ScrollViewProxy) {
        guard let song = pendingScroll,
              let position = SongListBuilder.position(of: song, in: sections) else { return }
        pendingScroll = nil
        // + 1 skips the play & shuffle buttons section
        let expectedSections = sections.count + 1
        Task { @MainActor in
            // the collection view picks up the new rows just after this
            // update, so retry until the section counts line up
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                if listScroller.scrollToRow(
                    section: position.section + 1, row: position.row, expectedSections: expectedSections) {
                    return
                }
            }
            proxy.scrollTo(song.id, anchor: .center)
        }
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
                // no show in playlist entry for the playlist we're already in
                playlists: playlistsStore.playlists.filter { $0.id != playlist?.id },
                play: { play(song) },
                playNext: { player.playNext(song, token: auth.token, baseURL: auth.baseURL()) },
                edit: updates.canEditTracks ? { editingSong = song } : nil,
                artistDestination: $artistDestination,
                albumDestination: $albumDestination,
                // no show in songs entry when this is already the songs list
                songsDestination: playlist == nil ? nil : $songsDestination,
                playlistDestination: $playlistDestination)
        }
    }

    /// plays a tapped song within the whole list; when a filter is active it
    /// clears the search and plays the full list, scrolling to the tapped track
    private func play(_ song: Song) {
        let songs = fullSongList()
        let start = songs.firstIndex(of: song) ?? 0
        if !search.isEmpty {
            // scroll to the track once the cleared list rebuilds
            pendingScroll = song
            search = ""
        }
        player.play(songs, startingAt: start, token: auth.token, baseURL: auth.baseURL())
    }

    /// the full list in display order, ignoring any active search filter
    private func fullSongList() -> [Song] {
        // the built sections already are the full list when nothing is filtered
        guard !search.isEmpty else { return sections.flatMap(\.songs) }
        return SongListBuilder.orderedSongs(store.songs, trackIds: playlist?.trackIds, sortedBy: sort)
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
