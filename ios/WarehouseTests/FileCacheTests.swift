import Foundation
import Testing
@testable import Warehouse

@Suite("FileCache")
@MainActor
struct FileCacheTests {
    /// stepped by hand so recency order is exact instead of depending on how
    /// fast the writes happen
    final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000_000)

        func advance() {
            date += 60
        }
    }

    static func makeStore() -> FileStore {
        FileStore(rootURL: FileManager.default.temporaryDirectory
            .appending(path: "filecache-tests-\(UUID().uuidString)"))
    }

    static func makeCache(
        _ store: FileStore,
        music: Int64 = 250,
        artwork: Int64 = 250,
        clock: Clock = Clock()
    ) -> FileCache {
        FileCache(
            fileStore: store,
            budget: { _ in FileCacheBudget(music: music, artwork: artwork) },
            now: { clock.date })
    }

    /// writes a file of an exact size & pins its creation date, so the
    /// fallback ordering is deterministic rather than write-speed dependent
    static func write(
        _ store: FileStore, _ type: LibraryFileType, _ filename: String,
        bytes: Int, created: Date = Date(timeIntervalSince1970: 0)
    ) throws {
        try store.write(type, filename, data: Data(count: bytes))
        try FileManager.default.setAttributes(
            [.creationDate: created], ofItemAtPath: store.fileURL(type, filename).path)
    }

    @Test("eviction drops the least recently used first & stops once under budget")
    func evictsLeastRecentlyUsed() throws {
        let store = Self.makeStore()
        let clock = Clock()
        let cache = Self.makeCache(store, music: 250, clock: clock)
        for name in ["a.mp3", "b.mp3", "c.mp3"] {
            try Self.write(store, .music, name, bytes: 100)
        }
        for name in ["a.mp3", "b.mp3", "c.mp3"] {
            cache.recordUse(.music, name)
            clock.advance()
        }

        let removed = cache.evict()

        // 300 bytes over a 250 budget: dropping the oldest is enough
        #expect(removed == [FileToDownload(type: .music, filename: "a.mp3")])
        #expect(store.list(.music) == ["b.mp3", "c.mp3"])
    }

    @Test("a file marked in use survives even as the eviction candidate")
    func neverEvictsInUse() throws {
        let store = Self.makeStore()
        let clock = Clock()
        let cache = Self.makeCache(store, music: 250, clock: clock)
        for name in ["a.mp3", "b.mp3", "c.mp3"] {
            try Self.write(store, .music, name, bytes: 100)
        }
        for name in ["a.mp3", "b.mp3", "c.mp3"] {
            cache.recordUse(.music, name)
            clock.advance()
        }
        cache.setInUse(.music, ["a.mp3"])

        let removed = cache.evict()

        #expect(removed == [FileToDownload(type: .music, filename: "b.mp3")])
        #expect(store.list(.music) == ["a.mp3", "c.mp3"])
    }

    @Test("in use is replaced wholesale, so moving on releases the old track")
    func setInUseReleasesThePreviousTrack() throws {
        let store = Self.makeStore()
        let clock = Clock()
        let cache = Self.makeCache(store, music: 250, clock: clock)
        for name in ["a.mp3", "b.mp3", "c.mp3"] {
            try Self.write(store, .music, name, bytes: 100)
            cache.recordUse(.music, name)
            clock.advance()
        }
        cache.setInUse(.music, ["a.mp3"])
        cache.setInUse(.music, ["c.mp3"])

        #expect(cache.evict() == [FileToDownload(type: .music, filename: "a.mp3")])
    }

    @Test("artwork marked in use survives even as the eviction candidate")
    func neverEvictsInUseArtwork() throws {
        let store = Self.makeStore()
        let clock = Clock()
        let cache = Self.makeCache(store, artwork: 250, clock: clock)
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            try Self.write(store, .artwork, name, bytes: 100)
        }
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            cache.recordUse(.artwork, name)
            clock.advance()
        }
        cache.setInUse(.artwork, ["a.jpg"])

        let removed = cache.evict()

        // the cover on screen is the oldest here, so it would go first
        #expect(removed == [FileToDownload(type: .artwork, filename: "b.jpg")])
        #expect(store.list(.artwork) == ["a.jpg", "c.jpg"])
    }

    @Test("artwork in use is replaced wholesale, so the next track frees the old cover")
    func setInUseReleasesThePreviousCover() throws {
        let store = Self.makeStore()
        let clock = Clock()
        let cache = Self.makeCache(store, artwork: 250, clock: clock)
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            try Self.write(store, .artwork, name, bytes: 100)
            cache.recordUse(.artwork, name)
            clock.advance()
        }
        cache.setInUse(.artwork, ["a.jpg"])
        cache.setInUse(.artwork, ["c.jpg"])

        #expect(cache.evict() == [FileToDownload(type: .artwork, filename: "a.jpg")])
    }

    @Test("eviction on an empty store is a no-op")
    func emptyStoreIsANoOp() throws {
        let store = Self.makeStore()
        let cache = Self.makeCache(store, music: 0, artwork: 0)

        #expect(cache.evict().isEmpty)
        #expect(store.list(.music).isEmpty)
    }

    @Test("a lone file bigger than the whole budget is kept, not thrashed")
    func singleOversizedFileIsANoOp() throws {
        let store = Self.makeStore()
        let cache = Self.makeCache(store, music: 100)
        try Self.write(store, .music, "big.mp3", bytes: 500)
        cache.recordUse(.music, "big.mp3")

        #expect(cache.evict().isEmpty)
        #expect(store.list(.music) == ["big.mp3"])
    }

    @Test("music & artwork are budgeted separately")
    func typesHaveSeparateBudgets() throws {
        let store = Self.makeStore()
        let clock = Clock()
        let cache = Self.makeCache(store, music: 10_000, artwork: 25, clock: clock)
        try Self.write(store, .music, "a.mp3", bytes: 100)
        try Self.write(store, .music, "b.mp3", bytes: 100)
        try Self.write(store, .artwork, "a.jpg", bytes: 20)
        try Self.write(store, .artwork, "b.jpg", bytes: 20)
        let played: [(LibraryFileType, String)] = [
            (.music, "a.mp3"), (.music, "b.mp3"), (.artwork, "a.jpg"), (.artwork, "b.jpg")
        ]
        for (type, filename) in played {
            cache.recordUse(type, filename)
            clock.advance()
        }

        let removed = cache.evict()

        // music is far under its budget, artwork is over its own
        #expect(removed == [FileToDownload(type: .artwork, filename: "a.jpg")])
        #expect(store.list(.music) == ["a.mp3", "b.mp3"])
        #expect(store.list(.artwork) == ["b.jpg"])
    }

    @Test("recency outlives the cache instance, so relaunching keeps the order")
    func recencySurvivesRelaunch() throws {
        let store = Self.makeStore()
        let clock = Clock()
        // a is the older file on disk but the more recently played one
        try Self.write(store, .music, "a.mp3", bytes: 100, created: Date(timeIntervalSince1970: 1))
        try Self.write(store, .music, "b.mp3", bytes: 100, created: Date(timeIntervalSince1970: 2))
        let first = Self.makeCache(store, music: 150, clock: clock)
        first.recordUse(.music, "b.mp3")
        clock.advance()
        first.recordUse(.music, "a.mp3")

        let second = Self.makeCache(store, music: 150, clock: clock)
        let removed = second.evict()

        // creation dates alone would have taken a.mp3 instead
        #expect(removed == [FileToDownload(type: .music, filename: "b.mp3")])
        #expect(store.list(.music) == ["a.mp3"])
    }

    @Test("files the index has never seen fall back to their creation date")
    func unusedFilesFallBackToCreationDate() throws {
        let store = Self.makeStore()
        let cache = Self.makeCache(store, music: 150)
        try Self.write(store, .music, "old.mp3", bytes: 100, created: Date(timeIntervalSince1970: 1))
        try Self.write(store, .music, "new.mp3", bytes: 100, created: Date(timeIntervalSince1970: 500))

        #expect(cache.evict() == [FileToDownload(type: .music, filename: "old.mp3")])
        #expect(store.list(.music) == ["new.mp3"])
    }

    @Test("a pass at launch takes the mirror's leftovers ahead of anything played")
    func launchPassTakesMirrorLeftovers() throws {
        let store = Self.makeStore()
        let clock = Clock()
        // what the old sync left on an upgraded watch: on disk, never played,
        // so the index has nothing for either of them
        try Self.write(store, .music, "left1.mp3", bytes: 100, created: Date(timeIntervalSince1970: 1))
        try Self.write(store, .music, "left2.mp3", bytes: 100, created: Date(timeIntervalSince1970: 2))
        // older on disk than either leftover, so creation dates alone would
        // reach for it first
        try Self.write(store, .music, "played.mp3", bytes: 100, created: Date(timeIntervalSince1970: 0))
        let before = Self.makeCache(store, music: 150, clock: clock)
        before.recordUse(.music, "played.mp3")

        // the pass the app runs at launch, on a cache that has only the index
        // the last session wrote
        let atLaunch = Self.makeCache(store, music: 150, clock: clock)
        let removed = atLaunch.evict()

        #expect(removed == [
            FileToDownload(type: .music, filename: "left1.mp3"),
            FileToDownload(type: .music, filename: "left2.mp3")
        ])
        #expect(store.list(.music) == ["played.mp3"])
    }

    @Test("the budget is a clamped fraction of the space the cache could occupy")
    func budgetIsClamped() {
        let small = FileCacheBudget.forSpace(1_000_000)
        #expect(small.music == 256_000_000) // floored
        #expect(small.artwork == 16_000_000)

        let middling = FileCacheBudget.forSpace(8_000_000_000)
        #expect(middling.music == 2_000_000_000) // a quarter of the space
        #expect(middling.artwork == 128_000_000) // a fiftieth would be over the cap

        let huge = FileCacheBudget.forSpace(1_000_000_000_000)
        #expect(huge.music == 4_000_000_000) // capped
        #expect(huge.artwork == 128_000_000)
    }

    @Test("the budget is offered what the cache already holds, not just free space")
    func budgetSeesHeldBytes() throws {
        let store = Self.makeStore()
        var offered: Int64?
        let cache = FileCache(
            fileStore: store,
            budget: { held in
                offered = held
                return FileCacheBudget(music: .max, artwork: .max)
            },
            now: { Date() })
        try Self.write(store, .music, "a.mp3", bytes: 100)
        try Self.write(store, .artwork, "a.jpg", bytes: 20)

        cache.evict()

        #expect(offered == 120)
    }
}
