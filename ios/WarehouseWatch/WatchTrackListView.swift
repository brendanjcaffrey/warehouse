import SwiftUI

struct WatchTrackListView: View {
    let title: String
    let songs: [Song]

    @State private var search = ""
    /// scroll the buttons to the top once on open so the filter starts hidden
    /// just above them, revealed by scrolling up
    @State private var didHideFilter = false

    private enum Anchor {
        case buttons
    }

    private var filtered: [Song] {
        SongListBuilder.filtered(songs, matching: search)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter", text: $search)
                            .autocorrectionDisabled()
                        if !search.isEmpty {
                            Button {
                                search = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    HStack {
                        // playback comes in a later step
                        actionButton("Play", systemImage: "play.fill")
                        actionButton("Shuffle", systemImage: "shuffle")
                    }
                    .listRowBackground(Color.clear)
                    .id(Anchor.buttons)
                }
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(filtered) { song in
                        WatchSongRow(song: song)
                    }
                }
            }
            .navigationTitle(title)
            .onAppear {
                guard !didHideFilter else { return }
                didHideFilter = true
                // the list needs a beat to lay out before it can scroll
                Task { @MainActor in
                    proxy.scrollTo(Anchor.buttons, anchor: .top)
                }
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String) -> some View {
        Button {
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(true)
    }
}

struct WatchSongRow: View {
    @Environment(SongsStore.self) private var songs

    let song: Song

    var body: some View {
        HStack(spacing: 8) {
            WatchArtworkThumbnail(url: songs.artworkURL(song))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading) {
                Text(song.name)
                    .lineLimit(1)
                Text(song.artistName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
