import CoreSpotlight
import Foundation
import Testing
@testable import Warehouse

@Suite("SpotlightIndexer")
struct SpotlightIndexerTests {
    static let songs = [
        SearchListBuilderTests.song(id: "1", name: "Believe", artist: "Cher", album: "Believe", year: 1998),
        SearchListBuilderTests.song(id: "2", name: "Back in Black", artist: "AC:DC", album: "Back in Black", year: 1980)
    ]

    static let playlists = [
        EntityMatcherTests.playlist(id: "p1", name: "Road Trip", trackIds: ["1"])
    ]

    @Test("tapped items map back to their routes")
    func routes() throws {
        let album = try #require(EntityMatcher.albums(in: Self.songs, matching: "believe").first)
        let albumRoute = SpotlightIndexer.route(
            for: SpotlightIndexer.identifier(.album, id: album.id), songs: Self.songs, playlists: Self.playlists)
        guard case .album(let routed) = albumRoute else {
            Issue.record("expected an album route, got \(String(describing: albumRoute))")
            return
        }
        #expect(routed.id == album.id)

        let playlistRoute = SpotlightIndexer.route(
            for: SpotlightIndexer.identifier(.playlist, id: "p1"), songs: Self.songs, playlists: Self.playlists)
        guard case .playlist(let destination) = playlistRoute else {
            Issue.record("expected a playlist route, got \(String(describing: playlistRoute))")
            return
        }
        #expect(destination.playlist.id == "p1")
        #expect(destination.song == nil)
    }

    @Test("artist ids containing colons survive the identifier round trip")
    func colonInArtistId() throws {
        let artist = try #require(EntityMatcher.artists(in: Self.songs, matching: "ac:dc").first)
        let route = SpotlightIndexer.route(
            for: SpotlightIndexer.identifier(.artist, id: artist.id), songs: Self.songs, playlists: Self.playlists)
        guard case .artist(let routed) = route else {
            Issue.record("expected an artist route, got \(String(describing: route))")
            return
        }
        #expect(routed.id == artist.id)
    }

    @Test("stale & malformed identifiers resolve to nothing")
    func staleIdentifiers() {
        #expect(SpotlightIndexer.route(for: "album:gone", songs: Self.songs, playlists: Self.playlists) == nil)
        #expect(SpotlightIndexer.route(for: "nonsense", songs: Self.songs, playlists: Self.playlists) == nil)
        #expect(SpotlightIndexer.route(for: "movie:1", songs: Self.songs, playlists: Self.playlists) == nil)
    }

    @Test("donated items cover albums, artists & playlists with stable ids")
    func items() {
        let items = SpotlightIndexer.items(songs: Self.songs, playlists: Self.playlists) { _ in nil }
        let ids = items.map(\.uniqueIdentifier)
        #expect(items.count == 5)
        #expect(ids.filter { $0.hasPrefix("album:") }.count == 2)
        #expect(ids.filter { $0.hasPrefix("artist:") }.count == 2)
        #expect(ids.filter { $0.hasPrefix("playlist:") }.count == 1)
        #expect(items.allSatisfy { !$0.domainIdentifier!.isEmpty })
    }
}
