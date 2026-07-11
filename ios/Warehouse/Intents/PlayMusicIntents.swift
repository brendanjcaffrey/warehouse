import AppIntents

/// one intent per entity type, because a parameterized siri phrase can only
/// carry a single entity parameter; each re-resolves its entity id against
/// the live library so stale ids from renamed items fail with a clear message

struct PlaySongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song"
    static let description = IntentDescription("Plays a song from your library.")

    @Parameter(title: "Song") var song: SongAppEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$song)")
    }

    @Dependency private var service: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        try await service.prepare()
        guard let match = EntityMatcher.songs(in: service.allSongs, ids: [song.id]).first else {
            throw IntentError.notFound
        }
        service.play([match])
        return .result(dialog: "Playing \(match.name).", snippetIntent: NowPlayingSnippetIntent())
    }
}

struct PlayAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let description = IntentDescription("Plays an album from your library.")

    @Parameter(title: "Album") var album: AlbumAppEntity
    @Parameter(title: "Shuffle", default: false) var shuffled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$album)") {
            \.$shuffled
        }
    }

    @Dependency private var service: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        try await service.prepare()
        guard let match = EntityMatcher.albums(in: service.allSongs, ids: [album.id]).first else {
            throw IntentError.notFound
        }
        service.play(match.songs, shuffled: shuffled)
        return .result(dialog: "Playing \(match.name).", snippetIntent: NowPlayingSnippetIntent())
    }
}

struct PlayArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Artist"
    static let description = IntentDescription("Plays every song by an artist in your library.")

    @Parameter(title: "Artist") var artist: ArtistAppEntity
    @Parameter(title: "Shuffle", default: true) var shuffled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play songs by \(\.$artist)") {
            \.$shuffled
        }
    }

    @Dependency private var service: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        try await service.prepare()
        guard let match = EntityMatcher.artists(in: service.allSongs, ids: [artist.id]).first else {
            throw IntentError.notFound
        }
        service.play(EntityMatcher.songs(for: match), shuffled: shuffled)
        return .result(dialog: "Playing songs by \(match.name).", snippetIntent: NowPlayingSnippetIntent())
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays a playlist from your library.")

    @Parameter(title: "Playlist") var playlist: PlaylistAppEntity
    @Parameter(title: "Shuffle", default: false) var shuffled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") {
            \.$shuffled
        }
    }

    @Dependency private var service: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        try await service.prepare()
        guard let match = EntityMatcher.playlists(in: service.allPlaylists, ids: [playlist.id]).first else {
            throw IntentError.notFound
        }
        let songs = EntityMatcher.songs(for: match, in: service.allSongs)
        guard !songs.isEmpty else {
            throw IntentError.emptyPlaylist
        }
        service.play(songs, shuffled: shuffled)
        return .result(dialog: "Playing \(match.name).", snippetIntent: NowPlayingSnippetIntent())
    }
}

struct PlayLibraryShuffledIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Library"
    static let description = IntentDescription("Plays your whole library shuffled.")

    @Dependency private var service: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        try await service.prepare()
        guard !service.allSongs.isEmpty else {
            throw IntentError.libraryEmpty
        }
        service.play(service.allSongs, shuffled: true)
        return .result(dialog: "Shuffling your library.", snippetIntent: NowPlayingSnippetIntent())
    }
}
