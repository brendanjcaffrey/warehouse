import CoreData
import Foundation
import SwiftProtobuf

extension LibraryDatabase {
    func performLibraryWrite<T>(_ operation: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        let context = libraryWriter
        return try await context.perform {
            defer { context.reset() }
            do {
                return try operation(context)
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    static func document(_ id: String, context: NSManagedObjectContext) throws -> Data? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryDocument")
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return try context.fetch(request).first?.value(forKey: "data") as? Data
    }

    static func setDocument(_ id: String, data: Data?, context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryDocument")
        request.predicate = NSPredicate(format: "id == %@", id)
        for object in try context.fetch(request) { context.delete(object) }
        if let data {
            let object = NSEntityDescription.insertNewObject(forEntityName: "LibraryDocument", into: context)
            object.setValue(id, forKey: "id")
            object.setValue(data, forKey: "data")
        }
    }

    func selectWatchProtocol() async throws {
        try await performLibraryWrite { context in
            try Self.setDocument("watchProtocolSelected", data: Data([1]), context: context)
            try context.save()
        }
    }

    func watchProtocolSelected() async throws -> Bool {
        try await container.performBackgroundTask { context in
            try Self.document("watchProtocolSelected", context: context) != nil
        }
    }

    func watchHead() async throws -> WatchLibraryHead? {
        try await readDocument("watchHead", as: WatchLibraryHead.self)
    }

    func watchSnapshot() async throws -> WatchLibrarySnapshot? {
        try await readDocument("watchSnapshot", as: WatchLibrarySnapshot.self)
    }

    func watchRetiredPublishers() async throws -> Set<UUID> {
        Set(try await readDocument("watchRetiredPublishers", as: [UUID].self) ?? [])
    }

    private func readDocument<T: Decodable>(_ id: String, as type: T.Type) async throws -> T? {
        try await container.performBackgroundTask { context in
            try Self.document(id, context: context).map { try JSONDecoder().decode(type, from: $0) }
        }
    }

    /// the context is the authority for account changes; file arrivals cannot change it.
    func expectWatchLibrary(_ head: WatchLibraryHead) async throws -> Bool {
        guard head.revision > 0 else { throw WatchLibraryError.unsupported }
        let beforeSave = beforeLibrarySave
        return try await performLibraryWrite { context in
            let old = try Self.document("watchHead", context: context).map { try JSONDecoder().decode(WatchLibraryHead.self, from: $0) }
            var retired = try Self.document("watchRetiredPublishers", context: context)
                .map { try JSONDecoder().decode([UUID].self, from: $0) } ?? []
            if let old {
                if old.publisher == head.publisher {
                    guard head.revision >= old.revision else { return false }
                    if head.revision == old.revision {
                        guard head.libraryID == old.libraryID, head.playlistIDs == old.playlistIDs,
                              head.metadataReady != old.metadataReady, head.metadataReady else { return false }
                    }
                } else {
                    guard !retired.contains(head.publisher) else { return false }
                    retired.append(old.publisher)
                }
            }
            try Self.setDocument("watchProtocolSelected", data: Data([1]), context: context)
            try Self.setDocument("watchHead", data: JSONEncoder().encode(head), context: context)
            try Self.setDocument("watchRetiredPublishers", data: JSONEncoder().encode(retired), context: context)
            try beforeSave()
            try context.save()
            return true
        }
    }

    /// tracks, playlists, accepted revision and desired files have one commit point.
    func importWatchLibrary(_ snapshot: WatchLibrarySnapshot) async throws -> Bool {
        let library = try snapshot.validatedLibrary()
        let beforeSave = beforeLibrarySave
        return try await performLibraryWrite { context in
            guard let data = try Self.document("watchHead", context: context) else { return false }
            let expected = try JSONDecoder().decode(WatchLibraryHead.self, from: data)
            guard expected.version == snapshot.head.version,
                  expected.publisher == snapshot.head.publisher, expected.revision == snapshot.head.revision,
                  expected.libraryID == snapshot.head.libraryID, expected.playlistIDs == snapshot.head.playlistIDs else { return false }
            if let accepted = try Self.document("watchSnapshot", context: context),
               try JSONDecoder().decode(WatchLibrarySnapshot.self, from: accepted).head == snapshot.head { return false }
            try Self.importLibrary(library, context: context)
            try Self.setDocument("watchSnapshot", data: JSONEncoder().encode(snapshot), context: context)
            try beforeSave()
            try context.save()
            return true
        }
    }

    func hasPhoneLibrary(identity: String) async throws -> Bool {
        try await container.performBackgroundTask { context in
            try Self.document("phoneLibraryIdentity", context: context) == Data(identity.utf8)
        }
    }

    /// a read of the current phone database, including local edits, with its source identity.
    func selectedWatchLibrary(ids: [String], identity: String) async throws -> (library: Library, playlistIDs: [String], revision: Data?) {
        try beforeWatchLibraryRead()
        return try await container.performBackgroundTask { context in
            try context.setQueryGenerationFrom(.current)
            guard try Self.document("phoneLibraryIdentity", context: context) == Data(identity.utf8) else {
                throw WatchLibraryError.notLoaded
            }
            var library = Library()
            let tracks = try context.fetch(NSFetchRequest<TrackEntity>(entityName: "TrackEntity"))
            library.playlists = try context.fetch(NSFetchRequest<PlaylistEntity>(entityName: "PlaylistEntity"))
                .sorted(by: { $0.id < $1.id }).map { entity in
                    Playlist.with {
                        $0.id = entity.id; $0.name = entity.name; $0.parentID = entity.parentId
                        $0.isLibrary = entity.isLibrary; $0.trackIds = entity.trackIds
                    }
                }
            let playlists = Dictionary(library.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let selectedIDs = ids.filter { playlists[$0] != nil }
            let selectedTracks = Set(selectedIDs.flatMap { playlists[$0]?.trackIds ?? [] })
            // synthetic metadata ids depend only on selected tracks, never unrelated library additions.
            for (index, entity) in tracks.filter({ selectedTracks.contains($0.id) }).sorted(by: { $0.id < $1.id }).enumerated() {
                var track = Track()
                track.id = entity.id
                track.name = entity.name
                track.sortName = entity.sortName
                track.artistID = UInt64(index * 2 + 1)
                track.albumArtistID = UInt64(index * 2 + 2)
                track.albumID = UInt64(index + 1)
                track.genreID = UInt64(index + 1)
                library.artists[track.artistID] = SortName.with { $0.name = entity.artistName; $0.sortName = entity.artistSortName }
                library.artists[track.albumArtistID] = SortName.with {
                    $0.name = entity.albumArtistName; $0.sortName = entity.albumArtistSortName
                }
                library.albums[track.albumID] = SortName.with { $0.name = entity.albumName; $0.sortName = entity.albumSortName }
                library.genres[track.genreID] = Name.with { $0.name = entity.genre }
                track.year = UInt32(clamping: entity.year)
                track.duration = Float(entity.duration)
                track.start = Float(entity.start)
                track.finish = Float(entity.finish)
                track.trackNumber = UInt32(clamping: entity.trackNumber)
                track.discNumber = UInt32(clamping: entity.discNumber)
                track.playCount = UInt64(clamping: entity.playCount)
                track.rating = entity.rating
                track.musicFilename = entity.musicFilename
                track.artworkFilename = entity.artworkFilename ?? ""
                if let date = entity.addedDate { track.addedDate = Int64(date.timeIntervalSince1970) }
                track.playlistIds = entity.playlistIds
                library.tracks.append(track)
            }
            // only a complete same-source inventory can establish that a playlist was deleted.
            let availableTracks = Set(tracks.map(\.id))
            guard availableTracks.count == tracks.count, !availableTracks.contains(""),
                  playlists.count == library.playlists.count, playlists[""] == nil else { throw WatchLibraryError.invalid }
            for playlist in library.playlists {
                guard Set(playlist.trackIds).isSubset(of: availableTracks) else { throw WatchLibraryError.invalid }
                var ancestors = Set([playlist.id])
                var parent = playlist.parentID
                while !parent.isEmpty {
                    guard ancestors.insert(parent).inserted, let folder = playlists[parent] else { throw WatchLibraryError.invalid }
                    parent = folder.parentID
                }
            }
            library.playlists = library.playlists.map {
                var playlist = $0
                playlist.trackIds = playlist.trackIds.filter { selectedTracks.contains($0) }
                return playlist
            }
            return (try WatchLibrarySnapshot.selected(library, ids: selectedIDs), selectedIDs,
                    try Self.document("phoneLibraryRevision", context: context))
        }
    }

    /// the revision is committed with metadata, including edits, so it survives either service restarting.
    func phoneLibraryRevision(identity: String) async throws -> Data? {
        try await container.performBackgroundTask { context in
            try context.setQueryGenerationFrom(.current)
            guard try Self.document("phoneLibraryIdentity", context: context) == Data(identity.utf8) else {
                throw WatchLibraryError.notLoaded
            }
            return try Self.document("phoneLibraryRevision", context: context)
        }
    }
}
