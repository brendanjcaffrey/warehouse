import AVFoundation
import Foundation
import Testing
@testable import Warehouse

@Suite("watch playback handoff", .serialized)
@MainActor
struct WatchPlaybackHandoffTests {
    enum StartAction: CaseIterable {
        case resume, toggle, next, previous

        @MainActor
        func perform(on player: PlayerStore) {
            switch self {
            case .resume: player.resume()
            case .toggle: player.togglePlayPause()
            case .next: player.skipToNext()
            case .previous: player.skipToPrevious()
            }
        }
    }

    @MainActor
    final class Transport {
        var commands: [RemoteCommand] = []
        var observations: [PlaybackObservation.Handler] = []
    }

    @MainActor
    struct Rig {
        let root: URL
        let files: FileStore
        let songs = PlayerStoreTests.songs(3)
        let transport: Transport
        let remote: WatchRemoteStore
        let player: PlayerStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "watch-handoff-\(UUID().uuidString)")
            files = FileStore(rootURL: root)
            for song in songs { try files.write(.music, song.musicFilename, data: PlayerStoreTests.musicBytes) }
            let transport = Transport()
            self.transport = transport
            let remote = WatchRemoteStore(send: { command, _ in transport.commands.append(command) })
            self.remote = remote
            player = PlayerStore(fileStore: files, onPlaybackRequested: { remote.pausePhone() }, musicPolicy: .downloadedOnly,
                                 activateSessionForTests: { true }, observePlayback: { _, _, receive in
                                     transport.observations.append(receive)
                                     return {}
                                 })
            remote.setReachable(true)
            phoneStarts()
            transport.commands.removeAll()
        }

        func phoneStarts() {
            remote.apply(.nowPlaying(.init(trackId: "phone", name: "phone song", artistName: "", artworkFilename: nil,
                                           isPlaying: true, isActuallyPlaying: true)))
        }

        func cleanUp() {
            player.pause()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("now playing and system transport starts pause the phone", arguments: StartAction.allCases)
    func transportStarts(_ action: StartAction) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.player.play(rig.songs, startingAt: 1, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { rig.player.hasLoadedTrack && rig.player.nextItemURL != nil }
        rig.player.pause()
        rig.phoneStarts()
        rig.transport.commands.removeAll()

        action.perform(on: rig.player)

        #expect(rig.player.isPlaying)
        #expect(rig.transport.commands == [.pause])
        #expect(rig.remote.nowPlaying?.isPlaying == false)
        let expectedID = action == .next ? "3" : (action == .previous ? "1" : "2")
        try await PlayerStoreTests.waitFor {
            rig.player.song?.id == expectedID && rig.player.currentItemURL == rig.files.fileURL(.music, "\(expectedID).wav")
        }
        if action == .next { #expect(rig.player.advancedOntoEnqueuedItem) }
    }

    @Test("selection, play and shuffle use the same handoff", arguments: [0, 1, 2])
    func selection(_ mode: Int) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        switch mode {
        case 0: rig.player.playSelected(rig.songs, startingAt: 1, token: nil, baseURL: nil)
        case 1: rig.player.play(rig.songs, token: nil, baseURL: nil)
        default: rig.player.playShuffled(rig.songs, token: nil, baseURL: nil)
        }
        #expect(rig.player.isPlaying)
        #expect(rig.transport.commands == [.pause])
        try await PlayerStoreTests.waitFor { rig.player.hasLoadedTrack }
        #expect(rig.transport.commands == [.pause])
    }

    @Test("pending activation resumes and skips hand off without a second start callback", arguments: [StartAction.resume, .next])
    func pendingStart(_ action: StartAction) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        // keep the actor until the new request, so activation cannot finish first.
        rig.player.play(rig.songs, token: nil, baseURL: nil)
        #expect(!rig.player.hasLoadedTrack)
        rig.player.pause()
        rig.phoneStarts()
        rig.transport.commands.removeAll()
        action.perform(on: rig.player)
        #expect(rig.transport.commands == [.pause])
        let expectedID = action == .next ? "2" : "1"
        try await PlayerStoreTests.waitFor { rig.player.hasLoadedTrack && rig.player.song?.id == expectedID }
        #expect(rig.player.isPlaying)
        #expect(rig.transport.commands == [.pause])
    }

    @Test("pause, seek-only previous, unavailable selections and repeated observations do not hand off")
    func noNewStart() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.player.play(rig.songs, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { rig.player.hasLoadedTrack && !rig.transport.observations.isEmpty }
        rig.phoneStarts()
        rig.transport.commands.removeAll()
        let observation = try #require(rig.transport.observations.last)
        for _ in 0..<3 {
            observation(.init(itemStatus: .readyToPlay, likelyToKeepUp: true, timeControlStatus: .playing,
                              hasBufferedAudio: true, hasPlaybackProgress: true))
        }
        rig.player.resume()
        #expect(rig.transport.commands.isEmpty)
        rig.player.togglePlayPause()
        rig.player.pause()
        rig.player.seek(to: 10)
        rig.player.skipToPrevious()
        rig.player.playSelected([PlayerStoreTests.song(id: "missing")], startingAt: 0, token: nil, baseURL: nil)
        #expect(!rig.player.isPlaying)
        #expect(rig.transport.commands.isEmpty)
        #expect(rig.remote.nowPlaying?.isPlaying == true)
    }

    @Test("an unreachable phone does not block downloaded playback", arguments: StartAction.allCases)
    func offline(_ action: StartAction) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.player.play(rig.songs, startingAt: 1, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { rig.player.hasLoadedTrack && rig.player.nextItemURL != nil }
        rig.player.pause()
        rig.phoneStarts()
        rig.remote.setReachable(false)
        rig.transport.commands.removeAll()
        action.perform(on: rig.player)
        #expect(rig.player.isPlaying)
        #expect(rig.transport.commands.isEmpty)
        let expectedID = action == .next ? "3" : (action == .previous ? "1" : "2")
        try await PlayerStoreTests.waitFor {
            rig.player.currentItemURL == rig.files.fileURL(.music, "\(expectedID).wav")
        }
    }

    @Test("production watch composition hands restored playback to the local source")
    func restoredComposition() async throws {
        let env = try WatchLibraryStoreTests.Env()
        defer { env.cleanUp() }
        try await env.save()
        let phone = PlayerStore(fileStore: env.files, activateSessionForTests: { true })
        defer { phone.pause() }
        var commands: [RemoteCommand] = []
        let remote = WatchRemoteStore(send: { command, completion in
            commands.append(command)
            phone.apply(command)
            completion(.nowPlaying(RemotePlaybackPayload(player: phone)))
        })
        remote.setReachable(true)
        let services = WatchLibraryServices(database: env.database, fileStore: env.files, defaults: env.defaults,
                                           metadataDirectory: env.root.appending(path: "metadata"),
                                           contentDirectory: env.root.appending(path: "content"),
                                           onPlaybackRequested: { remote.pausePhone() })
        defer { services.player.pause() }
        await services.launch()
        let song = try #require(services.songs.songs.first)
        let snapshot = PlaybackSnapshot(queue: PlayQueue(songs: [song]).snapshot, repeatMode: .off, currentTime: 12)
        services.player.restore(snapshot, songs: [song.id: song], token: nil, baseURL: nil)
        #expect(!services.player.isPlaying)
        #expect(!services.player.hasLoadedTrack)
        phone.play([song], token: nil, baseURL: nil)
        remote.apply(.nowPlaying(RemotePlaybackPayload(player: phone)))
        commands.removeAll()

        services.player.resume()

        #expect(!phone.isPlaying)
        #expect(commands == [.pause])
        try await PlayerStoreTests.waitFor { services.player.hasLoadedTrack }
        #expect(services.player.isPlaying)
        #expect(services.player.currentTime >= 12)
    }
}
