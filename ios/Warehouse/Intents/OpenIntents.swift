import AppIntents

/// open intents foreground the app & push the item's view, so shortcuts &
/// spotlight results can jump straight to library content

struct OpenAlbumIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Album"
    static let description = IntentDescription("Shows an album in your library.")

    @Parameter(title: "Album") var target: AlbumAppEntity

    @Dependency private var service: IntentPlaybackService
    @Dependency private var router: NavigationRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        try await service.prepare()
        guard let match = EntityMatcher.albums(in: service.allSongs, ids: [target.id]).first else {
            throw IntentError.notFound
        }
        router.navigate(to: .album(match))
        return .result()
    }
}

struct OpenArtistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Artist"
    static let description = IntentDescription("Shows an artist in your library.")

    @Parameter(title: "Artist") var target: ArtistAppEntity

    @Dependency private var service: IntentPlaybackService
    @Dependency private var router: NavigationRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        try await service.prepare()
        guard let match = EntityMatcher.artists(in: service.allSongs, ids: [target.id]).first else {
            throw IntentError.notFound
        }
        router.navigate(to: .artist(match))
        return .result()
    }
}

struct OpenPlaylistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Playlist"
    static let description = IntentDescription("Shows a playlist in your library.")

    @Parameter(title: "Playlist") var target: PlaylistAppEntity

    @Dependency private var service: IntentPlaybackService
    @Dependency private var router: NavigationRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        try await service.prepare()
        guard let match = EntityMatcher.playlists(in: service.allPlaylists, ids: [target.id]).first else {
            throw IntentError.notFound
        }
        router.navigate(to: .playlist(PlaylistDestination(playlist: match, song: nil)))
        return .result()
    }
}
