import Foundation
import Testing
@testable import Warehouse

@Suite("WatchSyncSettingsStore")
@MainActor
struct WatchSyncSettingsStoreTests {
    static func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "WatchSyncSettingsStoreTests-\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("selected playlist presentation observes the production queue's acknowledged counts")
    func deliveredPresentation() throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let defaults = Self.makeDefaults("delivery")
        let store = WatchSyncSettingsStore(defaults: defaults)
        let queue = try env.queue()
        store.content = queue
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        store.onChange = { try? queue.invalidate(identity: "account", playlistIDs: store.playlistIds) }
        #expect(store.progress().state == .empty)
        store.toggle("p1")
        store.toggle("p2")
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        #expect(store.progress().music.downloaded == 0)
        #expect(store.progress(playlistID: "p2").music.total == 2)
        let file = env.queued[0].0
        try queue.receive(.init(file: file, status: .delivered))
        #expect(store.progress().music.downloaded == 1)
        #expect(store.progress(playlistID: "p2").music.downloaded == 1)
        store.toggle("p1")
        store.toggle("p2")
        #expect(store.progress().state == .empty)
        #expect(queue.jobs.isEmpty)
        #expect(env.outstanding.isEmpty)
    }

    @Test("selecting another playlist preserves downloaded counts on both devices")
    func progressAfterPlaylistSelection() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let metadata = try WatchLibraryDeliveryTests.Env()
        defer { metadata.cleanUp() }
        try await metadata.phone.replaceLibrary(with: WatchLibraryDeliveryTests.library(count: 4), sourceIdentity: "account")
        let store = WatchSyncSettingsStore(defaults: Self.makeDefaults("additional-playlist"))
        var queue = try env.queue()
        store.content = queue
        let publisher = try metadata.publisher()
        publisher.onSnapshot = { head, snapshot in queue.update(head: head, snapshot: snapshot) }
        store.onChange = {
            try? queue.invalidate(identity: "account", playlistIDs: store.playlistIds)
            publisher.publish(identity: "account", playlistIDs: store.playlistIds)
        }
        store.toggle("p2")
        await publisher.waitForPublication()
        let snapshot = try JSONDecoder().decode(WatchLibrarySnapshot.self, from: Data(contentsOf: try #require(metadata.deliveries.last).0))
        try env.cache(snapshot)
        env.now += 60
        queue.resume()
        let (file, url) = try #require(env.queued.first { $0.0.type == .music })
        try env.stage(file, url: url)
        let receiver = try env.receiver()
        try receiver.reconcile(head: snapshot.head, snapshot: snapshot)
        env.outstanding.removeAll { $0.id == file.id }
        try queue.receive(try #require(env.receipts.last))
        #expect(store.progress().music.downloaded == 1)
        #expect(receiver.progress().music.downloaded == 1)
        let (artwork, artworkURL) = try #require(env.queued.first { $0.0.type == .artwork })
        try env.stage(artwork, url: artworkURL)
        receiver.resume()
        env.outstanding.removeAll { $0.id == artwork.id }
        try queue.receive(try #require(env.receipts.last))
        let obsolete = try #require(env.outstanding.first)

        store.toggle("p1")
        #expect(store.progress().music.downloaded == 1)
        #expect(store.progress().artwork.downloaded == 1)
        #expect(store.progress().state == .preparing)
        #expect(env.outstanding.isEmpty)
        try queue.receive(.init(file: obsolete, status: .delivered))
        #expect(store.progress().music.downloaded == 1)
        queue = try env.queue()
        store.content = queue
        #expect(store.progress().music.downloaded == 1)
        await publisher.waitForPublication()
        let next = try JSONDecoder().decode(WatchLibrarySnapshot.self, from: Data(contentsOf: try #require(metadata.deliveries.last).0))
        try receiver.reconcile(head: next.head, snapshot: next)
        #expect(receiver.progress().music.downloaded == 1)
        #expect(store.progress().music.downloaded == 1)
        #expect(store.progress().artwork.downloaded == 1)
        #expect(store.progress().music.total == 4)
        #expect(store.progress(playlistID: "p2").music.downloaded == 1)
        #expect(env.queued.filter { $0.0.type == file.type && $0.0.filename == file.filename }.count == 1)
        #expect(env.queued.filter { $0.0.type == artwork.type && $0.0.filename == artwork.filename }.count == 1)
    }

    @Test("toggling selects and deselects playlists")
    func togglingSelectsAndDeselects() {
        let store = WatchSyncSettingsStore(defaults: Self.makeDefaults("toggle"))

        #expect(!store.isSelected("p1"))
        store.toggle("p1")
        store.toggle("p2")
        #expect(store.isSelected("p1"))
        #expect(store.playlistIds == ["p1", "p2"])

        store.toggle("p1")
        #expect(!store.isSelected("p1"))
        #expect(store.playlistIds == ["p2"])
    }

    @Test("the settings persist across instances")
    func settingsPersist() {
        let defaults = Self.makeDefaults("persist")
        let store = WatchSyncSettingsStore(defaults: defaults)
        store.toggle("p1")
        store.toggle("p2")
        store.setServerURLOverride("funnel.example.com:8443")
        store.setDeepPrefetchDepth(40)

        let reloaded = WatchSyncSettingsStore(defaults: defaults)
        #expect(reloaded.playlistIds == ["p1", "p2"])
        #expect(reloaded.serverURLOverride == "funnel.example.com:8443")
        #expect(reloaded.deepPrefetchDepth == 40)
    }

    @Test("the deep fetch is off until it's asked for, and bounded when it is")
    func deepPrefetchDepthIsOffAndBounded() {
        let store = WatchSyncSettingsStore(defaults: Self.makeDefaults("depth"))

        // it costs the watch's link, battery & disk, so nobody gets it by
        // accident
        #expect(store.deepPrefetchDepth == 0)

        store.setDeepPrefetchDepth(25)
        #expect(store.deepPrefetchDepth == 25)

        // the queue is walked against the disk every time the chain re-arms,
        // so the reach stays finite however it is asked for
        store.setDeepPrefetchDepth(99_999)
        #expect(store.deepPrefetchDepth == WatchSyncSettingsStore.maxDeepPrefetchDepth)

        store.setDeepPrefetchDepth(-5)
        #expect(store.deepPrefetchDepth == 0)
    }

    @Test("onChange fires after every change")
    func onChangeFires() {
        let store = WatchSyncSettingsStore(defaults: Self.makeDefaults("onchange"))
        var changes = 0
        store.onChange = { changes += 1 }

        store.toggle("p1")
        store.toggle("p2")
        store.toggle("p1")
        #expect(changes == 3)

        store.setServerURLOverride("funnel.example.com:8443")
        #expect(changes == 4)

        // setting the same value again shouldn't ping the watch
        store.setServerURLOverride("funnel.example.com:8443")
        #expect(changes == 4)

        store.setDeepPrefetchDepth(20)
        #expect(changes == 5)
        store.setDeepPrefetchDepth(20)
        #expect(changes == 5)
    }

    @Test("the override wins over the phone's server url when set")
    func effectiveServerURL() {
        let store = WatchSyncSettingsStore(defaults: Self.makeDefaults("effective"))
        #expect(store.effectiveServerURL(phoneServerURL: "phone.example.com") == "phone.example.com")

        store.setServerURLOverride("   ")
        #expect(store.effectiveServerURL(phoneServerURL: "phone.example.com") == "phone.example.com")

        store.setServerURLOverride(" https://funnel.example.com:8443 ")
        #expect(store.effectiveServerURL(phoneServerURL: "phone.example.com")
            == "https://funnel.example.com:8443")
    }
}
