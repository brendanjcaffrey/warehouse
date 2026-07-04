import Foundation

struct PlaylistItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let parentId: String
    let isLibrary: Bool
    let isFolder: Bool
    let trackIds: [String]
}

/// where show in playlist navigates: the playlist plus the track to scroll to
struct PlaylistDestination: Hashable {
    let playlist: PlaylistItem
    let song: Song
}

/// pure helpers for the playlists list
enum PlaylistListBuilder {
    /// direct children of a folder ("" for the top level), folders first then
    /// alphabetical, matching the web app; the library playlist is excluded
    /// because the songs screen already covers it
    static func children(of parentId: String, in playlists: [PlaylistItem]) -> [PlaylistItem] {
        playlists
            .filter { !$0.isLibrary && $0.parentId == parentId }
            .sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder {
                    return lhs.isFolder
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// the playlists a track appears in, alphabetical; folders & the library
    /// playlist are skipped since they aren't real playlists
    static func containing(trackId: String, in playlists: [PlaylistItem]) -> [PlaylistItem] {
        playlists
            .filter { !$0.isLibrary && !$0.isFolder && $0.trackIds.contains(trackId) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
