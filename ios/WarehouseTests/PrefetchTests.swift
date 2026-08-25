import Foundation
import Testing
@testable import Warehouse

/// what the player pulls ahead of the track that is playing: the next track,
/// how much further into the queue the chain reaches, what stops it and what
/// it holds while it works. the deep reach is a setting & off by default, so
/// a test about it says how far to go. the rest of the player's behaviour is
/// in `PlayerStoreTests`, whose fixtures these share
@Suite("PlayerStore prefetch")
struct PrefetchTests {
    /// how many music files the given number of tracks takes up, for a cache
    /// budget that fits an exact number of them
    static func trackBudget(_ tracks: Int) -> FileCacheBudget {
        FileCacheBudget(music: Int64(PlayerStoreTests.musicBytes.count * tracks), artwork: .max)
    }

    /// a music file already in the cache, with its age pinned so eviction
    /// order doesn't depend on how fast the writes happen
    @MainActor
    static func cache(_ store: FileStore, _ filename: String, created: TimeInterval) throws {
        try store.prepare()
        try PlayerStoreTests.musicBytes.write(to: store.fileURL(.music, filename))
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: created)],
            ofItemAtPath: store.fileURL(.music, filename).path)
    }

    /// counts how many requests are in flight at once, so the window can be
    /// shown to run its transfers one after another rather than all at once
    final class Concurrency: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var peak = 0

        func enter() {
            lock.lock()
            defer { lock.unlock() }
            current += 1
            peak = max(peak, current)
        }

        func leave() {
            lock.lock()
            defer { lock.unlock() }
            current -= 1
        }
    }

    @Test("the prefetch fills the queue past the protection window, not just the next track")
    @MainActor
    func fillsPastTheProtectionWindow() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, cache, baseURL) = PlayerStoreTests.makePlayer(
            host: host, budget: FileCacheBudget(music: .max, artwork: .max),
            deepPrefetchDepth: 12)
        let store = cache.fileStore

        player.play(PlayerStoreTests.songs(20), token: "tok", baseURL: baseURL)
        // a deep fill is a lot of transfers for the mock to answer while the
        // rest of the suite is running beside it
        try await PlayerStoreTests.waitFor(attempts: 900) { store.exists(.music, "14.wav") }
        try await PlayerStoreTests.settle()

        // the foreground is the only unthrottled transfer time the watch gets,
        // so it keeps going past the ten tracks eviction is holding rather
        // than stopping where the protection window does — the playhead has
        // not moved off the first track for any of this
        #expect((1...14).allSatisfy { store.exists(.music, "\($0).wav") })
        // & stops at the depth it was given rather than pulling a whole
        // library down
        #expect(!PlayerStoreTests.requested(host, "15.wav"))
        #expect(player.song?.id == "1")
    }

    @Test("off, the prefetch pulls the next track and nothing else")
    @MainActor
    func deepFetchOffPullsOnlyTheNextTrack() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, cache, baseURL) = PlayerStoreTests.makePlayer(
            host: host, budget: FileCacheBudget(music: .max, artwork: .max))
        let store = cache.fileStore

        player.play(PlayerStoreTests.songs(5), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { store.exists(.music, "2.wav") }
        try await PlayerStoreTests.settle()

        // the depth is a setting on the phone & starts at 0: a gap-free
        // boundary is what every watch gets, filling a playlist is asked for
        #expect(store.exists(.music, "2.wav"))
        #expect(!PlayerStoreTests.requested(host, "3.wav"))
    }

    @Test("the window runs its transfers one at a time")
    @MainActor
    func theWindowIsSerial() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let concurrency = Concurrency()
        let (player, cache, baseURL) = PlayerStoreTests.makePlayer(
            host: host, budget: FileCacheBudget(music: .max, artwork: .max),
            deepPrefetchDepth: 10
        ) { request in
            concurrency.enter()
            defer { concurrency.leave() }
            // long enough that overlapping transfers would be seen
            // overlapping, short enough not to hold the protocol's thread up
            Thread.sleep(forTimeInterval: 0.01)
            return (PlayerStoreTests.okResponse(request.url!), PlayerStoreTests.musicBytes)
        }
        let store = cache.fileStore

        player.play(PlayerStoreTests.songs(4), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor(attempts: 600) { store.exists(.music, "4.wav") }

        // transfers running alongside each other over one slow link finish
        // later than the same transfers in a row, & starve whatever is
        // streaming besides
        #expect(concurrency.peak == 1)
    }

    @Test("a streaming track only pulls the one track behind it")
    @MainActor
    func streamingShrinksTheWindowToTheNextTrack() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let baseURL = try PlayerStoreTests.localStreamBaseURL(containing: "1.wav")
        let (player, fileStore, _) = PlayerStoreTests.makeStreamingPlayer(
            host: host, baseURL: baseURL, budget: FileCacheBudget(music: .max, artwork: .max),
            deepPrefetchDepth: 10)

        player.play(PlayerStoreTests.songs(5), token: "tok", baseURL: baseURL)
        // a stream sits at .fetching until the item is playable, & the
        // prefetch stands down until then
        try await PlayerStoreTests.waitFor { player.status == .ready }
        try await PlayerStoreTests.waitFor(attempts: 600) { fileStore.exists(.music, "2.wav") }
        try await PlayerStoreTests.settle()

        // the link is already being spent on the sound the user is listening
        // to, so there is nothing spare to fill a cache with: only the track
        // that has to be there for a gap-free boundary is pulled
        #expect(player.isStreamingCurrentTrack)
        #expect(fileStore.exists(.music, "2.wav"))
        #expect(!fileStore.exists(.music, "3.wav"))
    }

    @Test("a track already on disk is stepped over rather than fetched again")
    @MainActor
    func theWindowStepsOverCachedTracks() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, cache, baseURL) = PlayerStoreTests.makePlayer(
            host: host, budget: FileCacheBudget(music: .max, artwork: .max),
            deepPrefetchDepth: 10)
        let store = cache.fileStore
        try store.prepare()
        try PlayerStoreTests.musicBytes.write(to: store.fileURL(.music, "3.wav"))

        player.play(PlayerStoreTests.songs(5), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor(attempts: 600) { store.exists(.music, "5.wav") }
        try await PlayerStoreTests.settle()

        // a cached track isn't work, but the window carries on past it to the
        // ones that are missing
        #expect(!PlayerStoreTests.requested(host, "3.wav"))
        #expect(store.exists(.music, "4.wav"))
        #expect(store.exists(.music, "5.wav"))
    }

    @Test("the protection window is held against eviction")
    @MainActor
    func theWindowIsHeldAgainstEviction() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, cache, baseURL) = PlayerStoreTests.makePlayer(
            host: host, budget: Self.trackBudget(2), deepPrefetchDepth: 10)
        let store = cache.fileStore
        try store.prepare()
        // a track from some earlier session, & the track that plays next: two
        // files where the budget is for two, so fetching the one that is
        // playing puts the cache over and something has to go
        try PlayerStoreTests.musicBytes.write(to: store.fileURL(.music, "old.wav"))
        try PlayerStoreTests.musicBytes.write(to: store.fileURL(.music, "2.wav"))

        player.play(PlayerStoreTests.songs(5), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor(attempts: 600) { store.exists(.music, "1.wav") }
        try await PlayerStoreTests.settle()

        // eviction reached for the one file nothing was holding, rather than
        // the track the chain is working towards
        #expect(!store.exists(.music, "old.wav"))
        #expect(store.exists(.music, "1.wav"))
        #expect(store.exists(.music, "2.wav"))
    }

    @Test("a track past the protection window is on disk but evictable")
    @MainActor
    func pastTheWindowIsEvictable() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, cache, baseURL) = PlayerStoreTests.makePlayer(
            host: host, budget: Self.trackBudget(3), deepPrefetchDepth: 20)
        let store = cache.fileStore
        try store.prepare()
        // tracks well past the ten the window covers, filling the budget
        // between them. their ages are pinned so the order eviction takes
        // them in doesn't depend on how fast the writes happened
        for (index, name) in ["18.wav", "19.wav", "20.wav"].enumerated() {
            try Self.cache(store, name, created: TimeInterval(index + 1))
        }

        player.play(PlayerStoreTests.songs(20), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { store.exists(.music, "2.wav") }
        try await PlayerStoreTests.settle()

        // the track playing & the one about to play are fetched whatever the
        // budget says, and the files the chain reached past made room for
        // them: past the window is exactly what eviction is left to work with
        #expect(store.exists(.music, "1.wav"))
        #expect(store.exists(.music, "2.wav"))
        #expect(!store.exists(.music, "18.wav"))
        #expect(!store.exists(.music, "19.wav"))
        #expect(store.exists(.music, "20.wav"))
        // & the cap stopped the chain where that exemption doesn't reach
        #expect(!PlayerStoreTests.requested(host, "3.wav"))
    }

    @Test("the window stops once the budget is spoken for")
    @MainActor
    func theWindowStopsWhenTheBudgetIsFull() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, cache, baseURL) = PlayerStoreTests.makePlayer(
            host: host, budget: Self.trackBudget(2), deepPrefetchDepth: 10)
        let store = cache.fileStore

        player.play(PlayerStoreTests.songs(5), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor(attempts: 600) { store.exists(.music, "2.wav") }
        try await PlayerStoreTests.settle()

        // the track playing & the one behind it fill the budget between them,
        // so pulling a third would only evict one of the two: a loop on the
        // slow link the chain exists to spend well
        #expect(store.exists(.music, "1.wav"))
        #expect(store.exists(.music, "2.wav"))
        #expect(!PlayerStoreTests.requested(host, "3.wav"))
    }

    @Test("the chain that stopped on the budget doesn't start over")
    @MainActor
    func theBudgetStopDoesNotOscillate() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, cache, baseURL) = PlayerStoreTests.makePlayer(
            host: host, budget: Self.trackBudget(5), deepPrefetchDepth: 20)
        let store = cache.fileStore

        player.play(PlayerStoreTests.songs(20), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor(attempts: 600) { store.exists(.music, "5.wav") }
        try await PlayerStoreTests.settle()
        let requests = MockURLProtocol.requests(forHost: host).count

        // whatever else happens while this track plays, the chain is done
        player.prefetchNext()
        player.prefetchNext()
        try await PlayerStoreTests.settle()

        // the count is what says so rather than what is on disk: a chain that
        // re-derived its target after every eviction would pull the same file
        // back over & over and leave the same five files behind
        #expect(requests == 5)
        #expect(MockURLProtocol.requests(forHost: host).count == requests)
        #expect(!PlayerStoreTests.requested(host, "6.wav"))
    }

    @Test("a miss deeper in the window doesn't spend the next track's retry")
    @MainActor
    func aDeepMissDoesNotSpendTheRetry() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, cache, baseURL) = PlayerStoreTests.makePlayer(
            host: host, budget: FileCacheBudget(music: .max, artwork: .max),
            deepPrefetchDepth: 10, prefetchRetryDelay: 0.05
        ) { request in
            if request.url?.lastPathComponent == "3.wav" {
                throw URLError(.timedOut)
            }
            return (PlayerStoreTests.okResponse(request.url!), PlayerStoreTests.musicBytes)
        }
        let store = cache.fileStore

        player.play(PlayerStoreTests.songs(5), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor(attempts: 600) { PlayerStoreTests.requested(host, "3.wav") }
        // long enough that the mid-track retry would have come round by now
        try await PlayerStoreTests.settle()

        // the retry budget belongs to the track that is about to play; a miss
        // filling the cache further out takes the chain down with it & waits
        // for the next track start or the next foreground return
        #expect(store.exists(.music, "2.wav"))
        let attempts = MockURLProtocol.requests(forHost: host)
            .filter { $0.url?.lastPathComponent == "3.wav" }
        #expect(attempts.count == 1)
        #expect(!PlayerStoreTests.requested(host, "4.wav"))
    }

    @Test("a reorder that moves the transfer in flight deeper leaves it running")
    @MainActor
    func aDeeperReorderLeavesTheTransferRunning() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let gate = DispatchSemaphore(value: 0)
        let (player, cache, baseURL) = PlayerStoreTests.makePlayer(
            host: host, budget: FileCacheBudget(music: .max, artwork: .max),
            deepPrefetchDepth: 10
        ) { request in
            if request.url?.lastPathComponent == "3.wav" {
                gate.wait()
            }
            return (PlayerStoreTests.okResponse(request.url!), PlayerStoreTests.musicBytes)
        }
        let store = cache.fileStore
        try store.prepare()
        // the track that plays next is already here, so the window is working
        // on the one behind it & nothing is waiting on the link
        try PlayerStoreTests.musicBytes.write(to: store.fileURL(.music, "2.wav"))

        player.play(PlayerStoreTests.songs(4), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { PlayerStoreTests.requested(host, "3.wav") }

        // 2, 3, 4 becomes 2, 4, 3: still wanted, just further out
        player.moveUpcoming(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        gate.signal()
        try await PlayerStoreTests.waitFor(attempts: 600) { store.exists(.music, "3.wav") }

        // its progress is on exactly the slow link that makes the window worth
        // having, so it finished rather than starting over from nothing
        let attempts = MockURLProtocol.requests(forHost: host)
            .filter { $0.url?.lastPathComponent == "3.wav" }
        #expect(attempts.count == 1)
    }

    @Test("starting a track prefetches the next queue entry")
    @MainActor
    func prefetchesTheNextTrack() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayerWithServer(host: host)

        player.play(PlayerStoreTests.songs(2), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { fileStore.exists(.music, "2.wav") }

        // the second track is on disk before it's ever reached
        #expect(fileStore.exists(.music, "2.wav"))
        #expect(player.song?.id == "1")
        #expect(player.status == .ready)
    }

    @Test("the last track of a queue has nothing to prefetch")
    @MainActor
    func doesNotPrefetchPastTheEnd() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayerWithServer(host: host)

        player.play([PlayerStoreTests.song(id: "1")], token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { fileStore.exists(.music, "1.wav") }
        try await PlayerStoreTests.settle()

        // repeat is off, so there is no next entry to fetch
        #expect(MockURLProtocol.requests(forHost: host).count == 1)
    }

    @Test("skipping to a new queue cancels the outstanding prefetch")
    @MainActor
    func skipCancelsThePrefetch() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        // hold the prefetch open so it is still in flight when the queue changes
        let gate = DispatchSemaphore(value: 0)
        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav" {
                gate.wait()
            }
            return (PlayerStoreTests.okResponse(request.url!), PlayerStoreTests.musicBytes)
        }

        player.play(PlayerStoreTests.songs(3), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { PlayerStoreTests.requested(host, "2.wav") }
        #expect(PlayerStoreTests.requested(host, "2.wav"))

        player.play([PlayerStoreTests.song(id: "9")], token: "tok", baseURL: baseURL)
        gate.signal()
        try await PlayerStoreTests.waitFor { fileStore.exists(.music, "9.wav") }
        try await PlayerStoreTests.settle()

        // the superseded prefetch neither lands nor takes over playback
        #expect(player.song?.id == "9")
        #expect(!fileStore.exists(.music, "2.wav"))
    }

    @Test("a failed prefetch leaves the playing track alone")
    @MainActor
    func prefetchFailureIsSilent() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav" {
                throw URLError(.notConnectedToInternet)
            }
            return (PlayerStoreTests.okResponse(request.url!), PlayerStoreTests.musicBytes)
        }

        player.play(PlayerStoreTests.songs(2), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { PlayerStoreTests.requested(host, "2.wav") }
        try await PlayerStoreTests.settle()

        #expect(!fileStore.exists(.music, "2.wav"))
        #expect(player.song?.id == "1")
        #expect(player.isPlaying)
        #expect(player.status == .ready)
    }

    @Test("a prefetch that misses is tried again while the track is still playing")
    @MainActor
    func prefetchIsRetriedMidTrack() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let failOnce = PlayerStoreTests.FailOnce()
        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayer(
            host: host, prefetchRetryDelay: 0.05
        ) { request in
            if request.url?.lastPathComponent == "2.wav", failOnce.shouldFail() {
                throw URLError(.timedOut)
            }
            return (PlayerStoreTests.okResponse(request.url!), PlayerStoreTests.musicBytes)
        }

        player.play(PlayerStoreTests.songs(2), token: "tok", baseURL: baseURL)
        // the first attempt missed, so the file is only here because a second
        // one went out for it part way through the current track
        try await PlayerStoreTests.waitFor { fileStore.exists(.music, "2.wav") }
        #expect(fileStore.exists(.music, "2.wav"))

        // & the track playing is untouched by the miss
        #expect(player.song?.id == "1")
        #expect(player.isPlaying)
        #expect(player.status == .ready)
    }

    @Test("leaving repeat one starts a prefetch for the next track")
    @MainActor
    func leavingRepeatOnePrefetches() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        // the prefetch armed as the queue starts misses, so the only way the
        // file can land is a later re-arm
        let failOnce = PlayerStoreTests.FailOnce()
        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav", failOnce.shouldFail() {
                throw URLError(.notConnectedToInternet)
            }
            return (PlayerStoreTests.okResponse(request.url!), PlayerStoreTests.musicBytes)
        }

        player.play(PlayerStoreTests.songs(2), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { PlayerStoreTests.requested(host, "2.wav") }

        player.setRepeatMode(.one)
        try await PlayerStoreTests.settle()
        // repeat one plays the same file again, so there is nothing to pull
        #expect(!fileStore.exists(.music, "2.wav"))

        player.setRepeatMode(.off)
        try await PlayerStoreTests.waitFor { fileStore.exists(.music, "2.wav") }
        #expect(fileStore.exists(.music, "2.wav"))
        #expect(player.song?.id == "1")
    }

    @Test("playing a track next re-points the prefetch at it")
    @MainActor
    func playNextRepointsThePrefetch() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        // hold the prefetch of the old next track open so it is still in
        // flight when the new one is inserted ahead of it
        let gate = DispatchSemaphore(value: 0)
        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav" {
                gate.wait()
            }
            return (PlayerStoreTests.okResponse(request.url!), PlayerStoreTests.musicBytes)
        }

        player.play(PlayerStoreTests.songs(3), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { PlayerStoreTests.requested(host, "2.wav") }

        player.playNext(PlayerStoreTests.song(id: "9"), token: "tok", baseURL: baseURL)
        gate.signal()
        try await PlayerStoreTests.waitFor { fileStore.exists(.music, "9.wav") }
        try await PlayerStoreTests.settle()

        #expect(player.queue.upcoming.first?.song.id == "9")
        #expect(fileStore.exists(.music, "9.wav"))
        // the prefetch of the track that used to be next was cancelled
        #expect(!fileStore.exists(.music, "2.wav"))
        #expect(player.song?.id == "1")
    }

    @Test("reordering the upcoming tracks re-points the prefetch")
    @MainActor
    func moveUpcomingRepointsThePrefetch() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayerWithServer(host: host)

        player.play(PlayerStoreTests.songs(3), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { fileStore.exists(.music, "2.wav") }

        player.moveUpcoming(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        try await PlayerStoreTests.waitFor { fileStore.exists(.music, "3.wav") }
        #expect(player.queue.upcoming.first?.song.id == "3")
        #expect(fileStore.exists(.music, "3.wav"))
    }

    @Test("re-arming the prefetch with the next track on disk asks for nothing")
    @MainActor
    func reArmingWithTheNextTrackCachedIsFree() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayerWithServer(host: host)

        player.play(PlayerStoreTests.songs(2), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { fileStore.exists(.music, "2.wav") }
        let requests = MockURLProtocol.requests(forHost: host).count

        player.prefetchNext()
        player.prefetchNext()
        try await PlayerStoreTests.settle()

        // the current track & the next one, and nothing from the re-arms
        #expect(requests == 2)
        #expect(MockURLProtocol.requests(forHost: host).count == requests)
    }

    @Test("re-arming the prefetch doesn't restart one already in flight")
    @MainActor
    func reArmingLeavesAnInFlightPrefetchAlone() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let gate = DispatchSemaphore(value: 0)
        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayer(host: host) { request in
            if request.url?.lastPathComponent == "2.wav" {
                gate.wait()
            }
            return (PlayerStoreTests.okResponse(request.url!), PlayerStoreTests.musicBytes)
        }

        player.play(PlayerStoreTests.songs(2), token: "tok", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { PlayerStoreTests.requested(host, "2.wav") }

        player.prefetchNext()
        player.prefetchNext()
        try await PlayerStoreTests.settle()
        gate.signal()
        try await PlayerStoreTests.waitFor { fileStore.exists(.music, "2.wav") }
        try await PlayerStoreTests.settle()

        // the transfer that was already running finished, rather than being
        // cancelled & started over from nothing
        #expect(fileStore.exists(.music, "2.wav"))
        let requests = MockURLProtocol.requests(forHost: host)
            .filter { $0.url?.lastPathComponent == "2.wav" }
        #expect(requests.count == 1)
    }
}
