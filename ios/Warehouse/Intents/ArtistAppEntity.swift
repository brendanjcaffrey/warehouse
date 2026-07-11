import AppIntents
import Foundation

struct ArtistAppEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Artist")
    static let defaultQuery = ArtistAppEntityQuery()

    let id: String
    let name: String
    let artworkURL: URL?

    init(artist: Artist, artworkURL: URL?) {
        id = artist.id
        name = artist.name
        self.artworkURL = artworkURL
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            image: artworkURL.map { .init(url: $0) })
    }
}

struct ArtistAppEntityQuery: EntityStringQuery {
    static let suggestedLimit = 100

    @Dependency private var service: IntentPlaybackService

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ArtistAppEntity] {
        try await service.prepare()
        return EntityMatcher.artists(in: service.allSongs, ids: identifiers).map(entity(for:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [ArtistAppEntity] {
        try await service.prepare()
        return EntityMatcher.artists(in: service.allSongs, matching: string).map(entity(for:))
    }

    @MainActor
    func suggestedEntities() async throws -> [ArtistAppEntity] {
        guard (try? await service.prepare()) != nil else { return [] }
        return ArtistListBuilder.artists(from: service.allSongs)
            .prefix(Self.suggestedLimit)
            .map(entity(for:))
    }

    @MainActor
    private func entity(for artist: Artist) -> ArtistAppEntity {
        let artwork = artist.albums.compactMap(\.artworkFilename).first
        return ArtistAppEntity(artist: artist, artworkURL: service.artworkURL(filename: artwork))
    }
}
