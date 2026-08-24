import Foundation
import Testing
@testable import Warehouse

/// the shared fixtures & player factories, which live with the tests that
/// established them
private typealias Helpers = PlayerStoreTests

/// what the player keeps enqueued behind the track that is playing. the play
/// queue stays the source of truth for order; this covers the one slot after
/// it, and what happens when the media daemon steps onto that slot by itself
@Suite("PlayerStore next item")
struct PlayerQueueTests {
    /// records the tracks written back as plays, which is what reaches itunes
    @MainActor
    final class PlayedTracks {
        var ids = [String]()
    }

    /// pins a music file's creation date, so eviction order doesn't depend on
    /// how fast the writes happened
    static func age(_ store: FileStore, _ filename: String, created: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: created)],
            ofItemAtPath: store.fileURL(.music, filename).path)
    }

    /// puts every track of a queue on disk, so what the player enqueues behind
    /// the current one is about the queue rather than about the network
    static func cacheSongs(_ store: FileStore, _ ids: [String]) throws {
        try store.prepare()
        for id in ids {
            try Helpers.musicBytes.write(to: store.fileURL(.music, "\(id).wav"))
        }
    }

    @Test("the track after this one is handed to the player before it's needed")
    @MainActor
    func enqueuesTheNextTrack() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Helpers.makeStreamingPlayer(host: host)
        try Self.cacheSongs(fileStore, ["1"])

        player.play(Helpers.songs(2), token: "tok", baseURL: baseURL)
        try await Helpers.waitFor { player.nextItemURL != nil }

        // track 1 plays off disk while track 2 sits in the player as a stream,
        // so the daemon pulls it ahead whether or not this app is scheduled
        #expect(player.currentItemURL == fileStore.fileURL(.music, "1.wav"))
        #expect(player.nextItemURL == baseURL.appending(path: "music/2.wav"))
    }

    @Test("playing a track next re-points the enqueued item at it")
    @MainActor
    func playNextRepointsTheEnqueuedItem() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Helpers.makeStreamingPlayer(host: host)
        try Self.cacheSongs(fileStore, ["1", "2", "3", "9"])

        player.play(Helpers.songs(3), token: "tok", baseURL: baseURL)
        try await Helpers.waitFor { player.nextItemURL != nil }
        #expect(player.nextItemURL == fileStore.fileURL(.music, "2.wav"))

        player.playNext(Helpers.song(id: "9"), token: "tok", baseURL: baseURL)

        // only the slot behind the current track moves: re-pointing by
        // removing the item that is playing would skip a track instead
        #expect(player.nextItemURL == fileStore.fileURL(.music, "9.wav"))
        #expect(player.currentItemURL == fileStore.fileURL(.music, "1.wav"))
        #expect(player.song?.id == "1")
    }

    @Test("reordering the upcoming tracks re-points the enqueued item")
    @MainActor
    func moveUpcomingRepointsTheEnqueuedItem() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Helpers.makeStreamingPlayer(host: host)
        try Self.cacheSongs(fileStore, ["1", "2", "3"])

        player.play(Helpers.songs(3), token: "tok", baseURL: baseURL)
        try await Helpers.waitFor { player.nextItemURL != nil }
        #expect(player.nextItemURL == fileStore.fileURL(.music, "2.wav"))

        player.moveUpcoming(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        #expect(player.queue.upcoming.first?.song.id == "3")
        #expect(player.nextItemURL == fileStore.fileURL(.music, "3.wav"))
        #expect(player.currentItemURL == fileStore.fileURL(.music, "1.wav"))
    }

    @Test("repeat one enqueues nothing & leaving it queues the next track again")
    @MainActor
    func repeatOneEnqueuesNothing() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Helpers.makeStreamingPlayer(host: host)
        try Self.cacheSongs(fileStore, ["1", "2"])

        player.play(Helpers.songs(2), token: "tok", baseURL: baseURL)
        try await Helpers.waitFor { player.nextItemURL != nil }

        // the same item can't sit in the player's queue twice, & repeating
        // means playing the file that's already loaded again anyway
        player.setRepeatMode(.one)
        #expect(player.nextItemURL == nil)

        player.setRepeatMode(.off)
        #expect(player.nextItemURL == fileStore.fileURL(.music, "2.wav"))
    }

    @Test("an enqueued item that won't load leaves the playing track alone")
    @MainActor
    func failedEnqueuedItemLeavesPlaybackAlone() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let played = PlayedTracks()
        let (player, fileStore, _) = Helpers.makeStreamingPlayer(
            host: host, onTrackPlayed: { played.ids.append($0) })
        try Self.cacheSongs(fileStore, ["1"])

        // backgrounded, which is both where this matters & what keeps the
        // prefetch off the dead base url below
        player.setForeground(false)
        // track 1 plays off disk, so it needs no link at all; track 2 isn't
        // cached & goes into the slot behind it as a stream against a base url
        // nothing is listening on, which is the one enqueued item that really
        // does fail while the track in front of it is still playing
        player.play(Helpers.songs(2), token: "tok", baseURL: Helpers.deadBaseURL)
        // an item is in the slot from the moment the current track is loaded,
        // so this can only become true by that item failing & being dropped
        try await Helpers.waitFor { player.hasLoadedTrack && player.nextItemURL == nil }

        #expect(player.nextItemURL == nil)
        #expect(player.song?.id == "1")
        #expect(player.isPlaying)
        #expect(player.status == .ready)
        #expect(player.currentItemURL == fileStore.fileURL(.music, "1.wav"))
        // the queue didn't move & no play was written back for a track that
        // never played: a failure in the slot is not a track ending
        #expect(player.queue.history.isEmpty)
        #expect(played.ids.isEmpty)
        // handleItemFailure deletes the file behind the item it is given; run
        // for the slot it would take the playing track's file out from under it
        #expect(fileStore.exists(.music, "1.wav"))
    }

    @Test("skipping steps onto the enqueued item rather than starting it over")
    @MainActor
    func skipAdvancesOntoTheEnqueuedItem() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let played = PlayedTracks()
        let (player, fileStore, baseURL) = Helpers.makeStreamingPlayer(
            host: host, onTrackPlayed: { played.ids.append($0) })
        try Self.cacheSongs(fileStore, ["1", "2"])

        player.play(Helpers.songs(2), token: "tok", baseURL: baseURL)
        try await Helpers.waitFor { player.nextItemURL != nil }

        player.skipToNext()

        // whatever the daemon already has of track 2 is kept rather than
        // thrown away and pulled again from nothing
        #expect(player.advancedOntoEnqueuedItem)
        #expect(player.song?.id == "2")
        #expect(player.currentItemURL == fileStore.fileURL(.music, "2.wav"))
        #expect(player.isPlaying)
        // a skip is not a play, & the queue records it the way it always has
        #expect(played.ids.isEmpty)
        #expect(player.queue.history.map(\.song.id) == ["1"])
        // there is nothing after track 2, so the slot behind it stays empty
        #expect(player.nextItemURL == nil)
    }

    @Test("a stream that fails doesn't report a play for a track that never played")
    @MainActor
    func failedStreamReportsNoPlay() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let played = PlayedTracks()
        let (player, fileStore, _) = Helpers.makeStreamingPlayer(
            host: host, onTrackPlayed: { played.ids.append($0) })
        try Self.cacheSongs(fileStore, ["3"])
        player.setForeground(false)

        // 1 & 2 have nowhere to stream from; 3 is on disk, so it is sitting in
        // the slot behind track 2 as a file item when track 2's stream fails
        player.play(Helpers.songs(3), token: "tok", baseURL: Helpers.deadBaseURL)
        try await Helpers.waitFor {
            player.currentItemURL == fileStore.fileURL(.music, "3.wav") && !player.isStreamingCurrentTrack
        }

        #expect(player.song?.id == "3")
        // stepping off an item because it failed is not a track finishing, &
        // a play written back here would be a play in itunes for a track the
        // watch never made a sound of
        #expect(played.ids.isEmpty)
    }

    @Test("stepping off an item that failed doesn't report a play for it")
    @MainActor
    func failedItemAdvanceReportsNoPlay() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let played = PlayedTracks()
        // 1 downloads fine & is still not something avfoundation can play; 2 is
        // prefetched behind it, so the player has somewhere to step to when the
        // item that is playing fails
        let (player, fileStore, baseURL) = Helpers.makePlayer(
            host: host,
            onTrackPlayed: { played.ids.append($0) },
            handler: { request in
                let data = request.url?.lastPathComponent == "1.wav"
                    ? Data("not-audio".utf8) : Helpers.musicBytes
                return (Helpers.okResponse(request.url!), data)
            })

        player.play(Helpers.songs(2), token: "tok", baseURL: baseURL)
        try await Helpers.waitFor { player.song?.id == "2" && player.hasLoadedTrack }

        #expect(player.song?.id == "2")
        // track 1 never played a note, so nothing may be written back for it: a
        // play here is a play in the user's itunes library for silence
        #expect(played.ids.isEmpty)
        // & the failure was handled rather than stepped over: a file that won't
        // load has to go, or every later fetch short circuits on it being there
        #expect(!fileStore.exists(.music, "1.wav"))
    }

    @Test("a track with a stop time hands over at it instead of playing its tail")
    @MainActor
    func autoAdvanceRespectsTheStopTime() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let played = PlayedTracks()
        let (player, fileStore, baseURL) = Helpers.makeStreamingPlayer(
            host: host, onTrackPlayed: { played.ids.append($0) })
        try Self.cacheSongs(fileStore, ["1", "2", "3"])

        // 1 & 2 stop half a second in; the files behind them are thirty
        // seconds long, so playing their tails would be unmistakable
        player.play(
            [Helpers.edited(id: "1", finish: 0.5), Helpers.edited(id: "2", finish: 0.5), Helpers.song(id: "3")],
            token: "tok", baseURL: baseURL)
        try await Helpers.waitFor { player.song?.id == "3" }

        // nothing here asked for either of those advances: the daemon made
        // them at the stop time, & the queue followed
        #expect(player.song?.id == "3")
        #expect(player.advancedOntoEnqueuedItem)
        #expect(player.currentItemURL == fileStore.fileURL(.music, "3.wav"))
        #expect(player.isPlaying)
        #expect(player.status == .ready)
        // a track that played through to its finish counts as a play, & only
        // the ones that actually played do
        #expect(played.ids == ["1", "2"])
        #expect(player.queue.history.map(\.song.id) == ["1", "2"])
        // each advance re-armed the slot behind it, which is the only reason
        // the second one could happen at all
        #expect(player.nextItemURL == nil)
    }

    @Test("a track already queued to play isn't evicted from the cache")
    @MainActor
    func holdsTheEnqueuedTrackInUse() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, cache, baseURL) = Helpers.makePlayer(
            host: host, budget: FileCacheBudget(music: Int64(Helpers.musicBytes.count * 3), artwork: .max))
        let store = cache.fileStore
        // four tracks over a budget for three; 3 & 4 are just cache residue
        try Self.cacheSongs(store, ["1", "2", "3", "4"])
        // the track queued behind the playing one is the oldest file, so it is
        // the first thing a pass would reach for
        try Self.age(store, "2.wav", created: 1)
        try Self.age(store, "4.wav", created: 100)
        try Self.age(store, "3.wav", created: 900)
        try Self.age(store, "1.wav", created: 950)

        player.play(Helpers.songs(2), token: "tok", baseURL: baseURL)
        try await Helpers.waitFor { player.nextItemURL != nil }

        // unpinned, 2.wav goes & the track queued to play a minute from now
        // has no file behind it, with nothing left to re-point the slot
        #expect(cache.evict().map(\.filename) == ["4.wav"])
        #expect(store.exists(.music, "2.wav"))
    }
}
