import AppIntents
import Foundation
import MediaIntents

@available(iOS 27.0, *)
@AppEntity(schema: .audio.playlist)
struct AudioPlaylistEntity {
    static let defaultQuery = AudioPlaylistEntityQuery()

    var title: String
    var owner: AudioPlaylistOwner?
    var createdByMe: Bool?
    var curatedForMe: Bool?

    let id: String
    let trackCount: Int

    init(playlist: PlaylistItem) {
        id = playlist.id
        trackCount = playlist.trackIds.count
        title = playlist.name
        owner = nil
        createdByMe = true
        curatedForMe = false
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(trackCount) songs",
            image: .init(systemName: "music.note.list"))
    }
}

@available(iOS 27.0, *)
@UnionValue
enum AudioPlaylistOwner {
    case curator(String)
    case person(IntentPerson)
}

@available(iOS 27.0, *)
struct AudioPlaylistEntityQuery: EntityStringQuery {
    static let suggestedLimit = 100

    @Dependency private var service: IntentPlaybackService

    @MainActor
    func entities(for identifiers: [String]) async throws -> [AudioPlaylistEntity] {
        try await service.prepare()
        return EntityMatcher.playlists(in: service.allPlaylists, ids: identifiers).map(AudioPlaylistEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [AudioPlaylistEntity] {
        try await service.prepare()
        return EntityMatcher.playlists(in: service.allPlaylists, matching: string).map(AudioPlaylistEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [AudioPlaylistEntity] {
        guard (try? await service.prepare()) != nil else { return [] }
        return EntityMatcher.playlists(in: service.allPlaylists)
            .prefix(Self.suggestedLimit)
            .map(AudioPlaylistEntity.init)
    }
}

@available(iOS 27.0, *)
@UnionValue
enum WarehouseAudioEntity {
    case playlist(AudioPlaylistEntity)

    @available(iOS 27.0, *)
    struct AudioIntentValueQuery {
        @Dependency private var service: IntentPlaybackService

        @MainActor
        func values(for input: AudioSearch) async throws -> [WarehouseAudioEntity] {
            try await service.prepare()
            switch input.criteria {
            case .searchQuery(let query):
                return EntityMatcher.playlists(in: service.allPlaylists, matching: query)
                    .map(AudioPlaylistEntity.init)
                    .map(WarehouseAudioEntity.playlist)
            case .unspecified, .url:
                return []
            @unknown default:
                return []
            }
        }
    }
}

@available(iOS 27.0, *)
extension WarehouseAudioEntity.AudioIntentValueQuery: IntentValueQuery {}
