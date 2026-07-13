import SwiftUI

struct WatchTrackListView: View {
    @Environment(PlayerStore.self) private var player

    let title: String
    let songs: [Song]

    @State private var search = ""
    @State private var showingNowPlaying = false
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
                        actionButton("Play", systemImage: "play.fill") {
                            play(startingAt: 0)
                        }
                        actionButton("Shuffle", systemImage: "shuffle") {
                            playShuffled()
                        }
                    }
                    .listRowBackground(Color.clear)
                    .id(Anchor.buttons)
                }
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(filtered) { song in
                        Button {
                            // a tap always plays the whole list, dropping any filter
                            play(startingAt: songs.firstIndex(where: { $0.id == song.id }) ?? 0)
                        } label: {
                            WatchSongRow(song: song)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationDestination(isPresented: $showingNowPlaying) {
                WatchNowPlayingView()
            }
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

    private func play(startingAt index: Int) {
        // no credentials: the watch plays downloaded files only, anything
        // missing arrives through the phone relay on the next sync
        player.play(songs, startingAt: index, token: nil, baseURL: nil)
        startedPlaying()
    }

    private func playShuffled() {
        player.playShuffled(songs, token: nil, baseURL: nil)
        startedPlaying()
    }

    private func startedPlaying() {
        search = ""
        showingNowPlaying = true
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(songs.isEmpty)
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
