import Foundation

/// trims a fetched library down to just the playlists the watch syncs
enum LibraryFilter {
    static func filter(_ library: Library, playlistIds: Set<String>) -> Library {
        var filtered = library
        filtered.playlists = library.playlists
            .filter { playlistIds.contains($0.id) }
            .map { playlist in
                // the watch menu is flat, so folder ancestry is dropped
                var flattened = playlist
                flattened.parentID = ""
                return flattened
            }
        let keptTrackIds = Set(filtered.playlists.flatMap(\.trackIds))
        filtered.tracks = library.tracks.filter { keptTrackIds.contains($0.id) }
        return filtered
    }
}
