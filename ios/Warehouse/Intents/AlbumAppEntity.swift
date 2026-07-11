import AppIntents
import Foundation

struct AlbumAppEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Album")
    static let defaultQuery = AlbumAppEntityQuery()

    let id: String
    let name: String
    let artistName: String
    let artworkURL: URL?

    init(album: Album, artworkURL: URL?) {
        id = album.id
        name = album.name
        artistName = album.artistName
        self.artworkURL = artworkURL
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: artistName.isEmpty ? nil : "\(artistName)",
            image: artworkURL.map { .init(url: $0) })
    }
}

struct AlbumAppEntityQuery: EntityStringQuery {
    static let suggestedLimit = 100

    @Dependency private var service: IntentPlaybackService

    @MainActor
    func entities(for identifiers: [String]) async throws -> [AlbumAppEntity] {
        try await service.prepare()
        return EntityMatcher.albums(in: service.allSongs, ids: identifiers).map(entity(for:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [AlbumAppEntity] {
        try await service.prepare()
        return EntityMatcher.albums(in: service.allSongs, matching: string).map(entity(for:))
    }

    @MainActor
    func suggestedEntities() async throws -> [AlbumAppEntity] {
        guard (try? await service.prepare()) != nil else { return [] }
        return AlbumListBuilder.albums(from: service.allSongs)
            .prefix(Self.suggestedLimit)
            .map(entity(for:))
    }

    @MainActor
    private func entity(for album: Album) -> AlbumAppEntity {
        AlbumAppEntity(album: album, artworkURL: service.artworkURL(filename: album.artworkFilename))
    }
}
