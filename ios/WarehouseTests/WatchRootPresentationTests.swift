import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("watch root presentation", .serialized)
@MainActor
struct WatchRootPresentationTests {
    @Test("local and phone destinations remain independent of library readiness", arguments: [false, true], [false, true])
    func destinations(hasLocalTrack: Bool, isRemoteAvailable: Bool) {
        let states: [WatchLibraryStore.State] = [.setup, .loading, .needsSync, .empty, .ready, .failed("unreadable")]
        for state in states {
            let presentation = WatchRootPresentation(
                libraryState: state, hasLocalTrack: hasLocalTrack, isRemoteAvailable: isRemoteAvailable)
            #expect(presentation.libraryState == state)
            #expect(presentation.showsLibraryMenu == (state == .ready))
            #expect(presentation.showsLocalNowPlaying == hasLocalTrack)
            #expect(presentation.showsRemoteNowPlaying == isRemoteAvailable)
        }
    }

    @Test("empty phone snapshots preserve playing and paused controls until files are released", arguments: [false, true])
    func emptySnapshot(paused: Bool) async throws {
        let env = try WatchLibraryStoreTests.Env()
        defer { env.cleanUp() }
        let cache = FileCache(fileStore: env.files)
        let content = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "content"), send: { _ in })
        let receiver = WatchLibraryReceiver(database: env.database, directory: env.root.appending(path: "metadata"))
        let library = WatchLibraryStore(songs: env.songs, playlists: env.playlists, defaults: env.defaults, receiver: receiver)
        let player = PlayerStore(fileStore: env.files, fileCache: cache, musicPolicy: .downloadedOnly,
                                 activateSessionForTests: { true })
        defer { player.pause() }
        cache.onMusicChanged = { [weak player] in player?.downloadsChanged() }
        var saved = Library()
        saved.tracks = (1...2).map { number in
            Track.with {
                $0.id = "t\(number)"
                $0.name = "song \(number)"
                $0.musicFilename = "t\(number).wav"
                $0.artworkFilename = "a\(number).jpg"
                $0.duration = 240
            }
        }
        saved.playlists = [Playlist.with { $0.id = "p"; $0.trackIds = saved.tracks.map(\.id) }]
        for track in saved.tracks {
            try env.files.write(.music, track.musicFilename, data: PlayerStoreTests.musicBytes)
            try env.files.write(.artwork, track.artworkFilename, data: Data("artwork".utf8))
        }
        let head = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "account", playlistIDs: ["p"], metadataReady: true)
        let initial = WatchLibrarySnapshot(head: head, libraryData: try saved.serializedData())
        try await deliver(initial, receiver: receiver, root: env.root)
        try content.reconcile(head: receiver.head, snapshot: receiver.snapshot)
        await library.load()
        player.play(env.songs.songs.sorted { $0.id < $1.id }, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { player.currentTime > 0 && player.nextItemURL != nil }
        if paused { player.pause() }

        let emptyHead = WatchLibraryHead(publisher: head.publisher, revision: 2, libraryID: "account",
                                        playlistIDs: [], metadataReady: true)
        let empty = WatchLibrarySnapshot(head: emptyHead, libraryData: try Library().serializedData())
        try await deliver(empty, receiver: receiver, root: env.root)
        try content.reconcile(head: receiver.head, snapshot: receiver.snapshot)
        await library.load()

        let presentation = WatchRootPresentation(libraryState: library.presentation(isConfigured: true),
                                                hasLocalTrack: player.song != nil, isRemoteAvailable: true)
        #expect(presentation.libraryState == .empty)
        #expect(!presentation.showsLibraryMenu)
        #expect(presentation.showsLocalNowPlaying && presentation.showsRemoteNowPlaying)
        #expect(env.songs.songs.isEmpty && env.playlists.playlists.isEmpty)
        #expect(player.isPlaying == !paused)
        #expect(cache.isMusicInUse("t1.wav") && cache.isMusicInUse("t2.wav"))
        #expect(env.files.exists(.music, "t1.wav") && env.files.exists(.music, "t2.wav"))
        #expect(env.files.exists(.artwork, "a1.jpg"))
        #expect(!env.files.exists(.artwork, "a2.jpg"))

        player.pause()
        #expect(!player.isPlaying)
        player.togglePlayPause()
        try await PlayerStoreTests.waitFor { player.isPlaying && player.currentTime > 0 }
        player.seek(to: 10)
        player.skipToPrevious()
        #expect(player.song?.id == "t1")
        player.skipToNext()
        try await PlayerStoreTests.waitFor { player.song?.id == "t2" && player.hasLoadedTrack && player.isPlaying }
        #expect(player.isPlaying)
        #expect(cache.isMusicInUse("t2.wav"))
        #expect(env.files.exists(.music, "t2.wav"))
        #expect(!cache.isMusicInUse("t1.wav"))
        #expect(!env.files.exists(.music, "t1.wav"))
        #expect(!env.files.exists(.artwork, "a1.jpg"))
        #expect(library.state == .empty)
    }

    @Test("failed library loading preserves local controls alongside the phone destination")
    func failedLibrary() async throws {
        let env = try WatchLibraryStoreTests.Env()
        defer { env.cleanUp() }
        try await env.save()
        await env.library.load()
        let player = PlayerStore(fileStore: env.files, musicPolicy: .downloadedOnly, activateSessionForTests: { true })
        defer { player.pause() }
        player.play(env.songs.songs, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { player.hasLoadedTrack && player.currentTime > 0 }
        player.pause()
        let invalid = env.root.appending(path: "invalid.sqlite")
        try Data("not a sqlite database".utf8).write(to: invalid)
        let database = LibraryDatabase(storeURL: invalid)
        defer { WatchLibraryStoreTests.Env.close(database) }
        let library = WatchLibraryStore(songs: SongsStore(database: database, fileStore: env.files),
                                        playlists: PlaylistsStore(database: database), defaults: env.defaults)
        await library.load()
        let remote = WatchRemoteStore(send: { _ in })
        remote.setReachable(true)
        remote.apply(.nowPlaying(.init(trackId: "phone", name: "phone song", artistName: "", artworkFilename: nil,
                                       isPlaying: true, isActuallyPlaying: true)))
        let presentation = WatchRootPresentation(libraryState: library.presentation(isConfigured: true),
                                                hasLocalTrack: player.song != nil, isRemoteAvailable: remote.isAvailable)
        guard case .failed = presentation.libraryState else { Issue.record("expected library failure"); return }
        #expect(!presentation.showsLibraryMenu)
        #expect(presentation.showsLocalNowPlaying && presentation.showsRemoteNowPlaying)
        var navigation = RemoteNavigation()
        navigation.open()
        navigation.isPresented = false
        navigation.update(isRemoteAvailable: remote.isAvailable, isRemotePlaying: remote.isPhonePlaying, isPlayingLocally: false)
        #expect(!navigation.isPresented)
        player.togglePlayPause()
        try await PlayerStoreTests.waitFor { player.isPlaying && player.currentTime > 0 }
        #expect(player.currentItemURL == env.files.fileURL(.music, "local.wav"))
        player.togglePlayPause()
        #expect(!player.isPlaying)
        #expect(player.song != nil && env.files.exists(.music, "local.wav"))
    }

    private func deliver(_ snapshot: WatchLibrarySnapshot, receiver: WatchLibraryReceiver, root: URL) async throws {
        await receiver.waitForImport()
        let source = root.appending(path: "snapshot.json")
        try JSONEncoder().encode(snapshot).write(to: source)
        _ = try WatchLibraryReceiver.stage(source, directory: receiver.directory)
        receiver.expect(snapshot.head)
        await receiver.waitForImport()
        #expect(receiver.snapshot == snapshot)
    }
}
