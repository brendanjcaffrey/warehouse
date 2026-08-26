import Foundation
import Testing
@testable import Warehouse

@Suite("PlaybackStateStore")
struct PlaybackStateStoreTests {
    static func makeStore() -> PlaybackStateStore {
        PlaybackStateStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "playback-tests-\(UUID().uuidString)/playback.json"))
    }

    static func makeSnapshot(currentTime: TimeInterval = 12) -> PlaybackSnapshot {
        let song = PlayerStoreTests.song(id: "t1")
        var queue = PlayQueue(songs: [song, PlayerStoreTests.song(id: "t2")])
        queue.advance()
        return PlaybackSnapshot(queue: queue.snapshot, repeatMode: .all, currentTime: currentTime)
    }

    @Test("a saved snapshot comes back off disk")
    func roundTrip() {
        let store = Self.makeStore()
        let snapshot = Self.makeSnapshot()
        store.save(snapshot)

        #expect(store.load() == snapshot)
    }

    @Test("nothing playing clears what was stored")
    func savingNilClears() {
        let store = Self.makeStore()
        store.save(Self.makeSnapshot())
        store.save(nil)

        #expect(store.load() == nil)
        // clearing a state that was never written is not an error either
        store.save(nil)
        #expect(store.load() == nil)
    }

    @Test("a missing or unreadable file just means nothing to restore")
    func loadFailures() throws {
        let store = Self.makeStore()
        #expect(store.load() == nil)

        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
    }
}
