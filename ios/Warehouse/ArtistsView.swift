import SwiftUI

struct ArtistsView: View {
    @Environment(SongsStore.self) private var store
    @Environment(SyncStore.self) private var sync

    @State private var search = ""
    @State private var sections = [ArtistSection]()

    private struct SectionInput: Equatable, Sendable {
        let songs: [Song]
        let search: String
    }

    var body: some View {
        Group {
            if store.songs.isEmpty {
                ContentUnavailableView(
                    "No Artists",
                    systemImage: "music.microphone",
                    description: Text("Sync your library from the Settings tab."))
            } else {
                artistList
            }
        }
        .navigationTitle("Artists")
        .task {
            await store.load()
        }
        .task(id: SectionInput(songs: store.songs, search: search)) {
            // grouping & sorting thousands of songs is too slow to redo in body
            let input = SectionInput(songs: store.songs, search: search)
            sections = await Task.detached(priority: .userInitiated) {
                let artists = ArtistListBuilder.artists(from: input.songs)
                return ArtistListBuilder.sections(artists, matching: input.search)
            }.value
        }
        .onChange(of: sync.completedSyncs) {
            // pick up new artists once a sync finishes
            Task { await store.load() }
        }
    }

    private var artistList: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.artists) { artist in
                        NavigationLink {
                            ArtistView(artist: artist)
                        } label: {
                            Text(artist.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .playbackContextMenu()
                    }
                }
                .sectionIndexLabel(Text(section.title))
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Search")
    }
}
