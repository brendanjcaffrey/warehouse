import Foundation
import SwiftProtobuf
import Testing
import WatchConnectivity
@testable import Warehouse

@Suite("watch production composition", .serialized)
@MainActor
struct WatchLibraryServicesTests {
    @MainActor
    struct StatusEnv {
        let metadata: WatchLibraryDeliveryTests.Env
        let defaults: UserDefaults
        let services: WatchLibraryServices
        let session: WatchPhoneSession
        let forwarder = WatchReceiptReplayTests.ReceiptForwarder()

        init(saved: Bool = true, isForeground: Bool = true) async throws {
            metadata = try WatchLibraryDeliveryTests.Env()
            defaults = UserDefaults(suiteName: metadata.root.lastPathComponent)!
            let files = FileStore(rootURL: metadata.root.appending(path: "files"))
            if saved {
                let head = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "account",
                                           playlistIDs: ["p2"], metadataReady: true)
                let library = try WatchLibrarySnapshot.selected(WatchLibraryDeliveryTests.library(count: 2), ids: ["p2"])
                let snapshot = WatchLibrarySnapshot(head: head, libraryData: try library.serializedData())
                _ = try await metadata.watch.expectWatchLibrary(head)
                _ = try await metadata.watch.importWatchLibrary(snapshot)
                try files.write(.music, "m0.mp3", data: PlayerStoreTests.musicBytes)
            }
            let forwarder = forwarder
            services = WatchLibraryServices(database: metadata.watch, fileStore: files, defaults: defaults,
                                           metadataDirectory: metadata.inbox, contentDirectory: metadata.root.appending(path: "content"),
                                           sendReceipt: { forwarder.send($0) },
                                           isForeground: isForeground)
            session = WatchPhoneSession(library: services.receiver)
            session.content = services.content
            forwarder.session = session
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: metadata.root.lastPathComponent)
            metadata.cleanUp()
        }
    }

    @Test("background launch and unchanged contexts defer presentation and inventory scans")
    func backgroundLaunch() async throws {
        let env = try await StatusEnv(isForeground: false)
        defer { env.cleanUp() }
        let content = try #require(env.services.content)
        let probes = WatchProgressCacheTests.Probes()
        let files = env.services.fileCache.fileStore
        content.progressSource.exists = { type, name in probes.record(); return files.exists(type, name) }
        await env.services.launch()
        await content.waitForWork()
        let head = try #require(env.services.receiver.head)
        #expect(env.services.fileCache.hasDurableWatchSelection)
        #expect(env.services.songs.songs.isEmpty)
        for _ in 0..<4 {
            env.session.applyContext(try head.encode())
            env.services.receiver.resume()
            content.resume()
            await env.services.receiver.waitForImport()
            await content.waitForWork()
        }
        let backgroundReads = probes.count
        #expect(backgroundReads == 0)
        env.services.isForeground = true
        await env.services.refresh()
        await content.waitForWork()
        #expect(probes.count >= 3)
        #expect(env.services.library.progress().music.downloaded == 1)
        #expect(!env.services.songs.songs.isEmpty)
    }

    @Test("background file delivery persists its receipt before completing without progress scans")
    func backgroundDelivery() async throws {
        let env = try await StatusEnv(isForeground: false)
        defer { env.cleanUp() }
        let content = try #require(env.services.content)
        let probes = WatchProgressCacheTests.Probes()
        content.progressSource.exists = { _, _ in probes.record(); return false }
        await env.services.launch()
        await content.waitForWork()
        let head = try #require(env.services.receiver.head)
        let directory = env.metadata.root.appending(path: "content")
        let source = env.metadata.root.appending(path: "incoming")
        try Data("incoming music".utf8).write(to: source)
        let fingerprint = try WatchContentFile.fingerprint(source)
        let file = WatchContentFile(head: head, type: .music, filename: "m1.mp3", bytes: fingerprint.bytes, digest: fingerprint.digest)
        var sent = [WatchContentReceipt]()
        let session = WatchPhoneSession(library: env.services.receiver, libraryTransport: .init(
            available: { true }, outstanding: { [] }, enqueue: { if let receipt = WatchContentReceipt(dictionary: $0) { sent.append(receipt) } }),
            sessionState: { (true, false) }, contentDirectory: directory)
        session.content = content
        env.forwarder.session = session
        session.receiveFile(source, metadata: try file.encode())
        var completed = false
        session.updateBackgroundLifetime()
        session.lifetime.hold {
            #expect(content.receipts.contains(.init(file: file, status: .delivered)))
            #expect(file.matches(env.services.fileCache.fileStore.fileURL(file.type, file.filename)))
            completed = true
        }
        try await PlayerStoreTests.waitFor { completed }
        let saved = try JSONDecoder().decode([WatchContentReceipt].self, from: Data(contentsOf: directory.appending(path: "receipts.json")))
        #expect(saved == [.init(file: file, status: .delivered)])
        #expect(sent == saved)
        let deliveryReads = probes.count
        #expect(deliveryReads == 0)
        // route a lost receipt query through the real delegate after the file has committed.
        var query = try file.encode()
        query["kind"] = "watchContentQuery"
        session.session(WCSession.default, didReceiveUserInfo: query)
        try await PlayerStoreTests.waitFor {
            let active = session.contentActivity.count
            return active == 0
        }
        await content.waitForWork()
        #expect(sent == saved + saved)
        let queryReads = probes.count
        #expect(queryReads == 0)
    }

    @Test("a rejected stale context resumes delivery under the current accepted selection")
    func staleBackgroundContext() async throws {
        let env = try await StatusEnv(isForeground: false)
        defer { env.cleanUp() }
        await env.services.launch()
        let snapshot = try #require(env.services.receiver.snapshot)
        let previous = snapshot.head
        let head = WatchLibraryHead(publisher: previous.publisher, revision: previous.revision + 1,
                                    libraryID: previous.libraryID, playlistIDs: previous.playlistIDs, metadataReady: true)
        let next = WatchLibrarySnapshot(head: head, libraryData: snapshot.libraryData)
        let source = env.metadata.root.appending(path: "source")
        try JSONEncoder().encode(next).write(to: source)
        _ = try WatchLibraryReceiver.stage(source, directory: env.metadata.inbox)
        env.session.applyContext(try head.encode())
        await env.services.receiver.waitForImport()
        let content = try #require(env.services.content)
        await content.waitForWork()
        env.session.applyContext(try previous.encode())
        await env.services.receiver.waitForImport()
        #expect(env.services.receiver.head == head)
        try Data("incoming".utf8).write(to: source)
        let fingerprint = try WatchContentFile.fingerprint(source)
        let file = WatchContentFile(head: head, type: .music, filename: "m1.mp3", bytes: fingerprint.bytes, digest: fingerprint.digest)
        try WatchContentReceiver.stage(source, file: file, directory: env.metadata.root.appending(path: "content"))
        await content.settledStaged(file)
        #expect(content.receipts.contains(.init(file: file, status: .delivered)))
        #expect(file.matches(env.services.fileCache.fileStore.fileURL(file.type, file.filename)))
    }

    @Test("startup restores configuration before offering setup", arguments: [false, true])
    func downloadStatusStartup(saved: Bool) async throws {
        let env = try await StatusEnv(saved: saved)
        defer { env.cleanUp() }
        #expect(env.services.library.presentation(isConfigured: false) == .loading)
        #expect(env.services.library.progress().state == .preparing)
        await env.services.launch()
        #expect(env.services.library.presentation(isConfigured: false) == (saved ? .ready : .setup))
        #expect(env.services.library.progress().state == (saved ? .waiting : .setup))
        #expect(env.services.library.progress().music.downloaded == (saved ? 1 : 0))
        #expect(env.services.library.progress().music.total == (saved ? 2 : 0))
    }

    @Test("unchanged contexts preserve download counts and phone status during refresh",
          arguments: [WatchLibraryProgress.State.waiting, .needsPhoneSync, .storageFull, .failed, .ready])
    func unchangedContextProgress(state: WatchLibraryProgress.State) async throws {
        let env = try await StatusEnv()
        defer { env.cleanUp() }
        if state == .ready {
            try env.services.fileCache.fileStore.write(.music, "m1.mp3", data: PlayerStoreTests.musicBytes)
        }
        await env.services.launch()
        let head = try #require(env.services.receiver.head)
        var reported = env.services.library.progress()
        reported.state = state
        let content = try #require(env.services.content)
        try content.receive(.init(head: head, sequence: 1, overall: reported, playlists: ["p2": reported]))
        let expected = env.services.library.progress()
        #expect(expected.state == state)
        for _ in 0..<2 {
            env.session.applyContext(try head.encode())
            #expect(env.services.library.progress() == expected)
            #expect(env.services.library.progress(playlistID: "p2") == expected)
            // activation and file release callbacks may resume content before metadata finishes.
            content.resume()
            #expect(env.services.library.progress() == expected)
            await env.services.receiver.waitForImport()
            #expect(env.services.library.progress() == expected)
            #expect(env.services.library.presentation(isConfigured: false) == .ready)
        }
        await env.services.refresh()
        #expect(env.services.library.progress() == expected)
    }

    @Test("an accepted unconfigured phone head still offers setup and preserves saved music")
    func unconfiguredContextProgress() async throws {
        let env = try await StatusEnv()
        defer { env.cleanUp() }
        await env.services.launch()
        let old = try #require(env.services.receiver.head)
        let head = WatchLibraryHead(publisher: old.publisher, revision: old.revision + 1, libraryID: nil, playlistIDs: [])
        env.session.applyContext(try head.encode())
        #expect(env.services.library.progress().state == .waiting)
        await env.services.receiver.waitForImport()
        #expect(env.services.library.progress().state == .setup)
        #expect(env.services.library.progress().music.downloaded == 1)
        #expect(env.services.library.presentation(isConfigured: false) == .ready)
        #expect(env.services.fileCache.fileStore.exists(.music, "m0.mp3"))
    }

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
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
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
        await services.content?.settledStaged(file)
        #expect(receipts.last?.status == .storageFull)
        #expect(!env.watchFiles.exists(file.type, file.filename))
        #expect(services.artwork.artworkURL("a1.jpg") == nil)
        capacity = 1_000_000_000
        env.now += 3_600
        // storage-full admission asks for redelivery; the phone retains the desired job.
        try await queue.settledReceive(try #require(receipts.last))
        await queue.settledResume()
        try WatchContentReceiver.stage(source, file: file, directory: inbox)
        await services.refresh()
        await services.content?.waitForWork()
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
