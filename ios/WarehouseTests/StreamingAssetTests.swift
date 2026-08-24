import AVFoundation
import Foundation
import Testing
@testable import Warehouse

@Suite("StreamingAsset")
struct StreamingAssetTests {
    static let baseURL = URL(string: "https://warehouse.example.ts.net")!

    @Test("builds the same file url the downloader would have fetched")
    func buildsTheFileURL() {
        let url = StreamingAsset.url(.music, filename: "abc.mp3", baseURL: Self.baseURL)

        #expect(url == URL(string: "https://warehouse.example.ts.net/music/abc.mp3")!)
    }

    @Test("artwork streams from its own directory")
    func buildsTheArtworkURL() {
        let url = StreamingAsset.url(.artwork, filename: "abc.jpg", baseURL: Self.baseURL)

        #expect(url == URL(string: "https://warehouse.example.ts.net/artwork/abc.jpg")!)
    }

    @Test("the cookie carries the token & is scoped to the server")
    func cookieCarriesTheToken() throws {
        let url = StreamingAsset.url(.music, filename: "abc.mp3", baseURL: Self.baseURL)
        let cookie = try #require(StreamingAsset.cookie(token: "tok", url: url))

        #expect(cookie.name == StreamingAsset.cookieName)
        #expect(cookie.value == "tok")
        #expect(cookie.domain == "warehouse.example.ts.net")
        // the whole server, since artwork streams from a sibling path
        #expect(cookie.path == "/")
        #expect(cookie.isSecure)
    }

    @Test("a plain http server gets a cookie that isn't marked secure")
    func cookieOverHTTPIsNotSecure() throws {
        let url = StreamingAsset.url(
            .music, filename: "abc.mp3", baseURL: URL(string: "http://192.168.1.2:8080")!)
        let cookie = try #require(StreamingAsset.cookie(token: "tok", url: url))

        // marked secure it would never be sent at all, which is a server on
        // the local network failing to play for no visible reason
        #expect(!cookie.isSecure)
        #expect(cookie.domain == "192.168.1.2")
    }

    @Test("no token means no cookie & so no stream")
    func emptyTokenHasNoCookie() {
        let url = StreamingAsset.url(.music, filename: "abc.mp3", baseURL: Self.baseURL)

        #expect(StreamingAsset.cookie(token: "", url: url) == nil)
    }

    @Test("the asset is pointed at the server")
    func assetUsesTheFileURL() throws {
        let asset = try #require(
            StreamingAsset.make(.music, filename: "abc.mp3", token: "tok", baseURL: Self.baseURL))

        #expect(asset.url == URL(string: "https://warehouse.example.ts.net/music/abc.mp3")!)
    }

    @Test("the stream is allowed onto the links a watch away from its phone has")
    func optionsAllowExpensiveNetworks() throws {
        let url = StreamingAsset.url(.music, filename: "abc.mp3", baseURL: Self.baseURL)
        let cookie = try #require(StreamingAsset.cookie(token: "tok", url: url))
        let options = StreamingAsset.options(cookie: cookie)

        // left to their defaults these refuse the cellular & low-data links
        // that are the only ones there during a workout
        #expect(options[AVURLAssetAllowsCellularAccessKey] as? Bool == true)
        #expect(options[AVURLAssetAllowsExpensiveNetworkAccessKey] as? Bool == true)
        #expect(options[AVURLAssetAllowsConstrainedNetworkAccessKey] as? Bool == true)
        // the cookie is the only thing authenticating the request, since
        // avplayer has nowhere to put a bearer header
        #expect((options[AVURLAssetHTTPCookiesKey] as? [HTTPCookie])?.first?.value == "tok")
    }
}
