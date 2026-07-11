import AppIntents
import Foundation

struct PlaylistAppEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static let defaultQuery = PlaylistAppEntityQuery()

    let id: String
    let name: String
    let songCount: Int

    init(playlist: PlaylistItem) {
        id = playlist.id
        name = playlist.name
        songCount = playlist.trackIds.count
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(songCount) songs",
            image: .init(systemName: "music.note.list"))
    }
}

struct PlaylistAppEntityQuery: EntityStringQuery {
    static let suggestedLimit = 100

    @Dependency private var service: IntentPlaybackService

    @MainActor
    func entities(for identifiers: [String]) async throws -> [PlaylistAppEntity] {
        try await service.prepare()
        return EntityMatcher.playlists(in: service.allPlaylists, ids: identifiers).map(PlaylistAppEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistAppEntity] {
        try await service.prepare()
        return EntityMatcher.playlists(in: service.allPlaylists, matching: string).map(PlaylistAppEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistAppEntity] {
        guard (try? await service.prepare()) != nil else { return [] }
        return EntityMatcher.playlists(in: service.allPlaylists)
            .prefix(Self.suggestedLimit)
            .map(PlaylistAppEntity.init)
    }
}
