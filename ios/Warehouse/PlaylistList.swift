import Foundation

struct PlaylistItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let parentId: String
    let isLibrary: Bool
    let isFolder: Bool
    let trackIds: [String]
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
}
