import Foundation

struct PlaylistItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let parentId: String
    let isLibrary: Bool
    let isFolder: Bool
    let trackIds: [String]
}

/// where show in playlist navigates: the playlist plus the track to scroll
/// to; the song is nil when opening the playlist without a target track,
/// e.g. from a spotlight result
struct PlaylistDestination: Hashable {
    let playlist: PlaylistItem
    let song: Song?
}

/// leaf playlists grouped under their folder, for the watch sync picker
struct PlaylistSection: Identifiable, Hashable {
    /// the folder's playlist id, "" for the top level
    let id: String
    let title: String
    let playlists: [PlaylistItem]
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

    /// leaf playlists sectioned by folder, top level first then folders
    /// depth-first with nested folder names joined; empty sections are skipped
    static func watchSections(in playlists: [PlaylistItem]) -> [PlaylistSection] {
        var sections = [PlaylistSection]()
        func walk(parentId: String, title: String) {
            let children = children(of: parentId, in: playlists)
            let leaves = children.filter { !$0.isFolder }
            if !leaves.isEmpty {
                sections.append(PlaylistSection(id: parentId, title: title, playlists: leaves))
            }
            for folder in children where folder.isFolder {
                walk(parentId: folder.id, title: title.isEmpty ? folder.name : "\(title) › \(folder.name)")
            }
        }
        walk(parentId: "", title: "")
        return sections
    }

    /// the playlists a track appears in, alphabetical; folders & the library
    /// playlist are skipped since they aren't real playlists
    static func containing(trackId: String, in playlists: [PlaylistItem]) -> [PlaylistItem] {
        playlists
            .filter { !$0.isLibrary && !$0.isFolder && $0.trackIds.contains(trackId) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
