import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// donates library albums, artists & playlists to spotlight so they show up
/// in system search, & maps a tapped result back to a navigation route
enum SpotlightIndexer {
    enum Kind: String, CaseIterable {
        case album
        case artist
        case playlist

        var domainIdentifier: String { "warehouse.\(rawValue)" }
    }

    /// spotlight items per kind are capped so large libraries don't
    /// overwhelm the index
    static let donationLimit = 500

    static func identifier(_ kind: Kind, id: String) -> String {
        "\(kind.rawValue):\(id)"
    }

    /// the navigation route for a tapped spotlight result, or nil when the
    /// item no longer exists in the library
    static func route(for identifier: String, songs: [Song], playlists: [PlaylistItem]) -> LibraryRoute? {
        let parts = identifier.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let kind = Kind(rawValue: String(parts[0])) else { return nil }
        let id = String(parts[1])

        switch kind {
        case .album:
            return EntityMatcher.albums(in: songs, ids: [id]).first.map(LibraryRoute.album)
        case .artist:
            return EntityMatcher.artists(in: songs, ids: [id]).first.map(LibraryRoute.artist)
        case .playlist:
            return EntityMatcher.playlists(in: playlists, ids: [id]).first.map {
                LibraryRoute.playlist(PlaylistDestination(playlist: $0, song: nil))
            }
        }
    }

    static func items(
        songs: [Song], playlists: [PlaylistItem], artworkURL: (String?) -> URL?
    ) -> [CSSearchableItem] {
        var items = [CSSearchableItem]()

        for album in AlbumListBuilder.albums(from: songs).prefix(donationLimit) {
            let url = artworkURL(album.artworkFilename)
            let item = item(
                kind: .album, id: album.id, title: album.name,
                description: album.artistName.isEmpty ? "Album" : "Album · \(album.artistName)",
                thumbnailURL: url)
            item.associateAppEntity(AlbumAppEntity(album: album, artworkURL: url))
            items.append(item)
        }

        for artist in ArtistListBuilder.artists(from: songs).prefix(donationLimit) {
            let url = artworkURL(artist.albums.compactMap(\.artworkFilename).first)
            let item = item(
                kind: .artist, id: artist.id, title: artist.name,
                description: "Artist", thumbnailURL: url)
            item.associateAppEntity(ArtistAppEntity(artist: artist, artworkURL: url))
            items.append(item)
        }

        for playlist in EntityMatcher.playlists(in: playlists).prefix(donationLimit) {
            let item = item(
                kind: .playlist, id: playlist.id, title: playlist.name,
                description: "Playlist", thumbnailURL: nil)
            item.associateAppEntity(PlaylistAppEntity(playlist: playlist))
            items.append(item)
        }

        return items
    }

    /// replaces the whole index so renamed & deleted items don't linger
    static func donate(_ items: [CSSearchableItem]) async {
        let index = CSSearchableIndex.default()
        try? await index.deleteSearchableItems(withDomainIdentifiers: Kind.allCases.map(\.domainIdentifier))
        try? await index.indexSearchableItems(items)
    }

    private static func item(
        kind: Kind, id: String, title: String, description: String, thumbnailURL: URL?
    ) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = title
        attributes.contentDescription = description
        attributes.thumbnailURL = thumbnailURL
        return CSSearchableItem(
            uniqueIdentifier: identifier(kind, id: id),
            domainIdentifier: kind.domainIdentifier,
            attributeSet: attributes)
    }
}
