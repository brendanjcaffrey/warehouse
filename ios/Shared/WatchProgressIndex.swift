import Foundation

/// built from accepted metadata once; presentation reads only the receiver's cached values.
struct WatchProgressIndex {
    struct Selection {
        let music: [String]
        let artwork: Set<String>

        init(tracks: [Track]) {
            music = tracks.map(\.musicFilename)
            artwork = Set(tracks.map(\.artworkFilename).filter { !$0.isEmpty })
        }

        func progress(head: WatchLibraryHead?, snapshotHead: WatchLibraryHead,
                      statuses: [FileToDownload: WatchContentStatus]) -> WatchLibraryProgress {
            WatchLibraryProgress.make(head: head, snapshotHead: snapshotHead,
                                      music: .init(statuses: music.map { statuses[.init(type: .music, filename: $0)] ?? .pending }),
                                      artwork: .init(statuses: artwork.map { statuses[.init(type: .artwork, filename: $0)] ?? .pending }))
        }
    }

    let snapshot: WatchLibrarySnapshot
    let overall: Selection
    let playlists: [String: Selection]
    let files: Set<FileToDownload>
    var head: WatchLibraryHead { snapshot.head }

    init(snapshot: WatchLibrarySnapshot, library: Library) {
        self.snapshot = snapshot
        overall = Selection(tracks: library.tracks)
        let tracks = Dictionary(uniqueKeysWithValues: library.tracks.map { ($0.id, $0) })
        playlists = Dictionary(uniqueKeysWithValues: library.playlists.map { playlist in
            (playlist.id, Selection(tracks: Set(playlist.trackIds).compactMap { tracks[$0] }))
        })
        files = Set(overall.music.map { FileToDownload(type: .music, filename: $0) })
            .union(overall.artwork.map { FileToDownload(type: .artwork, filename: $0) })
    }
}
