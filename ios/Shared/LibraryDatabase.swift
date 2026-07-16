import CoreData
import Foundation

@objc(TrackEntity)
final class TrackEntity: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var name: String
    @NSManaged var sortName: String
    @NSManaged var artistName: String
    @NSManaged var artistSortName: String
    @NSManaged var albumArtistName: String
    @NSManaged var albumArtistSortName: String
    @NSManaged var albumName: String
    @NSManaged var albumSortName: String
    @NSManaged var genre: String
    @NSManaged var year: Int32
    @NSManaged var duration: Double
    @NSManaged var start: Double
    @NSManaged var finish: Double
    @NSManaged var trackNumber: Int32
    @NSManaged var discNumber: Int32
    @NSManaged var playCount: Int64
    @NSManaged var rating: Int32
    @NSManaged var musicFilename: String
    @NSManaged var artworkFilename: String?
    @NSManaged var addedDate: Date?
    @NSManaged var playlistIds: [String]
}

@objc(PlaylistEntity)
final class PlaylistEntity: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var name: String
    @NSManaged var parentId: String
    @NSManaged var isLibrary: Bool
    @NSManaged var trackIds: [String]
    @NSManaged var parentPlaylistIds: [String]
    @NSManaged var childPlaylistIds: [String]
}

/// core data store holding the synced library, denormalized the same way as
/// the web app's indexeddb: artist/album/genre names are flattened into each track
final class LibraryDatabase {
    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "Library", managedObjectModel: Self.model)
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { _, error in
            if let error {
                fatalError("failed to load library store: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    /// wipes all existing data and imports the given library
    func replaceLibrary(with library: Library) async throws {
        let viewContext = container.viewContext
        try await container.performBackgroundTask { context in
            try Self.deleteAll(entityName: "TrackEntity", context: context, mergeInto: viewContext)
            try Self.deleteAll(entityName: "PlaylistEntity", context: context, mergeInto: viewContext)

            for track in library.tracks {
                let artist = library.artists[track.artistID]
                let albumArtist = library.artists[track.albumArtistID]
                let album = library.albums[track.albumID]

                let entity = TrackEntity(context: context)
                entity.id = track.id
                entity.name = track.name
                entity.sortName = track.sortName
                entity.artistName = artist?.name ?? ""
                entity.artistSortName = Self.sortName(artist)
                entity.albumArtistName = albumArtist?.name ?? ""
                entity.albumArtistSortName = Self.sortName(albumArtist)
                entity.albumName = album?.name ?? ""
                entity.albumSortName = Self.sortName(album)
                entity.genre = library.genres[track.genreID]?.name ?? ""
                entity.year = Int32(track.year)
                entity.duration = Double(track.duration)
                entity.start = Double(track.start)
                entity.finish = Double(track.finish)
                entity.trackNumber = Int32(track.trackNumber)
                entity.discNumber = Int32(track.discNumber)
                entity.playCount = Int64(track.playCount)
                entity.rating = track.rating
                entity.musicFilename = track.musicFilename
                entity.artworkFilename = track.artworkFilename.isEmpty ? nil : track.artworkFilename
                entity.addedDate = track.hasAddedDate ? Date(timeIntervalSince1970: TimeInterval(track.addedDate)) : nil
                entity.playlistIds = track.playlistIds
            }

            var parentId = [String: String]()
            var childIds = [String: [String]]()
            for playlist in library.playlists {
                parentId[playlist.id] = playlist.parentID
                childIds[playlist.parentID, default: []].append(playlist.id)
            }

            for playlist in library.playlists {
                let entity = PlaylistEntity(context: context)
                entity.id = playlist.id
                entity.name = playlist.name
                entity.parentId = playlist.parentID
                entity.isLibrary = playlist.isLibrary
                entity.trackIds = playlist.trackIds
                entity.parentPlaylistIds = Self.gatherParentPlaylistIds(playlist.id, parentId)
                entity.childPlaylistIds = Self.gatherChildPlaylistIds(playlist.id, childIds)
            }

            try context.save()
        }
    }

    /// writes an edited track's fields back to its entity so the change
    /// shows before the next sync; sort names are left stale until then,
    /// matching the web app
    func updateTrack(_ song: Song) async throws {
        try await container.performBackgroundTask { context in
            let request = NSFetchRequest<TrackEntity>(entityName: "TrackEntity")
            request.predicate = NSPredicate(format: "id == %@", song.id)
            request.fetchLimit = 1
            guard let entity = try context.fetch(request).first else { return }
            entity.name = song.name
            entity.artistName = song.artistName
            entity.albumArtistName = song.albumArtistName
            entity.albumName = song.albumName
            entity.genre = song.genre
            entity.year = Int32(song.year)
            entity.start = song.start
            entity.finish = song.finish
            entity.rating = Int32(song.rating)
            entity.artworkFilename = song.artworkFilename
            try context.save()
        }
    }

    /// all music filenames referenced by tracks
    func musicFilenames() async throws -> Set<String> {
        try await fetchFilenames(attribute: "musicFilename")
    }

    /// all artwork filenames referenced by tracks
    func artworkFilenames() async throws -> Set<String> {
        try await fetchFilenames(attribute: "artworkFilename")
    }

    /// lightweight copies of every track for the songs list
    func allSongs() async throws -> [Song] {
        try await container.performBackgroundTask { context in
            let request = NSFetchRequest<TrackEntity>(entityName: "TrackEntity")
            let tracks = try context.fetch(request)
            return tracks.map {
                Song(
                    id: $0.id,
                    name: $0.name,
                    sortName: $0.sortName,
                    artistName: $0.artistName,
                    artistSortName: $0.artistSortName,
                    albumArtistName: $0.albumArtistName,
                    albumArtistSortName: $0.albumArtistSortName,
                    albumName: $0.albumName,
                    albumSortName: $0.albumSortName,
                    genre: $0.genre,
                    year: Int($0.year),
                    duration: $0.duration,
                    start: $0.start,
                    finish: $0.finish,
                    discNumber: Int($0.discNumber),
                    trackNumber: Int($0.trackNumber),
                    playCount: Int($0.playCount),
                    rating: Int($0.rating),
                    musicFilename: $0.musicFilename,
                    artworkFilename: $0.artworkFilename,
                    addedDate: $0.addedDate)
            }
        }
    }

    /// lightweight copies of every playlist for the playlists list
    func allPlaylists() async throws -> [PlaylistItem] {
        try await container.performBackgroundTask { context in
            let request = NSFetchRequest<PlaylistEntity>(entityName: "PlaylistEntity")
            let playlists = try context.fetch(request)
            return playlists.map {
                PlaylistItem(
                    id: $0.id,
                    name: $0.name,
                    parentId: $0.parentId,
                    isLibrary: $0.isLibrary,
                    isFolder: !$0.childPlaylistIds.isEmpty,
                    trackIds: $0.trackIds)
            }
        }
    }

    func trackCount() async throws -> Int {
        try await container.performBackgroundTask { context in
            try context.count(for: NSFetchRequest<TrackEntity>(entityName: "TrackEntity"))
        }
    }

    private func fetchFilenames(attribute: String) async throws -> Set<String> {
        try await container.performBackgroundTask { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "TrackEntity")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = [attribute]
            request.returnsDistinctResults = true
            let rows = try context.fetch(request)
            let filenames = rows.compactMap { $0[attribute] as? String }
            return Set(filenames.filter { !$0.isEmpty })
        }
    }

    private static func deleteAll(entityName: String, context: NSManagedObjectContext,
                                  mergeInto viewContext: NSManagedObjectContext) throws {
        let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        let request = NSBatchDeleteRequest(fetchRequest: fetch)
        request.resultType = .resultTypeObjectIDs
        let result = try context.execute(request) as? NSBatchDeleteResult
        let objectIDs = result?.result as? [NSManagedObjectID] ?? []
        NSManagedObjectContext.mergeChanges(
            fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs], into: [context, viewContext])
    }

    /// matches the web app: empty when there's no sort name or it duplicates the name
    private static func sortName(_ value: SortName?) -> String {
        guard let value, !value.sortName.isEmpty, value.sortName != value.name else { return "" }
        return value.sortName
    }

    private static func gatherParentPlaylistIds(_ playlistId: String, _ parentId: [String: String]) -> [String] {
        var out = [String]()
        var current = playlistId
        while let parent = parentId[current], !parent.isEmpty {
            out.append(parent)
            current = parent
        }
        return out
    }

    private static func gatherChildPlaylistIds(_ playlistId: String, _ childIds: [String: [String]]) -> [String] {
        var out = [String]()
        for childId in childIds[playlistId] ?? [] {
            out.append(childId)
            out.append(contentsOf: gatherChildPlaylistIds(childId, childIds))
        }
        return out
    }

    private static let model: NSManagedObjectModel = {
        let track = NSEntityDescription()
        track.name = "TrackEntity"
        track.managedObjectClassName = "TrackEntity"
        track.properties = [
            stringAttribute("id"),
            stringAttribute("name"),
            stringAttribute("sortName"),
            stringAttribute("artistName"),
            stringAttribute("artistSortName"),
            stringAttribute("albumArtistName"),
            stringAttribute("albumArtistSortName"),
            stringAttribute("albumName"),
            stringAttribute("albumSortName"),
            stringAttribute("genre"),
            numberAttribute("year", .integer32AttributeType),
            numberAttribute("duration", .doubleAttributeType),
            numberAttribute("start", .doubleAttributeType),
            numberAttribute("finish", .doubleAttributeType),
            numberAttribute("trackNumber", .integer32AttributeType),
            numberAttribute("discNumber", .integer32AttributeType),
            numberAttribute("playCount", .integer64AttributeType),
            numberAttribute("rating", .integer32AttributeType),
            stringAttribute("musicFilename"),
            stringAttribute("artworkFilename", optional: true),
            dateAttribute("addedDate"),
            stringArrayAttribute("playlistIds")
        ]

        let playlist = NSEntityDescription()
        playlist.name = "PlaylistEntity"
        playlist.managedObjectClassName = "PlaylistEntity"
        playlist.properties = [
            stringAttribute("id"),
            stringAttribute("name"),
            stringAttribute("parentId"),
            numberAttribute("isLibrary", .booleanAttributeType),
            stringArrayAttribute("trackIds"),
            stringArrayAttribute("parentPlaylistIds"),
            stringArrayAttribute("childPlaylistIds")
        ]

        let model = NSManagedObjectModel()
        model.entities = [track, playlist]
        return model
    }()

    private static func stringAttribute(_ name: String, optional: Bool = false) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .stringAttributeType
        attribute.isOptional = optional
        if !optional {
            attribute.defaultValue = ""
        }
        return attribute
    }

    private static func dateAttribute(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .dateAttributeType
        attribute.isOptional = true
        return attribute
    }

    private static func numberAttribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = false
        attribute.defaultValue = 0
        return attribute
    }

    private static func stringArrayAttribute(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .transformableAttributeType
        attribute.valueTransformerName = NSValueTransformerName.secureUnarchiveFromDataTransformerName.rawValue
        attribute.attributeValueClassName = "NSArray"
        attribute.isOptional = false
        attribute.defaultValue = [String]()
        return attribute
    }
}
