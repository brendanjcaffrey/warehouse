import AppIntents
import Foundation

struct SongAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song")
    static let defaultQuery = SongAppEntityQuery()

    let id: String
    let name: String
    let artistName: String
    let artworkURL: URL?

    init(song: Song, artworkURL: URL?) {
        id = song.id
        name = song.name
        artistName = song.artistName
        self.artworkURL = artworkURL
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: artistName.isEmpty ? nil : "\(artistName)",
            image: artworkURL.map { .init(url: $0) })
    }
}

struct SongAppEntityQuery: EntityStringQuery {
    /// songs offered in the shortcuts editor & siri's phrase vocabulary are
    /// capped to the most played so large libraries don't flood the system
    static let suggestedLimit = 50

    @Dependency private var service: IntentPlaybackService

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SongAppEntity] {
        try await service.prepare()
        return EntityMatcher.songs(in: service.allSongs, ids: identifiers).map(entity(for:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [SongAppEntity] {
        try await service.prepare()
        return EntityMatcher.songs(in: service.allSongs, matching: string).map(entity(for:))
    }

    @MainActor
    func suggestedEntities() async throws -> [SongAppEntity] {
        guard (try? await service.prepare()) != nil else { return [] }
        return service.allSongs
            .sorted { $0.playCount > $1.playCount }
            .prefix(Self.suggestedLimit)
            .map(entity(for:))
    }

    @MainActor
    private func entity(for song: Song) -> SongAppEntity {
        SongAppEntity(song: song, artworkURL: service.artworkURL(filename: song.artworkFilename))
    }
}
