import Foundation
import Testing
import SwiftProtobuf
@testable import Warehouse

extension WatchContentDeliveryTests {
    @Test("removing a paused player's next item automatically commits pending replacement bytes")
    func replacingReleasedNextFile() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let songs = PlayerStoreTests.songs(2)
        var library = Library()
        library.tracks = songs.map { song in Track.with { $0.id = song.id; $0.musicFilename = song.musicFilename } }
        library.playlists = [Playlist.with { $0.id = "p"; $0.trackIds = songs.map(\.id) }]
        let head = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "account", playlistIDs: ["p"], metadataReady: true)
        let snapshot = WatchLibrarySnapshot(head: head, libraryData: try library.serializedData())
        for song in songs {
            try env.watchFiles.write(.music, song.musicFilename, data: PlayerStoreTests.musicBytes)
            try env.files.write(.music, song.musicFilename, data: Data("replacement \(song.id)".utf8))
        }
        let queue = try env.queue()
        try queue.reconcile(head: head, snapshot: snapshot)
        let (file, url) = try #require(env.queued.first { $0.0.filename == "2.wav" })
        let cache = FileCache(fileStore: env.watchFiles)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"),
                                                send: { env.receipts.append($0) })
        try receiver.reconcile(head: head, snapshot: snapshot)
        let player = PlayerStore(fileStore: env.watchFiles, fileCache: cache, musicPolicy: .downloadedOnly,
                                 activateSessionForTests: { true })
        defer { player.pause() }
        cache.onMusicChanged = { [weak player] in player?.downloadsChanged() }
        player.play(songs, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { player.nextItemURL != nil }
        player.pause()
        try env.stage(file, url: url)
        receiver.resume()
        #expect(cache.isMusicInUse("2.wav"))
        #expect(try Data(contentsOf: env.watchFiles.fileURL(.music, "2.wav")) == PlayerStoreTests.musicBytes)
        #expect(env.receipts.isEmpty)

        player.setRepeatMode(.one)

        try await PlayerStoreTests.waitFor { env.receipts.last?.status == .delivered }
        #expect(file.matches(env.watchFiles.fileURL(.music, "2.wav")))
        #expect(!cache.isMusicInUse("2.wav"))
        #expect(cache.isMusicInUse("1.wav"))
        #expect(player.currentItemURL == env.watchFiles.fileURL(.music, "1.wav"))
        #expect(!player.isPlaying)
    }
}
