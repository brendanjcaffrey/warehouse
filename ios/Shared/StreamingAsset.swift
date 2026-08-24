import AVFoundation
import Foundation

/// builds the avplayer asset for a track played straight off the server
/// instead of a file on disk.
///
/// the point is where the transfer runs. a download happens in this process,
/// and the watch only keeps running in the background while audio is actually
/// rendering — so a fetch at a track boundary is racing a suspension it loses,
/// which is what stops the music mid-workout. handing avplayer the remote url
/// moves the loading into the media daemon, which keeps going regardless of
/// whether this app is scheduled.
///
/// that rules out the obvious way to authenticate. avplayer can't be given an
/// authorization header, and `AVAssetResourceLoaderDelegate` — the supported
/// way to add one — calls back on our own queue, putting the loading right
/// back in the process we just got it out of. cookies are the way that keeps
/// it out: coremedia applies them to the requests it makes on its own.
enum StreamingAsset {
    /// the cookie name the server takes in place of the bearer header, on the
    /// music & artwork routes only
    static let cookieName = "token"

    static func url(_ type: LibraryFileType, filename: String, baseURL: URL) -> URL {
        baseURL.appendingPathComponent(type.directory).appendingPathComponent(filename)
    }

    /// nil when the url has no host to scope the cookie to, which leaves the
    /// caller to fall back on downloading the file
    static func cookie(token: String, url: URL) -> HTTPCookie? {
        guard let host = url.host(), !token.isEmpty else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookieName,
            .value: token,
            .domain: host,
            .path: "/"
        ]
        // a funnel is always https; the scheme is only ever http against a
        // server on the local network, where marking it secure would mean the
        // cookie is never sent at all
        if url.scheme == "https" {
            properties[.secure] = "TRUE"
        }
        return HTTPCookie(properties: properties)
    }

    /// avurlasset gives no way to read its options back, so they are built
    /// here where a test can see them
    static func options(cookie: HTTPCookie) -> [String: Any] {
        [
            AVURLAssetHTTPCookiesKey: [cookie],
            // a cellular watch out of range of the phone is the case this
            // exists for, and watchos counts that link as both cellular and
            // expensive; leaving these to their defaults would have the stream
            // refuse to load in exactly the situation it is here to cover
            AVURLAssetAllowsCellularAccessKey: true,
            AVURLAssetAllowsExpensiveNetworkAccessKey: true,
            AVURLAssetAllowsConstrainedNetworkAccessKey: true
        ]
    }

    /// nil when the token can't be turned into a cookie for this url, meaning
    /// there is no way to authenticate the stream
    static func make(
        _ type: LibraryFileType, filename: String, token: String, baseURL: URL
    ) -> AVURLAsset? {
        let url = url(type, filename: filename, baseURL: baseURL)
        guard let cookie = cookie(token: token, url: url) else { return nil }
        return AVURLAsset(url: url, options: options(cookie: cookie))
    }
}
