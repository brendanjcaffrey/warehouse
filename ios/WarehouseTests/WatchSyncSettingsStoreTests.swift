import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("WatchSyncSettingsStore")
@MainActor
struct WatchSyncSettingsStoreTests {
    @Test("deleted selected playlists publish the surviving selection or a valid empty library", arguments: [false, true])
    func deletedSelectedPlaylists(deleteAll: Bool) async throws {
        let metadata = try WatchLibraryDeliveryTests.Env()
        defer { metadata.cleanUp() }
        var library = WatchLibraryDeliveryTests.library(count: 4)
        try await metadata.phone.replaceLibrary(with: library, sourceIdentity: "account")
        let defaults = Self.makeDefaults("deleted-playlists-\(deleteAll)")
        var store = WatchSyncSettingsStore(defaults: defaults)
        store.setPlaylistIds(["p1", "p2"])
        let publisher = try metadata.publisher()
        publisher.onSelectionReconciled = { store.reconcilePlaylistIds($0) }
        publisher.publish(identity: "account", playlistIDs: store.playlistIds)
        await publisher.waitForPublication()
        let original = publisher.head
        let content = try WatchContentDeliveryTests.Env()
        defer { content.cleanUp() }
        let queue = try content.queue()
        let cache = FileCache(fileStore: content.watchFiles)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: content.root.appending(path: "receiver"), send: {
            content.receipts.append($0)
        })
        let initial = try JSONDecoder().decode(WatchLibrarySnapshot.self, from: Data(contentsOf: metadata.deliveries[0].0))
        try content.cache(initial)
        try queue.reconcile(head: initial.head, snapshot: initial)
        try receiver.reconcile(head: initial.head, snapshot: initial)
        while !content.outstanding.isEmpty {
            let file = content.outstanding[0]
            let (_, url) = try #require(content.queued.first { $0.0.id == file.id })
            try content.stage(file, url: url)
            receiver.resume()
            content.outstanding.removeAll { $0.id == file.id }
            try queue.receive(try #require(content.receipts.last))
        }
        #expect(queue.progress().music.downloaded == 4)
        #expect(receiver.progress().music.downloaded == 4)
        cache.setInUse(.music, ["m2.mp3"])

        library.playlists.removeAll { $0.id == "p1" || (deleteAll && $0.id == "p2") }
        try await metadata.phone.replaceLibrary(with: library, sourceIdentity: "account")
        // recreation after sync still sees old intent until publication validates the new inventory.
        store = WatchSyncSettingsStore(defaults: defaults)
        var changes = 0
        store.onChange = { changes += 1 }
        publisher.onSnapshot = { head, snapshot in queue.update(head: head, snapshot: snapshot) }
        publisher.publish(identity: "account", playlistIDs: store.playlistIds)
        await publisher.waitForPublication()

        #expect(publisher.errorMessage == nil)
        #expect(publisher.head.metadataReady && publisher.head.failed != true)
        #expect(publisher.head.revision > original.revision)
        #expect(publisher.head.playlistIDs == (deleteAll ? [] : ["p2"]))
        #expect(metadata.deliveries.count == 2)
        #expect(store.playlistIds == publisher.head.playlistIDs)
        #expect(WatchSyncSettingsStore(defaults: defaults).playlistIds == store.playlistIds)
        #expect(changes == 0)
        let next = try JSONDecoder().decode(WatchLibrarySnapshot.self, from: Data(contentsOf: metadata.deliveries[1].0))
        try receiver.reconcile(head: next.head, snapshot: next)
        #expect(content.watchFiles.list(.music) == (deleteAll ? ["m2.mp3"] : ["m0.mp3", "m1.mp3", "m2.mp3"]))
        #expect(content.watchFiles.list(.artwork) == (try next.artwork))
        cache.setInUse(.music, [])
        #expect(content.watchFiles.list(.music) == (try next.music))
        #expect(queue.progress().music.downloaded == (deleteAll ? 0 : 2))
        store.setPlaylistIds([])
        #expect(store.playlistIds.isEmpty)
        #expect(changes == (deleteAll ? 0 : 1))
    }

    @Test("failed saves, incomplete inventories and account mismatches preserve selection until an authoritative refresh")
    func unsafeDeletionPreservesSelection() async throws {
        let metadata = try WatchLibraryDeliveryTests.Env()
        defer { metadata.cleanUp() }
        let store = WatchSyncSettingsStore(defaults: Self.makeDefaults("unsafe-deletion"))
        store.setPlaylistIds(["p1", "p2"])
        var library = WatchLibraryDeliveryTests.library(count: 4)
        try await metadata.phone.replaceLibrary(with: library, sourceIdentity: "account")
        let publisher = try metadata.publisher()
        publisher.onSelectionReconciled = { store.reconcilePlaylistIds($0) }
        publisher.publish(identity: "account", playlistIDs: store.playlistIds)
        await publisher.waitForPublication()
        let receiver = metadata.receiver()
        receiver.expect(publisher.head)
        try metadata.stage(0)
        receiver.received()
        await receiver.waitForImport()
        let accepted = receiver.snapshot

        library.playlists.removeAll { $0.id == "p1" }
        metadata.phone.beforeLibrarySave = { throw CocoaError(.fileWriteOutOfSpace) }
        await #expect(throws: CocoaError.self) {
            try await metadata.phone.replaceLibrary(with: library, sourceIdentity: "account")
        }
        metadata.phone.beforeLibrarySave = {}
        publisher.publish(identity: "account", playlistIDs: store.playlistIds)
        await publisher.waitForPublication()
        #expect(store.playlistIds == ["p1", "p2"])
        #expect(publisher.head.playlistIDs == store.playlistIds && publisher.head.metadataReady)

        // even deletion of every selected playlist cannot hide incomplete membership elsewhere.
        var incomplete = library
        incomplete.playlists = [Playlist.with { $0.id = "other"; $0.trackIds = ["missing"] }]
        try await metadata.phone.replaceLibrary(with: incomplete, sourceIdentity: "account")
        publisher.publish(identity: "account", playlistIDs: store.playlistIds)
        await publisher.waitForPublication()
        #expect(publisher.head.failed == true && store.playlistIds == ["p1", "p2"])
        receiver.expect(publisher.head)
        await receiver.waitForImport()
        #expect(receiver.snapshot == accepted)

        try await metadata.phone.replaceLibrary(with: library, sourceIdentity: "account")
        publisher.publish(identity: "new-account", playlistIDs: store.playlistIds)
        await publisher.waitForPublication()
        #expect(publisher.head.failed == true && store.playlistIds == ["p1", "p2"])
        publisher.publish(identity: nil, playlistIDs: store.playlistIds)
        await publisher.waitForPublication()
        #expect(store.playlistIds == ["p1", "p2"])

        try await metadata.phone.replaceLibrary(with: Library())
        publisher.publish(identity: "new-account", playlistIDs: store.playlistIds)
        await publisher.waitForPublication()
        #expect(publisher.head.failed == true && store.playlistIds == ["p1", "p2"])

        try await metadata.phone.replaceLibrary(with: library, sourceIdentity: "new-account")
        let relaunched = try metadata.publisher()
        relaunched.onSelectionReconciled = { store.reconcilePlaylistIds($0) }
        relaunched.publish(identity: "new-account", playlistIDs: store.playlistIds)
        await relaunched.waitForPublication()
        #expect(relaunched.errorMessage == nil && relaunched.head.playlistIDs == ["p2"])
        #expect(store.playlistIds == ["p2"])
    }

    @Test("reconciled selection survives unavailable transport and publisher recreation")
    func deletionWhileDisconnected() async throws {
        let metadata = try WatchLibraryDeliveryTests.Env()
        defer { metadata.cleanUp() }
        let defaults = Self.makeDefaults("disconnected-deletion")
        let store = WatchSyncSettingsStore(defaults: defaults)
        store.setPlaylistIds(["p1"])
        var library = WatchLibraryDeliveryTests.library(count: 4)
        try await metadata.phone.replaceLibrary(with: library, sourceIdentity: "account")
        let publisher = try metadata.publisher()
        publisher.onSelectionReconciled = { store.reconcilePlaylistIds($0) }
        publisher.publish(identity: "account", playlistIDs: store.playlistIds)
        await publisher.waitForPublication()

        library.playlists.removeAll { $0.id == "p1" }
        try await metadata.phone.replaceLibrary(with: library, sourceIdentity: "account")
        metadata.unavailable = true
        publisher.publish(identity: "account", playlistIDs: store.playlistIds)
        await publisher.waitForPublication()
        #expect(publisher.errorMessage != nil)
        #expect(publisher.head.metadataReady && publisher.head.failed != true && store.playlistIds.isEmpty)
        #expect(metadata.deliveries.count == 1)

        metadata.unavailable = false
        let reloaded = WatchSyncSettingsStore(defaults: defaults)
        let relaunched = try metadata.publisher()
        #expect(relaunched.head == publisher.head && reloaded.playlistIds.isEmpty)
        relaunched.publish(identity: "account", playlistIDs: reloaded.playlistIds)
        await relaunched.waitForPublication()
        #expect(relaunched.errorMessage == nil && metadata.deliveries.count == 2)
        let snapshot = try JSONDecoder().decode(WatchLibrarySnapshot.self, from: Data(contentsOf: metadata.deliveries[1].0))
        #expect(try snapshot.validatedLibrary().tracks.isEmpty)
    }

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

    @Test("saving a selection publishes the complete persisted selection once")
    func saveSelection() {
        let defaults = Self.makeDefaults("save-selection")
        let store = WatchSyncSettingsStore(defaults: defaults)
        store.toggle("p1")
        var published: [[String]] = []
        store.onChange = {
            published.append(WatchSyncSettingsStore(defaults: defaults).playlistIds)
        }

        store.setPlaylistIds(["p2", "p3"])
        #expect(store.playlistIds == ["p2", "p3"])
        #expect(published == [["p2", "p3"]])
        store.setPlaylistIds(["p3", "p2"])
        #expect(published.count == 1)
        store.setPlaylistIds([])
        #expect(published == [["p2", "p3"], []])
        #expect(WatchSyncSettingsStore(defaults: defaults).playlistIds.isEmpty)
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

        let reloaded = WatchSyncSettingsStore(defaults: defaults)
        #expect(reloaded.playlistIds == ["p1", "p2"])
    }

    @Test("obsolete server and prefetch settings are discarded without changing selection")
    func obsoleteSettings() {
        let defaults = Self.makeDefaults("obsolete")
        defaults.set(["p1"], forKey: "watchPlaylistIds")
        defaults.set("private-server", forKey: "watchServerURLOverride")
        defaults.set(40, forKey: "watchDeepPrefetchDepth")
        let store = WatchSyncSettingsStore(defaults: defaults)
        #expect(store.playlistIds == ["p1"])
        #expect(defaults.object(forKey: "watchServerURLOverride") == nil)
        #expect(defaults.object(forKey: "watchDeepPrefetchDepth") == nil)
    }
}
