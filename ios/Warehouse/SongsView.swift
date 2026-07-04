import SwiftUI

struct SongsView: View {
    @Environment(SongsStore.self) private var store
    @Environment(SyncStore.self) private var sync

    @AppStorage("songsSortOption") private var sortRaw = SongSortOption.title.rawValue
    @State private var search = ""
    @State private var sections = [SongSection]()

    private var sort: SongSortOption {
        SongSortOption(rawValue: sortRaw) ?? .title
    }

    private struct SectionInput: Equatable, Sendable {
        let songs: [Song]
        let sort: SongSortOption
        let search: String
    }

    var body: some View {
        Group {
            if store.songs.isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "music.note",
                    description: Text("Sync your library from the Settings tab."))
            } else {
                songList
            }
        }
        .navigationTitle("Songs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
        }
        .task {
            await store.load()
        }
        .task(id: SectionInput(songs: store.songs, sort: sort, search: search)) {
            // sorting & sectioning thousands of songs is too slow to redo in body
            let input = SectionInput(songs: store.songs, sort: sort, search: search)
            sections = await Task.detached(priority: .userInitiated) {
                SongListBuilder.sections(input.songs, sortedBy: input.sort, matching: input.search)
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
                    playbackButton("Play", systemImage: "play.fill")
                    playbackButton("Shuffle", systemImage: "shuffle")
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.songs) { song in
                        SongRow(
                            song: song,
                            artworkURL: store.artworkURL(song),
                            downloaded: store.isDownloaded(song))
                    }
                }
                .sectionIndexLabel(Text(section.title))
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .searchable(text: $search, prompt: "Search")
    }

    private func playbackButton(_ title: String, systemImage: String) -> some View {
        Button {
            // playback isn't implemented yet
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortRaw) {
                ForEach(SongSortOption.allCases) { option in
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
    }
}
