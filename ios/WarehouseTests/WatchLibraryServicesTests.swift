import Foundation
import Testing
@testable import Warehouse

@Suite("watch production composition", .serialized)
@MainActor
struct WatchLibraryServicesTests {
    @Test("launch, browse, playback, missing artwork, refresh, retry and recovery issue no server requests")
    func localLifecycle() async throws {
        let env = try WatchLibraryStoreTests.Env()
        defer { env.cleanUp() }
        let host = "watch-composition.test"
        MockURLProtocol.setHandler(forHost: host) { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        var client = LibraryClient()
        client.session = MockURLProtocol.makeSession()
        try await env.save()
        env.defaults.set("https://\(host)", forKey: "serverURL")
        env.defaults.set(100, forKey: "deepPrefetchDepth")
        let metadata = env.root.appending(path: "metadata")
        let inbox = env.root.appending(path: "content")
        var requests = 0
        let services = WatchLibraryServices(database: env.database, fileStore: env.files, defaults: env.defaults,
                                           metadataDirectory: metadata, contentDirectory: inbox, client: client)
        services.requestLibrary = { requests += 1 }
        defer { services.player.pause() }
        let session = WatchPhoneSession(library: services.receiver)
        session.content = services.content
        await services.launch()
        #expect(services.library.presentation(isConfigured: false) == .ready)
        #expect(!services.songs.songs.isEmpty)
        #expect(services.artwork.artworkURL("missing.jpg") == nil)
        #expect(env.defaults.object(forKey: "serverURL") == nil)
        #expect(env.defaults.object(forKey: "deepPrefetchDepth") == nil)
        services.player.play(services.songs.songs, token: "old-token", baseURL: URL(string: "https://\(host)")!)
        try await PlayerStoreTests.waitFor { services.player.hasLoadedTrack }
        #expect(services.player.currentItemURL?.isFileURL == true)
        #expect(services.player.downloadedOnly)
        // an old phone or unsupported protocol cannot reopen network acquisition.
        session.applyContext(["serverURL": "https://\(host)", "token": "legacy-secret", "playlistIds": ["p1"]])
        await services.receiver.waitForImport()
        #expect(services.receiver.refreshFailed)
        await services.refresh()
        session.applyContext(["watchLibraryHead": ["version": 99]])
        await services.receiver.waitForImport()
        await services.refresh()
        services.content?.resume()
        services.fileCache.evict()
        #expect(services.library.state == .ready)
        #expect(env.files.exists(.music, "local.wav"))
        #expect(requests == 2)
        #expect(MockURLProtocol.requests(forHost: host).isEmpty)
        let restored = WatchLibraryServices(database: env.database, fileStore: env.files, defaults: env.defaults,
                                           metadataDirectory: metadata, contentDirectory: inbox, client: client)
        await restored.launch()
        #expect(restored.library.state == .ready)
        #expect(restored.artwork.artworkURL("missing.jpg") == nil)
        #expect(MockURLProtocol.requests(forHost: host).isEmpty)
    }

    @Test("phone metadata and content recover from storage full with zero watch server requests")
    func storageRecovery() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let metadata = try WatchLibraryDeliveryTests.Env()
        defer { metadata.cleanUp() }
        let host = "watch-storage-composition.test"
        MockURLProtocol.setHandler(forHost: host) { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        var client = LibraryClient()
        client.session = MockURLProtocol.makeSession()
        let defaults = UserDefaults(suiteName: env.root.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: env.root.lastPathComponent) }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try queue.reconcile(head: snapshot.head, snapshot: snapshot)
        let (file, source) = try #require(env.queued.first { $0.0.type == .music })
        var receipts: [WatchContentReceipt] = []
        let inbox = env.root.appending(path: "production-content")
        let services = WatchLibraryServices(database: metadata.watch, fileStore: env.watchFiles, defaults: defaults,
                                           metadataDirectory: metadata.inbox, contentDirectory: inbox, client: client,
                                           sendReceipt: { receipts.append($0) })
        var capacity: Int64 = 0
        services.availableBytes = { capacity }
        services.now = { env.now }
        let session = WatchPhoneSession(library: services.receiver)
        session.content = services.content
        await services.launch()
        let snapshotFile = env.root.appending(path: "snapshot.json")
        try JSONEncoder().encode(snapshot).write(to: snapshotFile)
        _ = try WatchLibraryReceiver.stage(snapshotFile, directory: metadata.inbox)
        session.applyContext(try snapshot.head.encode())
        await services.receiver.waitForImport()
        #expect(services.library.state == .ready)
        try WatchContentReceiver.stage(source, file: file, directory: inbox)
        services.content?.staged(file)
        #expect(receipts.last?.status == .storageFull)
        #expect(!env.watchFiles.exists(file.type, file.filename))
        #expect(services.artwork.artworkURL("a1.jpg") == nil)
        capacity = 1_000_000_000
        env.now += 3_600
        // storage-full admission asks for redelivery; the phone retains the desired job.
        try queue.receive(try #require(receipts.last))
        queue.resume()
        try WatchContentReceiver.stage(source, file: file, directory: inbox)
        await services.refresh()
        #expect(env.watchFiles.exists(file.type, file.filename))
        #expect(receipts.last?.status == .delivered)
        #expect(services.library.progress().music.downloaded == 1)
        services.fileCache.evict()
        #expect(env.watchFiles.exists(file.type, file.filename))
        #expect(MockURLProtocol.requests(forHost: host).isEmpty)
    }

    @Test("phone token refresh publishes no credentials and preserves watch local content")
    func tokenRefresh() async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        defer { env.cleanUp() }
        let defaults = UserDefaults(suiteName: env.root.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: env.root.lastPathComponent) }
        let claims = Data("{\"username\":\"user\"}".utf8).base64EncodedString()
        let origin = URL(string: "https://phone-only.test")!
        let identity = try #require(LibraryIdentity.make(token: "header.\(claims).old-signature", baseURL: origin))
        try await env.phone.replaceLibrary(with: WatchLibraryDeliveryTests.library(count: 4), sourceIdentity: identity)
        let publisher = try env.publisher()
        publisher.publish(identity: identity, playlistIDs: ["p2"])
        await publisher.waitForPublication()
        let head = publisher.head
        let context = try head.encode()
        #expect(Set(context.keys) == ["watchLibraryHead"])
        let encoded = String(data: try #require(context["watchLibraryHead"] as? Data), encoding: .utf8)!
        #expect(!encoded.contains("token") && !encoded.contains("serverURL") && !encoded.contains(origin.absoluteString))
        let files = FileStore(rootURL: env.root.appending(path: "watch-files"))
        try files.write(.music, "m0.mp3", data: PlayerStoreTests.musicBytes)
        let services = WatchLibraryServices(database: env.watch, fileStore: files, defaults: defaults,
                                           metadataDirectory: env.inbox, contentDirectory: env.root.appending(path: "content"))
        let session = WatchPhoneSession(library: services.receiver)
        session.content = services.content
        try env.stage(0)
        session.applyContext(context)
        await services.receiver.waitForImport()
        #expect(services.library.progress().music.downloaded == 1)
        publisher.publish(identity: LibraryIdentity.make(token: "header.\(claims).refreshed-signature", baseURL: origin), playlistIDs: ["p2"])
        await publisher.waitForPublication()
        #expect(publisher.head == head)
        #expect(env.deliveries.count == 1)
        session.applyContext(try publisher.head.encode())
        await services.receiver.waitForImport()
        await services.refresh()
        #expect(services.library.state == .ready)
        #expect(services.library.progress().music.downloaded == 1)
        #expect(files.exists(.music, "m0.mp3"))
    }

    @Test("failed content ledger startup preserves local playback and refresh retries initialization")
    func damagedLedger() async throws {
        let env = try WatchLibraryStoreTests.Env()
        defer { env.cleanUp() }
        try await env.save()
        let inbox = env.root.appending(path: "content")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let ledger = inbox.appending(path: "receipts.json")
        try Data("broken".utf8).write(to: ledger)
        let services = WatchLibraryServices(database: env.database, fileStore: env.files, defaults: env.defaults,
                                           metadataDirectory: env.root.appending(path: "metadata"), contentDirectory: inbox)
        await services.launch()
        #expect(services.content == nil)
        #expect(services.library.progress().state == .deliveryUnavailable)
        #expect(services.library.state == .ready)
        #expect(env.files.exists(.music, "local.wav"))
        services.player.play(services.songs.songs, token: "", baseURL: nil)
        defer { services.player.pause() }
        try await PlayerStoreTests.waitFor { services.player.hasLoadedTrack }
        #expect(services.player.currentItemURL?.isFileURL == true)
        await services.refresh()
        #expect(services.content != nil)
        #expect(services.library.deliveryStartupError == nil && services.library.deliveryRecovered)
        #expect(services.library.progress().state != .deliveryUnavailable)
        #expect(services.library.state == .ready)
        #expect(services.player.hasLoadedTrack && env.files.exists(.music, "local.wav"))
        let archives = try FileManager.default.contentsOfDirectory(at: inbox.appending(path: "recovery"), includingPropertiesForKeys: nil)
        #expect(try Data(contentsOf: #require(archives.first)) == Data("broken".utf8))
    }
}
